#!/bin/bash
# Checks a signed PappuClip.app the way notarization and Gatekeeper will (PRD §11.4): a strict, deep
# signature; the hardened runtime and one signing authority on every piece of code in the bundle; and
# each process's entitlements exactly as architecture §2 lists them. Scripts/release.sh runs it; it can
# also be pointed at any copy, a downloaded release included.
#
# Usage: Scripts/verify-signature.sh <PappuClip.app> [--identity "<name>"]

set -euo pipefail

APP=${1:?usage: Scripts/verify-signature.sh <PappuClip.app> [--identity NAME]}
shift
IDENTITY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity) IDENTITY="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

failures=0
bad() { echo "  FAIL $*" >&2; failures=$((failures + 1)); }
ok() { echo "  ok   $*"; }

codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | sed 's/^/  /' \
  && ok "codesign --verify --deep --strict" \
  || bad "codesign --verify --deep --strict"

# Every signed piece of code: Mach-O files and the bundles that hold them.
while IFS= read -r -d '' file; do
  file -b "$file" | grep -q "Mach-O" || continue
  info=$(codesign -dvv "$file" 2>&1) || { bad "${file#"$APP/"} is not signed"; continue; }
  name=${file#"$APP/"}
  if ! grep -q 'flags=.*runtime' <<<"$info"; then bad "$name: no hardened runtime"; continue; fi
  if [[ -n "$IDENTITY" && "$IDENTITY" != "-" ]] && ! grep -qF "Authority=$IDENTITY" <<<"$info"; then
    bad "$name: not signed by \"$IDENTITY\""; continue
  fi
  ok "$name: hardened runtime${IDENTITY:+, $IDENTITY}"
done < <(find "$APP/Contents" -type f -perm -u+x -print0)

entitlements() { # <bundle>: its entitlement keys and values, one "key=value" per line, sorted
  codesign -d --entitlements - --xml "$1" 2>/dev/null \
    | plutil -convert json -o - - 2>/dev/null \
    | /usr/bin/python3 -c 'import json,sys
d = json.load(sys.stdin) if sys.stdin.readable() else {}
for k in sorted(d): print(f"{k}={json.dumps(d[k])}")' 2>/dev/null || true
}

expect() { # <bundle> <label> <exact expected entitlements, newline separated>
  local actual
  actual=$(entitlements "$1")
  if [[ "$actual" == "$3" ]]; then
    ok "$2 entitlements: ${3//$'\n'/, }"
  else
    bad "$2 entitlements are \"${actual//$'\n'/, }\", expected \"${3//$'\n'/, }\""
  fi
}

# The app: not sandboxed (Accessibility and the event tap need that), library validation kept, and no
# get-task-allow, which a debugger needs and a release must not have.
expect "$APP" "PappuClip" 'com.apple.security.cs.disable-library-validation=false'
expect "$APP/Contents/XPCServices/PappuClipRunner.xpc" "PappuClipRunner" 'com.apple.security.automation.apple-events=true'
expect "$APP/Contents/XPCServices/PappuClipJSHost.xpc" "PappuClipJSHost" 'com.apple.security.app-sandbox=true'

if [[ $failures -gt 0 ]]; then
  echo "$failures signature check(s) failed for $APP" >&2
  exit 1
fi
echo "Signature checks passed for $APP"
