#!/bin/bash
# sign_and_notarize.sh — build, sign, notarize and staple PCemMac for
# distribution to other Macs. Local development needs NONE of this (the
# Xcode build is ad-hoc signed and runs fine on this machine).
#
# ONE-TIME SETUP (only the owner can do these — they need her Apple ID):
#   1. Apple Developer Program membership (paid, developer.apple.com).
#   2. Xcode → Settings → Accounts → add your Apple ID → select your team →
#      "Manage Certificates…" → "+" → "Developer ID Application".
#   3. Create an app-specific password at appleid.apple.com
#      (Sign-In and Security → App-Specific Passwords), then store the
#      notarization credentials in the Keychain:
#        xcrun notarytool store-credentials "pcem-notary" \
#          --apple-id "you@example.com" --team-id "ABCDE12345" \
#          --password "xxxx-xxxx-xxxx-xxxx"
#   4. Fill in the three variables below and run this script.
#
# Afterwards, verify with:  spctl -a -vv <app>  →  "accepted … Notarized
# Developer ID", and share the PCemMac.zip it produces.

set -euo pipefail

# ---- fill these in after the one-time setup ------------------------------
DEVELOPER_ID="Developer ID Application: YOUR NAME (ABCDE12345)"
KEYCHAIN_PROFILE="pcem-notary"   # name used in store-credentials (step 3)
# ---------------------------------------------------------------------------

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build/dist"
APP="$BUILD_DIR/PCemMac.app"
ZIP="$BUILD_DIR/PCemMac.zip"
ENTITLEMENTS="$PROJECT_DIR/macos/PCem.entitlements"

if [[ "$DEVELOPER_ID" == *"YOUR NAME"* ]]; then
    echo "error: edit $0 first — set DEVELOPER_ID (see the header comments)." >&2
    exit 1
fi

echo "==> building Release"
rm -rf "$BUILD_DIR"
xcodebuild -project "$PROJECT_DIR/PCem.xcodeproj" -scheme PCemMac \
    -configuration Release -derivedDataPath "$BUILD_DIR/dd" build
mv "$BUILD_DIR/dd/Build/Products/Release/PCemMac.app" "$APP"

echo "==> signing with: $DEVELOPER_ID"
# --deep: sign the frameworks/dylibs inside first, then the bundle itself.
codesign --sign "$DEVELOPER_ID" --options runtime \
    --entitlements "$ENTITLEMENTS" --deep --force "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> notarizing (this talks to Apple, can take a few minutes)"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$KEYCHAIN_PROFILE" --wait

echo "==> stapling the ticket to the app"
xcrun stapler staple "$APP"

echo "==> done. Gatekeeper check:"
spctl -a -vv "$APP" || true
echo
echo "Distribute $ZIP — recipients can unzip and run without warnings."
