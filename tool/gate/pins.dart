/// The one toolchain the checks of this repository are true against.
///
/// The version is pinned so a red run is a finding in the tree and not a tool that moved underneath
/// it. It is read from the source named beside it: a version recalled from memory is as old as
/// whoever recalled it, which is why the source is part of the record.
///
/// The pin names a requirement, not an installation: tool/gate/version_guard.dart reads the SDK the
/// gate is running on and refuses the run where the two differ, naming what was found and what was
/// expected.
library;

/// The Dart SDK the checks are true against, and the only tool the gate starts.
///
/// The source is the workstation itself: `dart --version` answers 3.13.1 (stable). A toolchain that
/// moves under the pin makes this guard refuse every run, which is the guard working rather than
/// failing.
///
/// RAISED RATHER THAN INSTALLED ALONGSIDE. Where the workstation carries a version this constant
/// does not name, the gate cannot run there at all — and a gate that cannot run is a gate nobody
/// uses: releases then get cut on `dart test` alone, which is a subset of what this gate asks. The
/// build workflow takes its SDK from THIS constant, so raising it moves the machine and the build
/// together rather than splitting them.
const String dartVersion = '3.13.1';
