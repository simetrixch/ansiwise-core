import '../domain/arguments.dart';
import '../domain/machine.dart';
import '../domain/recorder.dart';
import '../domain/resolved_program.dart';
import '../domain/predicate.dart';
import '../domain/step_context.dart';
import '../domain/logger.dart';
import '../model/failures.dart';
import '../model/mode.dart';
import '../model/names.dart';
import '../model/run_event.dart';
import '../model/run_record.dart';
import '../model/step_record.dart';
import '../model/verdict.dart';
import 'measurements.dart';
import 'predicate_evaluation.dart';
import 'recording_ports.dart';
import 'redactor.dart';
import 'step_execution.dart';
import 'unwind.dart';

/// Runs a program against a machine, in one of the three modes, and produces its record.
///
/// It does four things and delegates the rest: it refuses a program that does not apply to this
/// machine, it has the conditions measured once, it walks the steps applying the failure policy
/// each one declared, and when a step ends the run it has what was already done taken back.
///
/// What it never does is decide what a step means. A verdict comes from the step's own checked
/// postcondition, and what a failure costs comes from the program file. Both of those live outside
/// this class on purpose: a runner that also judged would be a runner every judgement had to be
/// argued with.
final class Runner {
  /// Creates a runner against [machine], recording to [recorder].
  const Runner({
    required this.machine,
    required this.recorder,
    required this.redactor,
    this.logLevel = LogLevel.info,
    this.unwindDisabledBy,
  });

  /// What the program acts on.
  final Machine machine;

  /// Where everything that happens is written.
  final Recorder recorder;

  /// What is removed on the way into the record.
  final Redactor redactor;

  /// The quietest level this run writes.
  ///
  /// Read from the installation's configuration, or from the command line where a run says otherwise.
  /// It reaches every step and every unwind through here, so one run writes at one level and a
  /// reader never has to work out which part of a record was filtered and which was not.
  final LogLevel logLevel;

  /// What turned the unwind off, or null where it is on.
  ///
  /// One field rather than a flag beside a reason, because the two cannot then disagree. It holds
  /// the SURFACE the decision came from — the option, or the configuration file and its key — since
  /// a message naming a command-line flag to an operator who never typed one sends them looking in
  /// the wrong place.
  final String? unwindDisabledBy;

  /// Whether a failure takes the applied steps back.
  bool get allowUnwind => unwindDisabledBy == null;

  /// Runs [program] in [mode] against the machine described by [header].
  ///
  /// [answers] is what the operator supplied, already checked against what the program declared.
  /// The checking happens where the values were taken in and not here, so a bad answer is refused
  /// before there is a run to refuse — a half-finished installation waiting on a value somebody
  /// could have typed at the start is worse than a refusal. A program that declares nothing is run
  /// with [Arguments.none], which is what a step reading no answer sees.
  ///
  /// Returns the completed record. Throws [RoleMismatch] when the program does not apply to this
  /// machine — before anything is measured, because measuring a machine a program will not run
  /// against is work with no reader.
  Future<RunRecord> run({
    required ResolvedProgram program,
    required Mode mode,
    required RunRecord header,
    Arguments answers = Arguments.none,
  }) async {
    if (!program.declared.appliesTo(header.role)) {
      throw RoleMismatch(
        program: program.declared.name.value,
        role: header.role.value,
        applies: program.declared.roles.map((Role r) => r.value).join(', '),
      );
    }

    try {
      recorder.record(
        (int sequence, DateTime at) =>
            RunStarted(sequence: sequence, at: at, program: program.declared.name, mode: mode.flag),
      );

      final Facts facts = await _measure(program, answers);
      final _Walk walk = await _walkSteps(program, mode, facts, answers);

      // What the run applied and did not take back. Empty unless the unwind was turned off, which
      // is the one way a failed run leaves the machine in a state nothing produced on purpose.
      List<String> leftStanding = const <String>[];

      if (walk.ended && walk.applied.isNotEmpty) {
        if (allowUnwind) {
          await Unwind(
            machine: machine,
            recorder: recorder,
            redactor: redactor,
            logLevel: logLevel,
          ).undo(walk.applied, facts, answers);
        } else {
          leftStanding = <String>[
            for (final AppliedStep applied in walk.applied) applied.name.value,
          ];
          final Logger log = RecordingLogger(
            recorder: recorder,
            redactor: redactor,
            step: const StepName('unwind'),
            threshold: logLevel,
          );
          log.warn(
            'a failure would have taken ${leftStanding.length} applied step(s) back, and '
            '$unwindDisabledBy says not to — ${leftStanding.join(', ')} are still on this machine',
          );
        }
      }

      final int exitCode = walk.ended ? 1 : (walk.issues.isEmpty ? 0 : 2);
      final DateTime end = machine.clock.now();
      final RunRecord closed = header.closed(
        end: end,
        exitCode: exitCode,
        steps: walk.records,
        issues: walk.issues,
        leftStanding: leftStanding,
      );
      // The closing line carries the three numbers beside the exit code, because the exit code
      // answers a different question. A run that skipped half its steps returns the same zero as one
      // that measured every row, and only these three tell the two apart. Read off the record that
      // is about to be returned, so the event and the record cannot state different numbers.
      recorder.record(
        (int sequence, DateTime at) => RunFinished(
          sequence: sequence,
          at: at,
          exitCode: exitCode,
          issues: walk.issues,
          standings: closed.standings,
          leftStanding: leftStanding,
        ),
      );

      return closed;
    } on Object catch (thrown) {
      // ANYTHING THE ENGINE DOES NOT OTHERWISE HANDLE, and the reason it is caught this widely is
      // measured rather than assumed. A record that is never closed says a run is still going, for
      // ever, to everything that reads records afterwards — and the process that would have said
      // otherwise is gone. That is worse than any failure the exception could describe.
      //
      // Twice on a machine: first a condition that could not be answered, then a step whose restart
      // never came back. Each carried a message that said exactly what had happened, and each left
      // a record claiming the run had not finished.
      //
      // Caught here rather than left to the caller because only this method holds the header the
      // record is closed from. What was thrown becomes the run's single issue, so nothing about it
      // is lost by being handled.
      final String because = switch (thrown) {
        ConditionUnanswerable(:final String because) => because,
        final EngineFailure failure => failure.message,
        _ => thrown.toString(),
      };
      final RunRecord closed = header.closed(
        end: machine.clock.now(),
        exitCode: 1,
        steps: const <StepRecord>[],
        issues: <String>[because],
        leftStanding: const <String>[],
      );
      recorder.record(
        (int sequence, DateTime at) => RunFinished(
          sequence: sequence,
          at: at,
          exitCode: 1,
          issues: <String>[because],
          standings: closed.standings,
          leftStanding: const <String>[],
        ),
      );
      return closed;
    } finally {
      // Closed even when a step threw something this engine does not catch. A run that crashed
      // without leaving its record is a run nobody can find out anything about, which is the one
      // outcome worse than failing.
      await recorder.close();
    }
  }

