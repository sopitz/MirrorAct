#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Baut MirrorAct zum Weitergeben: mit Developer ID signiert, von Apple notarisiert, als ZIP für
# das GitHub-Release und den Homebrew-Cask (sopitz/homebrew-tap).
#   scripts/release.sh             bauen, notarisieren, ZIP nach build/release/
#   scripts/release.sh --publish   dazu GitHub-Release v<version> anlegen und den Cask nachführen
# Einmalig nötig: das Zertifikat «Developer ID Application» im Schlüsselbund und ein
# notarytool-Profil (Name in NOTARY_PROFILE, Standard mirroract-notary):
#   xcrun notarytool store-credentials mirroract-notary --apple-id <Apple-ID> --team-id <Team>
# Mit --publish muss die Arbeitskopie sauber sein und HEAD das Tag v<version> tragen.
set -euo pipefail

ROOT=${0:A:h:h}
PUBLISH=0
for arg in "$@"; do
  case $arg in
    --publish) PUBLISH=1 ;;
    *) echo "Unbekannte Option: $arg"; exit 2 ;;
  esac
done

IDENTITY="Developer ID Application"
NOTARY_PROFILE=${NOTARY_PROFILE:-mirroract-notary}
TAP_REPO=${TAP_REPO:-sopitz/homebrew-tap}
CASK=Casks/mirroract.rb
OUT=$ROOT/build/release
cd $ROOT

VERSION=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"$/\1/p' project.yml)
[[ -n $VERSION ]] || { echo "MARKETING_VERSION fehlt in project.yml"; exit 1; }
TEAM=$(security find-identity -v -p codesigning \
  | sed -n "s/.*\"$IDENTITY: .*(\([A-Z0-9]*\))\"\$/\1/p" | head -1)
[[ -n $TEAM ]] || { echo "Kein Zertifikat «$IDENTITY» im Schlüsselbund (siehe CONTRIBUTING.md)"; exit 1; }
xcrun notarytool history --keychain-profile $NOTARY_PROFILE > /dev/null 2>&1 \
  || { echo "notarytool-Profil «$NOTARY_PROFILE» fehlt (siehe Kopf dieses Skripts)"; exit 1; }
if (( PUBLISH )); then
  command -v gh > /dev/null || { echo "Fehlt: gh (brew install gh)"; exit 1; }
  [[ -z $(git status --porcelain) ]] || { echo "Arbeitskopie nicht sauber"; exit 1; }
  git tag --points-at HEAD | grep -qx "v$VERSION" || { echo "HEAD trägt nicht das Tag v$VERSION"; exit 1; }
fi

echo "MirrorAct $VERSION, Team $TEAM"
rm -rf $OUT
mkdir -p $OUT
# UxPlay immer neu konfigurieren, damit das Mindest-macOS stimmt
scripts/bootstrap-uxplay.sh
MIRRORACT_DERIVED=$OUT/DerivedData scripts/build.sh --no-install \
  "CODE_SIGN_IDENTITY=$IDENTITY" DEVELOPMENT_TEAM=$TEAM OTHER_CODE_SIGN_FLAGS=--timestamp \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
APP=$OUT/DerivedData/Build/Products/Release/MirrorAct.app
codesign --verify --deep --strict $APP
[[ $(codesign -dv $APP 2>&1) == *flags=*runtime* ]] || { echo "Hardened Runtime fehlt"; exit 1; }
# Apple notarisiert nichts mit Debug-Entitlement
[[ $(codesign -d --entitlements - $APP 2>/dev/null) != *get-task-allow* ]] \
  || { echo "get-task-allow gesetzt"; exit 1; }

ZIP=$OUT/MirrorAct-$VERSION.zip
ditto -c -k --keepParent $APP $ZIP
echo "Notarisieren (dauert meist ein paar Minuten) …"
RESULT=$(xcrun notarytool submit $ZIP --keychain-profile $NOTARY_PROFILE --wait --output-format json)
if [[ $(jq -r .status <<< $RESULT) != Accepted ]]; then
  echo $RESULT
  xcrun notarytool log $(jq -r .id <<< $RESULT) --keychain-profile $NOTARY_PROFILE || true
  exit 1
fi
xcrun stapler staple -q $APP
spctl --assess --type execute $APP
# erneut packen, damit das Ticket im ZIP steckt
rm $ZIP
ditto -c -k --keepParent $APP $ZIP
SHA=$(shasum -a 256 $ZIP | cut -d' ' -f1)
echo "Notarisiert: $ZIP"
echo "SHA-256: $SHA"
(( PUBLISH )) || exit 0

git push -q origin v$VERSION
gh release create v$VERSION $ZIP --title "MirrorAct $VERSION" --generate-notes --verify-tag

# Cask im Tap auf die neue Version setzen
CASK_SHA=$(gh api repos/$TAP_REPO/contents/$CASK -q .sha)
gh api repos/$TAP_REPO/contents/$CASK -q .content | base64 -D \
  | sed -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" \
  > $OUT/mirroract.rb
grep -q "version \"$VERSION\"" $OUT/mirroract.rb || { echo "Cask nicht erkannt: $OUT/mirroract.rb"; exit 1; }
gh api -X PUT repos/$TAP_REPO/contents/$CASK --silent -f message="mirroract $VERSION" \
  -f content="$(base64 -i $OUT/mirroract.rb)" -f sha=$CASK_SHA
echo "Veröffentlicht: brew install --cask ${TAP_REPO/homebrew-/}/mirroract"
