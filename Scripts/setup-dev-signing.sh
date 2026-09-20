#!/bin/bash
# Creates the self-signed certificate that development builds are signed with.
#
# macOS ties the Accessibility grant to the code signature. An ad-hoc signature changes with every
# build, so every rebuild would lose the grant; a certificate that stays the same keeps it (PRD §12).
# The certificate is local to this Mac, trusted by nobody, and useless for distribution.
#
# Usage: Scripts/setup-dev-signing.sh [--keychain <path>] [--name <common name>]
# Run once. Safe to run again: it does nothing when the identity already exists.

set -euo pipefail

NAME="PappuClip Development"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keychain) KEYCHAIN="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
  echo "Signing identity \"$NAME\" already exists in $KEYCHAIN."
  exit 0
fi

# The system LibreSSL writes a PKCS#12 that `security import` reads; Homebrew's OpenSSL 3 does not
# without -legacy.
OPENSSL=/usr/bin/openssl
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$WORK/cert.conf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

# The password only protects the file between these two commands.
PASSWORD=$("$OPENSSL" rand -hex 16)
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -out "$WORK/identity.p12" -passout "pass:$PASSWORD"

security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null

if ! security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
  echo "The identity was imported but codesign cannot see it. Check Keychain Access." >&2
  exit 1
fi

# find-identity reports the certificate as not trusted. That is expected and codesign uses it anyway,
# but only from a keychain on the search list; `codesign --keychain` does not widen the search.
if ! security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "warning: $KEYCHAIN is not on the keychain search list, so builds will not find the identity." >&2
  echo "warning: add it with: security list-keychains -d user -s <existing keychains> \"$KEYCHAIN\"" >&2
fi

cat <<EOF
Created signing identity "$NAME" in $KEYCHAIN.

The first build will ask for permission to use the key: choose "Always Allow".
Scripts/build.sh picks the identity up by name.
EOF
