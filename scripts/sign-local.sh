#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
identity="Local Development Signing"
app=${1:-"$project_root/.build/release/Build/Products/Release/DevRadar.app"}

if [ ! -d "$app" ]; then
    echo "App bundle not found: $app" >&2
    exit 1
fi

if ! security find-identity -v -p codesigning | grep -Fq "\"$identity\""; then
    echo "Code signing identity not found: $identity" >&2
    exit 1
fi

proxy="$app/Contents/Resources/devradar-proxy"
if [ -f "$proxy" ]; then
    codesign --force --options runtime --sign "$identity" "$proxy"
fi

codesign --force --deep --options runtime --sign "$identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
echo "Signed with $identity: $app"
