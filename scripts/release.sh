#!/bin/bash
# Baut Pace Lab zur Weitergabe: mit „Developer ID Application“ signiert, von Apple notarisiert und
# als DMG verpackt. Team-ID und Bundle-ID kommen aus Config/Signing.local.xcconfig, die Zugangsdaten
# für die Notarisierung aus dem Schlüsselbund — im Repository steht davon nichts.
#
# Aufruf:
#   scripts/release.sh                  bauen, signieren, notarisieren → build/release/Pace-Lab-<Version>.dmg
#   scripts/release.sh --no-notarize    nur bauen, signieren, verpacken (Trockenlauf ohne Apple-Zugang)
#   scripts/release.sh --upload         zusätzlich ans GitHub-Release v<Version> hängen (gh)
#
# Einmalig vorher: Notarisierungs-Profil im Schlüsselbund anlegen (fragt nach einem app-spezifischen
# Passwort von account.apple.com):
#   xcrun notarytool store-credentials pacelab-notary --apple-id <Apple-ID> --team-id <Team-ID>
# Anderer Profilname: PACELAB_NOTARY_PROFILE=<Name> scripts/release.sh

set -euo pipefail

PROFILE="${PACELAB_NOTARY_PROFILE:-pacelab-notary}"
NOTARIZE=1
UPLOAD=0
for arg in "$@"; do
  case "$arg" in
    --no-notarize) NOTARIZE=0 ;;
    --upload) UPLOAD=1 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unbekannte Option: $arg (siehe --help)" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*" >&2; }
die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[[ $UPLOAD == 0 || $NOTARIZE == 1 ]] || die "--upload geht nur mit Notarisierung: ein nicht notarisiertes DMG gehört nicht ins Release."

cd "$(dirname "$0")/.."

# --- Einstellungen aus dem Projekt (inkl. Config/Signing.local.xcconfig) ---
step "Einstellungen lesen"
settings=$(xcodebuild -project PaceLab.xcodeproj -target PaceLab -configuration Release -showBuildSettings 2>/dev/null) \
  || die "xcodebuild konnte die Build-Einstellungen nicht lesen."
setting() { sed -n "s/^[[:space:]]*$1 = //p" <<<"$settings" | head -1; }
TEAM=$(setting DEVELOPMENT_TEAM)
BUNDLE_ID=$(setting PACELAB_BUNDLE_ID)
VERSION=$(setting MARKETING_VERSION)
PRODUCT=$(setting FULL_PRODUCT_NAME)   # „Pace Lab.app“
[[ -n $TEAM ]] || die "DEVELOPMENT_TEAM fehlt: Config/Signing.local.xcconfig anlegen (Vorlage: Signing.local.example.xcconfig)."
[[ $BUNDLE_ID != com.example.* ]] || die "PACELAB_BUNDLE_ID ist noch der Platzhalter: in Config/Signing.local.xcconfig eintragen."
TAG="v$VERSION"
[[ $VERSION =~ ^[0-9]+\.[0-9]+$ ]] && TAG="v$VERSION.0"
echo "  Version $VERSION (Tag $TAG), Bundle-ID $BUNDLE_ID"

# --- Zertifikat ---
step "Zertifikat suchen"
IFS=$'\t' read -r HASH EXPIRES OLD_AUTHORITY IDENTITY < <(python3 scripts/signing_identity.py "$TEAM") || true
[[ -n ${HASH:-} ]] || die "Kein gültiges „Developer ID Application“-Zertifikat für Team $TEAM im Schlüsselbund.
  Anlegen: Xcode → Settings → Accounts → Team → Manage Certificates → + → Developer ID Application
  (ein bezahltes Apple-Developer-Konto ist nötig). Dabei die Zertifizierungsstelle „G2“ wählen."
days=$(( (EXPIRES - $(date +%s)) / 86400 ))
echo "  $IDENTITY"
echo "  gültig bis $(date -r "$EXPIRES" '+%d.%m.%Y') (noch $days Tage)"
if [[ $OLD_AUTHORITY == 1 ]]; then
  warn "Das Zertifikat stammt aus der alten Developer-ID-Kette, die am 01.02.2027 abläuft. Bereits notarisierte Apps laufen danach weiter,"
  warn "für neue Releases brauchst du ein Zertifikat aus der Kette „G2“ (Xcode → Manage Certificates → Developer ID Application)."
elif (( days < 90 )); then
  warn "Das Zertifikat läuft in $days Tagen ab. Bereits notarisierte Apps laufen weiter, für neue Releases ein neues Zertifikat anlegen."
fi

