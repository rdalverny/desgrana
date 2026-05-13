#!/usr/bin/env bash
# Collect Swift dylibs needed by a binary, recursively.
# Only bundles libs found in SWIFT_DIR; system libs (libcurl, libQt6, …) are left
# as package dependencies and not copied.
#
# Usage: collect-swift-libs.sh <binary> <swift-dir> <out-dir>
set -euo pipefail

BINARY="${1:?usage: $0 <binary> <swift-dir> <out-dir>}"
SWIFT_DIR="${2:?}"
OUT_DIR="${3:?}"

mkdir -p "$OUT_DIR"

# Returns NEEDED entries from an ELF file.
needed() { readelf -d "$1" 2>/dev/null | grep NEEDED | sed 's/.*\[//;s/\]//'; }

declare -A seen=()
queue=()

# Seed: direct deps of the binary that live in SWIFT_DIR.
for lib in $(needed "$BINARY"); do
    if [[ -f "$SWIFT_DIR/$lib" && -z "${seen[$lib]+x}" ]]; then
        seen[$lib]=1
        queue+=("$lib")
    fi
done

while [[ ${#queue[@]} -gt 0 ]]; do
    lib="${queue[0]}"
    queue=("${queue[@]:1}")

    src="$SWIFT_DIR/$lib"
    [[ -f "$src" ]] || continue

    cp -n "$src" "$OUT_DIR/"

    for dep in $(needed "$src"); do
        if [[ -f "$SWIFT_DIR/$dep" && -z "${seen[$dep]+x}" ]]; then
            seen[$dep]=1
            queue+=("$dep")
        fi
    done
done

echo "Collected ${#seen[@]} Swift lib(s) into $OUT_DIR:"
ls "$OUT_DIR/"
[[ ${#seen[@]} -gt 0 ]]
