import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../domain/clock.dart';
import '../domain/run_retention.dart';
import '../model/failures.dart';
import '../model/names.dart';
import '../model/removed_runs.dart';
import '../model/run_record.dart';
import 'permissions.dart';
import 'record_codec.dart';
import 'run_directory.dart';

/// Holds a machine to the number of run records it keeps, and writes down that it did.
///
/// **IT RUNS WHERE A RUN'S HEADER LANDS, so no program names it.** A retention written into a
/// program would bound that one program, and the next program that runs on a timer grows the store
/// the same way. Writing one program's records somewhere volatile instead buys the same silence and
/// loses the record that says whether that program proved anything.
///
/// **THE HEADER AND NOT THE OPEN, and the difference is a record that would be taken wrongly.** A
/// run's own header is the first moment the run is a record: before it there is a directory with
/// nothing in it, and the run it RESUMES is named nowhere on the disk — so a removal run any earlier
/// would delete the first half of the story of the very run that is starting.
///
/// **TWO RECORDS ARE NEVER REMOVED, AND BOTH ARE SOMEBODY'S CURRENT READING.** A run that has not
/// finished is still being written, and a client may be following its events. A run another record
/// names as the one it resumes is the first half of a story the second half points at, and removing
/// it leaves a record naming a run that cannot be opened. Everything else, once it is past the
/// bound, is a record whose only reader would be a history — and [RemovedRuns] is what that reader
/// gets instead.
///
/// **NOTHING IS OPENED WHILE THE MACHINE IS INSIDE ITS BOUND.** The listing alone answers that, so
/// the ordinary run reads no header at all. A run that is over the bound reads one header per record
/// on disk, and the bound itself is what keeps that number small.
///
/// **THE BOUND IS OVER THE RECORDS THIS ACCOUNT OWNS, and every other record is left where it is.**
/// One machine's store is written by every account that runs the engine on it: a program on a
/// minutely timer runs as root while an operator runs the deployment programs as themselves, and
/// then almost every record belongs to root. Counting all of them makes this account's own history
/// the thing that is spent to stay inside a bound the other account keeps pushing past — measured
/// on 2026-09-06, a store of 501 records, 499 of them root's, whose note said 1,078 records had
/// been removed and named the machine's own first record as the oldest of them. Removing them is
/// not possible either, and the attempt is what ends the run.
final class RunRemoval {
  /// Holds the records under [directory] to [retention], stamping the note with [clock].
  const RunRemoval({
    required this.directory,
    required this.clock,
    this.retention = const RunRetention(),
    this.otherAccounts = recordsOfOtherAccounts,
  });

  /// Where the runs are.
  final RunDirectory directory;

  /// What stamps the note with the moment a removal ran.
  final Clock clock;

  /// How many records this machine keeps.
  final RunRetention retention;

  /// What answers which of the records here another account owns, and which account that is.
  ///
  /// A test supplies its own. A directory owned by another account cannot be planted by an account
  /// that is not that one, because changing an owner needs root — so the only way to drive this
  /// rule over a mixed store is to answer the question rather than to arrange it.
  final Future<Map<String, String>> Function(List<String> paths) otherAccounts;

  static const RecordCodec _codec = RecordCodec();

  /// Indented, because this file is read by a person with whatever is at hand.
  static const JsonEncoder _noteFormat = JsonEncoder.withIndent('  ');

  /// Removes the records this account owns past the bound, and adds what it took to the note
  /// beside the runs. Answers what it left where it was because another account owns it, or null
  /// where every record here is this account's own.
  ///
  /// What is left afterwards is the newest [RunRetention.keep] of this account's records, plus
  /// every record past them that may not be taken, plus every record of another account. A
  /// directory whose header cannot be read is not a record, is counted as nothing, and stays.
  ///
  /// A record that is gone by the time this reaches it was removed by another run doing the same
  /// thing, and is not counted twice. A record this account OWNS and that the file system refuses
  /// raises [RecordNotRemoved]: a machine that cannot remove its own records is one where this
  /// bound does not hold, and a run that carried on would leave that unsaid.
  Future<String?> apply() async {
    final Directory root = Directory(directory.root);
    if (!await root.exists()) {
      return null;
    }

    final List<String> names = <String>[];
    await for (final FileSystemEntity entry in root.list(followLinks: false)) {
      if (entry is Directory) {
        names.add(p.basename(entry.path));
      }
    }
    if (names.length <= retention.keep) {
      return null;
    }

    // Asked only where the store is over the bound counting every directory in it, because inside
    // that nothing is removed whoever owns it, and the answer would change nothing.
    final Map<String, String> elsewhere = await otherAccounts(<String>[
      for (final String name in names) directory.of(RunId(name)),
    ]);
    final String? leftAlone = elsewhere.isEmpty ? null : _leftAlone(names.length, elsewhere);

    final List<RunRecord> records = <RunRecord>[];
    for (final String name in names) {
      final RunRecord? record = await _header(RunId(name));
      if (record != null) {
        records.add(record);
      }
    }
    records.sort(RunRecord.newestFirst);

    // Collected from every record on disk and not only from the ones being kept, and not only from
    // this account's. A record naming a resume target is often past the bound in the same pass, and
    // removing the target in that pass would break the link before anything read it.
    final Set<String> resumed = <String>{
      for (final RunRecord each in records)
        if (each.resumes case final RunId earlier) earlier.value,
    };

    // The bound is counted here and nowhere else, over this account's own records in the same order
    // the whole store was sorted into. Counting the rest would put this account's oldest records
    // past a bound that another account's records filled.
    final List<RunRecord> ours = <RunRecord>[
      for (final RunRecord each in records)
        if (!elsewhere.containsKey(directory.of(each.id))) each,
    ];

    final List<RunId> taken = <RunId>[];
    for (int at = retention.keep; at < ours.length; at++) {
      final RunRecord record = ours[at];
      if (!record.finished || resumed.contains(record.id.value)) {
        continue;
      }
      if (await _remove(record.id)) {
        taken.add(record.id);
      }
    }
    if (taken.isEmpty) {
      return leftAlone;
    }

    // The records were ordered newest first, so the first one taken is the newest of this pass and
    // the last one is the oldest of it. The oldest end of the whole range is whatever this machine
    // removed first, which an earlier note already holds.
    final RemovedRuns? before = await removed();
    await _write(
      RemovedRuns(
        count: (before?.count ?? 0) + taken.length,
        oldest: before?.oldest ?? taken.last,
        newest: taken.first,
        at: clock.now(),
      ),
    );
    return leftAlone;
  }

