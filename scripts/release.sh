#!/bin/bash
# Builds Pace Lab for distribution: signed with "Developer ID Application", notarized by Apple and
# packaged as a DMG. Team ID and bundle ID come from Config/Signing.local.xcconfig, the credentials
# for notarization from the keychain — none of this is in the repository.
#
# Usage:
#   scripts/release.sh                  build, sign, notarize → build/release/Pace-Lab-<Version>.dmg
#   scripts/release.sh --no-notarize    only build, sign, package (dry run without Apple access)
#   scripts/release.sh --upload         additionally attach to the GitHub release v<version> (gh)
#
# Once beforehand: create a notarization profile in the keychain (asks for an app-specific
# password from account.apple.com):
#   xcrun notarytool store-credentials pacelab-notary --apple-id <Apple-ID> --team-id <Team-ID>
# Different profile name: PACELAB_NOTARY_PROFILE=<Name> scripts/release.sh

set -euo pipefail

PROFILE="${PACELAB_NOTARY_PROFILE:-pacelab-notary}"
NOTARIZE=1
UPLOAD=0
for arg in "$@"; do
  case "$arg" in
    --no-notarize) NOTARIZE=0 ;;
    --upload) UPLOAD=1 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg (see --help)" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*" >&2; }
die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[[ $UPLOAD == 0 || $NOTARIZE == 1 ]] || die "--upload only works with notarization: a non-notarized DMG doesn't belong in the release."

cd "$(dirname "$0")/.."

# --- Settings from the project (incl. Config/Signing.local.xcconfig) ---
step "Reading settings"
settings=$(xcodebuild -project PaceLab.xcodeproj -target PaceLab -configuration Release -showBuildSettings 2>/dev/null) \
  || die "xcodebuild could not read the build settings."
setting() { sed -n "s/^[[:space:]]*$1 = //p" <<<"$settings" | head -1; }
TEAM=$(setting DEVELOPMENT_TEAM)
BUNDLE_ID=$(setting PACELAB_BUNDLE_ID)
VERSION=$(setting MARKETING_VERSION)
PRODUCT=$(setting FULL_PRODUCT_NAME)   # "Pace Lab.app"
[[ -n $TEAM ]] || die "DEVELOPMENT_TEAM is missing: create Config/Signing.local.xcconfig (template: Signing.local.example.xcconfig)."
[[ $BUNDLE_ID != com.example.* ]] || die "PACELAB_BUNDLE_ID is still the placeholder: set it in Config/Signing.local.xcconfig."
TAG="v$VERSION"
[[ $VERSION =~ ^[0-9]+\.[0-9]+$ ]] && TAG="v$VERSION.0"
echo "  Version $VERSION (tag $TAG), bundle ID $BUNDLE_ID"

# --- Certificate ---
step "Looking for certificate"
IFS=$'\t' read -r HASH EXPIRES OLD_AUTHORITY IDENTITY < <(python3 scripts/signing_identity.py "$TEAM") || true
[[ -n ${HASH:-} ]] || die "No valid "Developer ID Application" certificate for team $TEAM in the keychain.
  Create one: Xcode → Settings → Accounts → Team → Manage Certificates → + → Developer ID Application
  (a paid Apple Developer account is required). Choose the certificate authority "G2"."
days=$(( (EXPIRES - $(date +%s)) / 86400 ))
echo "  $IDENTITY"
echo "  valid until $(date -r "$EXPIRES" '+%Y-%m-%d') ($days days left)"
if [[ $OLD_AUTHORITY == 1 ]]; then
  warn "The certificate comes from the old Developer ID chain, which expires on 2027-02-01. Apps that are already notarized keep working afterwards,"
  warn "but for new releases you need a certificate from the "G2" chain (Xcode → Manage Certificates → Developer ID Application)."
elif (( days < 90 )); then
  warn "The certificate expires in $days days. Apps that are already notarized keep working; create a new certificate for new releases."
fi

if [[ $NOTARIZE == 1 ]]; then
  step "Checking notarization profile"
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || die "Notarization profile "$PROFILE" is missing or invalid (or there is no connection to Apple). Create it once:
  xcrun notarytool store-credentials $PROFILE --apple-id <Apple-ID> --team-id $TEAM
  (asks for an app-specific password: account.apple.com → Sign-In and Security → App-Specific Passwords)"
  echo "  Profile "$PROFILE" ok"
