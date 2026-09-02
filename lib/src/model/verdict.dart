import 'package:meta/meta.dart';

import 'on_failure.dart';

/// How one step ended.
///
/// Sealed, so every place that reacts to a verdict must handle all three cases. Adding a fourth
/// breaks the build at every such place instead of falling into somebody's default branch.
///
/// **ONE FAILURE, NOT ONE VERDICT PER OUTCOME OF ONE.** A step that failed and ended the run, a
/// step that failed and was carried to the end as a problem, and a step that failed and was only
/// noted are three classes for one thing. What differs between them is not what the step did — it
/// failed — but what the program said should happen next, and how loudly it is written down. Both
/// of those are recorded elsewhere, and a verdict apiece restates them here.
@immutable
sealed class Verdict {
  const Verdict();

  /// A short lower-case word naming this verdict, used in the record and in the command line
  /// output.
  String get label;

  /// Whether the run may continue past this step.
  ///
  /// For a failure this is not the verdict's own property. It is what the program's [OnFailure] said
  /// for that row, which is why [Failed] is told rather than asked.
  bool get continues;
}

/// The step ran and its postcondition holds.
@immutable
final class Succeeded extends Verdict {
  /// Creates the verdict of a step that ran and whose postcondition holds.
  const Succeeded();

  @override
  String get label => 'ok';

  @override
  bool get continues => true;
}

/// The step did not run, because a condition the program declared did not hold.
///
/// This is not a failure. It is the answer to "does this machine need this step", and the operator
/// sees it as a skipped row together with [predicate], the name of the condition that skipped it.
@immutable
final class Skipped extends Verdict {
  /// Creates the verdict of a step that was not run because [predicate] did not hold.
  const Skipped(this.predicate);

  /// The registered name of the predicate that did not hold.
  final String predicate;

  @override
  String get label => 'skipped';

  @override
  bool get continues => true;
}

/// The step failed.
///
/// **One verdict for every failure, whatever the run did afterwards.** Whether the run went on is
/// the program's `on_failure` for that row, carried here as [policy] rather than turned into a
/// second and a third class. How bad it was is the level the failure was written at, which every
/// step does whatever a program file says. Each fact is stated once.
@immutable
final class Failed extends Verdict {
  /// Creates the verdict of a step that failed, under the program's [policy] for that row.
  const Failed(this.reason, {required this.policy});

  /// What the operator is told about the failure.
  final String reason;

  /// What the program said a failure of this step costs the run.
  final OnFailure policy;

  @override
  String get label => writtenFor(policy);

  @override
  bool get continues => policy == OnFailure.continueRun;
}
