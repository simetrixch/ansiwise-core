import '../model/record_json.dart';
import '../model/check_result.dart';
import '../model/mode.dart';
import '../model/names.dart';
import '../model/on_failure.dart';
import '../model/removed_runs.dart';
import '../model/run_event.dart';
import '../model/run_record.dart';
import '../model/standings.dart';
import '../model/step_plan.dart';
import '../model/step_record.dart';
import '../model/step_standing.dart';
import '../model/verdict.dart';

/// Turns the record into JSON and reads it back.
///
/// One class for both directions and for both destinations. It implements [RecordJson], so what is
/// written into `events.jsonl` on the machine and what a client receives over the network are the
/// same object — an exported run can be opened later by the same reader that reads a live one.
///
/// Writing switches on the sealed type. Every family the record carries — [RunEvent], [Verdict],
/// [StepPlan], [CheckResult] — is sealed, and an exhaustive switch over one of them stops compiling
/// the moment a new member is added. A method on each class would have accepted the new member in
/// silence and written nothing for it. Reading switches on the `kind` the writer put in the object,
/// because a reader has no type to switch on yet.
final class RecordCodec implements RecordJson {
  /// Creates the codec. It holds nothing, so one instance serves every run.
  const RecordCodec();

  @override
  Map<String, Object?> run(RunRecord record) {
    final DateTime? end = record.end;
    return <String, Object?>{
      'id': record.id.value,
      'program': record.program.value,
      'mode': record.mode.name,
      'argv': record.argv,
      'start': _written(record.start),
      'stage': record.stage.value,
      'role': record.role.value,
      'fqdn': record.fqdn.value,
      'commit': record.commit,
      'fingerprint': record.fingerprint,
      // Absent rather than null on a run that starts fresh, for the same reason `end` is.
      'resumes': ?record.resumes?.value,
      // Always written, including the empty list. An absent key would read as an old record that
      // predates waivers, and a reader cannot tell that from a run that waived nothing — which are
      // opposite answers to the only question this field is asked.
      'waived': <Object?>[for (final Mode mode in record.waived) mode.name],
      // Absent rather than null while the run is going. A header with no end is a run still
      // running, and that is the same fact whichever way it is written down.
      if (end != null) 'end': _written(end),
      'exit_code': ?record.exitCode,
      'steps': <Object?>[for (final StepRecord step in record.steps) stepRecord(step)],
      'issues': record.issues,
      // Written only when it is not empty, so a record that carries the key is a record about a
      // machine somebody has to go and look at. An empty list on every other run would read as a
      // field somebody forgot to fill in.
      if (record.leftStanding.isNotEmpty) 'left_standing': record.leftStanding,
    };
  }

  /// Reads back what [run] wrote.
  RunRecord runFrom(Map<String, Object?> json) => RunRecord(
    id: RunId(_text(json, 'id')),
    program: ProgramName(_text(json, 'program')),
    mode: _named(Mode.values, _text(json, 'mode'), 'mode'),
    argv: _texts(json, 'argv'),
    start: _instant(json, 'start'),
    stage: Stage(_text(json, 'stage')),
    role: Role(_text(json, 'role')),
    fqdn: Fqdn(_text(json, 'fqdn')),
    commit: _text(json, 'commit'),
    fingerprint: _text(json, 'fingerprint'),
    resumes: switch (json['resumes']) {
      final String id => RunId(id),
      _ => null,
    },
    waived: <Mode>[
      for (final String name in _texts(json, 'waived')) _named(Mode.values, name, 'mode'),
    ],
    end: _optionalInstant(json, 'end'),
    exitCode: _optionalNumber(json, 'exit_code'),
    steps: <StepRecord>[
      for (final Map<String, Object?> step in _objects(json, 'steps')) stepRecordFrom(step),
    ],
    issues: _texts(json, 'issues'),
    leftStanding: json.containsKey('left_standing')
        ? _texts(json, 'left_standing')
        : const <String>[],
  );

  @override
  Map<String, Object?> event(RunEvent event) {
    final StepName? step = event.step;
    return <String, Object?>{
      'kind': event.kind,
      'sequence': event.sequence,
      'at': _written(event.at),
      if (step != null) 'step': step.value,
      ..._detailOf(event),
    };
  }

