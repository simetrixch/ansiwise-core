import 'package:meta/meta.dart';

/// How many run records one machine keeps for the account that is running.
///
/// **PER ACCOUNT, BECAUSE A STORE IS WRITTEN BY MORE THAN ONE.** A machine that runs one program
/// on a timer as root and the deployment programs as the operator holds two sets of records in one
/// directory, and neither account may remove the other's. So this bounds what the running account
/// owns; the rest is left where it is and named.
///
/// **A BOUND, AND NOT A POLICY.** Every invocation of the engine writes a record directory, so the
/// number a machine holds is the number of invocations it has ever had. A program that runs on a
/// timer makes that a growth without end: measured on 2026-08-30 one record directory is 12 KB on
/// disk, and a program that runs a dry and then a real run every minute writes 2880 of them a day.
/// This is the one value an installation states so every program is held to it. It is a named slot
/// holding one whole number, never an expression: the moment configuration can compute, what is
/// being debugged stops being the engine and starts being the configuration.
///
/// **A COUNT, AND NOT AN AGE OR A SIZE.** All three bound the disk. A count is the only one whose
/// answer does not move under the machine: an age keeps everything for ever on a machine that runs
/// rarely and empties the store the moment somebody corrects a clock, and a size cannot be decided
/// without walking every file of every record, which is the reading this exists to stop growing.
/// A count is also the bound the reader of a history asks in — "the last few hundred runs" — and it
/// is decided from the directory listing alone.
@immutable
final class RunRetention {
  /// Keeps [keep] run records.
  const RunRetention([this.keep = defaultKeep])
    : assert(keep > 0, 'a machine keeps at least one run record');

  /// How many records a machine keeps where the installation states nothing.
  ///
  /// Five hundred, because a record measured at 12 KB makes that about six megabytes, which fits on
  /// the system disk of every machine while still holding hours of a program that runs on a timer —
  /// and the gate reads the dry run standing one record behind its real run, so a bound this size
  /// can never take the proof a run is about to ask for.
  static const int defaultKeep = 500;

  /// How many records this machine keeps.
  final int keep;

  @override
  bool operator ==(Object other) => other is RunRetention && other.keep == keep;

  @override
  int get hashCode => keep.hashCode;

  @override
  String toString() => 'keeps $keep run records';
}
