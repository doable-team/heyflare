#!/usr/bin/env bash
# Builds heyflare and installs it on the connected iPhone.
#
# Requires an Apple ID signed into Xcode (Xcode > Settings > Accounts). A free
# account works; builds signed that way expire after seven days and need
# reinstalling, which is the same deal as the Tauri app in ../ios.
#
# Usage:  ./install-device.sh [TEAM_ID]
# With no argument it uses the first team Xcode knows about.

set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_ID=$(sed -n 's/.*PRODUCT_BUNDLE_IDENTIFIER: *//p' project.yml | head -1)

echo "==> Checking for a signing identity"
if ! security find-identity -v -p codesigning | grep -q "Apple Development"; then
  cat <<'MSG'
No "Apple Development" certificate is installed, so nothing can be signed.

Fix it once:
  1. Open Xcode > Settings > Accounts
  2. Press + and sign in with your Apple ID (a free one is fine)
  3. Select the account, press "Manage Certificates", press + > "Apple Development"

Then run this script again.
MSG
  exit 1
fi

TEAM="${1:-}"
if [ -z "$TEAM" ]; then
  # Xcode records the team behind a signed-in account here. Preferred over the
  # certificate's name: on a personal team the bracketed id in the certificate is the
  # person, not the team, and signing with it fails.
  # The provisioning profile Xcode made for this app names the team it belongs to.
  for profile in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.mobileprovision \
                 "$HOME/Library/MobileDevice/Provisioning Profiles"/*.mobileprovision; do
    [ -f "$profile" ] || continue
    if security cms -D -i "$profile" 2>/dev/null | grep -q "$BUNDLE_ID"; then
      TEAM=$(security cms -D -i "$profile" 2>/dev/null | plutil -extract TeamIdentifier.0 raw - 2>/dev/null || true)
      [ -n "$TEAM" ] && break
    fi
  done
fi
if [ -z "$TEAM" ]; then
  TEAM=$(security find-identity -v -p codesigning \
    | sed -n 's/.*Apple Development: .*(\([A-Z0-9]\{10\}\)).*/\1/p' | head -1)
fi
[ -n "$TEAM" ] || { echo "Could not work out a team id. Pass one: ./install-device.sh TEAMID"; exit 1; }
echo "    team: $TEAM"

echo "==> Finding the device"
DEVICE_ID=$(xcrun devicectl list devices 2>/dev/null \
  | awk '/available|connected/ && !/^Name/ {print $3; exit}')
[ -n "$DEVICE_ID" ] || { echo "No iPhone found. Plug it in, unlock it, and trust this Mac."; exit 1; }
echo "    device: $DEVICE_ID"

echo "==> Generating the project"
command -v xcodegen >/dev/null || { echo "xcodegen is missing. brew install xcodegen"; exit 1; }
xcodegen generate >/dev/null

echo "==> Building"
DERIVED=$(mktemp -d)
xcodebuild \
  -project Heyflare.xcodeproj \
  -scheme Heyflare \
  -configuration Debug \
  -destination "id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" \
  CODE_SIGN_STYLE=Automatic \
  build | tail -5

APP=$(find "$DERIVED/Build/Products" -maxdepth 2 -name "heyflare.app" | head -1)
[ -n "$APP" ] || { echo "Build produced no app bundle."; exit 1; }

echo "==> Installing $BUNDLE_ID"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"

echo
echo "Installed. On the phone, the first launch needs the profile trusted once:"
echo "  Settings > General > VPN & Device Management > your Apple ID > Trust"
