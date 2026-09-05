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
/// elevating tool is started directly, like any other executable, and the password reaches it on
/// its standard input.
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
  /// `--stdin` reads the password from standard input instead of the terminal, because there is no
  /// terminal. `--reset-timestamp` drops any credential this machine cached, so a run behaves the
  /// same whether or not somebody typed a password on that machine minutes ago. `--prompt=` empties
  /// the prompt, so nothing is written to standard error that a step would then record as output.
  /// `--` ends the options, so a command whose own name begins with a dash is still the command.
  static const List<String> elevatedPrefix = <String>[
    '--stdin',
    '--reset-timestamp',
    '--prompt=',
    '--',
  ];

  @override
  Future<CommandResult> run(Command command) async {
    final Stopwatch watch = Stopwatch()..start();

    final String executable;
    final List<String> arguments;
    // Read BEFORE the process is started, so a command that cannot be raised to root never runs at
    // all. Started first and elevated afterwards, the operator would read the tool's own failure
    // and go looking for a problem that is not in it.
    final String? password;

    if (command.elevated) {
      password = elevation.password;
      if (password == null) {
        throw ElevationUnavailable(
          '${command.argv.join(' ')} has to run as root, and nothing says where the elevation '
          'password comes from\n'
          'the installation\'s configuration names one of two sources under "elevation": '
          '"password_from_caller: true", and then whoever starts the run sends it beside the '
          'answers, or "password_file:" with a path on this machine',
        );
      }
      executable = 'sudo';
      arguments = elevatedArgumentsFor(command);
    } else {
      password = null;
      executable = command.executable;
      arguments = command.arguments;
    }

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
      environment: command.environment.isEmpty ? null : command.environment,
      runInShell: false,
    );

    if (password != null) {
      await _answerThePrompt(process, password);
    }

    // Both streams are drained while the process is still running. A process whose output fills the
    // pipe buffer blocks on its next write until somebody reads, so collecting the output only after
    // waiting for the exit code deadlocks — and only once the output is large enough, which on a
    // deployment it eventually is.
    final Future<String> out = process.stdout.transform(_decoder).join();
    final Future<String> err = process.stderr.transform(_decoder).join();

    final int exitCode = await _waitFor(process, command);
    watch.stop();

    return CommandResult(
      exitCode: exitCode,
      stdout: await out,
      stderr: await err,
      elapsed: watch.elapsed,
    );
  }

  /// Writes [password] to the elevating tool and closes the stream.
  ///
  /// Closing is what makes the command underneath it see an ended standard input rather than a pipe
  /// nobody ever writes to again, which a tool that reads standard input would wait on forever.
  ///
  /// A write that fails is left alone on purpose, and this is not a swallowed failure: it happens
  /// when the tool has already exited — a wrong password, a machine where the account may not
  /// elevate — and the exit code that follows is the answer. Reporting the broken pipe instead
  /// would replace a failure an operator can act on with one about a stream.
  static Future<void> _answerThePrompt(Process process, String password) async {
    try {
      process.stdin.write('$password\n');
      await process.stdin.flush();
      await process.stdin.close();
    } on Object {
      return;
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