  /// Reads back what [event] wrote.
  RunEvent eventFrom(Map<String, Object?> json) {
    final int sequence = _number(json, 'sequence');
    final DateTime at = _instant(json, 'at');
    final String kind = _text(json, 'kind');

    return switch (kind) {
      'run-started' => RunStarted(
        sequence: sequence,
        at: at,
        program: ProgramName(_text(json, 'program')),
        mode: _text(json, 'mode'),
      ),
      'predicate-evaluated' => PredicateEvaluated(
        sequence: sequence,
        at: at,
        predicate: PredicateName(_text(json, 'predicate')),
        held: _flag(json, 'held'),
        because: _text(json, 'because'),
      ),
      'step-started' => StepStarted(
        sequence: sequence,
        at: at,
        step: _step(json),
        source: _text(json, 'source'),
      ),
      'command-started' => CommandStarted(
        sequence: sequence,
        at: at,
        step: _step(json),
        argv: _texts(json, 'argv'),
        // False where the key is absent, which is what a record written before this field existed
        // showed its reader anyway. Every record this build writes carries it.
        elevated: json['elevated'] == true,
        workingDirectory: _optionalText(json, 'working_directory'),
      ),
      'output' => Output(
        sequence: sequence,
        at: at,
        step: _step(json),
        stream: _named(OutputStream.values, _text(json, 'stream'), 'output stream'),
        text: _text(json, 'text'),
      ),
      'command-finished' => CommandFinished(
        sequence: sequence,
        at: at,
        step: _step(json),
        exitCode: _number(json, 'exit_code'),
        elapsed: _span(json, 'elapsed_micros'),
        stdoutLines: _number(json, 'stdout_lines'),
        stderrLines: _number(json, 'stderr_lines'),
      ),
      'file-written' => FileWritten(
        sequence: sequence,
        at: at,
        step: _step(json),
        path: _text(json, 'path'),
        bytes: _number(json, 'bytes'),
        created: _flag(json, 'created'),
      ),
      'request-sent' => RequestSent(
        sequence: sequence,
        at: at,
        step: _step(json),
        method: _text(json, 'method'),
        url: _text(json, 'url'),
        status: _number(json, 'status'),
        socketPath: _optionalText(json, 'socket_path'),
      ),
      'planned' => Planned(
        sequence: sequence,
        at: at,
        step: _step(json),
        plan: stepPlanFrom(_object(json, 'plan')),
      ),
      'log' => Log(
        sequence: sequence,
        at: at,
        step: _step(json),
        level: _named(LogLevel.values, _text(json, 'level'), 'log level'),
        message: _text(json, 'message'),
      ),
      'step-finished' => StepFinished(
        sequence: sequence,
        at: at,
        step: _step(json),
        verdict: verdictFrom(_object(json, 'verdict')),
        elapsed: _span(json, 'elapsed_micros'),
        standing: _named(StepStanding.values, _text(json, 'standing'), 'standing'),
      ),
      'run-finished' => RunFinished(
        sequence: sequence,
        at: at,
        exitCode: _number(json, 'exit_code'),
        issues: _texts(json, 'issues'),
        standings: _standings(_object(json, 'standings')),
        leftStanding: json.containsKey('left_standing')
            ? _texts(json, 'left_standing')
            : const <String>[],
      ),
      _ => throw FormatException('there is no event kind called "$kind"'),
    };
  }

  /// What the machine has removed, as the note beside the runs states it.
  Map<String, Object?> removedRuns(RemovedRuns removed) => <String, Object?>{
    'count': removed.count,
    'oldest': removed.oldest.value,
    'newest': removed.newest.value,
    'at': _written(removed.at),
  };

  /// Reads back what [removedRuns] wrote.
  RemovedRuns removedRunsFrom(Map<String, Object?> json) => RemovedRuns(
    count: _number(json, 'count'),
    oldest: RunId(_text(json, 'oldest')),
    newest: RunId(_text(json, 'newest')),
    at: _instant(json, 'at'),
  );

  /// One step's row, as it sits inside a run.
  Map<String, Object?> stepRecord(StepRecord record) {
    final StepPlan? plan = record.plan;
    return <String, Object?>{
      'step': record.step.value,
      'source': record.source,
      'start': _written(record.start),
      'end': _written(record.end),
      'verdict': verdict(record.verdict),
      'standing': record.standing.name,
      'first_event': record.firstEvent,
      'last_event': record.lastEvent,
      if (plan != null) 'plan': stepPlan(plan),
      'issues': record.issues,
    };
  }

  /// Reads back what [stepRecord] wrote.
  StepRecord stepRecordFrom(Map<String, Object?> json) {
    final Map<String, Object?>? plan = _optionalObject(json, 'plan');
    return StepRecord(
      step: StepName(_text(json, 'step')),
      source: _text(json, 'source'),
      start: _instant(json, 'start'),
      end: _instant(json, 'end'),
      verdict: verdictFrom(_object(json, 'verdict')),
      standing: _named(StepStanding.values, _text(json, 'standing'), 'standing'),
      firstEvent: _number(json, 'first_event'),
      lastEvent: _number(json, 'last_event'),
      plan: plan == null ? null : stepPlanFrom(plan),
      issues: _texts(json, 'issues'),
    );
  }

