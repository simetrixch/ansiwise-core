import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../domain/shell.dart';
import '../model/failures.dart';

/// Runs a command by starting the process, and never by way of a shell.
///
/// `runInShell` stays false and there is no code path that turns it on. The executable and its
/// arguments are handed to the operating system as a list, so a value carrying a quote, a dollar
/// sign, a semicolon or a newline arrives at the process as that value. There is no string for it to
/// be part of, which is why the whole class of quoting failures a shell script spends its comments
/// on cannot occur here.
///
/// **That holds for an elevated command too.** Raising a command to root by handing `sh -c` a line
/// that redirects a fixed path into the elevating tool is wrong three ways at once: the path is a
/// literal nobody can change, a missing file fails inside the shell and comes back as a non-zero
/// exit of the STEP's command, and the quoting the rest of this class exists to avoid is back. The
/// elevating tool is started directly, like any other executable, and the password reaches it
/// through its askpass helper, never on the standard input the command inherits.
final class RealShell implements Shell {
  /// Creates the shell a real run is given, told where an elevation password comes from.
  ///
  /// Required rather than defaulted. A shell built without thinking about elevation is one that
  /// silently reaches for somebody's home directory, which is the defect this exists to end;
  /// [Elevation.unconfigured] is how an installation says it never elevates, and it says it out
  /// loud.
  const RealShell({required this.elevation});

  /// Where the password comes from for a command that has to run as root.
  final Elevation elevation;

  /// What starts an elevated command, and what each argument of it is for.
  ///
  /// `--askpass` has sudo run the helper `SUDO_ASKPASS` names when, and only when, its policy wants
  /// a password, and read the password from that helper's output. The command's standard input is
  /// its own: a policy that lets the command run without a password would otherwise hand it the
  /// password as the first line of its input. `--reset-timestamp` drops any credential this machine
  /// cached, so a run behaves the same whether or not somebody typed a password on that machine
  /// minutes ago. `--` ends the options, so a command whose own name begins with a dash is still the
  /// command.
  static const List<String> elevatedPrefix = <String>['--askpass', '--reset-timestamp', '--'];

  @override
  Future<CommandResult> run(Command command) async {
    final String executable;
    final List<String> arguments;
    final Map<String, String> environment;
    // Prepared BEFORE the process is started, so a command that cannot be raised to root never runs
    // at all. Started first and elevated afterwards, the operator would read the tool's own failure
    // and go looking for a problem that is not in it.
    final _PasswordChannel? channel;

    if (command.elevated) {
      final String? password = elevation.password;
      if (password == null) {
        throw ElevationUnavailable(
          '${command.argv.join(' ')} has to run as root, and nothing says where the elevation '
          'password comes from\n'
          'the installation\'s configuration names one of two sources under "elevation": '
          '"password_from_caller: true", and then whoever starts the run sends it beside the '
          'answers, or "password_file:" with a path on this machine',
        );
      }
      channel = await _PasswordChannel.open(password, command);
      executable = 'sudo';
      arguments = elevatedArgumentsFor(command);
      environment = <String, String>{...command.environment, 'SUDO_ASKPASS': channel.helper};
    } else {
      channel = null;
      executable = command.executable;
      arguments = command.arguments;
      environment = command.environment;
    }
    try {
      return await _start(command, executable, arguments, environment);
    } finally {
      await channel?.close();
    }
  }

  Future<CommandResult> _start(
    Command command,
    String executable,
    List<String> arguments,
    Map<String, String> environment,
  ) async {
    final Stopwatch watch = Stopwatch()..start();
    final Process process = await Process.start(
      executable,
      arguments,
      workingDirectory: command.workingDirectory,
      // Added to the environment rather than replacing it: null means the parent's environment is
      // passed through unchanged, and a map is merged on top of it.
      //
      // For an ELEVATED command this reaches sudo and no further — sudo resets what it passes on —
      // so the same pair is set again above, on the far side of that reset. It stays here as well
      // because sudo itself reads its own environment, and a variable meant for the command is
      // harmless there.
      environment: environment.isEmpty ? null : environment,
      runInShell: false,
    );

    // Both streams are drained while the process is still running. A process whose output fills the
    // pipe buffer blocks on its next write until somebody reads, so collecting the output only after
    // waiting for the exit code deadlocks — and only once the output is large enough, which on a
    // deployment it eventually is.
    final Future<String> out = process.stdout.transform(_decoder).join();
    final Future<String> err = process.stderr.transform(_decoder).join();
    // Read at the exit and registered before anything is written: Dart destroys the input pipe in the
    // same turn that reports the exit (handleExit in the SDK's process_patch.dart) and drops what it
    // had not written yet without an error, so only that moment tells a delivered input from a cut one.
    final _Delivery delivery = _Delivery();
    final Future<bool> deliveredByExit = process.exitCode.then((_) => delivery.written);
    // Fed concurrently: a child can fill stdout before it finishes reading a large input.
    final Future<void> writing = _writeInput(process, command.stdin, delivery);

    final int exitCode = await _waitFor(process, command);
    await writing;
    if (command.stdin != null && exitCode == 0 && !await deliveredByExit) {
      throw InputUndelivered(command.argv);
    }
    watch.stop();

    return CommandResult(
      exitCode: exitCode,
      stdout: await out,
      stderr: await err,
      elapsed: watch.elapsed,
    );
  }

