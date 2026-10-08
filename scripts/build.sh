#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Baut MirrorAct.app und installiert sie nach ~/Applications.
#   scripts/build.sh            Release-Build + Installation
#   scripts/build.sh --debug    Debug-Build
#   scripts/build.sh --no-install   nur bauen
# Signatur: standardmässig ad-hoc; eigenes Zertifikat in Config/Local.xcconfig
# (Vorlage: Config/Local.xcconfig.example).
set -euo pipefail

ROOT=${0:A:h:h}
CONFIG=Release
INSTALL=1
for arg in "$@"; do
  case $arg in
    --debug) CONFIG=Debug ;;
    --no-install) INSTALL=0 ;;
    *) echo "Unbekannte Option: $arg"; exit 2 ;;
  esac
done

for tool in xcodegen xcodebuild cmake brew; do
  command -v $tool > /dev/null || { echo "Fehlt: $tool (siehe README)"; exit 1; }
done
BREW_PREFIX=$(brew --prefix)
DERIVED=$HOME/Library/Caches/MirrorAct/DerivedData
APP_DEST=$HOME/Applications/MirrorAct.app

[[ -f $ROOT/Vendor/uxplay-build/lib/libairplay.a ]] || $ROOT/scripts/bootstrap-uxplay.sh
[[ -f $ROOT/Resources/AppIcon.icns ]] || $ROOT/scripts/make-icon.sh

cd $ROOT
xcodegen generate --quiet

LOG=$DERIVED/build.log
mkdir -p $DERIVED
if ! xcodebuild -project MirrorAct.xcodeproj -scheme MirrorAct -configuration $CONFIG \
     -derivedDataPath $DERIVED HOMEBREW_PREFIX=$BREW_PREFIX build > $LOG 2>&1; then
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
