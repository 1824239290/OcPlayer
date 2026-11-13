#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
apple_root="${1:?Usage: verify-macos.sh /path/to/OcPlayer [output-directory]}"
output_dir="${2:-$repo_root/artifacts/macos-verification}"
[[ -f "$apple_root/OcPlayer.xcodeproj/project.pbxproj" ]] || { echo 'OcPlayer Apple source checkout is required' >&2; exit 1; }
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/tmp/ocplayer-target}"
cd "$repo_root"
cargo fmt --all -- --check > "$output_dir/rust-format.log" 2>&1
cargo test --workspace --locked > "$output_dir/rust-tests.log" 2>&1
Scripts/build-apple-dylib.sh "$output_dir" > "$output_dir/rust-build.log" 2>&1
export OCP_CORE_LIBRARY_PATH="$output_dir/libocp_ffi.dylib"
export OCP_CORE_ENABLED=1
Scripts/check-apple-binding.sh "$apple_root" > "$output_dir/apple-binding-equivalence.log" 2>&1
swift test --package-path bindings/apple/OcPlayerCore --scratch-path "$output_dir/AppleBindingBuild" > "$output_dir/apple-binding-tests.log" 2>&1
python3 tests/bangumi_contract.py > "$output_dir/bangumi-contract-tests.log" 2>&1
python3 tests/network_contract.py > "$output_dir/network-contract-tests.log" 2>&1
python3 tests/moviepilot_contract.py > "$output_dir/moviepilot-contract-tests.log" 2>&1
python3 tests/media_login_contract.py > "$output_dir/media-login-contract-tests.log" 2>&1
python3 tests/danmaku_contract.py > "$output_dir/danmaku-contract-tests.log" 2>&1
python3 tests/danmaku_policy_contract.py > "$output_dir/danmaku-policy-contract-tests.log" 2>&1
python3 tests/danmaku_cache_contract.py > "$output_dir/danmaku-cache-contract-tests.log" 2>&1
for package in OcPlayerCore JellyfinKit MetadataKit MoviePilotKit BangumiKit PlaybackKit DanmakuKit; do
  swift test --package-path "$apple_root/Packages/$package" --skip-update > "$output_dir/$package-tests.log" 2>&1
done
xcodebuild -project "$apple_root/OcPlayer.xcodeproj" -scheme OcPlayer-macOS \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$output_dir/DerivedData" -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO build > "$output_dir/macos-build.log" 2>&1
TEST_RUNNER_OCP_CORE_ENABLED=1 TEST_RUNNER_OCP_CORE_LIBRARY_PATH="$OCP_CORE_LIBRARY_PATH" \
xcodebuild -project "$apple_root/OcPlayer.xcodeproj" -scheme OcPlayer-macOS \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$output_dir/DerivedData" -disableAutomaticPackageResolution \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test > "$output_dir/macos-app-tests.log" 2>&1
Scripts/embed-macos-core.sh "$output_dir/DerivedData/Build/Products/Debug/OcPlayer.app" \
  "$OCP_CORE_LIBRARY_PATH" > "$output_dir/macos-embed.log" 2>&1
echo "macOS build and package checks passed; complete raw logs: $output_dir"
