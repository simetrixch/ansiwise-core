#!/usr/bin/env bash
# check.sh — every check of this repository, run here, in one command.
#
# WHO RUNS IT. The push hook (.githooks/pre-push) runs it before any commit leaves this machine.
# A person runs it while working, to get the same answer without pushing.
#
# THE STEPS ARE NAMED. The run stops at the first red step. Its last line is then
# `check: FAIL — <step>`, where <step> is the command that was red. A run where every step is
# green ends with `check: OK — every check green`.
#
# A MISSING TOOL IS A RED STEP, NEVER A SKIPPED ONE. A skipped step prints nothing, and a run
# that prints nothing about a check reads like a run in which that check passed.
#
# THE DART VERSION IS NOT READ HERE. package:ansiwise_checks_gate names the one Dart SDK the checks
# of this repository are true against, and tool/ci.dart refuses every other one, printing the
# version it found and the version it expected. Reading that pin here as well would make this file
# a second carrier of it, and a second carrier drifts.
#
# Windows entry point: check.ps1 beside this file. It is a shim that starts THIS file, so there
# is no second spelling of these checks that could answer differently.

set -uo pipefail

# The root is this file's own folder, one level up. That answer needs no git, so the two steps and
# their verdict are still reached from a directory git cannot read.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
cd "$root" || exit 1

fail() {  # fail <step>
  echo "check: FAIL — $1"
  exit 1
}

if ! command -v dart >/dev/null 2>&1; then
  echo "dart is not on PATH. Every check of this repository is a Dart program, so none of them can start."
  fail 'dart pub get'
fi

echo "check: dart pub get"
dart pub get || fail 'dart pub get'

echo "check: dart run tool/ci.dart"
dart run tool/ci.dart || fail 'dart run tool/ci.dart'

echo "check: OK — every check green"
