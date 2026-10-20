#!/usr/bin/env bash
# =============================================================================
# build.sh — prove this part locally, the way scripts/check.sh does before every push.
# =============================================================================
#
# THIS REPOSITORY BUILDS NOTHING. It is a passive part of ansiwise-cli: no
# binary, no release, no tag of its own. "Building" it therefore means proving
# it — resolving it, and running the gate that decides whether it is sound.
#
# WHY IT EXISTS BESIDE scripts/check.sh. The push gate runs scripts/check.sh, and
# it stops at the first red step. This is for a run you want NOW, without pushing,
# with the whole output of the gate in front of you. Both run tool/ci.dart, so a
# green here means a green there.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

echo "build: resolving"
dart pub get

echo "build: the gate"
dart run tool/ci.dart
