#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package="${1:?Usage: verify-apple-release.sh /path/to/release-package [verification-output]}"
package="$(cd "$package" && pwd)"
output="${2:-$repo_root/artifacts/apple-release-verification}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
[[ -f "$package/release-manifest.json" ]] || { echo 'Apple release package is required' >&2; exit 1; }
env -u OCP_CORE_LIBRARY_PATH OCP_CORE_ENABLED=1 swift test --package-path "$package" \
  --scratch-path "$output/SwiftPackageBuild" --configuration release > "$output/static-package-tests.log" 2>&1

framework="$package/OcPlayerCore.xcframework"
sources=("$package"/Sources/OcPlayerCore/*.swift)
touch "$output/hidden-symbols.txt"
for entry in 'macos arm64 macosx arm64-apple-macosx13.0' \
             'macos x86_64 macosx x86_64-apple-macosx13.0' \
             'ios arm64 iphoneos arm64-apple-ios16.0' \
             'simulator arm64 iphonesimulator arm64-apple-ios16.0-simulator' \
             'simulator x86_64 iphonesimulator x86_64-apple-ios16.0-simulator'; do
  read -r platform architecture sdk triple <<< "$entry"
  case "$platform" in
    macos) slice=macos-arm64_x86_64 ;;
    ios) slice=ios-arm64 ;;
    simulator) slice=ios-arm64_x86_64-simulator ;;
  esac
  destination="$output/$platform-$architecture"
  mkdir -p "$destination"
  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  headers="$framework/$slice/Headers"
  library="$framework/$slice/libocp_ffi.a"
  xcrun swiftc -O -whole-module-optimization -target "$triple" -sdk "$sdk_path" \
    -I "$headers" -module-name OcPlayerCore -emit-module -emit-library \
    -emit-module-path "$destination/OcPlayerCore.swiftmodule" "${sources[@]}" "$library" \
    -framework Security -framework CoreFoundation -liconv -lresolv \
    -o "$destination/libOcPlayerCore.dylib" > "$destination/sdk-link.log" 2>&1
  if [[ "$platform" == macos ]]; then
    # Compile source and probe in one executable to exercise direct static ABI
    # references with all dynamic Core exports hidden by the release linker.
    sed '/^import OcPlayerCore$/d' "$repo_root/tests/apple_release_probe.swift" > "$destination/probe.swift"
    xcrun swiftc -O -whole-module-optimization -parse-as-library -target "$triple" -sdk "$sdk_path" \
      -I "$headers" "${sources[@]}" "$destination/probe.swift" "$library" \
      -framework Security -framework CoreFoundation -liconv -lresolv \
      -Xlinker -dead_strip -Xlinker -exported_symbols_list -Xlinker "$output/hidden-symbols.txt" \
      -o "$destination/release-probe" > "$destination/probe-link.log" 2>&1
    env -u OCP_CORE_LIBRARY_PATH OCP_CORE_ENABLED=1 arch "-$architecture" \
      "$destination/release-probe" > "$destination/probe-result.json" 2> "$destination/probe-runtime.log"
  fi
done
python3 - "$package" "$output" <<'PY'
import hashlib, json, pathlib, re, sys
package, output = map(pathlib.Path, sys.argv[1:])
manifest = json.loads((package/'release-manifest.json').read_text())
for relative, expected in manifest['files'].items():
    digest = hashlib.sha256((package/relative).read_bytes()).hexdigest()
    assert digest == expected, relative
log = (output/'static-package-tests.log').read_text()
assert re.search(r'Executed 35 tests, with 0 failures', log) and 'skipped' not in log.lower()
results = [json.loads((output/f'macos-{arch}/probe-result.json').read_text()) for arch in ('arm64','x86_64')]
assert all(item['staticOnly'] and item['abiVersion']==1 for item in results)
summary = {'staticSwiftTests':35,'skips':0,'platformArchitectureLinks':5,'macOSReleaseProbes':results,'deliveryHashesVerified':len(manifest['files'])}
(output/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary))
PY
