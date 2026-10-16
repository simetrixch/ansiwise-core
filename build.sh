#!/usr/bin/env bash
# =============================================================================
# build.sh — prove this part locally, the way the ci of the master does.
# =============================================================================
#
# THIS REPOSITORY BUILDS NOTHING. It is a passive part of ansiwise-cli: no
# binary, no release, no tag of its own. "Building" it therefore means proving
# it — resolving it, and running the gate that decides whether it is sound.
#
# WHY IT EXISTS BESIDE THE CI. The ci of the master, `ansiwise-core-ci`, answers
# on a push of the default branch or of a `ci/` branch, which is the right moment
# for a change somebody else will read. This is for the other times:
# a run you want NOW, without pushing, and with the whole output in front of you
# rather than folded into a page. The two do the same thing in the same order, so
# a green here means a green there.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

echo "build: resolving"
dart pub get

echo "build: the gate"
dart run tool/ci.dart
