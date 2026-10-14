#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Tests loading Shared/DeviceProfiles.json: the real table must pass, deliberately
# broken copies must fail with the matching message (syntax via
# check-device-profiles.sh, content via DeviceProfile.swift, built with swiftc outside the app).
#   scripts/test-device-profiles.sh
set -euo pipefail

ROOT=${0:A:h:h}
WORK=$(mktemp -d)
trap 'rm -rf $WORK' EXIT

# Probe without DeviceProfiles.json next to the binary, so MIRRORACT_DEVICE_PROFILES applies
mkdir -p $WORK/bin $WORK/cases
cat > $WORK/main.swift <<'SWIFT'
import Foundation
let id = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "iPhone14,2"
guard let profile = DeviceProfile.forModelIdentifier(id) else { print("nil"); exit(0) }
print("\(profile.displayName) \(profile.cutout) corner=\(Double(profile.screenCornerRatio))")
SWIFT
swiftc -o $WORK/bin/probe $WORK/main.swift \
  $ROOT/MirrorAct/Frame/DeviceProfile.swift $ROOT/MirrorAct/Frame/DeviceProfileTable.swift

# Copies of the table, each with one error; name → expected message
/usr/bin/env python3 -I - $ROOT/Shared/DeviceProfiles.json $WORK/cases <<'PY'
import json, sys
source, out = sys.argv[1], sys.argv[2]
text = open(source, encoding="utf-8").read()

def variant(name, expected, change):
    table = json.loads(text)
    change(table)
    with open(f"{out}/{name}.json", "w", encoding="utf-8") as f:
        json.dump(table, f, ensure_ascii=False, indent=1)
    with open(f"{out}/{name}.expected", "w", encoding="utf-8") as f:
        f.write(expected)

def rename(d, old, new):
    d[new] = d.pop(old)

variant("entry-key-typo", "unknown key cornr", lambda t: rename(t["models"]["iPhone14,2"], "corner", "cornr"))
variant("cutout-key-typo", "unknown key widht", lambda t: rename(t["cutouts"]["notch13"], "width", "widht"))
variant("scale-zero", "byPixels 750x1334 needs a scale above 0", lambda t: t["byPixels"]["750x1334"].update(scale=0))
variant("pixel-key-landscape", "byPixels 1334x750 is not a portrait pixel size", lambda t: rename(t["byPixels"], "750x1334", "1334x750"))
variant("pixel-key-format", "byPixels 750*1334 is not a portrait pixel size", lambda t: rename(t["byPixels"], "750x1334", "750*1334"))
variant("pad-pixels", "byPixels 1668x2388 is an iPad; pixels applies to iPhones only", lambda t: t["byPixels"]["1668x2388"].update(pixels=999))
variant("phone-without-cutout", "models iPhone13,2 needs a cutout", lambda t: t["models"]["iPhone13,2"].pop("cutout"))
variant("cutout-unknown-type", "cutout blob1 has the unknown type blob", lambda t: t["cutouts"].update(blob1={"type": "blob"}))
variant("hole-missing-value", "cutout hole1 has type hole with missing values: diameter",
        lambda t: t["cutouts"].update(hole1={"type": "hole", "centerX": 0.5, "centerY": 0.04}))

# valid: a camera hole, as the Windows app also knows it
def hole(t):
    t["cutouts"]["hole1"] = {"type": "hole", "centerX": 0.5, "centerY": 0.04, "diameter": 0.03}
    t["models"]["iPhone14,2"]["cutout"] = "hole1"
variant("hole-valid", "", hole)

# Trailing comma: Foundation reads it, System.Text.Json does not
trailing = text.replace('"corner": 0.085\n', '"corner": 0.085,\n', 1)
assert trailing != text
open(f"{out}/trailing-comma.json", "w", encoding="utf-8").write(trailing)
PY

failures=0
fail() { echo "FAIL: $1"; failures=$((failures + 1)) }

# real table
$ROOT/scripts/check-device-profiles.sh || fail "check-device-profiles.sh rejects Shared/DeviceProfiles.json"
out=$(MIRRORACT_DEVICE_PROFILES=$ROOT/Shared/DeviceProfiles.json $WORK/bin/probe 2>&1) \
  && [[ $out == "iPhone 13 Pro notch(width: 0.415, height: 0.085) corner=0.121" ]] \
  || fail "Shared/DeviceProfiles.json: $out"

# Syntax
if $ROOT/scripts/check-device-profiles.sh $WORK/cases/trailing-comma.json 2> /dev/null; then
  fail "trailing-comma: check-device-profiles.sh accepts a trailing comma"
fi

# Content
for json in $WORK/cases/*.json; do
  name=${json:t:r}
  [[ $name == trailing-comma || $name == hole-valid ]] && continue
  expected=$(< $WORK/cases/$name.expected)
  if out=$(MIRRORACT_DEVICE_PROFILES=$json $WORK/bin/probe 2>&1); then
    if [[ -n $expected ]]; then fail "$name: loaded, expected '$expected'"; fi
  elif [[ -z $expected ]]; then
    fail "$name: $out"
  elif [[ $out != *"$expected"* ]]; then
    fail "$name: expected '$expected', got: $out"
  fi
done
out=$(MIRRORACT_DEVICE_PROFILES=$WORK/cases/hole-valid.json $WORK/bin/probe 2>&1) || true
[[ $out == *"hole(centerX: 0.5, centerY: 0.04, diameter: 0.03)"* ]] || fail "hole-valid: $out"

if (( failures )); then
  echo "$failures device profile check(s) failed"
  exit 1
fi
echo "Device profiles: all checks passed"
