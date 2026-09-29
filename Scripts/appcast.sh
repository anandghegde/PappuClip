#!/bin/bash
# Signs update archives with the EdDSA key and writes the Sparkle appcast (PRD §11.4).
#
# Usage:
#   Scripts/appcast.sh <archives-dir> [--channel beta] [--download-url-prefix URL] [--link URL]
#   Scripts/appcast.sh --generate-keys        make the key pair, once, in the login keychain
#   Scripts/appcast.sh --print-public-key     print the public key, for PAPPU_SPARKLE_PUBLIC_KEY
#
# <archives-dir> holds every PappuClip-<version>.zip ever published (Scripts/release.sh makes them)
# and the current appcast.xml, if there is one; generate_appcast adds the new archives to it, signs
# them, and writes deltas next to them. Upload the directory's contents to where PAPPU_APPCAST_URL and
# --download-url-prefix point.
#
# --channel beta publishes the new items on Sparkle's "beta" channel: only copies with "Include beta
# versions" on (Settings → App) see them. Without it an item is on the default channel, which every
# copy sees, betas included.
#
# The private key is never in this repository and never on a command line:
#   PAPPU_SPARKLE_KEY_ACCOUNT        keychain account holding it (default: generate_keys's, "ed25519")
#   PAPPU_SPARKLE_PRIVATE_KEY_FILE   or a file holding it, e.g. from a CI secret; refused if inside the repo
#   PAPPU_SPARKLE_BIN                directory with Sparkle's tools; default: the SwiftPM artifacts of a
#                                    build (run Scripts/build.sh PappuClip once first)

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
fail() { echo "error: $*" >&2; exit 1; }

sparkle_bin() {
  local candidate
  for candidate in \
    "${PAPPU_SPARKLE_BIN:-}" \
    "$ROOT/build/release/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin" \
    "$ROOT/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"; do
    if [[ -n "$candidate" && -x "$candidate/generate_appcast" ]]; then
      echo "$candidate"
      return
    fi
  done
  fail "Sparkle's tools were not found. Run Scripts/build.sh PappuClip once (it fetches Sparkle), or set PAPPU_SPARKLE_BIN."
}

BIN=$(sparkle_bin)
ACCOUNT=${PAPPU_SPARKLE_KEY_ACCOUNT:-ed25519}

case "${1:-}" in
  --generate-keys)
    # Stored in the login keychain only. Back it up with `generate_keys -x <file>` somewhere that is
    # not this repository: losing it means no copy in the field can be updated again.
    exec "$BIN/generate_keys" --account "$ACCOUNT"
    ;;
  --print-public-key)
    exec "$BIN/generate_keys" --account "$ACCOUNT" -p
    ;;
  ""|-h|--help)
    sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
    [[ -n "${1:-}" ]] && exit 0 || exit 2
    ;;
esac

ARCHIVES=$1
shift
[[ -d "$ARCHIVES" ]] || fail "no such directory: $ARCHIVES"
ls "$ARCHIVES"/*.zip >/dev/null 2>&1 || fail "no .zip update archives in $ARCHIVES (Scripts/release.sh makes them)"

ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel)
      [[ "$2" == "beta" ]] || fail "the only channel is \"beta\"; stable items go on the default channel (no --channel)"
      ARGS+=(--channel "$2"); shift 2 ;;
    --download-url-prefix|--link|--release-notes-url-prefix)
      [[ "$2" == https://* ]] || fail "$1 must be an https URL: $2"
      ARGS+=("$1" "$2"); shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -n "${PAPPU_SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
  KEY=$(cd "$(dirname "$PAPPU_SPARKLE_PRIVATE_KEY_FILE")" && pwd)/$(basename "$PAPPU_SPARKLE_PRIVATE_KEY_FILE")
  [[ -f "$KEY" ]] || fail "PAPPU_SPARKLE_PRIVATE_KEY_FILE does not exist: $KEY"
  [[ "$KEY" == "$ROOT"/* ]] && fail "the private key must not live inside the repository: $KEY"
  # Through stdin, so the key's path is the only thing on the command line and never the key.
  "$BIN/generate_appcast" --ed-key-file - "${ARGS[@]+"${ARGS[@]}"}" "$ARCHIVES" < "$KEY"
else
  "$BIN/generate_appcast" --account "$ACCOUNT" "${ARGS[@]+"${ARGS[@]}"}" "$ARCHIVES"
fi

# generate_appcast leaves an item unsigned, with only a warning, when the archive's SUPublicEDKey does
# not match the key it signs with (or is empty, as in a --local build). Sparkle rejects such an item,
# so publishing it would strand every copy on the old version without saying why.
unsigned=$(grep '<enclosure ' "$ARCHIVES/appcast.xml" | grep -vc 'sparkle:edSignature=' || true)
if [[ "$unsigned" -gt 0 ]]; then
  fail "$unsigned item(s) in $ARCHIVES/appcast.xml have no EdDSA signature: the archive's SUPublicEDKey does not match this private key. Do not publish it."
fi
echo "Wrote $ARCHIVES/appcast.xml"
