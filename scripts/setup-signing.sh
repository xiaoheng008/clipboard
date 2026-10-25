#!/bin/zsh
# One-time: creates a self-signed code-signing identity "ClipVault Local Signing" in the login keychain.
# build-app.sh signs with it when present, so the designated requirement (identifier + certificate leaf hash)
# stays the same across rebuilds and macOS keeps the app's privacy grants (pasteboard, Accessibility).
# Trusted only on this Mac; nothing here goes into the app bundle or the repository.
set -euo pipefail
NAME="ClipVault Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "already present: $NAME"
  security find-identity -p codesigning "$KEYCHAIN" | grep "$NAME" || true
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
# The .p12 only carries the pair into the keychain; its password is random and dies with $TMP.
P12PASS=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -passout "pass:$P12PASS" -out "$TMP/id.p12"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$P12PASS" -T /usr/bin/codesign >/dev/null
echo "created: $NAME"
security find-identity -p codesigning "$KEYCHAIN" | grep "$NAME"
echo "The first build may ask to let codesign use this key: choose 「始终允许」."
