import 'package:meta/meta.dart';

import 'mode.dart';
import 'names.dart';
import 'standings.dart';
import 'step_record.dart';

/// What one run was and how it ended.
///
/// Written when the run begins and completed when it ends, so a run that was killed still leaves a
/// header and its steps rather than nothing at all.
@immutable
final class RunRecord {
  /// Creates the record of one run.
  const RunRecord({
    required this.id,
    required this.program,
    required this.mode,
    required this.argv,
    required this.start,
    required this.stage,
    required this.role,
    required this.fqdn,
    required this.commit,
    required this.fingerprint,
    this.resumes,
    this.waived = const <Mode>[],
    this.end,
    this.exitCode,
    this.steps = const <StepRecord>[],
    this.issues = const <String>[],
    this.leftStanding = const <String>[],
  });

  /// The run's identifier, unique on the machine that produced it.
  final RunId id;

  /// The program that was run.
  final ProgramName program;

  /// Which of the three modes it was run in.
  final Mode mode;

  /// How it was invoked, word for word.
  final List<String> argv;

  /// When it began, in UTC.
  final DateTime start;

  /// The steps this run applied and did NOT take back, by the name a program file writes.
  ///
  /// Empty for every run that either changed nothing or unwound what it changed. Not empty means the
  /// machine is in a state no run produced on purpose, and there are exactly two ways to get there.
  /// The unwind was deliberately not performed, and then this names every step that had acted. Or
  /// the unwind ran and stopped at a step it could not take back, and then this names that step and
  /// everything applied before it — which stand because a step that ran earlier can hold what a
  /// later one wrote, so taking it back would remove what the run has just said would survive.
  ///
  /// **A field and not a log line.** Whoever reads the result decides what to do to a machine next,
  /// and a warning among the log entries is not where that decision is made. A run that could have
  /// taken its steps back and did not says so where the outcome is stated.
  final List<String> leftStanding;

  /// The stage this installation is.
  final Stage stage;

  /// The role of the machine it ran against.
  final Role role;

  /// The installation's domain name.
  ///
  /// This is installation state and lives only on the machine. It is never written to a file that
  /// belongs in the repository.
  final Fqdn fqdn;

  /// The commit of the branch that was executing.
  ///
  /// This is what makes every [StepRecord.source] still meaningful weeks later: the line numbers
  /// are the line numbers of this commit, not of whatever the branch holds today.
  final String commit;

  /// What makes two runs the same input.
  ///
  /// Computed from the program, the arguments every step resolved to, and the commit. The gate asks
  /// for a clean dry run with this exact value: a real run is refused unless one exists, and
  /// changing any answer changes the value, so an operator cannot get a green dry for one set of
  /// answers and then run a different set.
  final String fingerprint;

  /// The run this one continues, or null when it starts fresh.
  ///
  /// **Resuming does not skip anything.** It runs the same program again, and every step that
  /// already did its work answers that there is nothing to do — which is what idempotence is for.
  /// Skipping to a remembered position would be faster and worse: a machine somebody touched between
  /// the two runs would never be re-measured, and the run would build on a state nobody checked.
  ///
  /// What this field is for is the record. Without it a resumed run is a second, unrelated run, and
  /// an operator reading the history sees two halves of one story with nothing joining them.
  final RunId? resumes;

  /// The proofs this run went without, named by the mode that would have produced each.
  ///
  /// Empty on a run that was gated normally, which is every run of the installation this platform
  /// was built for. An entry means an operator decided the gate did not apply to them, and it is
  /// written into the header where the run begins rather than worked out afterwards from what is
  /// missing — an absent proof and a waived one look identical from the outside, and only one of
  /// them was somebody's decision.
  final List<Mode> waived;

  /// When it ended, in UTC, or null while it is still running.
  final DateTime? end;

  /// What the process returned, or null while it is still running.
  final int? exitCode;

  /// One record per step that was reached.
  final List<StepRecord> steps;

  /// Everything reported as an issue, repeated at the run level.
  final List<String> issues;

  /// Whether the run has finished.
  bool get finished => end != null;

  /// Whether the run finished and reported nothing.
  bool get clean => exitCode == 0 && issues.isEmpty;

  /// How many of its rows were measured, how many were taken on trust, how many did not run.
  ///
  /// Counted from [steps] rather than stored, so it cannot fall out of step with the rows it counts.
  Standings get standings => Standings.of(steps.map((StepRecord each) => each.standing));

  /// Whether everything this run claims was measured, and nothing was waived.
  ///
  /// **The one question the whole record exists to answer honestly.** A single declared row, a
  /// single skipped one, or a waived gate all make this false, and a green exit code does not make
  /// it true — those are two different facts and a reader who conflated them would be told a run
  /// proved something it did not.
  bool get fullyProven => waived.isEmpty && standings.fullyProven;

  /// Orders two records with the newer one first, by when each began.
  ///
  /// **ONE ORDER FOR EVERYBODY WHO ORDERS RECORDS.** What a listing shows first and what a removal
  /// keeps have to be the same records, and two comparators drift: the day one of them changed, the
  /// machine would keep a set the operator's listing does not begin with.
  ///
  /// Two runs can begin within the same microsecond. The identifier breaks the tie so the order is
  /// total, and a list read twice does not come back in a different order the second time.
  static int newestFirst(RunRecord a, RunRecord b) {
    final int byStart = b.start.compareTo(a.start);
    return byStart != 0 ? byStart : b.id.value.compareTo(a.id.value);
  }

  /// A copy of this record with the closing fields filled in.
  RunRecord closed({
    required DateTime end,
    required int exitCode,
    required List<StepRecord> steps,
    required List<String> issues,
    List<String> leftStanding = const <String>[],
  }) => RunRecord(
    id: id,
    program: program,
    mode: mode,
    argv: argv,
    start: start,
    stage: stage,
    role: role,
    fqdn: fqdn,
    commit: commit,
    fingerprint: fingerprint,
    resumes: resumes,
    waived: waived,
    end: end,
    exitCode: exitCode,
    steps: steps,
    issues: issues,
    leftStanding: leftStanding,
  );
}
