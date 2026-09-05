/// The analyzer and the formatter, over every Dart package of this repository.
///
/// ```
/// dart run tool/analysis.dart
/// ```
///
/// The one check of this repository that is not a test, because it judges the analysis that
/// compiles the tests: a package it should have failed is a package whose suite does not run at
/// all. Everything it decides is in [AnalysisCheck] and [AnalysisReading], in
/// package:ansiwise_checks_gate; this is the composition root — it finds the packages, chooses the
/// real toolchain, prints what came back and answers with a status.
library;

import 'dart:io';

import 'package:ansiwise_checks_gate/ansiwise_checks_gate.dart';

/// Judges every package of this repository and answers non-zero when anything is wrong.
Future<void> main() async {
  final AnalysisReading reading = await AnalysisCheck(
    toolchain: const RealDartToolchain(),
    packages: dartPackagesIn(packageOfToolScript(Platform.script)),
  ).run();

  for (final AnalysisFinding finding in reading.findings) {
    stdout.writeln('  finding: $finding');
  }
  for (final String name in reading.notAnalysed) {
    stdout.writeln(
      '  NOT ANALYSED: $name — nothing here resolved its dependencies, so the analyzer would answer '
      'with one error per import and the formatter with every file at the page width it falls back '
      'to, and neither answer would be about the code. Resolving it with the SDK its own pubspec '
      'asks for is what opens it to this check.',
    );
  }

  if (reading.green) {
    stdout.writeln(reading.verdictLine);
    return;
  }
  stderr.writeln(reading.verdictLine);
  exitCode = 1;
}
