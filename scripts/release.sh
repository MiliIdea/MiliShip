#!/usr/bin/env bash
# Publishes a signed, notarized Mili Ship release from this Mac.
#
#   ./scripts/release.sh 0.2.0            build, notarize, tag v0.2.0 and publish on GitHub
#   ./scripts/release.sh 0.2.0 --dry-run  build and notarize only
#
# Needs, once:
#   - a "Developer ID Application" certificate in the login keychain
#     (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application)
#   - notarization credentials saved as a notarytool keychain profile:
#       xcrun notarytool store-credentials "MiliShip-notary" --apple-id you@example.com --team-id TEAMID
#     (set NOTARY_PROFILE to use another profile name)
#   - the GitHub CLI, logged in (gh auth login)
# Release notes come from the version's section in CHANGELOG.md.
set -euo pipefail

VERSION="${1:?usage: ./scripts/release.sh <version> [--dry-run]}"
VERSION="${VERSION#v}"
DRY_RUN=0
[[ "${2:-}" == "--dry-run" ]] && DRY_RUN=1
TAG="v$VERSION"
REPO="MiliIdea/MiliShip"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() { printf "\033[31m✖ %s\033[0m\n" "$*" >&2; exit 1; }
ok() { printf "\033[32m✓\033[0m %s\n" "$*"; }

[[ -z "$(git status --porcelain)" ]] || fail "Commit or stash your changes first."
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "Tag $TAG already exists."

# Several identical certificates can be installed; sign with the first one's hash so codesign isn't ambiguous.
IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "Developer ID Application:.*/\1/p' | head -1)"
[[ -n "$IDENTITY" ]] || fail "No Developer ID Application certificate in the keychain."
ok "Signing identity $(security find-identity -v -p codesigning | grep "$IDENTITY" | sed 's/.*"\(.*\)"/\1/')"

if [[ -z "${NOTARY_PROFILE:-}" ]]; then
  for candidate in MiliShip-notary MiliControl-notary; do
    xcrun notarytool history --keychain-profile "$candidate" >/dev/null 2>&1 && { NOTARY_PROFILE="$candidate"; break; }
  done
fi
[[ -n "${NOTARY_PROFILE:-}" ]] || fail "No notarytool profile. Run: xcrun notarytool store-credentials MiliShip-notary --apple-id … --team-id …"
ok "Notarization profile $NOTARY_PROFILE"

NOTES="$(awk -v v="$VERSION" '
  $0 ~ "^## " v "( |$)" { found = 1; next }
  found && /^## / { exit }
  found { print }' CHANGELOG.md | sed '/./,$!d')"
[[ -n "$NOTES" ]] || fail "CHANGELOG.md has no \"## $VERSION\" section."

UNIVERSAL=1 VERSION="$VERSION" CODESIGN_IDENTITY="$IDENTITY" NOTARY_PROFILE="$NOTARY_PROFILE" \
  ./scripts/build_app.sh --package

APP="build/MiliShip.app"
DMG="build/MiliShip-$VERSION.dmg"
ZIP="build/MiliShip-$VERSION.zip"
spctl --assess --type execute -vv "$APP" 2>&1 | grep -q "Notarized Developer ID" || fail "Gatekeeper doesn't accept $APP as notarized."
xcrun stapler validate "$DMG" >/dev/null || fail "$DMG has no stapled notarization ticket."
lipo -archs "$APP/Contents/MacOS/MiliShip" | grep -q "x86_64 arm64\|arm64 x86_64" || fail "$APP isn't universal."
ok "Notarized, stapled, universal: $DMG ($(du -h "$DMG" | cut -f1))"

if [[ $DRY_RUN == 1 ]]; then
  ok "Dry run: not tagging or publishing."
  exit 0
fi

git tag -a "$TAG" -m "Mili Ship $VERSION"
git push -q origin "$TAG"
gh release create "$TAG" "$DMG" "$ZIP" --repo "$REPO" --title "Mili Ship $VERSION" --notes "$NOTES" --verify-tag
ok "Published https://github.com/$REPO/releases/tag/$TAG"