  /// How a step ended.
  ///
  /// The discriminator is [Verdict.label], the same lower-case word the command line prints and a
  /// program file writes, so the record and what an operator reads use one vocabulary.
  Map<String, Object?> verdict(Verdict verdict) => <String, Object?>{
    'label': verdict.label,
    ...switch (verdict) {
      Succeeded() => const <String, Object?>{},
      final Skipped v => <String, Object?>{'predicate': v.predicate},
      final Failed v => <String, Object?>{'reason': v.reason},
    },
  };

  /// Reads back what [verdict] wrote.
  Verdict verdictFrom(Map<String, Object?> json) {
    final String label = _text(json, 'label');
    return switch (label) {
      'ok' => const Succeeded(),
      'skipped' => Skipped(_text(json, 'predicate')),
      // The label of a failure IS what the program said it costs the run, so reading the label back
      // is reading the policy back. One word carries both, which is why there is no second field.
      'exit' => Failed(_text(json, 'reason'), policy: OnFailure.exit),
      'continue' => Failed(_text(json, 'reason'), policy: OnFailure.continueRun),
      _ => throw FormatException('there is no verdict called "$label"'),
    };
  }

  /// What a step would change.
  Map<String, Object?> stepPlan(StepPlan plan) => switch (plan) {
    final ArgvPlan p => <String, Object?>{
      'kind': 'argv',
      'argv': p.argv,
      if (p.workingDirectory case final String directory) 'working_directory': directory,
      'server_verified': p.serverVerified,
    },
    final DiffPlan p => <String, Object?>{
      'kind': 'diff',
      'path': p.path,
      'before': p.before,
      'after': p.after,
    },
    final RequestPlan p => <String, Object?>{
      'kind': 'request',
      'method': p.method,
      'url': p.url,
      if (p.body case final String body) 'body': body,
    },
    final NothingPlan p => <String, Object?>{'kind': 'nothing', 'because': p.because},
    final NotKnownYetPlan p => <String, Object?>{'kind': 'not-known-yet', 'because': p.because},
  };

  /// Reads back what [stepPlan] wrote.
  StepPlan stepPlanFrom(Map<String, Object?> json) {
    final String kind = _text(json, 'kind');
    return switch (kind) {
      'argv' => ArgvPlan(
        _texts(json, 'argv'),
        workingDirectory: _optionalText(json, 'working_directory'),
        serverVerified: _flag(json, 'server_verified'),
      ),
      'diff' => DiffPlan(
        _text(json, 'path'),
        before: _text(json, 'before'),
        after: _text(json, 'after'),
      ),
      'request' => RequestPlan(
        _text(json, 'method'),
        _text(json, 'url'),
        body: _optionalText(json, 'body'),
      ),
      'nothing' => NothingPlan(_text(json, 'because')),
      'not-known-yet' => NotKnownYetPlan(_text(json, 'because')),
      _ => throw FormatException('there is no plan called "$kind"'),
    };
  }

  /// What a step answered when it was asked about the machine.
  Map<String, Object?> checkResult(CheckResult result) => switch (result) {
    Ready() => const <String, Object?>{'kind': 'ready'},
    final Satisfied r => <String, Object?>{'kind': 'satisfied', 'because': r.because},
    final Blocked r => <String, Object?>{'kind': 'blocked', 'reason': r.reason},
  };

  /// Reads back what [checkResult] wrote.
  CheckResult checkResultFrom(Map<String, Object?> json) {
    final String kind = _text(json, 'kind');
    return switch (kind) {
      'ready' => const Ready(),
      'satisfied' => Satisfied(_text(json, 'because')),
      'blocked' => Blocked(_text(json, 'reason')),
      _ => throw FormatException('there is no check result called "$kind"'),
    };
  }

