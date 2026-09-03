import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../domain/run_store.dart';
import '../model/mode.dart';
import '../model/names.dart';
import '../model/run_event.dart';
import '../model/run_record.dart';
import 'record_codec.dart';
import 'run_directory.dart';

/// Reads back what `FileRecorder` wrote.
///
/// This is the other half of the record and it never writes. A run in progress is being written by a
/// recorder in one process and read by this in another — the run itself is detached, and whoever is
/// watching it started later and may leave before it ends.
final class FileRunStore implements RunStore {
  /// Reads the runs kept under [directory].
  ///
  /// [poll] is how long it waits before looking at a live run's event file again.
  const FileRunStore({required this.directory, this.poll = const Duration(milliseconds: 200)});

  /// Where the runs are.
  final RunDirectory directory;

  /// How often the event file of a run that is still going is looked at again.
  ///
  /// Polling and not a file-system watch. A watch answers differently on each operating system, does
  /// not fire at all on some network file systems, and needs this same loop as a fallback anyway —
  /// so the fallback is the whole implementation.
  final Duration poll;

  static const RecordCodec _codec = RecordCodec();

  /// The byte a line ends with. A UTF-8 continuation byte is always 0x80 or above, so this value can
  /// only ever be a real line ending and never part of a character.
  static const int _lineEnd = 0x0a;

  @override
  Future<List<RunRecord>> list({ProgramName? program, Mode? mode, int limit = 50}) async {
    if (limit <= 0) {
      // `take` throws on a negative count, and a limit of nothing has one answer anyway.
      return const <RunRecord>[];
    }
    // Collected by name and then ordered by start, which is the order this answer has always had.
    // The sort is over what was asked for rather than over the store, and the reading stops at the
    // limit: a machine that has kept a hundred thousand runs answers a request for fifty by opening
    // fifty headers.
    final List<RunRecord> runs = <RunRecord>[];
    await for (final RunRecord run in _headers(program: program, mode: mode)) {
      runs.add(run);
      if (runs.length == limit) {
        break;
      }
    }
    runs.sort(_newestFirst);
    return runs;
  }

  @override
  Future<RunRecord?> read(RunId id) => _header(id);

  @override
  Future<RunRecord?> lastCleanDryRun({
    required ProgramName program,
    required String fingerprint,
  }) async {
    // Newest first, so the first match is the most recent one, and the reading stops there. What it
    // costs is the number of runs NEWER than the proof, which is what a dry run followed by its own
    // real run makes small: on a machine that had kept 5322 records the gate's own read of them was
    // measured at 11.8 seconds, and the run it was gating was minted one record after its proof.
    //
    // The test is the exit code and not [RunRecord.clean]: they agree — the runner returns 2 when a
    // step reported an issue — and the exit code is the value the gate is defined in terms of.
    await for (final RunRecord run in _headers(program: program, mode: Mode.dry)) {
      if (run.exitCode == 0 && run.fingerprint == fingerprint) {
        return run;
      }
    }
    return null;
  }

  @override
  Stream<RunEvent> events(RunId id, {int from = 0}) {
    // A controller and not an `async*` generator, because of what cancelling one costs. A generator
    // notices that its listener has gone only when it reaches its next `yield`, and this loop may
    // have no more events to yield ever — a run that was killed writes neither a run-finished event
    // nor a closing header. The client's `cancel` would then never complete. Here the flag is read
    // once per turn, so leaving takes one poll interval at most.
    final StreamController<RunEvent> events = StreamController<RunEvent>();
    bool following = true;

    Future<void> follow() async {
      final File file = File(directory.events(id));
      int offset = 0;
      try {
        while (following) {
          // The header is read BEFORE the file, and that order is the whole of it. `run.json` only
          // says the run has ended once the last event has been written, so a read of the event file
          // that FOLLOWS a header saying so cannot be missing anything. The other order would let an
          // event land between the two reads and never be seen.
          final bool ended = await _hasEnded(id);
          final _Lines read = await _linesFrom(file, offset);
          offset = read.offset;

          for (final String line in read.lines) {
            if (!following) {
              return;
            }
            if (line.isEmpty) {
              continue;
            }
            final RunEvent event = _eventOf(line, file.path);
            if (event.sequence >= from) {
              events.add(event);
            }
            if (event is RunFinished) {
              return;
            }
          }

          if (ended) {
            return;
          }
          await Future<void>.delayed(poll);
        }
      } on Exception catch (failure, trace) {
        events.addError(failure, trace);
      } finally {
        await events.close();
      }
    }

    events.onListen = () => unawaited(follow());
    events.onCancel = () {
      following = false;
    };
    return events.stream;
  }

