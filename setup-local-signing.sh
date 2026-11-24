#!/bin/bash
# Persistent signing identity for this Mac. Never recreate it during normal builds.
set -euo pipefail
umask 077
state="$HOME/Library/Application Support/LuluDisplay/Signing"
mkdir -p "$state"
if [[ -f "$state/identity.sha1" ]]; then
  echo "LuluDisplay signing identity already configured."
  exit 0
fi
if [[ -e "$state/signing.keychain-db" ]]; then
  echo "An incomplete signing setup exists at $state; inspect it before retrying." >&2
  exit 1
fi
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
/usr/bin/openssl rand -base64 32 > "$state/password"
password=$(cat "$state/password")
cat > "$temporary/certificate.conf" <<'EOF'
[req]
distinguished_name=subject
x509_extensions=extensions
prompt=no
[subject]
CN=LuluDisplay Local Development
[extensions]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
subjectKeyIdentifier=hash
EOF
/usr/bin/openssl req -new -newkey rsa:3072 -nodes -x509 -sha256 -days 3650 \
  -config "$temporary/certificate.conf" -keyout "$temporary/key.pem" -out "$temporary/certificate.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$temporary/key.pem" -in "$temporary/certificate.pem" \
  -out "$temporary/identity.p12" -passout "file:$state/password"
/usr/bin/security create-keychain -p "$password" "$state/signing.keychain-db"
/usr/bin/security unlock-keychain -p "$password" "$state/signing.keychain-db"
/usr/bin/security import "$temporary/identity.p12" -k "$state/signing.keychain-db" \
  -P "$password" -x -T /usr/bin/codesign >/dev/null
/usr/bin/openssl x509 -in "$temporary/certificate.pem" -noout -fingerprint -sha1 \
  | sed 's/.*=//; s/://g' > "$state/identity.sha1"
echo "Created a persistent LuluDisplay signing identity. No system trust settings were changed."
