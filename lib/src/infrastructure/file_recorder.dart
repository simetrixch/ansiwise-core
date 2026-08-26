import 'dart:convert';
import 'dart:io';

import '../domain/clock.dart';
import '../domain/recorder.dart';
import '../engine/redactor.dart';
import '../model/failures.dart';
import '../model/names.dart';
import '../model/run_event.dart';
import '../model/run_record.dart';
import '../model/step_plan.dart';
import '../model/step_record.dart';
import '../model/verdict.dart';
import 'permissions.dart';
import 'record_codec.dart';
import 'run_directory.dart';

/// Writes a run's record to its directory: the header once at each end, the events one line at a
/// time as they happen.
///
/// It talks to `dart:io` directly instead of going through the `Files` port, and it has to. That
/// port reports every write to a recorder, so a recorder writing its own file through it would
/// record itself writing, and then record that.
final class FileRecorder implements Recorder {
  FileRecorder._(this.id, this._directory, this._clock, this._redactor, this._events);

  /// Opens the record of run [id] under [directory], creating the directory and the event file.
  ///
  /// [redactor] is what is taken out of everything on its way in, and it is the RUN'S OWN — the same
  /// object its ports, its logger and its measurement sink hold, so a credential registered while the
  /// run happens is hidden here too. A run with nothing to hide passes one built from no secrets
  /// rather than leaving it out, because a recorder that could be built without one is a recorder
  /// somebody builds without one.
  static Future<FileRecorder> open({
    required RunId id,
    required RunDirectory directory,
    required Clock clock,
    required Redactor redactor,
  }) async {
    final String home = directory.of(id);
    await Directory(home).create(recursive: true);
    await setPermissions(home, directoryMode);

    final String path = directory.events(id);
    final RandomAccessFile events = await File(path).open(mode: FileMode.append);
    await setPermissions(path, fileMode);

    return FileRecorder._(id, directory, clock, redactor, events);
  }

  /// The permission bits the record's files get: 0644, so anyone on the machine may read them.
  ///
  /// That is only safe BECAUSE of the redaction below. An operator reads the record without elevated
  /// rights and pastes it into a message, which is the whole reason it is world-readable — and the
  /// moment a value reaches these files unredacted, the same bits are a leak. A change that lets one
  /// through does not break anything that would notice.
  static const int fileMode = 420;

  /// The permission bits the run's directory gets: 0755, for the same reason and with the same
  /// dependency on redaction.
  static const int directoryMode = 493;

  /// The run being recorded.
  final RunId id;

  final RunDirectory _directory;
  final Clock _clock;
  final Redactor _redactor;
  final RandomAccessFile _events;

  static const RecordCodec _codec = RecordCodec();

  int _next = 0;
  bool _closed = false;

  @override
  int get nextSequence => _next;

  @override
  void record(RunEvent Function(int sequence, DateTime at) build) {
    if (_closed) {
      throw StateError('the record of ${id.value} is closed');
    }
    final RunEvent event = _redacted(build(_next, _clock.now()), _redactor);

    // What this guarantees: the line is handed to the operating system before this call returns, so
    // a process that is killed a moment later keeps every event it had recorded. There is no buffer
    // of ours holding a line back — the write is synchronous and unbuffered, which is also the only
    // way to give the guarantee at all from a method that returns void and cannot be awaited.
    //
    // What it does NOT guarantee: the bytes are in the operating system's cache and not yet on the
    // disk. A machine that loses power can still lose the tail of the file. [close] flushes, so a
    // run that ended in any ordinary way is on the disk when it ends.
    _events.writeStringSync('${jsonEncode(_codec.event(event))}\n');
    _next++;
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _events.flush();
    await _events.close();
  }

  /// How long the rename over the header is retried before it is reported as a failure.
  ///
  /// MEASURED, not chosen. On Windows the rename fails while any process holds the header open, and
  /// 34 of 265 runs that had a reader lost their closing header that way against 0 of 100 that had
  /// none. What the retry has to outlast is ONE reader's open-read-close of a file of a few
  /// kilobytes, and not the reader itself: every reader of this file reads it whole and closes it.
  /// A second is far longer than any such read and short enough that a run does not look hung.
  static const Duration renameBudget = Duration(seconds: 1);

