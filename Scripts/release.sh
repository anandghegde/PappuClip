#!/bin/bash
# Builds, signs, notarizes and packages a release of PappuClip (PRD §11.4, implementation plan §6 M3
# week 7).
#
# Usage: Scripts/release.sh [--local] [--version X.Y.Z] [--build N] [--output DIR]
#
#   --local      Sign with the development identity (or $PAPPU_SIGN_IDENTITY) and stop before
#                notarization: checks the signing, the entitlements and the hardened runtime of every
#                piece of code without any Apple credentials. The result is NOT distributable, and it
#                does not launch: library validation refuses Sparkle.framework in a process whose
#                signature has no Team ID, which is what a development certificate gives.
#   --version    CFBundleShortVersionString. Default: MARKETING_VERSION in App/project.yml.
#   --build      CFBundleVersion, which Sparkle compares. Default: CURRENT_PROJECT_VERSION.
#   --output     Where the artifacts go. Default: build/release/<version>.
#
# A real release needs, in the environment (never in the repository):
#   PAPPU_RELEASE_IDENTITY    "Developer ID Application: <name> (<team>)", in the login keychain.
#   PAPPU_NOTARY_PROFILE      a notarytool keychain profile, made once with
#                             `xcrun notarytool store-credentials <profile> --apple-id ... --team-id ...`
#   PAPPU_SPARKLE_PUBLIC_KEY  the EdDSA public key `Scripts/appcast.sh --print-public-key` prints.
#   PAPPU_APPCAST_URL         https URL the app reads its appcast from.
#
# Produces PappuClip-<version>.zip (the Sparkle update archive), PappuClip-<version>.dmg (for people),
# and PappuClip-<version>-dSYMs.zip. Then run Scripts/appcast.sh on the directory holding the archives.
#
# Order of signing is inside out, and every piece is re-signed here rather than trusting Xcode's copy
# step: Sparkle's helpers, Sparkle.framework, the two XPC services with their own entitlements, then
# the app. Each gets the hardened runtime and a secure timestamp, which notarization requires.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LOCAL=0
VERSION=""
BUILD=""
OUTPUT=""

fail() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local) LOCAL=1; shift ;;
    --version) VERSION="$2"; shift 2 ;;
    --build) BUILD="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

project_setting() { # <name>: its value in App/project.yml's base settings
  sed -n "s/^ *$1: *\"\{0,1\}\([^\"]*\)\"\{0,1\} *$/\1/p" "$ROOT/App/project.yml" | head -1
}
VERSION=${VERSION:-$(project_setting MARKETING_VERSION)}
BUILD=${BUILD:-$(project_setting CURRENT_PROJECT_VERSION)}
[[ -n "$VERSION" && -n "$BUILD" ]] || fail "could not read the version from App/project.yml; pass --version and --build"
[[ "$BUILD" =~ ^[0-9]+(\.[0-9]+)*$ ]] || fail "--build must be numeric (Sparkle compares it): $BUILD"

# --- What a release needs, checked before anything is built -------------------------------------

missing=()
if [[ $LOCAL -eq 1 ]]; then
  IDENTITY=${PAPPU_SIGN_IDENTITY:-"PappuClip Development"}
  TIMESTAMP="--timestamp=none"
  APPCAST_URL=${PAPPU_APPCAST_URL:-}
  PUBLIC_KEY=${PAPPU_SPARKLE_PUBLIC_KEY:-}
else
  IDENTITY=${PAPPU_RELEASE_IDENTITY:-}
  TIMESTAMP="--timestamp"
  APPCAST_URL=${PAPPU_APPCAST_URL:-}
  PUBLIC_KEY=${PAPPU_SPARKLE_PUBLIC_KEY:-}
  [[ -n "$IDENTITY" ]] || missing+=("PAPPU_RELEASE_IDENTITY (\"Developer ID Application: <name> (<team>)\")")
  [[ -z "$IDENTITY" || "$IDENTITY" == "Developer ID Application:"* ]] \
    || fail "PAPPU_RELEASE_IDENTITY must be a Developer ID Application identity, not \"$IDENTITY\""
  [[ -n "${PAPPU_NOTARY_PROFILE:-}" ]] || missing+=("PAPPU_NOTARY_PROFILE (a profile made with xcrun notarytool store-credentials)")
  [[ -n "$PUBLIC_KEY" ]] || missing+=("PAPPU_SPARKLE_PUBLIC_KEY (Scripts/appcast.sh --print-public-key)")
  [[ -n "$APPCAST_URL" ]] || missing+=("PAPPU_APPCAST_URL (https URL of appcast.xml)")
