import 'dart:io';

import '../domain/shell.dart';
import '../model/failures.dart';
import 'package:path/path.dart' as p;

import '../domain/files.dart';
import 'permissions.dart';

/// The file system of the machine the run is on.
///
/// The one method with anything in it is [write], which reads the file back and compares. Everything
/// else is a call through.
final class RealFiles implements Files {
  /// Creates the file system a real run is given.
  ///
  /// [asRoot] is what an ELEVATED call is performed through, and it is optional because the first
  /// thing a run reads is its own configuration, which needs no root and is read before anything
  /// knows where an elevation password would come from. A call asking for elevation without one is
  /// refused by name rather than attempted and failed on a permission error nobody can act on.
  const RealFiles({this.asRoot});

  /// What an elevated call is performed through, or null where this file system was given none.
  final Shell? asRoot;

  /// Runs [argv] as root, or refuses saying this file system was given no way to.
  Future<CommandResult> _root(List<String> argv, {required bool observes}) async {
    final Shell? shell = asRoot;
    if (shell == null) {
      throw ElevationUnavailable(
        '${argv.join(' ')} has to run as root, and this file system was given no way to run '
        'anything as root\n'
        'the run that composed it did so before its elevation was known, which is the case for the '
        'configuration read at start-up and for nothing else',
      );
    }
    final CommandResult answer = await shell.run(
      Command.detailed(argv.first, arguments: argv.sublist(1), observes: observes, elevated: true),
    );
    if (!answer.ok) {
      throw CommandFailed(argv: argv, exitCode: answer.exitCode, stdout: '', stderr: answer.stderr);
    }
    return answer;
  }

  @override
  Future<bool> exists(String path, {bool elevated = false}) async {
    if (elevated) {
      // The exit code is the answer, so this one does not go through _root: a path that is not
      // there is a legitimate answer rather than a failed command.
      final CommandResult answer = await _asRootOrRefuse(<String>[
        'test',
        '-e',
        path,
      ], observes: true);
      return answer.ok;
    }
    return await File(path).exists() || await Directory(path).exists();
  }

  /// The same refusal as [_root], for the one call whose non-zero exit is an answer.
  Future<CommandResult> _asRootOrRefuse(List<String> argv, {required bool observes}) async {
    final Shell? shell = asRoot;
    if (shell == null) {
      throw ElevationUnavailable(
        '${argv.join(' ')} has to run as root, and this file system was given no way to run '
        'anything as root',
      );
    }
    return shell.run(
      Command.detailed(argv.first, arguments: argv.sublist(1), observes: observes, elevated: true),
    );
  }

  @override
  Future<String> read(String path, {bool elevated = false}) async => elevated
      ? (await _root(<String>['cat', '--', path], observes: true)).stdout
      : File(path).readAsString();

  @override
  Future<void> write(
    String path,
    String content, {
    required int mode,
    bool elevated = false,
  }) async {
    if (elevated) {
      return _writeAsRoot(path, content, mode: mode);
    }
    final File file = File(path);
    if (!await file.exists()) {
      // Created empty and given its bits before it holds anything. Writing first and setting the
      // bits afterwards leaves a file that is meant to be private readable by everyone for the
      // moment in between, and that moment is exactly when the secret is in it.
      await file.create();
    }
    await setPermissions(path, mode);
    await file.writeAsString(content, flush: true);

    // The write is verified by reading the file back. A write that reported success and changed
    // nothing looks like success at every other layer: the call returns, the step's postcondition is
    // asked about the machine and finds the old content, and the failure is reported as the step
    // being wrong rather than as the file not having been written.
    final String written = await file.readAsString();
    if (written != content) {
      throw FileSystemException('the file does not hold what was just written to it', path);
    }
  }

  @override
  Future<void> delete(String path, {bool elevated = false}) async {
    if (elevated) {
      // -f so that a path that is not there is not an error, which is what this promises.
      await _root(<String>['rm', '-rf', '--', path], observes: false);
      return;
    }
    final File file = File(path);
    if (await file.exists()) {
      await file.delete();
      return;
    }
    final Directory directory = Directory(path);
    if (await directory.exists()) {
      // A directory goes with what is in it. The caller asked for the path to be gone, and a
      // non-recursive delete would refuse every directory that is not already empty.
      await directory.delete(recursive: true);
    }
  }