  Future<Facts> _measure(ResolvedProgram program, Arguments answers) {
    final Logger log = RecordingLogger(
      recorder: recorder,
      redactor: redactor,
      step: const StepName('when'),
      threshold: logLevel,
    );
    return PredicateEvaluation(
      machine: machine,
      recorder: recorder,
      log: log,
      answers: answers,
    ).evaluate(program);
  }

  Future<_Walk> _walkSteps(
    ResolvedProgram program,
    Mode mode,
    Facts facts,
    Arguments answers,
  ) async {
    final StepExecution execution = StepExecution(
      machine: machine,
      recorder: recorder,
      redactor: redactor,
      logLevel: logLevel,
    );
    // One collection for the whole walk, because a value one row measures is taken by a later one.
    // It belongs to the RUN and not to the runner: two runs of one program are two machines' worth
    // of measurements, and a collection that outlived a run would carry one into the other.
    //
    // It is given this run's redactor because a step may publish a credential. Registering it
    // where it is published is the only moment that hides it everywhere: the same redactor is
    // already held by the shell, the http port, the logger and the file the record is written to.
    final Measurements measurements = Measurements(redactor);
    final List<StepRecord> records = <StepRecord>[];
    final List<AppliedStep> applied = <AppliedStep>[];
    final List<String> issues = <String>[];

    for (final ResolvedStep step in program.steps) {
      final StepOutcome outcome;
      try {
        outcome = await execution.execute(
          resolved: step,
          mode: mode,
          facts: facts,
          answers: answers,
          start: machine.clock.now(),
          measurements: measurements,
          applied: applied,
        );
      } on Object catch (thrown) {
        // A THROW THAT GOT PAST THE STEP'S OWN CATCH ENDS THE WALK AND KEEPS EVERYTHING SO FAR.
        // What can still arrive here is the recorder refusing a line: [StepExecution] closes every
        // row by recording it, so a full event file throws out of the last thing a row does. Left
        // to reach the catch in [run], that took the rows the walk already had AND the list the
        // unwind walks — a machine changed by twenty steps was then neither taken back nor named.
        //
        // The step that threw has no row, because building one is what threw. Its name and the
        // throw go into the issues instead, which is the only place left that an operator reads —
        // the usual place, the last row of the record, is the one that could not be written.
        issues.add('${step.entry.step}: $thrown');
        return _Walk(records: records, applied: applied, issues: issues, ended: true);
      }
      records.add(outcome.record);
      // A failure the run carried on past is what the closing line reports. One that ended the run
      // needs no entry: the run stopped, and the last step of the record is the reason.
      if (outcome.record.verdict case final Failed failed when failed.continues) {
        issues.add('${step.entry.step}: ${failed.reason}');
      }
      if (!outcome.continues) {
        return _Walk(records: records, applied: applied, issues: issues, ended: true);
      }
    }
    return _Walk(records: records, applied: applied, issues: issues, ended: false);
  }
}

/// What walking the steps produced, gathered so the run can close on it.
final class _Walk {
  const _Walk({
    required this.records,
    required this.applied,
    required this.issues,
    required this.ended,
  });

  final List<StepRecord> records;
  final List<AppliedStep> applied;
  final List<String> issues;

  /// Whether a step ended the run before the last one was reached.
  final bool ended;
}
