#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
apple_root="${1:?Usage: check-apple-binding.sh /path/to/OcPlayer}"
python3 - "$repo_root" "$apple_root" <<'PY'
import re
import sys
from pathlib import Path

core_root, apple_root = (Path(value).resolve() for value in sys.argv[1:])
binding_root = core_root / "bindings/apple/OcPlayerCore"
assert (binding_root / "Package.swift").is_file(), "Shared Swift binding is missing"
assert not (apple_root / "Packages/OcPlayerCore/Package.swift").exists(), "Duplicate Swift binding remains"
packages = ("BangumiKit", "DanmakuKit", "JellyfinKit", "MetadataKit", "MoviePilotKit", "PlaybackKit")
for package in packages:
    manifest = apple_root / "Packages" / package / "Package.swift"
    dependencies = re.findall(r'\.package\(path:\s*"([^"]+)"\)', manifest.read_text(encoding="utf-8"))
    matches = [(manifest.parent / dependency).resolve() for dependency in dependencies if "OcPlayerCore" in dependency]
    assert matches == [binding_root], f"{package} must reference the shared Swift binding exactly once"
project = (apple_root / "OcPlayer.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
references = re.findall(r'relativePath\s*=\s*"?([^";]+)"?;', project)
matches = [(apple_root / reference.strip()).resolve() for reference in references if "OcPlayerCore" in reference]
assert matches == [binding_root], "Xcode must reference the shared Swift binding exactly once"
print("Apple consumers resolve the single shared Swift binding")
PY
