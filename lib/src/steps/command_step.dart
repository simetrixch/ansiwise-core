import '../domain/shell.dart';
import '../domain/step.dart';
import '../domain/step_context.dart';
import '../model/failures.dart';
import '../model/step_plan.dart';

/// A step whose work is one command.
///
/// It supplies the plan and the apply; the step supplies the command and its own check. The check
/// stays with the step because it is the one part that cannot be derived: what proves that a
/// package was installed is not the exit code of the command that installed it.
///
/// A mixin and not a base class, because the base class slot is taken by the answer to whether the
/// step can be undone — and that answer has to be forced by the compiler, which only a superclass
/// can do.
base mixin CommandStep on Step {
  /// The command this step runs.
  Command commandFor(StepContext context);

  @override
  Future<StepPlan> plan(StepContext context) async {
    final Command command = commandFor(context);
    return StepPlan.argv(command.argv, workingDirectory: command.workingDirectory);
  }

  @override
  Future<void> apply(StepContext context) async {
    final Command command = commandFor(context);
    final CommandResult result = await context.shell.run(command);
    if (result.ok) {
      return;
    }
    // The verdict is written into the record, so the command that says its output is a secret is
    // reported by its exit code alone. Quoting it here would put in the record through the verdict
    // exactly what the recording shell one call down refused to put there as output.
    throw command.secretOutput
        ? CommandFailed.withheldOutput(argv: command.argv, exitCode: result.exitCode)
        : CommandFailed(
            argv: command.argv,
            exitCode: result.exitCode,
            stdout: result.stdout,
            stderr: result.stderr,
          );
  }
}
