#!/bin/sh
set -eu

# The Go runtime is needed only when building, never when running DevRadar.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if ! command -v go >/dev/null 2>&1; then
    echo "DevRadar capture proxy requires Go to build (brew install go)" >&2
    exit 1
fi

destination="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/devradar-proxy"
mkdir -p "$(dirname "$destination")"
cd "${SRCROOT}/capture-proxy"
CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "$destination" .
chmod 755 "$destination"
