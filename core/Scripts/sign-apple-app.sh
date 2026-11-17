#!/usr/bin/env bash
set -euo pipefail

app="${1:?Usage: sign-apple-app.sh /path/OcPlayer.app [signing-identity]}"
identity="${2:--}"
[[ -d "$app" && "$app" == *.app ]] || { echo 'A built Apple application bundle is required' >&2; exit 2; }
app="$(cd "$app" && pwd -P)"
find "$app" -depth \( \( -type d \( -name '*.framework' -o -name '*.xctest' \) \) \
  -o \( -type f -name '*.dylib' \) \) -print0 |
while IFS= read -r -d '' component; do
  codesign --force --sign "$identity" --timestamp=none \
    --preserve-metadata=entitlements,requirements,flags "$component"
done
codesign --force --sign "$identity" --timestamp=none \
  --preserve-metadata=entitlements,requirements,flags "$app"
codesign --verify --deep --strict "$app"