  /// How long it waits between two attempts at that rename.
  ///
  /// Fixed rather than growing. The window is one read, so a longer wait after a first refusal
  /// would spend most of the budget asleep past the moment the file was free again.
  static const Duration renameRetry = Duration(milliseconds: 10);

  /// Writes [record] to `run.json`.
  ///
  /// Called twice for a run: once as it begins, so a run that is killed still says what it was, and
  /// once as it ends, with the closing fields and the step rows filled in. The file is written under
  /// a second name and renamed over the real one, so a reader never sees half a header — and the
  /// store reads this file to find out whether a run is still going.
  ///
  /// The second call comes after [close], and has to: the header may only say the run has ended once
  /// the last event is in the event file, which is what [close] finishes. This touches a different
  /// file, so a closed recorder still writes it.
  ///
  /// Throws [HeaderNotReplaced] where the rename cannot be completed within [renameBudget].
  Future<void> save(RunRecord record) async {
    final String pending = _directory.pendingHeader(id);
    final File file = File(pending);
    await file.writeAsString(
      _headerFormat.convert(_codec.run(_redactedRecord(record, _redactor))),
      flush: true,
    );
    await setPermissions(pending, fileMode);
    await _replaceHeaderWith(file);
  }

  /// Puts [pending] where the header goes, retrying while the file system refuses.
  ///
  /// **A stopwatch and not the clock this recorder holds.** The wait is real time on a real file
  /// system, so it has to run whatever a caller's clock does — and the clock here belongs to the
  /// machine, which a test freezes.
  ///
  /// **The pending file is left where it is when this gives up**, because it is the only copy of
  /// the header the run ended with. Nothing here writes over the real one directly instead: a
  /// rewrite in place can be read while it is half done, which is the whole reason for the second
  /// name, and a header that does not parse is worse than one that is out of date.
  Future<void> _replaceHeaderWith(File pending) async {
    final String header = _directory.header(id);
    final Stopwatch waited = Stopwatch()..start();
    while (true) {
      final FileSystemException refused;
      try {
        await pending.rename(header);
        return;
      } on FileSystemException catch (failure) {
        refused = failure;
      }
      if (waited.elapsed >= renameBudget) {
        throw HeaderNotReplaced(pending: pending.path, header: header, refused: refused.toString());
      }
      await Future<void>.delayed(renameRetry);
    }
  }

  /// Indented, because unlike the event file this one is read by a person with whatever is at hand.
  static const JsonEncoder _headerFormat = JsonEncoder.withIndent('  ');
}

/// Returns [event] with the values that reach a recorder unredacted taken out.
///
/// Where the boundary runs. `RecordingShell`, `RecordingHttp` and `RecordingLogger` in
/// `lib/src/engine/recording_ports.dart` redact what they carry as they build the event: a command's
/// argv, every line of its output, a request's address, the text of a log line. Those are left
/// alone here rather than passed through a second time.
///
/// What no port touches is everything the ENGINE puts into an event without having carried it: the
/// reason on a verdict, which is an exception message and so can quote a whole command line; a
/// plan's diff, which is the entire content of a file that is about to be written; what a predicate
/// found when it looked; and the issues repeated at the end of the run. Those are redacted here, and
/// here is the last place they can be — the next thing that happens to them is a world-readable
/// file.
RunEvent _redacted(RunEvent event, Redactor redactor) {
  if (redactor.isEmpty) {
    return event;
  }
  return switch (event) {
    RunStarted() ||
    StepStarted() ||
    CommandStarted() ||
    Output() ||
    CommandFinished() ||
    RequestSent() ||
    Log() => event,
    final PredicateEvaluated e => PredicateEvaluated(
      sequence: e.sequence,
      at: e.at,
      predicate: e.predicate,
      held: e.held,
      because: redactor.hide(e.because),
    ),
    final FileWritten e => FileWritten(
      sequence: e.sequence,
      at: e.at,
      step: _stepOf(e),
      path: redactor.hide(e.path),
      bytes: e.bytes,
      created: e.created,
    ),
    final Planned e => Planned(
      sequence: e.sequence,
      at: e.at,
      step: _stepOf(e),
      plan: _redactedPlan(e.plan, redactor),
    ),
    final StepFinished e => StepFinished(
      sequence: e.sequence,
      at: e.at,
      step: _stepOf(e),
      verdict: _redactedVerdict(e.verdict, redactor),
      elapsed: e.elapsed,
      standing: e.standing,
    ),
    final RunFinished e => RunFinished(
      sequence: e.sequence,
      at: e.at,
      exitCode: e.exitCode,
      issues: redactor.hideAll(e.issues),
      standings: e.standings,
    ),
  };
}

