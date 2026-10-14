#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Prüft Shared/DeviceProfiles.json als striktes JSON (RFC 8259).
# Foundation liest auch Kommas am Ende, NaN und doppelte Schlüssel; die Windows-App
# (System.Text.Json) nicht. Darum muss die Datei hier strenger durchgehen als in der Mac-App.
#   scripts/check-device-profiles.sh [DATEI]
set -euo pipefail

ROOT=${0:A:h:h}
FILE=${1:-$ROOT/Shared/DeviceProfiles.json}

/usr/bin/env python3 -I - "$FILE" <<'PY'
import json, sys

path = sys.argv[1]

def reject_constant(name):
    raise ValueError(f"{name} is not valid JSON")

def reject_duplicates(pairs):
    seen = set()
    for key, _ in pairs:
        if key in seen:
            raise ValueError(f"duplicate key {key!r}")
        seen.add(key)
    return dict(pairs)

try:
    with open(path, encoding="utf-8") as f:
        json.load(f, parse_constant=reject_constant, object_pairs_hook=reject_duplicates)
except (OSError, ValueError) as error:
    print(f"{path}: {error}", file=sys.stderr)
    sys.exit(1)
PY
