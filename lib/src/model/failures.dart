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

/// A program row asked to keep the output of a command that answers with a secret.
///
/// **Raised by the recording shell, before the command starts.** That is the first moment the two
/// halves are known together: `keep_output` is a fact of the row and is fixed before the run, while
/// a command declares its output secret in the code of the step that builds it, and a step builds
/// its commands while it runs. Nothing earlier in the run can see both, so nothing earlier can
/// refuse.
///
/// **A dry run reaches it wherever the step issues that command from its check**, which is where a
/// step reads what is already on the machine — and a real run is admitted only where a dry run of
/// the same input came back green, so such a row is met before the run has changed anything. Where
/// a step issues that command from its apply alone, nothing before the real run can meet it: the
/// row is refused at that step, and what the run did up to there is taken back by the unwind.
///
/// What the command wrote is in neither this message nor the record. That it is never written down
/// is the whole of what the declaration says.
final class KeepOutputRefused extends EngineFailure {
  /// Records that the row running [step] says `keep_output` while [argv] answers with a secret.
  KeepOutputRefused({required this.step, required this.argv}) : super(_said(step, argv));

  static String _said(StepName step, List<String> argv) =>
      'the row running $step says keep_output, and "${argv.join(' ')}" answers with a secret\n'
      'a command that says its output is secret never reaches the record, so keeping this row as it '
      'stands would put a credential in a file every account on the machine may read — take '
      'keep_output off the row, or run a command that does not answer with the secret';

  /// The step whose command it was, which is the row that named the step.
  final StepName step;

  /// The command, as the record would have written it: the executable and its arguments, with
  /// every registered secret already hidden.
  final List<String> argv;
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
/// an operator reads first and having to open the record to find it is one step too many. The one
/// command whose words it does not carry is the one that says its output is a secret, and
/// [CommandFailed.withheldOutput] is how that is said.
final class CommandFailed extends EngineFailure {
  /// Records that [argv] returned [exitCode].
  CommandFailed({
    required this.argv,
    required this.exitCode,
    required String stdout,
    required String stderr,
  }) : super(_format(argv, exitCode, stdout, stderr));

  /// Records that [argv] returned [exitCode], with nothing of what it wrote.
  ///
  /// For a command whose `secretOutput` says its answer is a credential. This message reaches the
  /// record as the row's verdict, so quoting the output here would write down exactly what the
  /// declaration says is never written down — and saying nothing at all would leave a reader to
  /// take a failure with no output for a command that answered with none.
  CommandFailed.withheldOutput({required this.argv, required this.exitCode})
    : super(
        '${argv.join(' ')} returned $exitCode\n'
        'what it wrote is not here: this command answers with a secret, so nothing keeps its '
        'output',
      );

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

/// The closing header could not be put where everything looks for it.
///
/// A run's header is written under a second name and renamed over the real one, so a reader never
/// sees half a header. On Windows that rename fails while any process holds the real one open, and
/// a run whose rename is lost keeps the header it STARTED with — so everything that reads records
/// shows a run still going, for ever, while the process that would have said otherwise is gone.
/// Measured over the real binaries: 34 of 265 runs that had a reader lost it, against 0 of 100 that
/// had none. The run itself finished every time.
///
/// **Raised rather than passed over**, because of what the two answers cost. The record is not
/// merely incomplete here, it is WRONG about the one thing every reader asks it, and a caller told
/// nothing would go on to report a run that ended as one still going.
final class HeaderNotReplaced extends EngineFailure {
  /// Records that the header written to [pending] could not be put at [header], because [refused].
  HeaderNotReplaced({required this.pending, required this.header, required this.refused})
    : super(
        'the closing header of this run could not be put in place\n'
        '$header still holds the header this run started with, and the header it ended with is in '
        '$pending — the run itself finished, and only this rename was lost\n'
        'what the file system said: $refused',
      );

  /// Where the finished header is sitting instead.
  final String pending;

  /// Where it was meant to go, and what still holds the stale one.
  final String header;

  /// What the file system said the last time it refused.
  final String refused;
}

/// A run record this account owns is past the bound and will not go.
///
/// The number of records a machine keeps is held by removing the oldest ones past it, and a record
/// this account owns and cannot remove is a record that will be met again on every run from now
/// on. So the bound is not a bound, and a run that carried on would leave that unsaid.
///
/// **RAISED FOR THIS ACCOUNT'S OWN RECORDS AND NOTHING ELSE.** A record another account owns is not
/// this account's to remove, is not counted against the bound, and is named rather than refused —
/// the store of a machine that runs one program as root on a timer and another as the operator is
/// mostly root's, and refusing there would end every run the operator starts.
final class RecordNotRemoved extends EngineFailure {
  /// Records that the run record at [path] stayed, because the file system said [refused].
  RecordNotRemoved({required this.path, required this.refused})
    : super(
        'this account owns the run record $path and cannot remove it, so the number of records '
        'this machine keeps is not a bound it can hold\n'
        'what the file system said: $refused\n'
        'give the account this runs as the right to remove that directory, or remove it by hand',
      );

  /// The record that stayed.
  final String path;

  /// What the file system said the last time it refused.
  final String refused;
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