RunRecord _redactedRecord(RunRecord record, Redactor redactor) {
  if (redactor.isEmpty) {
    return record;
  }
  return RunRecord(
    id: record.id,
    program: record.program,
    mode: record.mode,
    // How the run was invoked, word for word — which is where a credential typed on the command
    // line ends up.
    argv: redactor.hideAll(record.argv),
    start: record.start,
    stage: record.stage,
    role: record.role,
    fqdn: record.fqdn,
    commit: record.commit,
    fingerprint: record.fingerprint,
    // Neither carries anything a redactor could hide, and both were being dropped: a redacted
    // record forgot which run it continued and forgot that a proof had been waived. The second is
    // the one that mattered — a lost waiver reads as a run that was gated normally.
    resumes: record.resumes,
    waived: record.waived,
    end: record.end,
    exitCode: record.exitCode,
    steps: <StepRecord>[for (final StepRecord step in record.steps) _redactedStep(step, redactor)],
    issues: redactor.hideAll(record.issues),
  );
}

StepRecord _redactedStep(StepRecord step, Redactor redactor) {
  final StepPlan? plan = step.plan;
  return StepRecord(
    step: step.step,
    source: step.source,
    start: step.start,
    end: step.end,
    verdict: _redactedVerdict(step.verdict, redactor),
    standing: step.standing,
    firstEvent: step.firstEvent,
    lastEvent: step.lastEvent,
    plan: plan == null ? null : _redactedPlan(plan, redactor),
    issues: redactor.hideAll(step.issues),
  );
}

Verdict _redactedVerdict(Verdict verdict, Redactor redactor) => switch (verdict) {
  // Nothing to hide in either: one carries no text at all, and the other carries the registered
  // name of a predicate, which is an identifier and not a value read off the machine.
  Succeeded() || Skipped() => verdict,
  final Failed v => Failed(redactor.hide(v.reason), policy: v.policy),
};

StepPlan _redactedPlan(StepPlan plan, Redactor redactor) => switch (plan) {
  final ArgvPlan p => ArgvPlan(
    redactor.hideAll(p.argv),
    workingDirectory: p.workingDirectory,
    serverVerified: p.serverVerified,
  ),
  final DiffPlan p => DiffPlan(
    p.path,
    before: redactor.hide(p.before),
    after: redactor.hide(p.after),
  ),
  final RequestPlan p => RequestPlan(
    p.method,
    redactor.hide(p.url),
    body: _hidden(p.body, redactor),
  ),
  final NothingPlan p => NothingPlan(redactor.hide(p.because)),
  // It carries argument names, measurement names and the step that produces the value — no reading
  // off a machine. Passed through the redactor all the same: the day one of those names carries a
  // value is the day nobody remembers that this line said it could not.
  final NotKnownYetPlan p => NotKnownYetPlan(redactor.hide(p.because)),
};

String? _hidden(String? text, Redactor redactor) => text == null ? null : redactor.hide(text);

StepName _stepOf(RunEvent event) {
  final StepName? step = event.step;
  if (step == null) {
    // Every event rebuilt above requires a step in its own constructor, so this can only be reached
    // by an event type that stopped requiring one.
    throw StateError('a ${event.kind} event has no step');
  }
  return step;
}
