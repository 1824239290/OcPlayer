#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLE="$ROOT/Secrets.xcconfig.example"
SECRETS="$ROOT/Secrets.xcconfig"

if [[ -e "$SECRETS" || -L "$SECRETS" ]]; then
    echo "Local configuration already exists: $SECRETS"
    exit 0
fi

umask 077
cp "$EXAMPLE" "$SECRETS"
chmod 600 "$SECRETS"

echo "Created local configuration: $SECRETS"
echo "Add your DANDANPLAY_APP_ID and DANDANPLAY_APP_SECRET values before enabling danmaku."
