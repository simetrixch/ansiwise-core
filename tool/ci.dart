/// The gate of this repository, on this machine.
///
/// ```
/// dart run tool/ci.dart    run every check
/// ```
///
/// It has to end with `ci: OK — every check green`.
///
/// THE FIRST THING IT DOES IS REFUSE THE WRONG TOOLCHAIN. The pin names the one Dart version the
/// checks are true against, and every tool this gate starts is this process's own SDK — the real
/// toolchain launches `Platform.resolvedExecutable`. So the pin is enforced by reading this
/// process's version and refusing every other, with the found and the expected version in the
/// refusal.
///
/// WHAT IT IS MADE OF LIVES IN package:ansiwise_checks_gate, and this file is the composition root:
/// it finds the repository, chooses the real toolchain, and prints the verdict. The gate was
/// carried under tool/gate/ here and in ansiwise-cli until the two copies had drifted in five
/// files. Nothing about the ORDER of a run needed the copy — this program is started after the
/// package it sits in has been resolved, in every script and every workflow that starts it, and the
/// resolution the gate itself performs is the one over every package of the repository.
library;

import 'dart:io';

import 'package:ansiwise_checks_gate/ansiwise_checks_gate.dart';

/// Runs the gate and answers non-zero when anything is wrong.
Future<void> main(List<String> arguments) async {
  if (arguments.isNotEmpty) {
    stderr.writeln('ci: FAIL — unknown option ${arguments.first} (this gate takes no options)');
    exit(2);
  }

  final String? refusal = dartVersionRefusal(running: Platform.version, pinned: dartVersion);
  if (refusal != null) {
    stderr.writeln('ci: FAIL — $refusal');
    exit(1);
  }

  final Directory repository = packageOfToolScript(Platform.script);
  const GateLog log = StdoutGateLog();

  // BEFORE ANYTHING RUNS, because a suite cannot report a check that is not in it. Each package
  // declares its checks and carries the one that holds the declaration against the disk; what that
  // one cannot do is notice that the file holding it is gone, and this is where that is noticed.
  log.heading('declared checks');
  final List<String> undeclared = undeclaredSuites(dartPackagesIn(repository));
  if (undeclared.isNotEmpty) {
    for (final String refusal in undeclared) {
      stderr.writeln('  $refusal');
    }
    stderr.writeln('ci: FAIL — declared checks');
    exit(1);
  }
  stdout.writeln(
    'every package with a suite declares its checks and carries the check that reads it',
  );
  final GateVerdict verdict = await PackageGate(
    toolchain: const RealDartToolchain(),
    packages: dartPackagesIn(repository),
    log: log,
    analysisRoot: repository.path,
  ).run();

  log.heading('verdict');
  if (verdict.green) {
    stdout.writeln(verdict.line);
    return;
  }
  stderr.writeln(verdict.line);
  exitCode = 1;
}
