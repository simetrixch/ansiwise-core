import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:ansiwise_core/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// What an operator does with a run: list the recent ones, open one, watch one that is going, come
/// back to one after the connection dropped — and what the gate does with them, which is refuse a
/// real run that has no clean dry run behind it.
void main() {
  late Directory temp;
  late RunDirectory directory;
  final FakeClock clock = FakeClock();
  const StepName step = StepName('writes_a_thing');

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ansiwise-store-');
    directory = RunDirectory(temp.path);
  });

  tearDown(() async {
    try {
      await temp.delete(recursive: true);
    } on FileSystemException {
      // Windows can hold a handle open for a moment after a file is closed.
    }
  });

  RunRecord header(
    String id, {
    String program = 'deploy-something',
    Mode mode = Mode.dry,
    String fingerprint = 'a-digest',
    required DateTime start,
  }) => RunRecord(
    id: RunId(id),
    program: ProgramName(program),
    mode: mode,
    argv: <String>['ansiwise', program],
    start: start,
    stage: const Stage('prod'),
    role: const Role('master'),
    fqdn: const Fqdn('m1.example.com'),
    commit: 'abc1234',
    fingerprint: fingerprint,
  );

  Future<void> writeRun(
    String id, {
    String program = 'deploy-something',
    Mode mode = Mode.dry,
    String fingerprint = 'a-digest',
    required DateTime start,
    int? exitCode,
    List<String> issues = const <String>[],
  }) async {
    final FileRecorder recorder = await FileRecorder.open(
      id: RunId(id),
      directory: directory,
      clock: clock,
      redactor: Redactor.none,
    );
    final RunRecord begun = header(
      id,
      program: program,
      mode: mode,
      fingerprint: fingerprint,
      start: start,
    );
    await recorder.save(begun);
    if (exitCode != null) {
      await recorder.save(
        begun.closed(
          end: start.add(const Duration(minutes: 1)),
          exitCode: exitCode,
          steps: const <StepRecord>[],
          issues: issues,
        ),
      );
    }
    await recorder.close();
  }

  final DateTime noon = DateTime.utc(2026, 8, 7, 12);

  group('listing', () {
    setUp(() async {
      await writeRun('run-a', start: noon, exitCode: 0);
      await writeRun('run-b', start: noon.add(const Duration(hours: 1)), exitCode: 0);
      await writeRun(
        'run-c',
        program: 'onboard-thing',
        mode: Mode.run,
        start: noon.add(const Duration(hours: 2)),
        exitCode: 1,
      );
    });

    test('newest first', () async {
      final List<RunRecord> runs = await FileRunStore(directory: directory).list();

      expect(runs.map((RunRecord r) => r.id.value), <String>['run-c', 'run-b', 'run-a']);
    });

    test('filtered by program, by mode, and cut off by the limit', () async {
      final FileRunStore store = FileRunStore(directory: directory);

      expect(
        (await store.list(
          program: const ProgramName('onboard-thing'),
        )).map((RunRecord r) => r.id.value),
        <String>['run-c'],
      );
      expect((await store.list(mode: Mode.dry)).map((RunRecord r) => r.id.value), <String>[
        'run-b',
        'run-a',
      ]);
      expect((await store.list(limit: 2)).map((RunRecord r) => r.id.value), <String>[
        'run-c',
        'run-b',
      ]);
    });

    test('a run is read by name, and a name nobody used answers nothing', () async {
      final FileRunStore store = FileRunStore(directory: directory);

      expect(
        (await store.read(const RunId('run-b')))?.program,
        const ProgramName('deploy-something'),
      );
      expect(await store.read(const RunId('run-z')), isNull);
    });

    test('a root that does not exist yet lists nothing rather than failing', () async {
      final FileRunStore store = FileRunStore(directory: RunDirectory(p.join(temp.path, 'none')));

      expect(await store.list(), isEmpty);
    });
  });

  group('the gate asks for the last clean dry run', () {
    test('a clean dry run for exactly this input is the answer', () async {
      await writeRun('run-old', start: noon, exitCode: 0);
      await writeRun('run-new', start: noon.add(const Duration(hours: 1)), exitCode: 0);

      final RunRecord? found = await FileRunStore(
        directory: directory,
      ).lastCleanDryRun(program: const ProgramName('deploy-something'), fingerprint: 'a-digest');

      expect(found?.id, const RunId('run-new'), reason: 'the most recent one');
    });

    test('a dry run with the same input that failed is not one', () async {
      await writeRun('run-failed', start: noon, exitCode: 1);

      expect(
        await FileRunStore(
          directory: directory,
        ).lastCleanDryRun(program: const ProgramName('deploy-something'), fingerprint: 'a-digest'),
        isNull,
      );
    });

    test('a dry run that reported issues is not one either', () async {
      await writeRun(
        'run-issued',
        start: noon,
        exitCode: 2,
        issues: const <String>['x: no certificate'],
      );

      expect(
        await FileRunStore(
          directory: directory,
        ).lastCleanDryRun(program: const ProgramName('deploy-something'), fingerprint: 'a-digest'),
        isNull,
      );
    });

    test('a clean dry run of a different input is not one', () async {
      await writeRun('run-other', start: noon, fingerprint: 'another-digest', exitCode: 0);

      expect(
        await FileRunStore(
          directory: directory,
        ).lastCleanDryRun(program: const ProgramName('deploy-something'), fingerprint: 'a-digest'),
        isNull,
      );
    });

    test('a clean REAL run does not admit another real run', () async {
      await writeRun('run-real', mode: Mode.run, start: noon, exitCode: 0);

      expect(
        await FileRunStore(
          directory: directory,
        ).lastCleanDryRun(program: const ProgramName('deploy-something'), fingerprint: 'a-digest'),
        isNull,
      );
    });

    test('a clean dry run of another program does not admit this one', () async {
      await writeRun('run-elsewhere', program: 'onboard-thing', start: noon, exitCode: 0);

      expect(
        await FileRunStore(
          directory: directory,
        ).lastCleanDryRun(program: const ProgramName('deploy-something'), fingerprint: 'a-digest'),
        isNull,
      );
    });
  });

  group('reading the events of a run that has finished', () {
    late FileRunStore store;

    setUp(() async {
      final FileRecorder recorder = await FileRecorder.open(
        id: const RunId('run-done'),
        directory: directory,
        clock: clock,
        redactor: Redactor.none,
      );
      final RunRecord begun = header('run-done', start: noon);
      await recorder.save(begun);

      recorder.record(
        (int s, DateTime at) => RunStarted(
          sequence: s,
          at: at,
          program: const ProgramName('deploy-something'),
          mode: 'dry',
        ),
      );
      for (int i = 0; i < 4; i++) {
        recorder.record(
          (int s, DateTime at) =>
              Log(sequence: s, at: at, step: step, level: LogLevel.info, message: 'line $i'),
        );
      }
      recorder.record(
        (int s, DateTime at) =>
            RunFinished(sequence: s, at: at, exitCode: 0, issues: const <String>[]),
      );
      await recorder.close();
      await recorder.save(
        begun.closed(end: noon, exitCode: 0, steps: const <StepRecord>[], issues: const <String>[]),
      );

      store = FileRunStore(directory: directory, poll: const Duration(milliseconds: 5));
    });

    test('everything, in order, and the stream ends', () async {
      final List<RunEvent> events = await store.events(const RunId('run-done')).toList();

      expect(events, hasLength(6));
      expect(events.map((RunEvent e) => e.sequence), <int>[0, 1, 2, 3, 4, 5]);
      expect(events.first, isA<RunStarted>());
      expect(events.last, isA<RunFinished>());
    });

    test('from a sequence number, nothing before it and nothing missing after it', () async {
      final List<RunEvent> events = await store.events(const RunId('run-done'), from: 3).toList();

      expect(events.map((RunEvent e) => e.sequence), <int>[3, 4, 5]);
      expect((events.first as Log).message, 'line 2');
    });

    test('a run whose events file is empty ends at once', () async {
      await writeRun('run-silent', start: noon, exitCode: 0);

      expect(await store.events(const RunId('run-silent')).toList(), isEmpty);
    });

    test('a line without its newline yet is not an event', () async {
      // Half a line, exactly as a killed process leaves one.
      const RecordCodec codec = RecordCodec();
      final String half = jsonEncode(
        codec.event(
          Log(sequence: 6, at: noon, step: step, level: LogLevel.info, message: 'never finished'),
        ),
      ).substring(0, 20);
      await File(
        directory.events(const RunId('run-done')),
      ).writeAsString(half, mode: FileMode.append, flush: true);

      final List<RunEvent> events = await store.events(const RunId('run-done')).toList();

      expect(events, hasLength(6), reason: 'the fragment is not one of them');
    });
  });

  group('watching a run that is still going', () {
    test('events arrive as they are appended, and the stream ends when the run does', () async {
      const RunId id = RunId('run-live');
      final FileRecorder recorder = await FileRecorder.open(
        id: id,
        directory: directory,
        clock: clock,
        redactor: Redactor.none,
      );
      final RunRecord begun = header('run-live', start: noon);
      await recorder.save(begun);

      final FileRunStore store = FileRunStore(
        directory: directory,
        poll: const Duration(milliseconds: 5),
      );
      final List<RunEvent> seen = <RunEvent>[];
      final Completer<void> ended = Completer<void>();
      final StreamSubscription<RunEvent> watching = store
          .events(id)
          .listen(seen.add, onDone: ended.complete);

      recorder.record(
        (int s, DateTime at) => RunStarted(
          sequence: s,
          at: at,
          program: const ProgramName('deploy-something'),
          mode: 'run',
        ),
      );
      await waitUntil(() => seen.length == 1);

      recorder.record(
        (int s, DateTime at) =>
            Log(sequence: s, at: at, step: step, level: LogLevel.info, message: 'halfway'),
      );
      await waitUntil(() => seen.length == 2);
      expect(ended.isCompleted, isFalse, reason: 'the run is still going');

      recorder.record(
        (int s, DateTime at) =>
            RunFinished(sequence: s, at: at, exitCode: 0, issues: const <String>[]),
      );
      await recorder.close();

      await ended.future.timeout(const Duration(seconds: 5));
      await watching.cancel();

      expect(seen, hasLength(3));
      expect(seen.last, isA<RunFinished>());
    });

    test('a fragment is held back until its line is complete', () async {
      const RunId id = RunId('run-torn');
      final FileRecorder recorder = await FileRecorder.open(
        id: id,
        directory: directory,
        clock: clock,
        redactor: Redactor.none,
      );
      await recorder.save(header('run-torn', start: noon));
      recorder.record(
        (int s, DateTime at) => RunStarted(
          sequence: s,
          at: at,
          program: const ProgramName('deploy-something'),
          mode: 'run',
        ),
      );
      await recorder.close();

      const RecordCodec codec = RecordCodec();
      final String line = jsonEncode(
        codec.event(
          Log(sequence: 1, at: noon, step: step, level: LogLevel.info, message: 'arrives later'),
        ),
      );
      final File events = File(directory.events(id));
      await events.writeAsString(line, mode: FileMode.append, flush: true);

      final FileRunStore store = FileRunStore(
        directory: directory,
        poll: const Duration(milliseconds: 5),
      );
      final List<RunEvent> seen = <RunEvent>[];
      final StreamSubscription<RunEvent> watching = store.events(id).listen(seen.add);

      await waitUntil(() => seen.length == 1);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(seen, hasLength(1), reason: 'the second line has no newline yet');

      await events.writeAsString('\n', mode: FileMode.append, flush: true);
      await waitUntil(() => seen.length == 2);
      expect((seen.last as Log).message, 'arrives later');

      await watching.cancel();
    });

    test('a run that ended without saying so in its events still ends the stream', () async {
      const RunId id = RunId('run-quiet');
      final FileRecorder recorder = await FileRecorder.open(
        id: id,
        directory: directory,
        clock: clock,
        redactor: Redactor.none,
      );
      final RunRecord begun = header('run-quiet', start: noon);
      await recorder.save(begun);
      recorder.record(
        (int s, DateTime at) =>
            Log(sequence: s, at: at, step: step, level: LogLevel.info, message: 'only this'),
      );
      await recorder.close();
      await recorder.save(
        begun.closed(end: noon, exitCode: 1, steps: const <StepRecord>[], issues: const <String>[]),
      );

      final FileRunStore store = FileRunStore(
        directory: directory,
        poll: const Duration(milliseconds: 5),
      );

      expect(await store.events(id).toList(), hasLength(1));
    });
  });

  group('reading only as far as the answer', () {
    /// A run directory whose header is not a run header at all. Reading one throws, which is what
    /// makes it a probe: a lookup that never reaches it is the only one that can answer.
    Future<void> writeDamaged(String id) async {
      final Directory dir = Directory(directory.of(RunId(id)));
      await dir.create(recursive: true);
      await File(directory.header(RunId(id))).writeAsString('this is not a run header');
    }

    // The ids carry the mint stamp, so they sort chronologically. Written out in full rather than
    // generated, because which one is older than which is the whole subject here.
    const String older = '20260807T110000Z-1-aaaaaaaa';
    const String wanted = '20260807T120000Z-2-bbbbbbbb';
    const String newer = '20260807T130000Z-3-cccccccc';

    test('the gate stops at its proof and never reads what is older than it', () async {
      // The store this measures against is one where reading everything CANNOT work: the older
      // record would throw. So a lookup that answers at all has read only as far as its answer.
      await writeDamaged(older);
      await writeRun(wanted, start: noon, exitCode: 0);
      final FileRunStore store = FileRunStore(directory: directory);

      final RunRecord? proof = await store.lastCleanDryRun(
        program: const ProgramName('deploy-something'),
        fingerprint: 'a-digest',
      );

      expect(proof?.id.value, wanted);
    });

    test('a damaged header the gate DOES walk past is still refused, never skipped', () async {
      // The counter-probe of the test above, and the reason it is here: an early stop that answered
      // by ignoring what it could not read would pass that test while hiding real damage. A record
      // NEWER than the proof stands between the walk and the answer, so it has to be met.
      await writeRun(wanted, start: noon, exitCode: 0);
      await writeDamaged(newer);
      final FileRunStore store = FileRunStore(directory: directory);

      expect(
        store.lastCleanDryRun(
          program: const ProgramName('deploy-something'),
          fingerprint: 'a-digest',
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'a newer run that does not match is passed over, and the older proof is still found',
      () async {
        // The other way an early stop goes wrong: stopping at the first record rather than the first
        // MATCHING one. The newest here is a clean dry run of the same program under a different
        // fingerprint, which is exactly the shape a second attempt with changed answers leaves.
        await writeRun(wanted, start: noon, exitCode: 0);
        await writeRun(
          newer,
          start: noon.add(const Duration(hours: 1)),
          fingerprint: 'another',
          exitCode: 0,
        );
        final FileRunStore store = FileRunStore(directory: directory);

        final RunRecord? proof = await store.lastCleanDryRun(
          program: const ProgramName('deploy-something'),
          fingerprint: 'a-digest',
        );

        expect(proof?.id.value, wanted);
      },
    );

    test('a listing stops at its limit, and hands back what it read newest first', () async {
      await writeDamaged(older);
      await writeRun(wanted, start: noon, exitCode: 0);
      await writeRun(newer, start: noon.add(const Duration(hours: 1)), exitCode: 0);
      final FileRunStore store = FileRunStore(directory: directory);

      final List<RunRecord> two = await store.list(limit: 2);

      expect(two.map((RunRecord r) => r.id.value), <String>[newer, wanted]);
    });
  });
}

/// Waits for [ready] to become true, or gives up rather than hanging the whole suite.
Future<void> waitUntil(bool Function() ready) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('the condition never became true');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