  /// Writes [input], then closes the pipe, which is the command's end of input.
  ///
  /// [delivery] turns written once every byte is in the pipe and before it is closed, so a command
  /// that reads to the end of its input cannot exit before that.
  static Future<void> _writeInput(Process process, String? input, _Delivery delivery) async {
    try {
      if (input != null) process.stdin.write(input);
      await process.stdin.flush();
      delivery.written = true;
      await process.stdin.close();
    } on IOException {
      // A command that stopped reading: its exit code, or InputUndelivered, reports it.
    }
  }

  /// Malformed bytes become the replacement character instead of throwing. A command that writes
  /// something that is not UTF-8 has still run, and losing the whole run over one bad byte in a log
  /// line would be the wrong trade.
  static const Utf8Decoder _decoder = Utf8Decoder(allowMalformed: true);

  Future<int> _waitFor(Process process, Command command) async {
    final Duration? timeout = command.timeout;
    if (timeout == null) {
      return process.exitCode;
    }
    try {
      return await process.exitCode.timeout(timeout);
    } on TimeoutException {
      // Killed and then reaped, not abandoned. A command left running past its deadline goes on
      // changing the machine while the run that started it is already reporting a failure, and the
      // operator has no way of knowing that is happening.
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      throw TimeoutException('${command.argv.join(' ')} did not finish and was killed', timeout);
    }
  }
}

/// The way the elevation password takes to sudo, and to nothing else.
///
/// A directory only this account can open (`mktemp -d` makes it so), holding a named pipe and the
/// askpass [helper] that reads it. sudo runs the helper as the invoking user when its policy wants a
/// password (classic sudo `tgetpass.c` `sudo_askpass`, sudo-rs `src/pam/askpass.rs`), so the
/// password passes through the pipe once and is never at rest in a file. The pipe is removed as it
/// is read, so a second ask after a refused password fails at once instead of waiting.
final class _PasswordChannel {
  _PasswordChannel._(this._directory);

  final String _directory;
  late final Future<void> _serving;
  bool _asked = false;

  /// The askpass helper sudo is pointed at.
  String get helper => '$_directory/askpass';

  String get _pipe => '$_directory/password';

  static Future<_PasswordChannel> open(String password, Command command) async {
    final ProcessResult made = await Process.run('mktemp', <String>[
      '-d',
      '-t',
      'ansiwise-elevation.XXXXXXXXXX',
    ]);
    if (made.exitCode != 0) {
      throw ElevationUnavailable(
        '${command.argv.join(' ')} has to run as root, and no private directory could be made to '
        'hand sudo its password: mktemp -d answered ${made.exitCode}',
      );
    }
    final _PasswordChannel channel = _PasswordChannel._((made.stdout as String).trim());
    try {
      await File(channel.helper).writeAsString('#!/bin/sh\nexec cat "\${0%/*}/password"\n');
      for (final List<String> step in <List<String>>[
        <String>['chmod', '700', channel.helper],
        <String>['mkfifo', '-m', '600', channel._pipe],
      ]) {
        final ProcessResult done = await Process.run(step.first, step.sublist(1));
        if (done.exitCode != 0) {
          throw ElevationUnavailable(
            '${command.argv.join(' ')} has to run as root, and the way its password takes to sudo '
            'could not be prepared: ${step.join(' ')} answered ${done.exitCode}',
          );
        }
      }
    } on Object {
      await Directory(channel._directory).delete(recursive: true);
      rethrow;
    }
    channel._serving = channel._serve(password);
    return channel;
  }

  // Opening the pipe to write waits until the helper opens it to read.
  Future<void> _serve(String password) async {
    final RandomAccessFile pipe = await File(_pipe).open(mode: FileMode.writeOnly);
    _asked = true;
    try {
      await File(_pipe).delete();
      await pipe.writeString('$password\n');
    } on FileSystemException {
      // A helper that went away before reading: sudo's refusal and exit code say so.
    } finally {
      await pipe.close();
    }
  }

  /// Releases a writer nobody asked for, where sudo let the command run without a password, and
  /// removes the directory.
  Future<void> close() async {
    if (!_asked) {
      try {
        await File(_pipe).openRead().drain<void>();
      } on FileSystemException {
        // The helper asked after all, and the pipe went with its one answer.
      }
    }
    await _serving;
    await Directory(_directory).delete(recursive: true);
  }
}

/// Whether every byte of a command's input reached its pipe.
final class _Delivery {
  bool written = false;
}

/// What `sudo` is given so that [command] runs as root AND sees the variables it was promised.
///
/// Named and separate because it is a decision rather than plumbing, and a decision with no name of
/// its own can only be asserted by starting a real process.
///
/// **`env` appears wherever the command carries variables, and only then.** sudo resets the
/// environment it passes on — that is its purpose, and asking an installation to weaken it in its
/// sudoers would trade a real guarantee for a convenience. So the variables are set on the far side
/// of that reset: `env` runs as root, sets them, and execs the command.
///
/// Without it a package install passes its own "do not ask me anything", runs as root with the
/// variable stripped, and apt is one config-file question away from stopping an unattended run at a
/// prompt nobody will ever answer.
List<String> elevatedArgumentsFor(Command command) => <String>[
  ...RealShell.elevatedPrefix,
  if (command.environment.isNotEmpty) ...<String>[
    'env',
    for (final MapEntry<String, String> each in command.environment.entries)
      '${each.key}=${each.value}',
  ],
  command.executable,
  ...command.arguments,
];
