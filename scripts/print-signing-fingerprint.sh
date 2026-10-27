#!/usr/bin/env bash
# Print the signing key's SHA-256 certificate fingerprint (what Play Console's App integrity page and Android
# developer verification show) and, given a path, save the public certificate there as PEM.
# Needs only keytool (any JDK) or, for a PKCS12 keystore, openssl. Never creates a key.
# Usage: scripts/print-signing-fingerprint.sh [certificate.pem]
# Keystore, alias and password come from the same settings as the release scripts (see _signing-common.sh).
set +x
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/_signing-common.sh"
case "${1:-}" in -h|--help) sed -n '2,6p' "$0"; exit 0 ;; esac
out="${1:-}"

[ -f "$keystore" ] || die "No signing keystore at $keystore. Set ${env_prefix}_KEYSTORE."
keytool=''
# -help also rules out macOS's /usr/bin/keytool stub, which fails when no JDK is installed.
for candidate in "${JAVA_HOME:-/nonexistent}/bin/keytool" \
    "$( [ -x /usr/libexec/java_home ] && /usr/libexec/java_home 2>/dev/null)/bin/keytool" \
    "$(command -v keytool 2>/dev/null || true)"; do
  if [ -x "$candidate" ] && "$candidate" -help >/dev/null 2>&1; then keytool="$candidate"; break; fi
done
[ -n "$keytool" ] || command -v openssl >/dev/null 2>&1 || die 'Need keytool (any JDK) or openssl.'

trap forget_passwords EXIT
if [ -z "${!keystore_password_var:-}" ]; then
  [ -t 0 ] || die "Set $keystore_password_var when running without a terminal."
  read -r -s -p 'Keystore password: ' "$keystore_password_var"; printf '\n'
fi
export "$keystore_password_var"

pem="$(
  if [ -n "$keytool" ]; then
    "$keytool" -exportcert -rfc -keystore "$keystore" -alias "$alias_name" -storepass:env "$keystore_password_var"
  else
    openssl pkcs12 -in "$keystore" -passin "env:$keystore_password_var" -nokeys -clcerts 2>/dev/null | openssl x509
  fi
)" || die "Cannot read alias $alias_name from $keystore (wrong password, or a JKS keystore without keytool?)."

fingerprint="$(printf '%s\n' "$pem" | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//')" || true
if [ -z "$fingerprint" ]; then
  # No openssl: let keytool compute it.
  fingerprint="$(printf '%s\n' "$pem" | "$keytool" -printcert | sed -n 's/^[[:space:]]*SHA256: //p')"
fi
[ -n "$fingerprint" ] || die 'Cannot compute the SHA-256 fingerprint.'
printf '%s signing key (%s, alias %s)\nSHA-256: %s\n' "$app_name" "$keystore" "$alias_name" "$fingerprint"
if [ -n "$out" ]; then
  printf '%s\n' "$pem" > "$out"
  printf 'Certificate: %s\n' "$out"
fi
