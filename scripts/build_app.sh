#!/usr/bin/env bash
# Builds MiliShip.app with xcodebuild and optionally packages, signs and notarizes it.
#
#   ./scripts/build_app.sh               # build/MiliShip.app (this Mac's architecture, ad-hoc signed)
#   ./scripts/build_app.sh --package     # + build/MiliShip-<version>.zip and .dmg
#
# Optional environment:
#   VERSION=1.2.0        marketing version (default: latest git tag without "v", else 0.1.0)
#   UNIVERSAL=1          Apple silicon + Intel
#   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE=name  notarytool keychain profile (xcrun notarytool store-credentials), or:
#   NOTARY_KEY_PATH=… NOTARY_KEY_ID=… NOTARY_ISSUER_ID=…   App Store Connect API key for notarization
set -euo pipefail

APP_NAME="MiliShip"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
PACKAGE=0
[[ "${1:-}" == "--package" ]] && PACKAGE=1

BUILD="$ROOT/build"
DERIVED="$BUILD/DerivedData"
APP="$BUILD/$APP_NAME.app"
mkdir -p "$BUILD"

SETTINGS=(ONLY_ACTIVE_ARCH=YES)
[[ "${UNIVERSAL:-0}" == "1" ]] && SETTINGS=(ONLY_ACTIVE_ARCH=NO "ARCHS=arm64 x86_64")

FORMATTER=(cat)
command -v xcbeautify >/dev/null 2>&1 && FORMATTER=(xcbeautify)

echo "▶ Building $APP_NAME $VERSION ($BUILD_NUMBER)"
xcodebuild \
  -project "$ROOT/MiliShip.xcodeproj" \
  -scheme MiliShip \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_IDENTITY="-" \
  "${SETTINGS[@]}" \
  build | "${FORMATTER[@]}"

rm -rf "$APP"
cp -R "$DERIVED/Build/Products/Release/$APP_NAME.app" "$APP"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  echo "▶ Signing with $CODESIGN_IDENTITY"
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP"
else
  echo "  ad-hoc signed (set CODESIGN_IDENTITY to sign with a Developer ID)"
fi

notarize() {
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    xcrun notarytool submit "$1" \
      --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait
  fi
}
CAN_NOTARIZE=0
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  [[ -n "${NOTARY_PROFILE:-}" ]] && CAN_NOTARIZE=1
  [[ -n "${NOTARY_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]] && CAN_NOTARIZE=1
fi

if [[ $PACKAGE == 1 ]]; then
  ZIP="$BUILD/$APP_NAME-$VERSION.zip"
  DMG="$BUILD/$APP_NAME-$VERSION.dmg"
  rm -f "$ZIP" "$DMG"

  if [[ $CAN_NOTARIZE == 1 ]]; then
    echo "▶ Notarizing app"
    ditto -c -k --keepParent "$APP" "$BUILD/notarize.zip"
    notarize "$BUILD/notarize.zip"
    rm -f "$BUILD/notarize.zip"
    xcrun stapler staple "$APP"
  fi

  echo "▶ Packaging $ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"

  echo "▶ Packaging $DMG"
  STAGE="$(mktemp -d)"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGE"
  if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG"
  fi
  if [[ $CAN_NOTARIZE == 1 ]]; then
    echo "▶ Notarizing dmg"
    notarize "$DMG"
    xcrun stapler staple "$DMG"
  fi
fi

echo "✅ $APP"
if [[ $PACKAGE == 1 ]]; then
  echo "   $ZIP"
  echo "   $DMG"
fi
echo "   Install: drag MiliShip.app to /Applications, then open it."
