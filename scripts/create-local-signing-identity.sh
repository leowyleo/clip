#!/bin/sh
set -eu

identity_name="Clip Local Development"
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
configuration_file="$script_dir/clip-local-codesign.cnf"
login_keychain=$(security default-keychain -d user \
    | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')

if security find-identity -v -p codesigning "$login_keychain" \
    | grep -Fq "\"$identity_name\""; then
    echo "$identity_name"
    exit 0
fi

temporary_directory=$(mktemp -d)
cleanup() {
    rm -rf "$temporary_directory"
}
trap cleanup EXIT HUP INT TERM

private_key="$temporary_directory/private-key.pem"
certificate="$temporary_directory/certificate.pem"
identity_archive="$temporary_directory/identity.p12"
archive_password=$(uuidgen)

openssl req \
    -new \
    -newkey rsa:2048 \
    -nodes \
    -x509 \
    -sha256 \
    -days 3650 \
    -keyout "$private_key" \
    -out "$certificate" \
    -config "$configuration_file" \
    -extensions codesign >/dev/null 2>&1

openssl pkcs12 \
    -export \
    -legacy \
    -inkey "$private_key" \
    -in "$certificate" \
    -name "$identity_name" \
    -passout "pass:$archive_password" \
    -out "$identity_archive"

security import "$identity_archive" \
    -k "$login_keychain" \
    -P "$archive_password" \
    -T /usr/bin/codesign

security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "$login_keychain" \
    "$certificate"

security find-identity -v -p codesigning "$login_keychain" \
    | grep -F "\"$identity_name\""
