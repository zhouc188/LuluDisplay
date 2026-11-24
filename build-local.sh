#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
out="${1:-/Applications}"
destination="$out/LuluDisplay.app"
mkdir -p "$out"
if [[ -e "$destination" ]]; then
  existing_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$destination/Contents/Info.plist")
  [[ "$existing_id" == local.desktopcontrol.app ]] || {
    echo "Another application occupies $destination" >&2
    exit 1
  }
fi

stage=$(mktemp -d "$out/.LuluDisplay-build.XXXXXX")
app="$stage/LuluDisplay.app"
backup="$stage/previous.app"
cleanup() {
  if [[ -e "$backup" && ! -e "$destination" ]]; then
    mv "$backup" "$destination" || return
  fi
  rm -rf -- "$stage"
}
trap cleanup EXIT
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp App/Info.plist "$app/Contents/"
cp App/LuluDisplay.icns "$app/Contents/Resources/"
sdk=$(xcrun --sdk macosx --show-sdk-path)
arch=$(uname -m)
xcrun swiftc -swift-version 6 -target "$arch-apple-macosx14.0" -sdk "$sdk" \
  -module-name DesktopControl App/*.swift -o "$app/Contents/MacOS/DesktopControl"
signing="$HOME/Library/Application Support/LuluDisplay/Signing"
if [[ -n "${LULUDISPLAY_SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$LULUDISPLAY_SIGN_IDENTITY" "$app"
elif [[ -f "$signing/identity.sha1" ]]; then
  /usr/bin/security unlock-keychain -p "$(cat "$signing/password")" "$signing/signing.keychain-db"
  codesign --force --keychain "$signing/signing.keychain-db" \
    --sign "$(cat "$signing/identity.sha1")" "$app"
else
  echo "Run setup-local-signing.sh first, or supply LULUDISPLAY_SIGN_IDENTITY. Refusing an unstable ad-hoc application identity." >&2
  exit 1
fi
codesign --verify --strict "$app"
if [[ -e "$destination" ]]; then
  previous_requirement=$(codesign -d -r- "$destination" 2>&1 | sed -n 's/^designated => //p')
  if [[ "$previous_requirement" == *"certificate"* ]]; then
    codesign --verify --strict -R "=$previous_requirement" "$app"
  fi
fi
if [[ -e "$destination" ]]; then mv "$destination" "$backup"; fi
mv "$app" "$destination"
echo "$destination"
