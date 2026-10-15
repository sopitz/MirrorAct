#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds MirrorAct.app and installs it to ~/Applications.
#   scripts/build.sh            release build + install
#   scripts/build.sh --debug    debug build
#   scripts/build.sh --no-install   build only
#   scripts/build.sh NAME=VALUE ... pass build settings on to xcodebuild
# Signing: ad hoc by default; your own certificate in Config/Local.xcconfig
# (template: Config/Local.xcconfig.example). MIRRORACT_DERIVED replaces the build folder.
set -euo pipefail

ROOT=${0:A:h:h}
CONFIG=Release
INSTALL=1
SETTINGS=()
for arg in "$@"; do
  case $arg in
    --debug) CONFIG=Debug ;;
    --no-install) INSTALL=0 ;;
    *=*) SETTINGS+=($arg) ;;
    *) echo "Unbekannte Option: $arg"; exit 2 ;;
  esac
done

for tool in xcodegen xcodebuild cmake brew python3; do
  command -v $tool > /dev/null || { echo "Fehlt: $tool (siehe CONTRIBUTING.md)"; exit 1; }
done
BREW_PREFIX=$(brew --prefix)
DERIVED=${MIRRORACT_DERIVED:-$HOME/Library/Caches/MirrorAct/DerivedData}
APP_DEST=$HOME/Applications/MirrorAct.app

# Foundation also reads malformed JSON; stricter parsers do not
$ROOT/scripts/check-device-profiles.sh

[[ -f $ROOT/Vendor/uxplay-build/lib/libairplay.a ]] || $ROOT/scripts/bootstrap-uxplay.sh
$ROOT/scripts/bootstrap-scrcpy.sh
[[ -f $ROOT/Resources/AppIcon.icns ]] || $ROOT/scripts/make-icon.sh

cd $ROOT
xcodegen generate --quiet

LOG=$DERIVED/build.log
mkdir -p $DERIVED
if ! xcodebuild -project MirrorAct.xcodeproj -scheme MirrorAct -configuration $CONFIG \
     -derivedDataPath $DERIVED HOMEBREW_PREFIX=$BREW_PREFIX $SETTINGS build > $LOG 2>&1; then
  grep -E "error:|warning: .*(MirrorAct/|airplay_bridge)" $LOG | sort -u | head -60
  echo "Build fehlgeschlagen, Log: $LOG"
  exit 1
fi
grep -E "warning: " $LOG | grep "$ROOT/MirrorAct/" | sort -u | head -30 || true

BUILT=$DERIVED/Build/Products/$CONFIG/MirrorAct.app
if (( ! INSTALL )); then
  echo "Gebaut: $BUILT"
  exit 0
fi
if pgrep -x MirrorAct > /dev/null; then
  osascript -e 'tell application "MirrorAct" to quit' > /dev/null 2>&1 || true
  sleep 1
  pkill -x MirrorAct 2>/dev/null || true
fi
rm -rf $APP_DEST
mkdir -p ${APP_DEST:h}
cp -R $BUILT $APP_DEST
echo "Installiert: $APP_DEST"
