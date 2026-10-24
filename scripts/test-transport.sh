#!/usr/bin/env bash
# The deck's list logic and Jellyfin decoding, run with swiftc on the Mac runner before the app builds.
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library -o "$test_dir/transport" Spin/Sources/Transport.swift Spin/Sources/Jellyfin.swift scripts/transport.test.swift
"$test_dir/transport"