  /// The two sentences a run says about the records it left where they were.
  ///
  /// It says HOW MANY of the [all] records here belong elsewhere and WHICH accounts own them, with
  /// a count each, because a store that never shrinks and a store that is mostly somebody else's
  /// look identical from the outside. Said once per invocation and not once per record: a machine
  /// where this happens at all has hundreds of them.
  String _leftAlone(int all, Map<String, String> elsewhere) {
    final Map<String, int> perAccount = <String, int>{};
    for (final String account in elsewhere.values) {
      perAccount[account] = (perAccount[account] ?? 0) + 1;
    }
    final String who = <String>[
      for (final MapEntry<String, int> each in perAccount.entries) '${each.key} (${each.value})',
    ].join(', ');
    return 'another account owns ${elsewhere.length} of the $all run records in ${directory.root}: '
        '$who\n'
        'this account does not count or remove what it does not own, so the bound of '
        '${retention.keep} records is held over the rest';
  }

  /// What this machine has removed, or null where it has removed nothing.
  ///
  /// Throws [FormatException] where the note is there and does not parse. Not answered as an
  /// absence: a machine that has removed records and cannot say how many would report the same
  /// nothing as one that has removed none, and those are the two answers this file exists to tell
  /// apart.
  Future<RemovedRuns?> removed() async {
    final File note = File(directory.removals);
    if (!await note.exists()) {
      return null;
    }
    final Object? parsed = jsonDecode(await note.readAsString());
    if (parsed is! Map<String, Object?>) {
      throw FormatException('${note.path} does not hold what this machine has removed');
    }
    return _codec.removedRunsFrom(parsed);
  }

  /// Whether [id] was removed here, as opposed to being gone before this reached it.
  ///
  /// Throws [RecordNotRemoved] where it is still there. Every record that reaches this belongs to
  /// the account running, so a refusal here is about this account's own record and nothing else.
  Future<bool> _remove(RunId id) async {
    final Directory home = Directory(directory.of(id));
    try {
      await home.delete(recursive: true);
    } on FileSystemException catch (refused) {
      if (await home.exists()) {
        throw RecordNotRemoved(path: home.path, refused: refused.toString());
      }
      return false;
    }
    // What a run that never made a directory left beside the runs. It belongs to this identifier, so
    // it goes with it — otherwise the one file naming a removed run outlives the record itself.
    final File said = File(directory.startupLog(id));
    if (await said.exists()) {
      await said.delete();
    }
    return true;
  }

  Future<void> _write(RemovedRuns removed) async {
    final File pending = File(directory.pendingRemovals);
    await pending.writeAsString(_noteFormat.convert(_codec.removedRuns(removed)), flush: true);
    await setPermissions(pending.path, recordFileMode);
    await pending.rename(directory.removals);
  }

  /// The header of [id], or null where there is none that can be read.
  ///
  /// **DAMAGE ANSWERS AS ABSENT HERE, and only here.** A directory this cannot read is a directory
  /// it must not delete, and a run that refused to start over one broken header would be a machine
  /// where one damaged file stops every run. The store reads the same file and throws, which is what
  /// puts the damage in front of whoever lists the runs.
  Future<RunRecord?> _header(RunId id) async {
    final File file = File(directory.header(id));
    if (!await file.exists()) {
      return null;
    }
    try {
      final Object? parsed = jsonDecode(await file.readAsString());
      return parsed is Map<String, Object?> ? _codec.runFrom(parsed) : null;
    } on FormatException {
      return null;
    }
  }
}