  @override
  Future<void> createDirectory(String path, {required int mode, bool elevated = false}) async {
    // A DIRECTORY THAT IS ALREADY THERE IS NOT THIS CALL'S TO RE-PERMISSION. The mode belongs to
    // what this call CREATES: a caller asking for a file under a path says how the directory it had
    // to invent should stand, not how a directory the machine already keeps should stand.
    //
    // WHAT IT COST TO LEARN. Every step that writes a file goes through here (FileStep.apply makes
    // the directory first, so no step has to), and a program rendering a scratch manifest to
    // `/tmp/<name>.yaml` therefore asked for `/tmp` at the file's own mode. Unprivileged that is a
    // refusal — `chmod returned 1, path = '/tmp'` — and a deployment stopped on it. Elevated it
    // SUCCEEDS, and that is the worse half: `install -d -m 0755 /tmp` takes the sticky bit off the
    // one directory on a machine that most needs it, so every account could then delete every other
    // account's files there. Nothing would have reported it.
    if (await _directoryThere(path, elevated: elevated)) {
      return;
    }
    if (elevated) {
      await _root(<String>[
        'install',
        '-d',
        '-m',
        mode.toRadixString(8).padLeft(4, '0'),
        path,
      ], observes: false);
      return;
    }
    await Directory(path).create(recursive: true);
    await setPermissions(path, mode);
  }

  /// Whether a DIRECTORY stands at [path] — `-d` and not `-e`, because a file standing where a
  /// directory is wanted is not a directory this call may leave alone.
  Future<bool> _directoryThere(String path, {required bool elevated}) async {
    if (elevated) {
      return (await _asRootOrRefuse(<String>['test', '-d', path], observes: true)).ok;
    }
    return Directory(path).exists();
  }

  @override
  Future<List<String>> list(String path, {bool elevated = false}) async {
    final List<String> names = elevated
        ? <String>[
            for (final String line in (await _root(<String>[
              'ls',
              '-A',
              '--',
              path,
            ], observes: true)).stdout.split('\n'))
              if (line.trim().isNotEmpty) line.trim(),
          ]
        : <String>[
            await for (final FileSystemEntity entry in Directory(path).list(followLinks: false))
              p.basename(entry.path),
          ];
    // Sorted, because the order the file system hands entries back in is not stable. A step that
    // compares one listing against another would otherwise see a change that is not there.
    names.sort();
    return names;
  }

  /// Writes [content] to a path only root may write, and proves it arrived.
  ///
  /// **The content goes through a file this account owns and never through a command line.** A value
  /// on an argument list stands in the process listing of every account on the machine, and some of
  /// what is written this way is a credential. The staging file is created with 0600 BEFORE anything
  /// is put in it, so the moment where a secret sits in a world-readable file does not exist.
  ///
  /// `install` copies and sets the bits in one act, so the destination never exists with the wrong
  /// permissions, which is the same property the unelevated write has.
  Future<void> _writeAsRoot(String path, String content, {required int mode}) async {
    final Directory staging = await Directory.systemTemp.createTemp('ansiwise-');
    final File carrier = File('${staging.path}/content');
    try {
      await carrier.create();
      await setPermissions(carrier.path, 0x180);
      await carrier.writeAsString(content, flush: true);

      await _root(<String>[
        'install',
        '-m',
        mode.toRadixString(8).padLeft(4, '0'),
        carrier.path,
        path,
      ], observes: false);

      // Read back through the same door it was written through, for the reason the unelevated write
      // reads back: a write that reported success and changed nothing looks like success at every
      // other layer.
      final String written = (await _root(<String>['cat', '--', path], observes: true)).stdout;
      if (written != content) {
        throw FileSystemException('the file does not hold what was just written to it', path);
      }
    } finally {
      await staging.delete(recursive: true);
    }
  }
}