  /// Every matching run this store holds, newest first, ONE HEADER AT A TIME so a caller that has
  /// what it came for stops the reading.
  ///
  /// **THE DIRECTORY NAME IS THE ORDER KEY, and that is what makes the early stop possible.** A run
  /// is named for the moment it was minted, opening with the UTC stamp of that moment, so the names
  /// sort chronologically without any header being opened. Sorting by what is INSIDE the headers
  /// cannot order anything until every header has been read, which is the cost this exists to avoid.
  ///
  /// **IT IS NOT THE SAME ORDER AS BY START, and the difference is measurable.** A run's start is
  /// never earlier than its mint, but the gap between the two is not equal for every run: a run
  /// minted at 15:53:06 was measured starting at 15:53:17, while one minted four seconds after it
  /// started at once. By name the second is newer; by start it is older. So a caller that owes its
  /// reader an order by start sorts what it collected — over a handful of records, not the store.
  Stream<RunRecord> _headers({ProgramName? program, Mode? mode}) async* {
    final Directory root = Directory(directory.root);
    if (!await root.exists()) {
      return;
    }

    // The listing itself, and nothing opened yet. A name is all the ordering needs.
    final List<String> names = <String>[];
    await for (final FileSystemEntity entry in root.list(followLinks: false)) {
      if (entry is Directory) {
        names.add(p.basename(entry.path));
      }
    }

    // A NAME THAT CARRIES NO STAMP IS OF UNKNOWN AGE, and one of those puts every name back in
    // question: nothing outside its header says whether it is older or newer than the rest. An id
    // is normally minted with its stamp, but `--run` takes one a caller chose, so this is a state
    // the store can be handed rather than a state it can rule out. Where any name is like that,
    // the order comes from the headers as it always did and the whole store is read; where none is,
    // the names answer and the reading stops at the caller's answer.
    if (names.any((String name) => !_stamped.hasMatch(name))) {
      final List<RunRecord> all = <RunRecord>[];
      for (final String name in names) {
        final RunRecord? record = await _header(RunId(name));
        if (record != null) {
          all.add(record);
        }
      }
      all.sort(_newestFirst);
      for (final RunRecord record in all) {
        if (program != null && record.program != program) {
          continue;
        }
        if (mode != null && record.mode != mode) {
          continue;
        }
        yield record;
      }
      return;
    }
    names.sort((String a, String b) => b.compareTo(a));

    for (final String name in names) {
      // A directory with no header is not a run — something else put it here, or a run's directory
      // was made and the process died before it wrote anything. Either way there is nothing to list.
      final RunRecord? record = await _header(RunId(name));
      if (record == null) {
        continue;
      }
      if (program != null && record.program != program) {
        continue;
      }
      if (mode != null && record.mode != mode) {
        continue;
      }
      yield record;
    }
  }

  Future<RunRecord?> _header(RunId id) async {
    final File file = File(directory.header(id));
    if (!await file.exists()) {
      return null;
    }
    final Object? parsed = jsonDecode(await file.readAsString());
    if (parsed is! Map<String, Object?>) {
      // Not skipped quietly. The header is written whole and renamed into place, so a file here that
      // does not parse is real damage, and a list that silently left the run out would hide it.
      throw FormatException('${file.path} does not hold a run header');
    }
    return _codec.runFrom(parsed);
  }

  Future<bool> _hasEnded(RunId id) async {
    final RunRecord? header = await _header(id);
    return header != null && header.finished;
  }

  RunEvent _eventOf(String line, String path) {
    final Object? parsed = jsonDecode(line);
    if (parsed is! Map<String, Object?>) {
      throw FormatException('$path holds a line that is not an event');
    }
    return _codec.eventFrom(parsed);
  }

  Future<_Lines> _linesFrom(File file, int offset) async {
    if (!await file.exists()) {
      return _Lines(const <String>[], offset);
    }
    final RandomAccessFile handle = await file.open();
    try {
      final int length = await handle.length();
      if (length <= offset) {
        return _Lines(const <String>[], offset);
      }
      await handle.setPosition(offset);
      final Uint8List bytes = await handle.read(length - offset);

      // Read up to the last line ending and no further. What comes after it is a line the recorder
      // is still writing, and half a JSON object is not an event — it is a parse failure that would
      // end the stream of a run that is going perfectly well. The offset advances only over what was
      // whole, so the rest is read again next time round, by then complete.
      final int end = bytes.lastIndexOf(_lineEnd);
      if (end < 0) {
        return _Lines(const <String>[], offset);
      }
      return _Lines(utf8.decode(bytes.sublist(0, end)).split('\n'), offset + end + 1);
    } finally {
      await handle.close();
    }
  }

  /// What a minted run id opens with: the UTC moment it was minted, to the second. It is the whole
  /// of what lets names be ordered without opening anything.
  static final RegExp _stamped = RegExp(r'^\d{8}T\d{6}Z-');

  static int _newestFirst(RunRecord a, RunRecord b) {
    final int byStart = b.start.compareTo(a.start);
    // Two runs can begin within the same microsecond. The identifier breaks the tie so the order is
    // total, and a list read twice does not come back in a different order the second time.
    return byStart != 0 ? byStart : b.id.value.compareTo(a.id.value);
  }
}

/// The complete lines read out of the event file, and where reading stopped.
final class _Lines {
  const _Lines(this.lines, this.offset);

  final List<String> lines;

  /// The byte after the last complete line, which is where the next read begins.
  final int offset;
}
