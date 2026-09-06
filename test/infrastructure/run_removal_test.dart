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

  group('a record another account owns', () {
    /// One pass of the bound over the store, told which of the records are somebody else's.
    ///
    /// ANSWERED RATHER THAN ARRANGED. A directory owned by another account cannot be created by an
    /// account that is not that one — changing an owner needs root — so a store with records of two
    /// accounts in it can only be driven by answering the question the removal asks.
    Future<String?> applyWith({required int keep, Set<String> theirs = const <String>{}}) =>
        RunRemoval(
          directory: directory,
          clock: clock,
          retention: RunRetention(keep),
          otherAccounts: (List<String> paths) async => <String, String>{
            for (final String path in paths)
              if (theirs.contains(p.basename(path))) path: 'root',
          },
        ).apply();

    /// Four finished records, an hour apart, and nothing removed while they are planted.
    Future<void> plantFour() async {
      for (int at = 0; at < 4; at++) {
        await invoke('run-0$at', start: noon.add(Duration(minutes: at)), keep: 1000);
      }
    }

    test('is left where it is, and the bound is counted over this account\'s own', () async {
      // PLANTED: the oldest of four records belongs to another account, against a bound of two.
      // This is the shape measured on a master whose store held 501 records, 499 of them root's:
      // counting all of them puts this account's own records past a bound another account filled.
      await plantFour();

      await applyWith(keep: 2, theirs: <String>{'run-00'});

      expect(recordsOnDisk(), <String>[
        'run-00',
        'run-02',
        'run-03',
      ], reason: 'a record this account does not own is not this account\'s to remove');
      final RemovedRuns? note = await removed();
      expect(note?.count, 1, reason: 'the note says what THIS account removed');
      expect(note?.oldest, const RunId('run-01'));
      expect(note?.newest, const RunId('run-01'));
    });

    test('is named once, with how many there are and whose they are', () async {
      await plantFour();

      final String? said = await applyWith(keep: 2, theirs: <String>{'run-00', 'run-01'});

      expect(
        said,
        allOf(
          contains('another account owns 2 of the 4 run records in ${temp.path}'),
          contains('root (2)'),
          contains('the bound of 2 records is held over the rest'),
        ),
        reason: 'a store that never shrinks and one that is mostly somebody else\'s look alike',
      );
    });

    test('the innocent case beside it: with nothing elsewhere, the oldest two go', () async {
      // Without this the two tests above would pass on a removal that removes nothing at all, and
      // on one that says the same sentence whoever owns what.
      await plantFour();

      final String? said = await applyWith(keep: 2);

      expect(recordsOnDisk(), <String>['run-02', 'run-03']);
      expect(said, isNull, reason: 'there was nothing to leave alone and nothing to say');
    });

    test('a record this account owns and cannot remove ends the run, naming it', () async {
      // PLANTED: the oldest of three records is a directory this account owns and may not write, so
      // the file system refuses to remove what is inside it. That is the state the machine was in
      // when the engine died with a Dart stack and exit 255.
      for (int at = 0; at < 3; at++) {
        await invoke('run-0$at', start: noon.add(Duration(minutes: at)), keep: 1000);
      }
      final String held = directory.of(const RunId('run-00'));
      await setPermissions(held, 320);
      addTearDown(() => setPermissions(held, 448));

      await expectLater(
        RunRemoval(directory: directory, clock: clock, retention: const RunRetention(2)).apply(),
        throwsA(
          isA<RecordNotRemoved>()
              .having((RecordNotRemoved e) => e.path, 'path', held)
              .having(
                (RecordNotRemoved e) => e.message,
                'message',
                allOf(contains(held), contains('what the file system said')),
              ),
        ),
        reason: 'the refusal has to name the record, or the operator is left with a stack',
      );
    }, skip: Platform.isWindows ? 'Windows has no POSIX permission bits' : null);
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
