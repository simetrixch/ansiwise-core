import 'names.dart';

/// Something this framework refused, or could not do.
///
/// Sealed, so a caller that reacts to failures has to account for every kind, and a new kind breaks
/// the build at every such place rather than falling into a catch-all.
///
/// These are exceptions and not errors on purpose. Every one of them is a condition the engine is
/// built to meet and report — a program that does not add up, a step reaching for something the
/// mode forbids — and catching it in order to record it properly is the whole point. An error would
/// have to be left to crash the process, which would lose the record.
sealed class EngineFailure implements Exception {
  const EngineFailure(this.message);

  /// What went wrong, written for whoever has to act on it.
  final String message;

  @override
  String toString() => message;
}

/// A step tried to change something in a mode that does not allow changes.
///
/// This is the dry run's guarantee doing its work. Reaching this means a step performed a mutation
/// from inside a code path that a dry run enters — almost always its own check or plan — and the
/// port stopped it before it reached the machine.
final class MutationRefused extends EngineFailure {
  /// Records that [what] was refused because the run is only planning.
  const MutationRefused(this.what, {required this.step}) : super('refused while planning: $what');

  /// What the step tried to do.
  final String what;

  /// The step that tried.
  final StepName step;
}

/// A program file does not add up.
///
/// Raised by the loader before anything is looked at or touched: an unknown step name, an unknown
/// predicate, an argument a step does not accept, a required argument that is missing, a value of
/// the wrong kind, a failure policy that is not one of the three.
final class ProgramInvalid extends EngineFailure {
  /// Records that a program file is invalid, at [where], because [message].
  const ProgramInvalid(super.message, {required this.where});

  /// Where in the file the problem is, as far as it can be located.
  final String where;

  @override
  String toString() => '$where: $message';
}

/// The configuration says which plugins are active, and the answer does not add up.
///
/// Raised before a program file is even read, because which steps exist at all is decided here. It
/// carries every problem at once for the same reason the loader does: a configuration is fixed in
/// one pass rather than one error per attempt.
final class PluginRejected extends EngineFailure {
  /// Records that the active set was refused, because [message].
  const PluginRejected(super.message);
}

/// What an operator supplied for a program does not add up.
///
/// Raised before the gate and before the first step: an installation stopped halfway for a
/// value somebody could have typed at the start is the worst of both. Carries every problem at
/// once for the same reason the loader does.
final class AnswersRejected extends EngineFailure {
  /// Records that the answers were refused, because [message].
  const AnswersRejected(super.message);
}

/// A run was asked for that the gate does not allow yet.
///
/// The three modes gate each other, and the gate lives here rather than in whatever started the
/// run — so it holds for a person pressing a button and for another program calling the command
/// line alike. A gate in the user interface is a gate that can be walked around.
final class GateNotMet extends EngineFailure {
  /// Records that [wanted] was refused because [required] has not succeeded for this input.
  const GateNotMet({required this.wanted, required this.required})
    : super('$wanted needs a successful $required for the same input first');

  /// The mode that was asked for.
  final String wanted;

  /// The mode that has to have succeeded first.
  final String required;
}

/// A command has to run as root, and nothing usable says how.
///
/// Raised INSTEAD of starting the process. A command that cannot be raised to root and is started
/// anyway fails as the command itself, and then the operator reads a tool's output looking for a
/// problem that is not in it.
final class ElevationUnavailable extends EngineFailure {
  /// Records that a command could not be raised to root, because [message].
  const ElevationUnavailable(super.message);
}

/// A command returned something other than zero.
///
/// The message carries the command and what it wrote to standard error, because that pair is what
/// an operator reads first and having to open the record to find it is one step too many.
final class CommandFailed extends EngineFailure {
  /// Records that [argv] returned [exitCode].
  CommandFailed({
    required this.argv,
    required this.exitCode,
    required String stdout,
    required String stderr,
  }) : super(_format(argv, exitCode, stdout, stderr));

