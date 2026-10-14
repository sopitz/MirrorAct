#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Fetches the scrcpy server (pinned version, checksum) into Vendor/scrcpy/scrcpy-server.
# It runs on the Android device, delivers video and audio, and accepts input.
# The client in MirrorAct/Android speaks exactly this version's protocol.
set -euo pipefail

ROOT=${0:A:h:h}
VERSION=4.1
SHA256=deacb991ed2509715160ffdc7907e47b4160eb30d1566217e9047fd5b8850cae
DEST=$ROOT/Vendor/scrcpy/scrcpy-server

if [[ -f $DEST ]] && [[ $(shasum -a 256 $DEST | cut -d' ' -f1) == $SHA256 ]]; then
  exit 0
fi
mkdir -p ${DEST:h}
curl -fsSL -o $DEST.download \
  https://github.com/Genymobile/scrcpy/releases/download/v$VERSION/scrcpy-server-v$VERSION
if [[ $(shasum -a 256 $DEST.download | cut -d' ' -f1) != $SHA256 ]]; then
  rm -f $DEST.download
  echo "scrcpy-server: Prüfsumme stimmt nicht"
  exit 1
fi
mv $DEST.download $DEST
echo "scrcpy-server $VERSION geladen: $DEST"
