#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds the agent for controlling iPhone and iPad: WebDriverAgent (Appium, BSD license,
# pinned commit) as a UI test runner, signed with your own team from Config/Local.xcconfig.
# Result: ~/Library/Application Support/MirrorAct/Agent (where MirrorAct looks for it).
#   scripts/build-agent.sh                 for all devices registered in the team
#   scripts/build-agent.sh --device UDID   registers this device in the team if needed
set -euo pipefail

ROOT=${0:A:h:h}
WDA_COMMIT=2e98ac0ad4dbc99ab7c8bb01b7216fde252afb54   # v16.14.1
SRC=$ROOT/Vendor/WebDriverAgent
DERIVED=$HOME/Library/Caches/MirrorAct/AgentData
DEST="$HOME/Library/Application Support/MirrorAct/Agent"
DESTINATION=generic/platform=iOS
while (( $# )); do
  case $1 in
    --device) DESTINATION="id=$2"; shift ;;
    *) echo "Unbekannte Option: $1"; exit 2 ;;
  esac
  shift
done

LOCAL=$ROOT/Config/Local.xcconfig
setting() { [[ -f $LOCAL ]] && sed -n "s/^$1 *= *//p" $LOCAL | tr -d ' ' | head -1 }
TEAM=$(setting DEVELOPMENT_TEAM)
[[ -n $TEAM ]] || {
  echo "DEVELOPMENT_TEAM fehlt in Config/Local.xcconfig (Vorlage: Config/Local.xcconfig.example)."
  echo "Der Agent muss mit einem eigenen Apple-Entwicklerteam signiert werden."
  exit 1
}
APP_ID=$(setting PRODUCT_BUNDLE_IDENTIFIER)
BUNDLE_ID=${APP_ID:-io.github.sopitz.MirrorAct}.Agent

if [[ ! -d $SRC/.git ]]; then
  mkdir -p $SRC
  git -C $SRC init -q
  git -C $SRC remote add origin https://github.com/appium/WebDriverAgent.git
fi
if [[ $(git -C $SRC rev-parse HEAD 2>/dev/null) != $WDA_COMMIT ]]; then
  git -C $SRC fetch -q --depth 1 origin $WDA_COMMIT
  git -C $SRC checkout -q --detach $WDA_COMMIT
fi

# compile MirrorAct's extra commands (fast touches) along with it, without changing the Xcode project
COMMANDS=$SRC/WebDriverAgentLib/Commands
git -C $SRC checkout -q -- WebDriverAgentLib/Commands/FBCustomCommands.m
cp $ROOT/Agent/MirrorActCommands.m $COMMANDS/MirrorActCommands.m
print '\n#import "MirrorActCommands.m"' >> $COMMANDS/FBCustomCommands.m

LOG=$DERIVED.log
mkdir -p ${DERIVED:h}
if ! xcodebuild build-for-testing -project $SRC/WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner \
     -destination $DESTINATION -derivedDataPath $DERIVED \
     -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
     DEVELOPMENT_TEAM=$TEAM CODE_SIGN_STYLE=Automatic PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID > $LOG 2>&1; then
  grep -E "error:|No profiles|provisioning" $LOG | sort -u | head -20
  echo "Agent-Build fehlgeschlagen, Log: $LOG"
  exit 1
fi

rm -rf $DEST
mkdir -p $DEST
cp -R $DERIVED/Build/Products/ $DEST/
# new ID per build: MirrorAct only reinstalls the agent when it has changed
uuidgen > $DEST/build-id
echo "Agent gebaut ($BUNDLE_ID): $DEST"
