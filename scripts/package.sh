#!/usr/bin/env bash
# Package Slate as a standalone, Developer-ID-signed, hardened-runtime .app + DMG —
# runnable without Xcode, with TCC permissions (Screen Recording / Camera / Mic /
# Accessibility) that PERSIST across rebuilds because the signature is stable.
#
#   scripts/package.sh            # build + sign + DMG (+ notarize if a credential profile exists)
#   scripts/package.sh --no-notarize    # skip notarization even if a profile exists
#
# WHY SIGN: macOS keys each TCC grant to the binary's cdhash. A Developer ID cert yields the
# SAME cdhash every build, so grants survive rebuilds. Ad-hoc/unsigned builds change the
# cdhash every compile and macOS re-prompts (or silently drops the grant). So: never run an
# unsigned build day-to-day.
#
# NOTARIZATION (optional for a single Mac; required to move the app to ANOTHER Mac without a
# Gatekeeper warning). One-time setup of a keychain credential profile:
#   xcrun notarytool store-credentials "slate-notary" \
#       --apple-id "you@example.com" --team-id C9562TBW66 \
#       --password "<app-specific-password from appleid.apple.com>"
# (The APNs key ~/Documents/Anthology Secrets/AuthKey_*.p8 will NOT work — wrong key type.)
set -euo pipefail

DEV_ID="${SLATE_DEV_ID:-Developer ID Application: MICHAEL FRANCIS LOMUSCIO III (C9562TBW66)}"
TEAM_ID="${SLATE_TEAM_ID:-C9562TBW66}"
NOTARY_PROFILE="${SLATE_NOTARY_PROFILE:-slate-notary}"
SCHEME="Slate"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
APP="$DIST/Slate.app"
DMG="$DIST/Slate.dmg"
ENTITLEMENTS="$ROOT/Slate/Slate.entitlements"

NOTARIZE=1
[ "${1:-}" = "--no-notarize" ] && NOTARIZE=0

# Notarization auth: prefer explicit env credentials (robust if the keychain profile is flaky)
#   NOTARY_APPLE_ID=you@example.com NOTARY_PASSWORD=app-specific-pw ./scripts/package.sh
# else fall back to the stored keychain profile ($NOTARY_PROFILE).
if [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ]; then
  NOTARY_AUTH=(--apple-id "$NOTARY_APPLE_ID" --team-id "$TEAM_ID" --password "$NOTARY_PASSWORD")
else
  NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
fi

cd "$ROOT"
echo "▸ 1/6  Generating Xcode project (XcodeGen)…"
xcodegen generate >/dev/null

echo "▸ 2/6  Building Release (hardened runtime)…"
rm -rf "$BUILD" "$DIST"
mkdir -p "$DIST"
xcodebuild -scheme "$SCHEME" -configuration Release -derivedDataPath "$BUILD" \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY="$DEV_ID" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM_ID" \
  clean build >/dev/null
BUILT="$BUILD/Build/Products/Release/Slate.app"
[ -d "$BUILT" ] || { echo "✗ build did not produce $BUILT"; exit 1; }
cp -R "$BUILT" "$APP"

echo "▸ 3/6  Signing with Developer ID + hardened runtime…"
# Deep-sign any nested code first (none expected for Slate, but safe), then the app itself.
find "$APP/Contents" -type d \( -name "*.framework" -o -name "*.dylib" \) -print0 2>/dev/null \
  | while IFS= read -r -d '' f; do
      codesign --force --options runtime --timestamp --sign "$DEV_ID" "$f" || true
    done
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" --sign "$DEV_ID" "$APP"

echo "▸ 4/6  Verifying signature…"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP" 2>&1 || \
  echo "  (spctl will say 'rejected' until notarized — expected; the app still runs locally.)"

# DMG (built before notarization so we can staple the .app inside, then re-create if needed)
build_dmg() {
  echo "▸ 5/6  Building DMG…"
  rm -f "$DMG"
  local staging; staging="$(mktemp -d)"
  cp -R "$APP" "$staging/Slate.app"
  ln -s /Applications "$staging/Applications"
  hdiutil create -volname "Slate" -srcfolder "$staging" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$staging"
  codesign --force --timestamp --sign "$DEV_ID" "$DMG" 2>/dev/null || true
}

# Attempt notarization directly (don't gate on a fragile network `history` precheck — that
# silently skipped notarization when the call hiccuped). Fall back to signed-only on failure.
notarized=0
if [ "$NOTARIZE" = "1" ]; then
  echo "▸ 5/6  Notarizing the app (profile: $NOTARY_PROFILE)…"
  ZIP="$DIST/Slate-notarize.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  if xcrun notarytool submit "$ZIP" "${NOTARY_AUTH[@]}" --wait; then
    notarized=1
  else
    echo "  ⚠ Notarization unavailable (profile '$NOTARY_PROFILE' missing, or submit failed)."
    echo "    Create it once:  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\"
    echo "        --apple-id \"YOUR_APPLE_ID\" --team-id $TEAM_ID --password \"APP_SPECIFIC_PASSWORD\""
  fi
  rm -f "$ZIP"
fi

if [ "$notarized" = "1" ]; then
  echo "▸ 6/6  Stapling app, building + notarizing DMG…"
  xcrun stapler staple "$APP"          # offline-valid app (survives copy-out of the DMG)
  build_dmg
  xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait
  xcrun stapler staple "$DMG"
  echo "✓ Notarized + stapled (app and DMG)."
else
  build_dmg
  echo "✓ Signed (not notarized). Runs locally on this Mac by double-click."
fi

echo
echo "Done:"
echo "  App: $APP"
echo "  DMG: $DMG"
echo "Install: open the DMG and drag Slate to Applications. First launch grants Screen"
echo "Recording / Camera / Mic; grant Accessibility for click-driven auto-zoom."