fi
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "error: a release needs these, and they are not set:" >&2
  for item in "${missing[@]}"; do echo "  - $item" >&2; done
  echo "Nothing was built. Scripts/release.sh --local checks the signing without credentials." >&2
  exit 1
fi
[[ -z "$APPCAST_URL" || "$APPCAST_URL" == https://* ]] || fail "PAPPU_APPCAST_URL must be https: $APPCAST_URL"

for tool in xcodegen xcodebuild codesign ditto hdiutil plutil; do
  command -v "$tool" >/dev/null || fail "$tool is not installed"
done
# A release identity must be valid (-v: trusted, unexpired). The self-signed development one never is,
# so --local only asks that it exists, as Scripts/build.sh does.
VALID="-v"; [[ $LOCAL -eq 1 ]] && VALID=""
security find-identity $VALID -p codesigning | grep -qF "\"$IDENTITY\"" \
  || fail "no signing identity \"$IDENTITY\" in the keychain"
if [[ $LOCAL -eq 0 ]]; then
  # Before the build rather than after it: a stale profile is found in seconds, not minutes.
  xcrun notarytool history --keychain-profile "$PAPPU_NOTARY_PROFILE" >/dev/null \
    || fail "notarytool cannot use the keychain profile \"$PAPPU_NOTARY_PROFILE\""
fi

OUTPUT=${OUTPUT:-"$ROOT/build/release/$VERSION"}
DERIVED="$ROOT/build/release/DerivedData"
rm -rf "$OUTPUT"
mkdir -p "$OUTPUT"
NAME="PappuClip-$VERSION"
[[ $LOCAL -eq 1 ]] && NAME="$NAME-local"

# --- Build ---------------------------------------------------------------------------------------

echo "Building PappuClip $VERSION ($BUILD), universal, Release"
# Built ad-hoc: every piece is re-signed below with the release identity, so the build itself never
# needs the Developer ID key (and never asks the keychain for it).
export PAPPU_SIGN_IDENTITY="-"
(cd "$ROOT/App" && xcodegen generate --quiet)
xcodebuild \
  -project "$ROOT/App/PappuClip.xcodeproj" \
  -scheme PappuClip \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -destination "generic/platform=macOS" \
  -quiet \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  PAPPU_UPDATER_CONDITION=PAPPU_SPARKLE \
  PAPPU_APPCAST_URL="$APPCAST_URL" \
  PAPPU_SPARKLE_PUBLIC_KEY="$PUBLIC_KEY" \
  build

PRODUCTS="$DERIVED/Build/Products/Release"
STAGE="$OUTPUT/stage"
APP="$STAGE/PappuClip.app"
mkdir -p "$STAGE"
ditto "$PRODUCTS/PappuClip.app" "$APP"

# --- Sign, inside out ----------------------------------------------------------------------------

sign() { # <path> [codesign options...]
  local path=$1; shift
  codesign --force --sign "$IDENTITY" --options runtime $TIMESTAMP "$@" "$path"
}

echo "Signing with \"$IDENTITY\""
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
[[ -d "$SPARKLE" ]] || fail "Sparkle.framework is not in the bundle"
SPARKLE_B="$SPARKLE/Versions/B"
# Sparkle's own list (sparkle-project.org/documentation/sandboxing, "Code Signing"). The XPC services
# are unused by a non-sandboxed app but ship in the framework, so they are signed like everything else.
[[ -d "$SPARKLE_B/XPCServices/Installer.xpc" ]] && sign "$SPARKLE_B/XPCServices/Installer.xpc"
[[ -d "$SPARKLE_B/XPCServices/Downloader.xpc" ]] && sign "$SPARKLE_B/XPCServices/Downloader.xpc" --preserve-metadata=entitlements
sign "$SPARKLE_B/Autoupdate"
sign "$SPARKLE_B/Updater.app"
sign "$SPARKLE"

# The helpers, each with exactly its checked-in entitlements (architecture §2): the JavaScript helper
# the sandbox and nothing else, the Runner Apple events and nothing else.
sign "$APP/Contents/XPCServices/PappuClipRunner.xpc" --entitlements "$ROOT/App/PappuClipRunner/PappuClipRunner.entitlements"
sign "$APP/Contents/XPCServices/PappuClipJSHost.xpc" --entitlements "$ROOT/App/PappuClipJSHost/PappuClipJSHost.entitlements"

# Anything else that is code and was not named above would be shipped with an ad-hoc signature, which
# notarization refuses. There is nothing today; this makes a new one a failure rather than a surprise.
while IFS= read -r -d '' file; do
  case "$file" in
    "$SPARKLE"/*|"$APP/Contents/XPCServices"/*|"$APP/Contents/MacOS/PappuClip") continue ;;
  esac
  if file -b "$file" | grep -q "Mach-O"; then
    fail "unexpected executable code in the bundle, not signed by this script: ${file#"$STAGE/"}"
  fi
done < <(find "$APP/Contents" -type f -print0)

sign "$APP" --entitlements "$ROOT/App/PappuClip/PappuClip.entitlements"

# --- Verify --------------------------------------------------------------------------------------

echo "Verifying"
"$ROOT/Scripts/verify-signature.sh" "$APP" --identity "$IDENTITY"

# dSYMs, for symbolicating crash reports (DIA-3).
if compgen -G "$PRODUCTS/*.dSYM" >/dev/null; then
  (cd "$PRODUCTS" && zip -qry "$OUTPUT/$NAME-dSYMs.zip" ./*.dSYM)
fi

# --- Notarize and staple -------------------------------------------------------------------------

notarize() { # <file>
  local file=$1 result id status
  echo "Submitting ${file##*/} for notarization (this waits)"
  result=$(xcrun notarytool submit "$file" --keychain-profile "$PAPPU_NOTARY_PROFILE" --wait --output-format plist)
  id=$(plutil -extract id raw -o - - <<<"$result")
  status=$(plutil -extract status raw -o - - <<<"$result")
  if [[ "$status" != "Accepted" ]]; then
    xcrun notarytool log "$id" --keychain-profile "$PAPPU_NOTARY_PROFILE" >&2 || true
    fail "notarization of ${file##*/} ended \"$status\" (submission $id)"
  fi
}

