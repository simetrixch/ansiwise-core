import 'package:meta/meta.dart';

import 'names.dart';

/// What a machine has removed to stay inside the number of run records it keeps.
///
/// **A DELETION IS AN ACT, AND AN ACT IS WRITTEN DOWN.** Without this a reader who finds the
/// history starting somewhere cannot tell a record that was removed from one that was never
/// written, and those are opposite answers: the first says the machine ran and the record aged out,
/// the second says nothing ran.
///
/// **IT SAYS HOW MANY AND BETWEEN WHICH TWO, NOT WHICH ONES.** A line per removed record would grow
/// by one line per invocation for ever, which is the growth the bound exists to end — so what is
/// kept is the count, the two ends of the range, and when the last removal ran. A reader asking
/// about one identifier inside that range learns that records of that age were removed, and not
/// that this one was.
@immutable
final class RemovedRuns {
  /// States that [count] records have been removed, the oldest [oldest] and the newest [newest],
  /// the last of them at [at].
  const RemovedRuns({
    required this.count,
    required this.oldest,
    required this.newest,
    required this.at,
  });

  /// How many records this machine has removed, over its whole life.
  final int count;

  /// The oldest record it has removed.
  final RunId oldest;

  /// The newest record it has removed.
  final RunId newest;

  /// When the most recent removal ran, in UTC.
  final DateTime at;

  @override
  bool operator ==(Object other) =>
      other is RemovedRuns &&
      other.count == count &&
      other.oldest == oldest &&
      other.newest == newest &&
      other.at == at;

  @override
  int get hashCode => Object.hash(count, oldest, newest, at);

  @override
  String toString() => '$count run records removed, $oldest to $newest, last at $at';
}
