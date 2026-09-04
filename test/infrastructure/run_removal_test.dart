import 'dart:convert';
import 'dart:io';

import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:ansiwise_core/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Every invocation of the engine writes a record directory and nothing ever removed one, so the
/// number a machine held was the number of invocations it had ever had. This is the bound, what it
/// never takes, and what a reader is left with where it took something.
void main() {
  late Directory temp;
  late RunDirectory directory;
  final FakeClock clock = FakeClock();

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ansiwise-removal-');
    directory = RunDirectory(temp.path);
  });

  tearDown(() async {
    try {
      await temp.delete(recursive: true);
    } on FileSystemException {
      // Windows can hold a handle open for a moment after a file is closed.
    }
  });

  final DateTime noon = DateTime.utc(2026, 8, 7, 12);

  RunRecord header(String id, {required DateTime start, RunId? resumes}) => RunRecord(
    id: RunId(id),
    program: const ProgramName('deploy-something'),
    mode: Mode.dry,
    argv: const <String>['ansiwise', 'deploy-something'],
    start: start,
    stage: const Stage('prod'),
    role: const Role('master'),
    fqdn: const Fqdn('m1.example.com'),
    commit: 'abc1234',
    fingerprint: 'a-digest',
    resumes: resumes,
  );

  /// One whole invocation of the engine: it opens its record, writes its opening header — which is
  /// where the bound is applied — and then its closing one.
  Future<void> invoke(
    String id, {
    required DateTime start,
    required int keep,
    bool finishes = true,
    RunId? resumes,
  }) async {
    final FileRecorder recorder = await FileRecorder.open(
      id: RunId(id),
      directory: directory,
      clock: clock,
      redactor: Redactor.none,
      retention: RunRetention(keep),
    );
    final RunRecord begun = header(id, start: start, resumes: resumes);
    await recorder.save(begun);
    if (finishes) {
      await recorder.save(
        begun.closed(
          end: start.add(const Duration(minutes: 1)),
          exitCode: 0,
          steps: const <StepRecord>[],
          issues: const <String>[],
        ),
      );
    }
    await recorder.close();
  }

  List<String> recordsOnDisk() => <String>[
    for (final FileSystemEntity entry in temp.listSync())
      if (entry is Directory) p.basename(entry.path),
  ]..sort();

  Future<RemovedRuns?> removed() => RunRemoval(directory: directory, clock: clock).removed();

  group('the bound a machine is held to', () {
    test('a program invoked past the bound leaves exactly the bound behind', () async {
      // MEASURED BY INVOKING IT, not reasoned: twelve invocations of one program against a bound of
      // four, which is the shape of a program on a timer.
      for (int at = 0; at < 12; at++) {
        await invoke(
          'run-${at.toString().padLeft(2, '0')}',
          start: noon.add(Duration(minutes: at)),
          keep: 4,
        );
      }

      expect(recordsOnDisk(), <String>['run-08', 'run-09', 'run-10', 'run-11']);
    });

    test('nothing is removed while the machine is inside its bound', () async {
      for (int at = 0; at < 4; at++) {
        await invoke('run-0$at', start: noon.add(Duration(minutes: at)), keep: 4);
      }

      expect(recordsOnDisk(), <String>['run-00', 'run-01', 'run-02', 'run-03']);
      expect(await removed(), isNull, reason: 'a machine that removed nothing says nothing');
    });

    test('the oldest go and the newest stay, whatever order the names are in', () async {
      // The order is the one a listing shows, which is by when each run BEGAN. Names that sort the
      // other way round would keep the wrong four if anything ordered by name here.
      await invoke('zzz', start: noon, keep: 2);
      await invoke('mmm', start: noon.add(const Duration(hours: 1)), keep: 2);
      await invoke('aaa', start: noon.add(const Duration(hours: 2)), keep: 2);

      expect(recordsOnDisk(), <String>['aaa', 'mmm']);
    });
  });

  group('what it never removes', () {
    test('a run that has not finished stays, however far past the bound it is', () async {
      // PLANTED: one record with no end, three finished ones behind it, and a bound of two.
      await invoke('still-going', start: noon, keep: 2, finishes: false);
      for (int at = 1; at < 4; at++) {
        await invoke('run-0$at', start: noon.add(Duration(minutes: at)), keep: 2);
      }

      expect(recordsOnDisk(), <String>[
        'run-02',
        'run-03',
        'still-going',
      ], reason: 'a run still being written is a run somebody may be following');
    });

    test('a run another record names as the one it resumes stays', () async {
      // PLANTED: the oldest record is the one the newest resumes, with a bound of two.
      await invoke('the-first-half', start: noon, keep: 2);
      await invoke('run-01', start: noon.add(const Duration(minutes: 1)), keep: 2);
      await invoke(
        'run-02',
        start: noon.add(const Duration(minutes: 2)),
        keep: 2,
        resumes: const RunId('the-first-half'),
      );

      expect(recordsOnDisk(), <String>[
        'run-01',
        'run-02',
        'the-first-half',
      ], reason: 'a record naming a run that cannot be opened is a record that lies about it');
    });

    test('the innocent case beside them goes, so a clean answer is not nobody looking', () async {
      // The same three records with nothing planted in them: the oldest is finished and nothing
      // resumes it, and it is the one that goes. Without this the two tests above would pass on a
      // removal that removes nothing at all.
      await invoke('run-00', start: noon, keep: 2);
      await invoke('run-01', start: noon.add(const Duration(minutes: 1)), keep: 2);
      await invoke('run-02', start: noon.add(const Duration(minutes: 2)), keep: 2);

      expect(recordsOnDisk(), <String>['run-01', 'run-02']);
    });

    test('a directory whose header does not parse is left where it is', () async {
      await invoke('run-00', start: noon, keep: 1);
      File(directory.header(const RunId('run-00'))).writeAsStringSync('{ this is not a header');

      await invoke('run-01', start: noon.add(const Duration(minutes: 1)), keep: 1);

      expect(recordsOnDisk(), <String>[
        'run-00',
        'run-01',
      ], reason: 'a record this cannot read is a record it must not delete');
    });
  });

  group('what a reader is left with', () {
    test('the note says how many were removed, between which two, and when', () async {
      clock.advance(const Duration(days: 1));
      await invoke('run-00', start: noon, keep: 1);
      await invoke('run-01', start: noon.add(const Duration(minutes: 1)), keep: 1);

      final RemovedRuns? note = await removed();
      expect(note?.count, 1);
      expect(note?.oldest, const RunId('run-00'));
      expect(note?.newest, const RunId('run-00'));
      expect(note?.at, clock.now());
    });

    test('later removals add to it, and the oldest end stays where it was', () async {
      await invoke('run-00', start: noon, keep: 1);
      await invoke('run-01', start: noon.add(const Duration(minutes: 1)), keep: 1);
      await invoke('run-02', start: noon.add(const Duration(minutes: 2)), keep: 1);
      await invoke('run-03', start: noon.add(const Duration(minutes: 3)), keep: 1);

      final RemovedRuns? note = await removed();
      expect(note?.count, 3);
      expect(note?.oldest, const RunId('run-00'));
      expect(note?.newest, const RunId('run-02'));
    });

    test('it is one file beside the runs, and the listing steps over it', () async {
      await invoke('run-00', start: noon, keep: 1);
      await invoke('run-01', start: noon.add(const Duration(minutes: 1)), keep: 1);

      expect(File(directory.removals).existsSync(), isTrue);
      expect(recordsOnDisk(), <String>['run-01'], reason: 'it is a file and not a run');
      expect(jsonDecode(File(directory.removals).readAsStringSync()), <String, Object?>{
        'count': 1,
        'oldest': 'run-00',
        'newest': 'run-00',
        'at': clock.now().toIso8601String(),
      }, reason: 'an operator opens this with whatever is at hand');
    });

    test('a note that does not parse is reported, not read as nothing removed', () async {
      File(directory.removals).writeAsStringSync('[]');

      expect(
        removed(),
        throwsA(isA<FormatException>()),
        reason:
            'a machine that removed records and cannot say how many would answer the same nothing '
            'as one that removed none',
      );
    });
  });

  group('the bound a store is given when nobody states one', () {
    test('is the same number the configuration defaults to', () {
      expect(const RunRetention().keep, RunRetention.defaultKeep);
      expect(
        const Configuration(plugins: <String>['one']).retention,
        const RunRetention(),
        reason: 'the engine and the file it is configured by cannot hold two different bounds',
      );
    });
  });
}
