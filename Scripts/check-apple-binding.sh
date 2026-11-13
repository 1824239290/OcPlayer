#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
apple_root="${1:?Usage: check-apple-binding.sh /path/to/OcPlayer}"
for path in Package.swift Sources Tests; do
  diff -ru "$repo_root/bindings/apple/OcPlayerCore/$path" "$apple_root/Packages/OcPlayerCore/$path"
done
