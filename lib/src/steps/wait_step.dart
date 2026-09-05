import '../domain/step.dart';
import '../domain/step_context.dart';
import '../model/check_result.dart';
import '../model/failures.dart';
import '../model/step_plan.dart';

/// A step whose work is waiting for something to become true.
///
/// It supplies all three parts from one question: [holds]. That question is the postcondition, so
/// there is no way to write a wait whose verdict comes from anything else — which is the failure
/// this replaces. The shell it succeeds had a wait that reported success when more than zero pods
/// were running, and another that timed out, warned, and let the run continue on something nobody
/// had confirmed.
///
/// Here a wait that reaches its deadline fails, and what that failure costs is the program's
/// declared policy rather than the step's own opinion.
base mixin WaitStep on Step {
  /// How long to keep asking before giving up.
  Duration get deadline;

  /// How long to leave between asks.
  Duration get interval;

  /// What is being waited for, in the operator's words, for the plan and for the failure.
  String get waitingFor;

  /// Asks once, and says what it SAW where the answer was not the one waited for. Must change
  /// nothing.
  ///
  /// **`saw` is the difference between a timeout and a diagnosis.** A wait that reports only true or
  /// false throws away the one thing the machine said: a cluster answers within a second that a
  /// certificate authority has refused the mailbox by name, the step reports "waited 60s and it did
  /// not happen", and an operator is sent to look at a service that is working perfectly. Whatever
  /// the ask read instead of the answer belongs in `saw`, trimmed to what an operator can act on,
  /// and null where there is genuinely nothing to add.
  Future<({bool held, String? saw})> holds(StepContext context);

  /// Whether the wait is over, on a machine that may not carry what does the asking yet.
  ///
  /// **A wait is always on something an earlier step brings about**, so the tool it asks with is
  /// regularly not on the machine when the question is first put. Letting that escape as an exception
  /// is not a measurement: the step neither holds nor fails, it disappears — and the run stops on a
  /// stack trace where the truthful answer was "not yet, and here is why".
  ///
  /// No suite sees this, because a fake shell answers an argv without needing the executable to
  /// exist. It shows on a real machine carrying nothing yet: a program stops at its fourth step,
  /// asking with a tool the third step installs — in the mode whose whole purpose is to measure a
  /// machine before anything is done to it.
  ///
  /// The absence is carried rather than swallowed: the ask returns why, and the failure at the
  /// deadline says it instead of "did not answer in time", which would send an operator looking at a
  /// service that was never installed.
  ///
  /// **It carries no state.** A step is an immutable value object with a const constructor, so the
  /// reason is returned rather than remembered — a field here would take the const away from every
  /// step that waits.
  Future<({bool held, String? notAskable})> _ask(StepContext context) async {
    try {
      final ({bool held, String? saw}) asked = await holds(context);
      return (held: asked.held, notAskable: asked.saw);
    } on Object catch (why) {
      // The WHOLE reason, with its line breaks folded, because the useful half is usually not on
      // the first line: a failure to start a process names the error there and the command it could
      // not start below it. Keeping only the first line drops exactly the word an operator needs.
      return (held: false, notAskable: '$why'.split('\n').map((String l) => l.trim()).join(' '));
    }
  }

  @override
  Future<CheckResult> check(StepContext context) async =>
      (await _ask(context)).held ? CheckResult.satisfied(waitingFor) : const CheckResult.ready();

  @override
  Future<StepPlan> plan(StepContext context) async =>
      StepPlan.nothing('would wait up to ${deadline.inSeconds}s for $waitingFor');

  @override
  Future<void> apply(StepContext context) async {
    final DateTime giveUp = context.clock.now().add(deadline);
    while (true) {
      final ({bool held, String? notAskable}) asked = await _ask(context);
      if (asked.held) {
        return;
      }
      if (!context.clock.now().isBefore(giveUp)) {
        // The reason the last ask could not be put, OR what it read instead of the answer, where
        // there was one. Without it an operator whose command name is wrong is told the service did
        // not come up, and goes looking at a service rather than at the row — and an operator whose
        // machine stated the refusal in words is told only how long the waiting took.
        throw WaitedTooLong(
          waitingFor: asked.notAskable == null ? waitingFor : '$waitingFor — ${asked.notAskable}',
          deadline: deadline,
        );
      }
      await context.clock.sleep(interval);
    }
  }
}
