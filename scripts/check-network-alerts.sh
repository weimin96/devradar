#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
checks_directory=$(mktemp -d "${TMPDIR:-/tmp}/devradar-network-alert-checks.XXXXXX")
trap 'rm -rf "$checks_directory"' EXIT HUP INT TERM

swiftc -parse-as-library \
    "$project_root/DevRadar/NettopUploadRates.swift" \
    "$project_root/tests/NettopUploadRatesTests.swift" \
    -o "$checks_directory/upload-rates"
"$checks_directory/upload-rates"
