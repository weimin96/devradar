#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
checks_directory=$(mktemp -d "${TMPDIR:-/tmp}/devradar-port-import.XXXXXX")
trap 'rm -rf "$checks_directory"' EXIT HUP INT TERM
swiftc -parse-as-library \
    "$project_root/DevRadar/PortScanner.swift" \
    "$project_root/DevRadar/ProjectModels.swift" \
    "$project_root/DevRadar/ProjectCommand.swift" \
    "$project_root/DevRadar/ProjectPortImport.swift" \
    "$project_root/tests/ProjectPortImportTests.swift" \
    -o "$checks_directory/port-import-checks"
"$checks_directory/port-import-checks"
