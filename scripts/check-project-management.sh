#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
checks_directory=$(mktemp -d "${TMPDIR:-/tmp}/devradar-project-checks.XXXXXX")
trap 'rm -rf "$checks_directory"' EXIT HUP INT TERM

swiftc -parse-as-library \
    "$project_root/DevRadar/ProjectModels.swift" \
    "$project_root/DevRadar/ProjectCommand.swift" \
    "$project_root/DevRadar/ProjectGit.swift" \
    "$project_root/DevRadar/ProjectManager.swift" \
    "$project_root/tests/ProjectManagementTests.swift" \
    -o "$checks_directory/project-checks"
"$checks_directory/project-checks"
