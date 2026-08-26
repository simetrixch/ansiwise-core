import '../domain/arguments.dart';
import '../domain/machine.dart';
import '../domain/recorder.dart';
import '../domain/step.dart';
import '../domain/step_context.dart';
import '../model/names.dart';
import '../model/run_event.dart';
import 'recording_ports.dart';
import 'redactor.dart';

/// Takes back what a failed run had already done, in reverse.
///
/// A machine cannot be rolled back. There is no transaction around installing a package, and
/// pretending otherwise is how a system claims a guarantee it cannot keep. What is achievable is
/// compensation: each step that can be taken back says how, and when a later step ends the run the
/// ones already applied are undone from the newest backwards.
///
/// Two rules make this safe rather than merely well-meant:
///
/// - **Only steps whose apply actually ran are undone.** A skipped step, a step that had nothing to
///   do, and a step that was only planned all changed nothing. Undoing one of those would be a
///   mutation nobody asked for, performed while cleaning up after a failure — the worst moment for
///   a surprise.
/// - **A step that cannot be taken back STOPS the unwind, and everything applied before it stands.**
///   It declared that in its own class or the program said `undo: false` for it, and either way the
///   run announced the boundary before it started.
///
/// **Why the boundary stops it instead of being passed over.** The steps run in order, so a step
/// that ran EARLIER can hold what a later one wrote — a directory holding a file, an account owning
/// a key, a container holding what was put in it. Undoing the earlier step therefore removes what
/// the later one left behind, which is exactly the thing the run has just said would survive.
/// Measured on a real installation: a run said before it started that from step 8 it could not be
/// taken back because what that step installs leaves the data it wrote behind, and then its unwind
/// deleted the thing that data sat inside, made four steps earlier. The record said two things that
/// cannot both be true.
///
/// **An undo that FAILS does not stop the rest, and that is a different question.** The boundary is
/// a fact known before the run and told to the operator; a failed undo is discovered while cleaning
/// up, and how much of that step still stands is exactly what nobody knows. Stopping on it would
/// leave more standing than the run ever announced, on a guess. So the remaining steps are still
/// undone and every failure is recorded.
final class Unwind {
  /// Creates an unwind against [machine], reporting to [recorder].
  const Unwind({
    required this.machine,
    required this.recorder,
    required this.redactor,
    this.logLevel = LogLevel.info,
  });

  /// What the steps acted on.
  final Machine machine;

  /// Where the events go.
  final Recorder recorder;

  /// What is removed on the way into the record.
  final Redactor redactor;

  /// The quietest level this run writes, carried from the runner.
  final LogLevel logLevel;

  /// Undoes [applied] from the newest backwards, and answers what is left standing.
  ///
  /// The list is in the order the steps ran; this walks it in reverse. [answers] is the same bag the
  /// run was started with, because a step that read an answer to decide what it wrote reads the same
  /// answer to decide what to take back — an undo given an empty bag would fail on the one path
  /// where failing is least affordable.
  ///
  /// The answer is the names of the steps still on the machine, in the order they ran: the first one
  /// that could not be taken back and everything applied before it. It is empty where the walk
  /// reached the beginning. **It is returned rather than logged**, because it is what somebody
  /// deciding what to do to the machine next reads, and that decision is not made out of log lines.
  Future<List<String>> undo(List<AppliedStep> applied, Facts facts, Arguments answers) async {
    for (int at = applied.length - 1; at >= 0; at -= 1) {
      final AppliedStep entry = applied[at];
      final Step step = entry.step;
      final RecordingLogger log = RecordingLogger(
        recorder: recorder,
        redactor: redactor,
        step: entry.name,
      );

      if (step is! ReversibleStep) {
        final String reason = step is IrreversibleStep
            ? step.irreversibleReason
            : 'the step does not say how it could be taken back';
        log.warn('not taken back: $reason');
        return _stopsHere(applied, at, log);
      }

      // The operator switched it off for this program. A step that CAN be undone is not always one
      // that SHOULD be — putting a configuration back over one a person has edited since is a
      // correct undo doing damage — and that judgement is about one installation, so it is made in
      // the program file.
      //
      // It is said here AND it was said before the run started, because a step whose undo is off is
      // part of what this run cannot take back. Learning that at the moment it is needed is learning
      // it too late.
      if (!entry.undo) {
        log.warn(
          'not taken back: this program says undo: false for this step, so what it did stands',
        );
        return _stopsHere(applied, at, log);
      }

      log.info('taking back');
      try {
        await step.undo(_contextFor(entry, facts, answers), entry.captured);
        log.info('taken back');
      } on Object catch (failure) {
        // EVERYTHING AN UNDO CAN THROW, and not only what implements Exception. An Error out of a
        // step's own undo — a cast, an index, a null — left this loop entirely and reached the
        // catch in [Runner.run], which closes a record holding no rows: one undo with a bug in it
        // stopped every remaining step being taken back and took the record with it.
        log.warn('could not be taken back: $failure');
      }
    }
    return const <String>[];
  }

  /// The names of everything from the beginning up to and including [at], said and then returned.
  ///
  /// The line is written under the step that stopped the walk, directly after the line saying it was
  /// not taken back, so a reader of the record meets the consequence beside the cause.
  List<String> _stopsHere(List<AppliedStep> applied, int at, RecordingLogger log) {
    final List<String> standing = <String>[
      for (final AppliedStep each in applied.take(at + 1)) each.name.value,
    ];
    final int before = standing.length - 1;
    log.warn(
      'the unwind stops here: what this step did stands, and so do the $before step(s) applied '
      'before it, because a step that ran earlier can hold what this one wrote — '
      '${standing.join(', ')} are still on this machine',
    );
    return standing;
  }

  StepContext _contextFor(AppliedStep entry, Facts facts, Arguments answers) => StepContext(
    shell: RecordingShell(
      machine.shell,
      recorder: recorder,
      redactor: redactor,
      step: entry.name,
      keepsOutput: entry.keepsOutput,
    ),
    files: RecordingFiles(machine.files, recorder: recorder, step: entry.name),
    http: RecordingHttp(machine.http, recorder: recorder, redactor: redactor, step: entry.name),
    clock: machine.clock,
    entropy: machine.entropy,
    log: RecordingLogger(
      recorder: recorder,
      redactor: redactor,
      step: entry.name,
      threshold: logLevel,
    ),
    step: entry.name,
    arguments: entry.arguments,
    answers: answers,
    facts: facts,
  );
}

/// A step whose apply ran, kept so it can be taken back.
final class AppliedStep {
  /// Records that [step], registered as [name], was applied with [arguments].
  const AppliedStep({
    required this.name,
    required this.step,
    required this.arguments,
    required this.captured,
    this.undo = true,
    this.keepsOutput = false,
  });

  /// The registered name, for the record.
  final StepName name;

  /// The instance that ran.
  final Step step;

  /// What it was given, so its undo sees the same values its apply did.
  final Arguments arguments;

  /// What the step read before it changed anything, handed back to its undo.
  ///
  /// Null for a step that is not reversible, which is the only case where nothing was read. For
  /// every other step this is what makes the undo a restoration rather than a second guess at a
  /// machine that has changed since.
  final Object? captured;

  /// Whether the program allows this entry to be taken back.
  ///
  /// Carried from the program rather than read off the step, because it is not a property of the
  /// step at all: the same step is undone in one installation and left standing in another.
  final bool undo;

  /// Whether the record keeps what this entry's commands said even on success.
  ///
  /// Carried from the program for the same reason [undo] is, so the undo of a row whose output is
  /// evidence leaves the same evidence its apply did.
  final bool keepsOutput;
}
