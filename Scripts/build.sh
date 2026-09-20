#!/bin/bash
# Generates the Xcode project and builds one scheme into build/.
#
# Usage: Scripts/build.sh [scheme] [configuration]      default: SpikeLab Debug
#
# Signing identity, first match wins:
#   1. $PAPPU_SIGN_IDENTITY            any identity `security find-identity -p codesigning` lists; "-" for ad-hoc
#   2. "PappuClip Development"         made by Scripts/setup-dev-signing.sh
#   3. ad-hoc                          builds and runs, but every rebuild loses the Accessibility grant
#
# $PAPPU_DERIVED_DATA builds somewhere other than build/DerivedData, which leaves the app you are
# running spikes from untouched while you check that something else compiles.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCHEME=${1:-SpikeLab}
CONFIGURATION=${2:-Debug}
DEFAULT_IDENTITY="PappuClip Development"
DERIVED_DATA=${PAPPU_DERIVED_DATA:-$ROOT/build/DerivedData}

if ! command -v xcodegen >/dev/null; then
  echo "xcodegen is not installed. Install it with: brew install xcodegen" >&2
  exit 1
fi

if [[ -n "${PAPPU_SIGN_IDENTITY:-}" ]]; then
  IDENTITY="$PAPPU_SIGN_IDENTITY"
elif security find-identity -p codesigning | grep -q "\"$DEFAULT_IDENTITY\""; then
  IDENTITY="$DEFAULT_IDENTITY"
else
  IDENTITY="-"
  echo "warning: no \"$DEFAULT_IDENTITY\" identity; signing ad-hoc. macOS will forget the Accessibility" >&2
  echo "warning: grant on every rebuild. Run Scripts/setup-dev-signing.sh once to fix that." >&2
fi

# App/project.yml reads this. The identity is baked into the generated project, so it applies to the
# app targets only and an Xcode build uses the same one.
export PAPPU_SIGN_IDENTITY="$IDENTITY"
(cd "$ROOT/App" && xcodegen generate --quiet)

xcodebuild \
  -project "$ROOT/App/PappuClip.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -destination "platform=macOS,arch=$(uname -m)" \
  -quiet \
  build

PRODUCT="$DERIVED_DATA/Build/Products/$CONFIGURATION/$SCHEME.app"
echo "Built $PRODUCT"
codesign -dvv "$PRODUCT" 2>&1 | grep -E '^(Identifier|Authority|Signature|TeamIdentifier)=' | sed 's/^/  /'