if [[ $LOCAL -eq 0 ]]; then
  ditto -c -k --keepParent "$APP" "$OUTPUT/notarize.zip"
  notarize "$OUTPUT/notarize.zip"
  rm "$OUTPUT/notarize.zip"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi

# --- Package -------------------------------------------------------------------------------------

# The Sparkle update archive. ditto keeps the symlinks and extended attributes a framework needs.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT/$NAME.zip"

# The disk image people download: the app and a link to Applications.
DMG_ROOT="$OUTPUT/dmg"
mkdir -p "$DMG_ROOT"
ditto "$APP" "$DMG_ROOT/PappuClip.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -quiet -volname "PappuClip $VERSION" -srcfolder "$DMG_ROOT" -fs HFS+ -format UDZO -ov "$OUTPUT/$NAME.dmg"
rm -rf "$DMG_ROOT"
codesign --force --sign "$IDENTITY" $TIMESTAMP "$OUTPUT/$NAME.dmg"

if [[ $LOCAL -eq 0 ]]; then
  notarize "$OUTPUT/$NAME.dmg"
  xcrun stapler staple "$OUTPUT/$NAME.dmg"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$OUTPUT/$NAME.dmg"
fi

echo
echo "Done: $OUTPUT"
ls -1 "$OUTPUT" | grep -v '^stage$' | sed 's/^/  /'
if [[ $LOCAL -eq 1 ]]; then
  echo "Local build: signed with \"$IDENTITY\", not notarized, not for distribution."
else
  echo "Next: copy $NAME.zip into your archives folder and run Scripts/appcast.sh [--channel beta] on it."
fi
