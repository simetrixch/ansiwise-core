import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../model/names.dart';

/// Where a run's record lives on this machine: one directory per run, holding two files.
///
/// `run.json` is the header, written when the run begins and rewritten when it ends.
/// `events.jsonl` is one JSON object per line, appended and never rewritten.
///
/// Two files and not one, because of what a kill does to each. Appending means a run that is killed
/// keeps every line it had already written, and the reader can tell where the file stops. One
/// document rewritten in place would be left half-written by the same kill, and would not parse at
/// all — at exactly the moment the record is the only thing anybody has to go on.
@immutable
final class RunDirectory {
  /// Puts every run's own directory under [root].
  const RunDirectory([this.root = defaultRoot]);

  /// Where runs are kept when the caller says nothing.
  ///
  /// The only path this package hard-codes. A caller that keeps its records elsewhere passes its own
  /// root to the constructor; there is no file, environment variable or setting that changes this
  /// one behind the caller's back.
  static const String defaultRoot = '/var/lib/ansiwise/runs';

  /// The directory that every run's own directory sits in.
  final String root;

  /// The directory of run [id].
  String of(RunId id) {
    final String name = id.value;
    // An identifier becomes one path segment, so a value carrying a separator or a parent reference
    // would put the run's record somewhere other than under the root — including on top of a file
    // that has nothing to do with any run.
    if (name.isEmpty || name == '.' || name == '..' || name.contains(RegExp(r'[/\\]'))) {
      throw ArgumentError.value(name, 'id', 'a run identifier must be one path segment');
    }
    return p.join(root, name);
  }

  /// The header file of run [id].
  String header(RunId id) => p.join(of(id), 'run.json');

  /// The event file of run [id].
  String events(RunId id) => p.join(of(id), 'events.jsonl');

  /// Where a run says why it NEVER STARTED.
  ///
  /// **BESIDE THE RUNS AND NOT INSIDE ONE, because inside one is the failure.** Everything a run
  /// says once it is going goes into its own directory — and a run that dies while it is still
  /// working out what it is has no directory yet, and never makes one. The record it would have
  /// written is exactly what is missing, so the reason has to stand somewhere that exists before it.
  ///
  /// **IT IS FOR THE ONE READER WHO CANNOT SEE THE OUTPUT.** A run started at a command line writes
  /// its refusal to standard error and a person reads it. A run started over the REST surface is a
  /// DETACHED CHILD whose standard error is a pipe nobody reads — the launcher writes its standard
  /// input and forgets it — so the same sentence reaches nobody, and the caller is left with an
  /// absence: "accepted but never wrote its record". Measured on a real installation, three times in
  /// one evening, and each diagnosis had to be reconstructed by running the child by hand.
  String startupLog(RunId id) => p.join(root, '${id.value}.startup.log');

  /// Where this machine says what it has REMOVED to stay inside the records it keeps.
  ///
  /// **BESIDE THE RUNS AND NOT INSIDE ONE, because the runs it speaks of are gone.** A note written
  /// into the record of the run that removed them would be removed itself a few hundred runs later,
  /// and the reader who then finds the history starting somewhere is back to an absence that could
  /// mean either "removed" or "never ran".
  ///
  /// It is a file and not a directory, so the listing that finds runs steps over it.
  String get removals => p.join(root, 'removed.json');

  /// The name the note is written under before it replaces the one that is there.
  ///
  /// Same reason as [pendingHeader]: a rewrite in place can be read while it is half done, and a
  /// note that does not parse is a count nobody can read at the moment they are asking what
  /// happened to a run.
  String get pendingRemovals => p.join(root, 'removed.json.writing');

  /// The name the header is written under before it replaces the one that is there.
  ///
  /// A rewrite in place can be read while it is half done, and the store reads the header to find
  /// out whether a run is still going. Writing beside it and renaming over it means a reader sees
  /// either the whole old header or the whole new one.
  String pendingHeader(RunId id) => p.join(of(id), 'run.json.writing');
}