  static String _format(List<String> argv, int exitCode, String stdout, String stderr) {
    final String out = _bound(stdout.trim());
    final String err = _bound(stderr.trim());

    final StringBuffer buffer = StringBuffer('${argv.join(' ')} returned $exitCode');
    if (err.isNotEmpty) {
      buffer.write('\nstderr:\n$err');
    }
    if (out.isNotEmpty) {
      buffer.write('\nstdout:\n$out');
    }
    return buffer.toString();
  }

  static String _bound(String text) {
    if (text.isEmpty) return '';
    const int maxLines = 50;
    final List<String> lines = text.split('\n');
    if (lines.length <= maxLines) return text;
    final int toDrop = lines.length - maxLines;
    final Iterable<String> tail = lines.skip(toDrop);
    return '[dropped $toDrop lines of output]\n${tail.join('\n')}';
  }

  /// The command that failed.
  final List<String> argv;

  /// What it returned.
  final int exitCode;
}

/// A wait reached its deadline without what it was waiting for becoming true.
final class WaitedTooLong extends EngineFailure {
  /// Records that [waitingFor] did not become true within [deadline].
  WaitedTooLong({required this.waitingFor, required this.deadline})
    : super('waited ${deadline.inSeconds}s for $waitingFor and it did not happen');

  /// What was being waited for.
  final String waitingFor;

  /// How long it was waited for.
  final Duration deadline;
}

/// A request came back with a status the step does not accept.
final class RequestRefused extends EngineFailure {
  /// Records that [method] to [url] answered [status].
  RequestRefused({
    required this.method,
    required this.url,
    required this.status,
    required this.body,
  }) : super(_said(method, url, status, body));

  /// The sentence an operator reads, with the far side's own words IN it.
  ///
  /// A status names WHICH door was shut and never why. The other end has usually already answered
  /// the question the reader is about to ask — `{"pk":["This field is required."]}` names the
  /// defect exactly — and a message that drops it leaves them guessing at the one thing that was
  /// known. Quoting is safe HERE and only here: the body is redacted before it reaches this
  /// failure, which is precisely why [AnswerIncomplete] beside it carries no body at all.
  ///
  /// Long bodies are cut and SAY they were cut, with the full length: an HTML error page runs to
  /// kilobytes, and a record no one will read is as good as a record that says nothing.
  static String _said(String method, String url, int status, String body) {
    final String said = body.trim();
    if (said.isEmpty) return '$method $url answered $status with an empty body';
    const int cap = 600;
    final String shown = said.length <= cap
        ? said
        : '${said.substring(0, cap)}… (cut, ${said.length} characters in all)';
    return '$method $url answered $status: $shown';
  }

  /// The request method.
  final String method;

  /// Where it went.
  final String url;

  /// What came back.
  final int status;

  /// The body that came with it, redacted before it reaches the record.
  final String body;
}

/// An answer arrived and did not carry what the row named.
///
/// Not [RequestRefused]: the other end did its part and answered. What is missing is the VALUE this
/// row exists to take out of that answer — so the row publishes nothing, and whatever was meant to
/// read it later has nothing to read.
///
/// **The body is not carried here, and that is the point.** A row may be reading a credential out
/// of an answer, and a failure that quoted the body would put that credential into the record —
/// nothing hides a value that was never published. Where the body may ride along, the caller throws
/// [RequestRefused] instead and says so.
final class AnswerIncomplete extends EngineFailure {
  /// Records that an answer did not carry what was named, as [message] says.
  const AnswerIncomplete(super.message);
}

/// A machine role does not match the program.
final class RoleMismatch extends EngineFailure {
  /// Records that [program] does not apply to a machine of [role].
  const RoleMismatch({required this.program, required this.role, required this.applies})
    : super('$program applies to $applies, and this machine is $role');

  /// The program that was asked for.
  final String program;

  /// What this machine is.
  final String role;

  /// What the program says it applies to.
  final String applies;
}
