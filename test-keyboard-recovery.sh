#!/bin/bash
# Requires the existing LuluDisplay Accessibility grant and its fixed local certificate.
# This helper only tests event-tap lifecycle; it never consumes keys or writes brightness.
set -euo pipefail
cd "$(dirname "$0")"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/LuluDisplayKeyRecovery.XXXXXX")
app="$test_dir/LuluDisplay Keyboard Recovery.app"
cleanup() {
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$app" >/dev/null 2>&1 || true
  rm -rf "$test_dir"
}
trap cleanup EXIT
mkdir -p "$app/Contents/MacOS"
cp App/Info.plist "$app/Contents/"
sdk=$(xcrun --sdk macosx --show-sdk-path)
arch=$(uname -m)
xcrun swiftc -swift-version 6 -target "$arch-apple-macosx14.0" -sdk "$sdk" \
  -D APPKIT_SMOKE_TEST App/Hotkeys.swift Tests/KeyboardRecoveryTests.swift \
  -o "$app/Contents/MacOS/DesktopControl"
signing="$HOME/Library/Application Support/LuluDisplay/Signing"
/usr/bin/security unlock-keychain -p "$(cat "$signing/password")" "$signing/signing.keychain-db"
codesign --force --keychain "$signing/signing.keychain-db" --sign "$(cat "$signing/identity.sha1")" "$app"
requirement=$(codesign -d -r- /Applications/LuluDisplay.app 2>&1 | sed -n 's/^designated => //p')
codesign --verify --strict -R "=$requirement" "$app"
open -n -g -W --stdout "$test_dir/stdout.log" --stderr "$test_dir/stderr.log" "$app"
cat "$test_dir/stdout.log" "$test_dir/stderr.log"
rg -Fx 'PASS real keyboard tap recovery completed' "$test_dir/stdout.log" >/dev/null