fi

# --- Build ---
OUT="build/release"
APP="$OUT/dd/Build/Products/Release/$PRODUCT"
NAME="${PRODUCT%.app}"
DMG="$OUT/${NAME// /-}-$VERSION.dmg"
rm -rf "$OUT" && mkdir -p "$OUT"

step "Building and signing (Release)"
xcodebuild -project PaceLab.xcodeproj -scheme PaceLab -configuration Release -derivedDataPath "$OUT/dd" \
  -destination 'generic/platform=macOS' ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$HASH" DEVELOPMENT_TEAM="$TEAM" \
  ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS="--timestamp" \
  build -quiet || die "The build failed."
[[ -d $APP ]] || die "$APP was not built."
echo "  Architectures: $(lipo -archs "$APP/Contents/MacOS/${NAME}")"

# Checks what notarization requires: Developer ID, timestamp, Hardened Runtime, no get-task-allow.
verify() {
  local target="$1" label info entitlements
  label=$(basename "$target")
  codesign --verify --deep --strict "$target" 2>/dev/null || die "$label: the signature is invalid."
  info=$(codesign -dvv "$target" 2>&1)
  grep -q "Authority=Developer ID Application" <<<"$info" || die "$label: not signed with Developer ID."
  grep -q "Timestamp=" <<<"$info" || die "$label: timestamp is missing."
  grep -q "flags=0x10000(runtime)" <<<"$info" || die "$label: Hardened Runtime is missing."
  entitlements=$(codesign -d --entitlements :- "$target" 2>/dev/null || true)
  ! grep -q "get-task-allow" <<<"$entitlements" || die "$label: contains get-task-allow (debug entitlement), which Apple rejects."
  echo "  ✓ $label"
}
step "Verifying signature"
verify "$APP"
for appex in "$APP"/Contents/PlugIns/*.appex; do verify "$appex"; done

# Submits a file to Apple and waits for the result.
notarize() {
  local result status id
  result=$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json 2>&1) || true
  status=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' <<<"$result" 2>/dev/null || true)
  id=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' <<<"$result" 2>/dev/null || true)
  if [[ $status != Accepted ]]; then
    [[ -n $id ]] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || echo "$result" >&2
    die "Apple did not accept "$(basename "$1")" (status: ${status:-unknown})."
  fi
  echo "  ✓ accepted by Apple ($id)"
}

if [[ $NOTARIZE == 1 ]]; then
  step "Notarizing app (usually takes 1–5 minutes)"
  ditto -c -k --keepParent "$APP" "$OUT/app.zip"
  notarize "$OUT/app.zip"
  rm "$OUT/app.zip"
  xcrun stapler staple "$APP" >/dev/null && xcrun stapler validate "$APP" >/dev/null && echo "  ✓ ticket stapled to the app"
fi

# --- DMG ---
step "Packaging DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$PRODUCT"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null 2>"$OUT/hdiutil.log" \
  || { cat "$OUT/hdiutil.log" >&2; die "hdiutil could not create the DMG."; }
rm -rf "$STAGE"
codesign --sign "$HASH" --timestamp "$DMG"

if [[ $NOTARIZE == 1 ]]; then
  step "Notarizing DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG" >/dev/null && xcrun stapler validate "$DMG" >/dev/null && echo "  ✓ ticket stapled to the DMG"
  step "Gatekeeper check"
  spctl --assess --type execute --verbose=2 "$APP"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

( cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )

if [[ $UPLOAD == 1 ]]; then
  step "Attaching to GitHub release $TAG"
  gh release view "$TAG" >/dev/null 2>&1 || die "The release $TAG doesn't exist on GitHub yet — create it first."
  gh release upload "$TAG" "$DMG" "$DMG.sha256" --clobber
fi

step "Done"
echo "  $DMG ($(du -h "$DMG" | cut -f1))"
echo "  $(cat "$DMG.sha256")"
[[ $NOTARIZE == 1 ]] || warn "Not notarized (--no-notarize): Gatekeeper blocks this DMG on other Macs. For testing only."
