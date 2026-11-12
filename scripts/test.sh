#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Runs the tests (MirrorActTests, run in a debug build of the app).
#   scripts/test.sh                       all tests
#   scripts/test.sh PresentationTests     only this class (also Class/testName)
# The tests briefly open real windows, including presenting in full screen.
# Variables named TRACKING_* reach the tests (xcodebuild passes on only those named
# TEST_RUNNER_*), for example: TRACKING_ALL=1 scripts/test.sh TrackingBenchTests
set -euo pipefail

ROOT=${0:A:h:h}
ONLY=()
for arg in "$@"; do
  ONLY+=(-only-testing:MirrorActTests/$arg)
done

for tool in xcodegen xcodebuild cmake brew; do
  command -v $tool > /dev/null || { echo "Fehlt: $tool (siehe CONTRIBUTING.md)"; exit 1; }
done
BREW_PREFIX=$(brew --prefix)
DERIVED=${MIRRORACT_DERIVED:-$HOME/Library/Caches/MirrorAct/DerivedData}

[[ -f $ROOT/Vendor/uxplay-build/lib/libairplay.a ]] || $ROOT/scripts/bootstrap-uxplay.sh
$ROOT/scripts/bootstrap-scrcpy.sh
[[ -f $ROOT/Resources/AppIcon.icns ]] || $ROOT/scripts/make-icon.sh

cd $ROOT
xcodegen generate --quiet

# xcodebuild hands TEST_RUNNER_<NAME> to the tests as <NAME>
for name in ${(k)parameters[(I)TRACKING_*]}; do
  if [[ ${parameters[$name]} == *export* ]]; then
    export TEST_RUNNER_$name=${(P)name}
  fi
done

LOG=$DERIVED/test.log
mkdir -p $DERIVED
if ! xcodebuild -project MirrorAct.xcodeproj -scheme MirrorAct -configuration Debug \
     -derivedDataPath $DERIVED HOMEBREW_PREFIX=$BREW_PREFIX $ONLY test > $LOG 2>&1; then
  grep -E "error:|Test Case .* failed|XCTAssert|\*\* TEST" $LOG | sort -u | head -60
  echo "Tests fehlgeschlagen, Log: $LOG"
  exit 1
fi
grep -E "Executed [0-9]+ tests?," $LOG | tail -1
