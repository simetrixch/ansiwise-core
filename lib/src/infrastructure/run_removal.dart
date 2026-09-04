import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../domain/clock.dart';
import '../domain/run_retention.dart';
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
final class RunRemoval {
  /// Holds the records under [directory] to [retention], stamping the note with [clock].
  const RunRemoval({
    required this.directory,
    required this.clock,
    this.retention = const RunRetention(),
  });

  /// Where the runs are.
  final RunDirectory directory;

  /// What stamps the note with the moment a removal ran.
  final Clock clock;

  /// How many records this machine keeps.
  final RunRetention retention;

  static const RecordCodec _codec = RecordCodec();

  /// Indented, because this file is read by a person with whatever is at hand.
  static const JsonEncoder _noteFormat = JsonEncoder.withIndent('  ');

  /// Removes the records past the bound, and adds what it took to the note beside the runs.
  ///
  /// What is left afterwards is the newest [RunRetention.keep] records, plus every record past them
  /// that may not be taken. A directory whose header cannot be read is not a record, is counted as
  /// nothing, and stays.
  ///
  /// A record that is gone by the time this reaches it was removed by another run doing the same
  /// thing, and is not counted twice. Anything else the file system refuses is thrown: a machine
  /// that cannot delete its own records is one where this bound does not hold, and a run that
  /// carried on would leave that unsaid.
  Future<void> apply() async {
    final Directory root = Directory(directory.root);
    if (!await root.exists()) {
      return;
    }

    final List<String> names = <String>[];
    await for (final FileSystemEntity entry in root.list(followLinks: false)) {
      if (entry is Directory) {
        names.add(p.basename(entry.path));
      }
    }
    if (names.length <= retention.keep) {
      return;
    }

    final List<RunRecord> records = <RunRecord>[];
    for (final String name in names) {
      final RunRecord? record = await _header(RunId(name));
      if (record != null) {
        records.add(record);
      }
    }
    records.sort(RunRecord.newestFirst);

    // Collected from every record on disk and not only from the ones being kept. A record naming a
    // resume target is often past the bound in the same pass, and removing the target in that pass
    // would break the link before anything read it.
    final Set<String> resumed = <String>{
      for (final RunRecord each in records)
        if (each.resumes case final RunId earlier) earlier.value,
    };

    final List<RunId> taken = <RunId>[];
    for (int at = retention.keep; at < records.length; at++) {
      final RunRecord record = records[at];
      if (!record.finished || resumed.contains(record.id.value)) {
        continue;
      }
      if (await _remove(record.id)) {
        taken.add(record.id);
      }
    }
    if (taken.isEmpty) {
      return;
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
  Future<bool> _remove(RunId id) async {
    final Directory home = Directory(directory.of(id));
    try {
      await home.delete(recursive: true);
    } on FileSystemException {
      if (await home.exists()) {
        rethrow;
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
