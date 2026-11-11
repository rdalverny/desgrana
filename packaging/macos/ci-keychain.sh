#!/usr/bin/env bash
# ci-keychain.sh - Temporary keychain holding the Developer ID identity, for CI.
#
# Usage:
#   ci-keychain.sh create <keychain-path>
#   ci-keychain.sh delete <keychain-path>
#
# create reads from the environment:
#   SIGNING_P12_BASE64    Developer ID Application .p12, base64-encoded
#   SIGNING_P12_PASSWORD  its export password
#
# Then: make notarize KEYCHAIN=<keychain-path>

set -euo pipefail

readonly CMD_CREATE=create
readonly CMD_DELETE=delete
readonly LOCK_TIMEOUT_S=3600

usage() {
    echo "Usage: $0 {$CMD_CREATE|$CMD_DELETE} <keychain-path>" >&2
    exit 2
}

create() {
    local keychain="$1"
    : "${SIGNING_P12_BASE64:?not set}"
    : "${SIGNING_P12_PASSWORD:?not set}"

    local password
    password=$(openssl rand -base64 24)

    # Global: the EXIT trap runs after this function's locals are gone.
    P12=$(mktemp)
    trap 'rm -f "$P12"' EXIT

    printf '%s' "$SIGNING_P12_BASE64" | base64 --decode > "$P12"

    security create-keychain -p "$password" "$keychain"
    security set-keychain-settings -lut "$LOCK_TIMEOUT_S" "$keychain"
    security unlock-keychain -p "$password" "$keychain"

    security import "$P12" -k "$keychain" -f pkcs12 \
        -P "$SIGNING_P12_PASSWORD" -T /usr/bin/codesign

    security set-key-partition-list -S apple-tool:,apple: -s \
        -k "$password" "$keychain" > /dev/null

    # Prepend to the user search list, keeping the existing entries.
    local existing
    existing=$(security list-keychains -d user | xargs)
    security list-keychains -d user -s "$keychain" $existing

    security find-identity -v -p codesigning "$keychain"
}

delete() {
    local keychain="$1"
    security delete-keychain "$keychain"
}

[ $# -eq 2 ] || usage

case "$1" in
    "$CMD_CREATE") create "$2" ;;
    "$CMD_DELETE") delete "$2" ;;
    *) usage ;;
esac
