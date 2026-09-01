/// The one toolchain the checks of this repository are true against.
///
/// The version is pinned so a red run is a finding in the tree and not a tool that moved underneath
/// it. It was read from the source named beside it, on the date given: a version recalled from
/// memory is as old as whoever recalled it, which is why the source is part of the record.
///
/// The pin names a requirement, not an installation: tool/gate/version_guard.dart reads the SDK the
/// gate is running on and refuses the run where the two differ, naming what was found and what was
/// expected.
library;

/// The Dart SDK the checks are true against, and the only tool the gate starts.
///
/// The toolchain on the workstation, read 2026-09-01: `dart --version` answered 3.13.1 (stable),
/// built 2026-08-18. The previous pin was 3.13.0, read from
/// storage.googleapis.com/dart-archive/channels/stable/release/latest/VERSION on 2026-08-17; before
/// that 3.12.2, on 2026-08-08. Each time the toolchain on the machine moved under the pin and this
/// guard refused every run, which is the guard working rather than failing.
///
/// RAISED RATHER THAN INSTALLED ALONGSIDE, on 2026-09-01. The workstation carried 3.13.1 and no
/// 3.13.0, so the gate could not run there at all — and a gate that cannot run is a gate nobody
/// uses: two releases were cut that day on `dart test` alone, which is a subset of what this gate
/// asks. The build workflow takes its SDK from THIS constant, so raising it moves the machine and
/// the build together rather than splitting them.
const String dartVersion = '3.13.1';
