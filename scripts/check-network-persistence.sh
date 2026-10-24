#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
checks_directory=$(mktemp -d "${TMPDIR:-/tmp}/devradar-persistence-checks.XXXXXX")
trap 'rm -rf "$checks_directory"' EXIT HUP INT TERM
swiftc -parse-as-library \
    "$project_root/DevRadar/ProjectModels.swift" \
    "$project_root/DevRadar/NetworkTrafficModels.swift" \
    "$project_root/DevRadar/NetworkTrafficHistoryStore.swift" \
    "$project_root/DevRadar/IgnoreRules.swift" \
    "$project_root/DevRadar/HTTPSConnectionReader.swift" \
    "$project_root/DevRadar/HTTPSConnectionTracker.swift" \
    "$project_root/DevRadar/AutomaticHTTPSEvidenceModels.swift" \
    "$project_root/DevRadar/AutomaticHTTPSEvidence.swift" \
    "$project_root/tests/NetworkPersistenceTests.swift" \
    -o "$checks_directory/persistence-checks"
"$checks_directory/persistence-checks"