  Map<String, Object?> _detailOf(RunEvent event) => switch (event) {
    final RunStarted e => <String, Object?>{'program': e.program.value, 'mode': e.mode},
    final PredicateEvaluated e => <String, Object?>{
      'predicate': e.predicate.value,
      'held': e.held,
      'because': e.because,
    },
    final StepStarted e => <String, Object?>{'source': e.source},
    final CommandStarted e => <String, Object?>{
      'argv': e.argv,
      'elevated': e.elevated,
      if (e.workingDirectory case final String directory) 'working_directory': directory,
    },
    final Output e => <String, Object?>{'stream': e.stream.name, 'text': e.text},
    final CommandFinished e => <String, Object?>{
      'exit_code': e.exitCode,
      'elapsed_micros': e.elapsed.inMicroseconds,
      // Always written, both of them, zeroes included. An absent count would make "this command
      // said nothing" and "this writer did not count" the same reading, and telling those apart is
      // what the counts are for.
      'stdout_lines': e.stdoutLines,
      'stderr_lines': e.stderrLines,
    },
    final FileWritten e => <String, Object?>{
      'path': e.path,
      'bytes': e.bytes,
      'created': e.created,
    },
    final RequestSent e => <String, Object?>{
      'method': e.method,
      'url': e.url,
      'status': e.status,
      if (e.socketPath case final String socketPath) 'socket_path': socketPath,
    },
    final Planned e => <String, Object?>{'plan': stepPlan(e.plan)},
    final Log e => <String, Object?>{'level': e.level.name, 'message': e.message},
    final StepFinished e => <String, Object?>{
      'verdict': verdict(e.verdict),
      'elapsed_micros': e.elapsed.inMicroseconds,
      'standing': e.standing.name,
    },
    final RunFinished e => <String, Object?>{
      'exit_code': e.exitCode,
      'issues': e.issues,
      'standings': <String, Object?>{
        'proven': e.standings.proven,
        'declared': e.standings.declared,
        'skipped': e.standings.skipped,
      },
      if (e.leftStanding.isNotEmpty) 'left_standing': e.leftStanding,
    },
  };
}

/// A moment, always in UTC and always to the microsecond, so what is read back is what went in.
String _written(DateTime at) => at.toUtc().toIso8601String();

StepName _step(Map<String, Object?> json) => StepName(_text(json, 'step'));

String _text(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is String) {
    return value;
  }
  throw FormatException('"$key" is missing or is not text');
}

String? _optionalText(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value == null) {
    return null;
  }
  if (value is String) {
    return value;
  }
  throw FormatException('"$key" is not text');
}

int _number(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is int) {
    return value;
  }
  throw FormatException('"$key" is missing or is not a whole number');
}

int? _optionalNumber(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value == null) {
    return null;
  }
  if (value is int) {
    return value;
  }
  throw FormatException('"$key" is not a whole number');
}

bool _flag(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is bool) {
    return value;
  }
  throw FormatException('"$key" is missing or is not true or false');
}

DateTime _instant(Map<String, Object?> json, String key) {
  final DateTime parsed = DateTime.parse(_text(json, key));
  return parsed.isUtc ? parsed : parsed.toUtc();
}

DateTime? _optionalInstant(Map<String, Object?> json, String key) {
  final String? written = _optionalText(json, key);
  if (written == null) {
    return null;
  }
  final DateTime parsed = DateTime.parse(written);
  return parsed.isUtc ? parsed : parsed.toUtc();
}

/// Durations are written as whole microseconds, which is the resolution [Duration] holds. Anything
/// with a decimal point in it would come back rounded.
Duration _span(Map<String, Object?> json, String key) => Duration(microseconds: _number(json, key));

/// The three numbers a run closes with, read back as they were written.
///
/// All three are required. A missing one read as zero would turn "nothing was skipped" and "this
/// writer did not know about skipping" into the same answer, and the second is the one where the
/// number on the screen is wrong.
Standings _standings(Map<String, Object?> json) => Standings(
  proven: _number(json, 'proven'),
  declared: _number(json, 'declared'),
  skipped: _number(json, 'skipped'),
);

List<String> _texts(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! List<Object?>) {
    throw FormatException('"$key" is missing or is not a list');
  }
  final List<String> texts = <String>[];
  for (final Object? entry in value) {
    if (entry is! String) {
      throw FormatException('"$key" holds something that is not text');
    }
    texts.add(entry);
  }
  return texts;
}

Map<String, Object?> _object(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is Map<String, Object?>) {
    return value;
  }
  throw FormatException('"$key" is missing or is not an object');
}

Map<String, Object?>? _optionalObject(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value == null) {
    return null;
  }
  if (value is Map<String, Object?>) {
    return value;
  }
  throw FormatException('"$key" is not an object');
}

List<Map<String, Object?>> _objects(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! List<Object?>) {
    throw FormatException('"$key" is missing or is not a list');
  }
  final List<Map<String, Object?>> objects = <Map<String, Object?>>[];
  for (final Object? entry in value) {
    if (entry is! Map<String, Object?>) {
      throw FormatException('"$key" holds something that is not an object');
    }
    objects.add(entry);
  }
  return objects;
}

T _named<T extends Enum>(List<T> values, String name, String what) {
  for (final T value in values) {
    if (value.name == name) {
      return value;
    }
  }
  throw FormatException('there is no $what called "$name"');
}
