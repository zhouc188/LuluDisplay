#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/LuluDisplaySmoke.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
app="$test_dir/LuluDisplay AppKit Smoke.app"
mkdir -p "$app/Contents/MacOS"
cp App/Info.plist "$app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string local.desktopcontrol.appkit-smoke "$app/Contents/Info.plist"
sdk=$(xcrun --sdk macosx --show-sdk-path)
arch=$(uname -m)
xcrun swiftc -swift-version 6 -target "$arch-apple-macosx14.0" -sdk "$sdk" \
  -D APPKIT_SMOKE_TEST App/*.swift Tests/AppKitSmokeTests.swift -o "$app/Contents/MacOS/DesktopControl"
codesign --force --sign - "$app"
open -n -g -W --stdout "$test_dir/stdout.log" --stderr "$test_dir/stderr.log" "$app"
cat "$test_dir/stdout.log" "$test_dir/stderr.log"
grep -Fqx 'PASS AppKit smoke completed' "$test_dir/stdout.log"