if [[ $NOTARIZE == 1 ]]; then
  step "Notarisierungs-Profil prüfen"
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || die "Notarisierungs-Profil „$PROFILE“ fehlt oder ist ungültig (oder keine Verbindung zu Apple). Einmalig anlegen:
  xcrun notarytool store-credentials $PROFILE --apple-id <Apple-ID> --team-id $TEAM
  (fragt nach einem app-spezifischen Passwort: account.apple.com → Anmeldung und Sicherheit → App-spezifische Passwörter)"
  echo "  Profil „$PROFILE“ ok"
fi

# --- Bauen ---
OUT="build/release"
APP="$OUT/dd/Build/Products/Release/$PRODUCT"
NAME="${PRODUCT%.app}"
DMG="$OUT/${NAME// /-}-$VERSION.dmg"
rm -rf "$OUT" && mkdir -p "$OUT"

step "Bauen und signieren (Release)"
xcodebuild -project PaceLab.xcodeproj -scheme PaceLab -configuration Release -derivedDataPath "$OUT/dd" \
  -destination 'generic/platform=macOS' ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$HASH" DEVELOPMENT_TEAM="$TEAM" \
  ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS="--timestamp" \
  build -quiet || die "Der Build ist fehlgeschlagen."
[[ -d $APP ]] || die "$APP wurde nicht gebaut."
echo "  Architekturen: $(lipo -archs "$APP/Contents/MacOS/${NAME}")"

# Prüft, was die Notarisierung verlangt: Developer ID, Zeitstempel, Hardened Runtime, kein get-task-allow.
verify() {
  local target="$1" label info entitlements
  label=$(basename "$target")
  codesign --verify --deep --strict "$target" 2>/dev/null || die "$label: Die Signatur ist ungültig."
  info=$(codesign -dvv "$target" 2>&1)
  grep -q "Authority=Developer ID Application" <<<"$info" || die "$label: nicht mit Developer ID signiert."
  grep -q "Timestamp=" <<<"$info" || die "$label: Zeitstempel fehlt."
  grep -q "flags=0x10000(runtime)" <<<"$info" || die "$label: Hardened Runtime fehlt."
  entitlements=$(codesign -d --entitlements :- "$target" 2>/dev/null || true)
  ! grep -q "get-task-allow" <<<"$entitlements" || die "$label: enthält get-task-allow (Debug-Rechte), das lehnt Apple ab."
  echo "  ✓ $label"
}
step "Signatur prüfen"
verify "$APP"
for appex in "$APP"/Contents/PlugIns/*.appex; do verify "$appex"; done

# Reicht eine Datei bei Apple ein und wartet auf das Ergebnis.
notarize() {
  local result status id
  result=$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json 2>&1) || true
  status=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' <<<"$result" 2>/dev/null || true)
  id=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' <<<"$result" 2>/dev/null || true)
  if [[ $status != Accepted ]]; then
    [[ -n $id ]] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || echo "$result" >&2
    die "Apple hat „$(basename "$1")“ nicht akzeptiert (Status: ${status:-unbekannt})."
  fi
  echo "  ✓ von Apple akzeptiert ($id)"
}

if [[ $NOTARIZE == 1 ]]; then
  step "App notarisieren (dauert meist 1–5 Minuten)"
  ditto -c -k --keepParent "$APP" "$OUT/app.zip"
  notarize "$OUT/app.zip"
  rm "$OUT/app.zip"
  xcrun stapler staple "$APP" >/dev/null && xcrun stapler validate "$APP" >/dev/null && echo "  ✓ Ticket in die App geheftet"
fi

# --- DMG ---
step "DMG packen"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$PRODUCT"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null 2>"$OUT/hdiutil.log" \
  || { cat "$OUT/hdiutil.log" >&2; die "hdiutil konnte das DMG nicht anlegen."; }
rm -rf "$STAGE"
codesign --sign "$HASH" --timestamp "$DMG"

if [[ $NOTARIZE == 1 ]]; then
  step "DMG notarisieren"
  notarize "$DMG"
  xcrun stapler staple "$DMG" >/dev/null && xcrun stapler validate "$DMG" >/dev/null && echo "  ✓ Ticket in das DMG geheftet"
  step "Gatekeeper-Test"
  spctl --assess --type execute --verbose=2 "$APP"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

( cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )

if [[ $UPLOAD == 1 ]]; then
  step "An GitHub-Release $TAG hängen"
  gh release view "$TAG" >/dev/null 2>&1 || die "Das Release $TAG gibt es auf GitHub noch nicht — erst anlegen."
  gh release upload "$TAG" "$DMG" "$DMG.sha256" --clobber
fi

step "Fertig"
echo "  $DMG ($(du -h "$DMG" | cut -f1))"
echo "  $(cat "$DMG.sha256")"
[[ $NOTARIZE == 1 ]] || warn "Nicht notarisiert (--no-notarize): Auf anderen Macs blockiert Gatekeeper dieses DMG. Nur zum Testen."
