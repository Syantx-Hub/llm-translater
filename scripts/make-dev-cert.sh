#!/bin/zsh
# Creates a self-signed "Subtitler Dev" code-signing certificate in your login keychain.
#
# Why: macOS ties permissions (System Audio Recording, and "Always Allow" for the API keys
# in the Keychain) to the app's signature. An ad-hoc signature changes on every build, so
# macOS asks again after each rebuild. Signed with this certificate, the app keeps the same
# identity and asks once. scripts/build-app.sh uses it automatically when it exists.
#
# Only for your own builds on this Mac; it isn't trusted anywhere else. To remove it,
# delete "Subtitler Dev" in Keychain Access › login › My Certificates.
set -euo pipefail

NAME="Subtitler Dev"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "\"$NAME\" already exists."
  exit 0
fi

DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
PASS=$(openssl rand -hex 16)  # only protects the temporary .p12 file below

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
  -keyout "$DIR/key.pem" -out "$DIR/cert.pem" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -name "$NAME" \
  -out "$DIR/dev.p12" -passout "pass:$PASS"
# -T: let codesign use the key without asking each time.
security import "$DIR/dev.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "Created \"$NAME\". Rebuild with scripts/build-app.sh; macOS will ask for permissions once more, then remember."
