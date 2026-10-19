#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
export IDENTITY_RELEASE=1
source "$root/scripts/identity.sh"
if missing="$(identity_placeholders)"; then
  print "Set these in identity.env first:"
  print -r -- "$missing" | sed 's/^/  - /'
  exit 1
fi
name="$SIGN_IDENTITY"
if security find-certificate -c "$name" >/dev/null 2>&1; then
  print -r -- "Signing certificate '$name' already exists."
  exit 0
fi
ssl=/usr/bin/openssl
legacy=()
"$ssl" version | grep -q '^OpenSSL 3' && legacy=(-legacy)
tmp="$(mktemp -d)"
chmod 700 "$tmp"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/cert.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $name
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CNF
"$ssl" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.cnf" \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
pass="$("$ssl" rand -hex 24)"
"$ssl" pkcs12 -export "${legacy[@]}" -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$name" \
  -out "$tmp/identity.p12" -passout "pass:$pass"
security import "$tmp/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$pass" -T /usr/bin/codesign >/dev/null
print -r -- "Created signing certificate '$name' in your login keychain (valid 10 years)."
print "Keep a backup: Keychain Access → My Certificates → export it with a password."
print "Switching to a new certificate makes users re-grant permissions once, so do it before the first public release."
