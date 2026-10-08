#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Baut Resources/AppIcon.icns aus scripts/make-icon.swift
set -euo pipefail
ROOT=${0:A:h:h}
TMP=$(mktemp -d)
swift $ROOT/scripts/make-icon.swift $TMP/icon.png
mkdir $TMP/AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s $TMP/icon.png --out $TMP/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) $TMP/icon.png --out $TMP/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $TMP/AppIcon.iconset -o $ROOT/Resources/AppIcon.icns
cp $TMP/icon.png $ROOT/Resources/AppIcon-1024.png
rm -rf $TMP
echo "Icon: $ROOT/Resources/AppIcon.icns"
