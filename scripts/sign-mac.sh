#!/bin/bash
set -euo pipefail
umask 077

bundle_id="com.artlee12.prilo"
signing_dir="${PRILO_SIGNING_DIR:-$HOME/Library/Application Support/Prilo/Signing}"
keychain="$signing_dir/prilo-signing.keychain-db"
password_file="$signing_dir/keychain-password"
certificate="$signing_dir/certificate.pem"

require_local_identity() {
    if [[ ! -f "$keychain" || ! -f "$password_file" || ! -f "$certificate" ]]; then
        printf '%s\n' "Prilo signing identity is missing or incomplete in: $signing_dir" >&2
        printf '%s\n' "Run scripts/sign-mac.sh init once for a new identity. Restore the existing files if this Mac was already set up." >&2
        exit 1
    fi
}

local_fingerprint() {
    /usr/bin/openssl x509 -in "$certificate" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :
}

initialize() {
    if [[ -e "$signing_dir" || -L "$signing_dir" ]]; then
        require_local_identity
        printf '%s\n' "Prilo local signing identity already exists."
        return
    fi
    local parent password
    parent="$(dirname "$signing_dir")"
    mkdir -p "$parent"
    stage="$(mktemp -d "$parent/.prilo-signing.XXXXXX")"
    trap 'rm -rf "$stage"' EXIT
    password="$(/usr/bin/openssl rand -hex 32)"
    printf '%s' "$password" > "$stage/keychain-password"
    cat > "$stage/cert.conf" <<'CONFIG'
[req]
prompt = no
distinguished_name = dn
x509_extensions = extensions
[dn]
CN = Prilo Local Signing
[extensions]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
CONFIG
    /usr/bin/openssl req -new -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
        -config "$stage/cert.conf" -keyout "$stage/private.pem" -out "$stage/certificate.pem" >/dev/null 2>&1
    /usr/bin/openssl pkcs12 -export -inkey "$stage/private.pem" -in "$stage/certificate.pem" \
        -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg SHA1 \
        -passout "file:$stage/keychain-password" -out "$stage/identity.p12"

    # security create-keychain can add its destination to the user's search list.
    # Preserve that list and use this keychain only by its explicit path.
    python3 - "$stage/prilo-signing.keychain-db" "$stage/keychain-password" <<'PYTHON'
import pathlib
import shlex
import subprocess
import sys

security = "/usr/bin/security"
command = [security, "list-keychains", "-d", "user"]
previous = shlex.split(subprocess.check_output(command, text=True))
try:
    password = pathlib.Path(sys.argv[2]).read_text()
    subprocess.run([security, "create-keychain", "-p", password, sys.argv[1]], check=True)
finally:
    current = shlex.split(subprocess.check_output(command, text=True))
    if current != previous:
        subprocess.run(command + ["-s", *previous], check=True)
PYTHON
    /usr/bin/security unlock-keychain -p "$password" "$stage/prilo-signing.keychain-db"
    /usr/bin/security import "$stage/identity.p12" -k "$stage/prilo-signing.keychain-db" \
        -P "$password" -T /usr/bin/codesign
    /usr/bin/security set-key-partition-list -S apple-tool:,apple: -s -k "$password" \
        "$stage/prilo-signing.keychain-db" >/dev/null
    /usr/bin/security lock-keychain "$stage/prilo-signing.keychain-db"
    rm -f "$stage/private.pem" "$stage/identity.p12" "$stage/cert.conf"
    # Refuse to overwrite the identity if another initializer won the race.
    python3 - "$stage" "$signing_dir" <<'PYTHON'
import os
import sys
os.rename(sys.argv[1], sys.argv[2])
PYTHON
    trap - EXIT
    printf '%s\n' "Created Prilo local signing identity at: $signing_dir"
}

case "${1:-}" in
    init)
        initialize
        ;;
    sign)
        require_local_identity
        app="${2:?Pass a Prilo.app path}"
        fingerprint="$(local_fingerprint)"
        /usr/bin/security unlock-keychain -p "$(cat "$password_file")" "$keychain"
        trap '/usr/bin/security lock-keychain "$keychain" >/dev/null 2>&1 || true' EXIT
        /usr/bin/codesign --force --sign "$fingerprint" --keychain "$keychain" --timestamp=none \
            -r "=designated => identifier \"$bundle_id\" and certificate leaf = H\"$fingerprint\"" "$app"
        "$0" verify "$app"
        ;;
    verify)
        require_local_identity
        app="${2:?Pass a Prilo.app path}"
        fingerprint="$(local_fingerprint)"
        /usr/bin/codesign --verify --strict \
            -R "=identifier \"$bundle_id\" and certificate leaf = H\"$fingerprint\"" "$app"
        ;;
    *)
        printf '%s\n' 'Usage: sign-mac.sh init | sign Prilo.app | verify Prilo.app' >&2
        exit 2
        ;;
esac
