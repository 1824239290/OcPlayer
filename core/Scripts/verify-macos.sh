#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
apple_root="${1:?Usage: verify-macos.sh /path/to/OcPlayer [output-directory]}"
output_dir="${2:-$repo_root/artifacts/macos-verification}"
[[ -f "$apple_root/OcPlayer.xcodeproj/project.pbxproj" ]] || { echo 'OcPlayer Apple source checkout is required' >&2; exit 1; }
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$repo_root/target}"
cd "$repo_root"
cargo fmt --all -- --check > "$output_dir/rust-format.log" 2>&1
cargo test --workspace --locked > "$output_dir/rust-tests.log" 2>&1
Scripts/build-apple-dylib.sh "$output_dir" > "$output_dir/rust-build.log" 2>&1
export OCP_CORE_LIBRARY_PATH="$output_dir/libocp_ffi.dylib"
export OCP_CORE_ENABLED=1
cc -dynamiclib "$repo_root/tests/fixtures/apple_boundary_echo.c" -o "$output_dir/apple-boundary-echo.dylib" > "$output_dir/apple-boundary-fixture-build.log" 2>&1
cc -dynamiclib -DFIXTURE_MISSING_EXPORT "$repo_root/tests/fixtures/apple_boundary_echo.c" -o "$output_dir/apple-boundary-echo.dylib.missing.dylib" >> "$output_dir/apple-boundary-fixture-build.log" 2>&1
cc -dynamiclib -DFIXTURE_ABI_VERSION=2 "$repo_root/tests/fixtures/apple_boundary_echo.c" -o "$output_dir/apple-boundary-echo.dylib.version.dylib" >> "$output_dir/apple-boundary-fixture-build.log" 2>&1
cp "$repo_root/tests/fixtures/native_http_probe.swift" "$output_dir/native-http-probe.swift"
swiftc "$output_dir/native-http-probe.swift" -o "$output_dir/native-http-probe" > "$output_dir/native-http-probe-build.log" 2>&1
export OCP_NATIVE_HTTP_PROBE_PATH="$output_dir/native-http-probe"
export OCP_CORE_ECHO_LIBRARY_PATH="$output_dir/apple-boundary-echo.dylib"
python3 tests/transport_fidelity_contract.py > "$output_dir/transport-fidelity-contract-tests.log" 2>&1
Scripts/check-apple-binding.sh "$apple_root" > "$output_dir/apple-binding-layout.log" 2>&1
cmp tests/media_projection_server.py "$apple_root/Packages/JellyfinKit/Tests/JellyfinKitTests/Fixtures/media_projection_server.py" > "$output_dir/media-projection-fixture-equivalence.log" 2>&1
cmp tests/media_nullable_server.py "$apple_root/Packages/JellyfinKit/Tests/JellyfinKitTests/Fixtures/media_nullable_server.py" > "$output_dir/media-nullable-fixture-equivalence.log" 2>&1
cmp tests/playback_preparation_server.py "$apple_root/Packages/JellyfinKit/Tests/JellyfinKitTests/Fixtures/playback_preparation_server.py" > "$output_dir/playback-preparation-fixture-equivalence.log" 2>&1
cmp tests/intro_provider_server.py "$apple_root/Packages/DanmakuKit/Tests/DanmakuKitTests/Fixtures/intro_provider_server.py" > "$output_dir/intro-provider-fixture-equivalence.log" 2>&1
cmp tests/standalone_danmaku_server.py bindings/apple/OcPlayerCore/Tests/OcPlayerCoreTests/Fixtures/standalone_danmaku_server.py > "$output_dir/standalone-fixture-equivalence.log" 2>&1
cmp tests/tmdb_wire_server.py bindings/apple/OcPlayerCore/Tests/OcPlayerCoreTests/Fixtures/tmdb_wire_server.py > "$output_dir/tmdb-wire-fixture-equivalence.log" 2>&1
cmp tests/tmdb_wire_server.py "$apple_root/Packages/MetadataKit/Tests/MetadataKitTests/Fixtures/tmdb_wire_server.py" >> "$output_dir/tmdb-wire-fixture-equivalence.log" 2>&1
cmp tests/tmdb_enrichment_server.py "$apple_root/Packages/MetadataKit/Tests/MetadataKitTests/Fixtures/tmdb_enrichment_server.py" > "$output_dir/tmdb-enrichment-fixture-equivalence.log" 2>&1
swift test --package-path bindings/apple/OcPlayerCore --scratch-path "$output_dir/AppleBindingBuild" > "$output_dir/apple-binding-tests.log" 2>&1
python3 tests/bangumi_progress_contract.py > "$output_dir/bangumi-progress-contract-tests.log" 2>&1
python3 tests/bangumi_auth_flow_contract.py > "$output_dir/bangumi-auth-flow-contract-tests.log" 2>&1
python3 tests/playback_tracks_contract.py > "$output_dir/playback-tracks-contract-tests.log" 2>&1
python3 tests/playback_preparation_contract.py > "$output_dir/playback-preparation-contract-tests.log" 2>&1
python3 tests/bangumi_sync_contract.py > "$output_dir/bangumi-sync-contract-tests.log" 2>&1
python3 tests/bangumi_account_contract.py > "$output_dir/bangumi-account-contract-tests.log" 2>&1
python3 tests/bangumi_contract.py > "$output_dir/bangumi-contract-tests.log" 2>&1
python3 tests/network_contract.py > "$output_dir/network-contract-tests.log" 2>&1
python3 tests/moviepilot_contract.py > "$output_dir/moviepilot-contract-tests.log" 2>&1
python3 tests/moviepilot_account_contract.py > "$output_dir/moviepilot-account-contract-tests.log" 2>&1
python3 tests/moviepilot_flow_contract.py > "$output_dir/moviepilot-flow-contract-tests.log" 2>&1
python3 tests/settings_backup_contract.py > "$output_dir/settings-backup-contract-tests.log" 2>&1
python3 tests/diagnostic_export_contract.py > "$output_dir/diagnostic-export-contract-tests.log" 2>&1
python3 tests/media_projection_contract.py > "$output_dir/media-projection-contract-tests.log" 2>&1
python3 tests/media_nullable_contract.py > "$output_dir/media-nullable-contract-tests.log" 2>&1
python3 tests/media_login_contract.py > "$output_dir/media-login-contract-tests.log" 2>&1
python3 tests/danmaku_contract.py > "$output_dir/danmaku-contract-tests.log" 2>&1
python3 tests/danmaku_policy_contract.py > "$output_dir/danmaku-policy-contract-tests.log" 2>&1
python3 tests/danmaku_cache_contract.py > "$output_dir/danmaku-cache-contract-tests.log" 2>&1
python3 tests/intro_contract.py > "$output_dir/intro-contract-tests.log" 2>&1
python3 tests/intro_provider_contract.py > "$output_dir/intro-provider-contract-tests.log" 2>&1
python3 tests/intro_identity_contract.py > "$output_dir/intro-identity-contract-tests.log" 2>&1
python3 tests/danmaku_flow_contract.py > "$output_dir/danmaku-flow-contract-tests.log" 2>&1
python3 tests/standalone_danmaku_contract.py > "$output_dir/standalone-contract-tests.log" 2>&1
python3 tests/tmdb_matcher_contract.py > "$output_dir/tmdb-matcher-contract-tests.log" 2>&1
python3 tests/tmdb_wire_contract.py > "$output_dir/tmdb-wire-contract-tests.log" 2>&1
python3 tests/tmdb_enrichment_contract.py > "$output_dir/tmdb-enrichment-contract-tests.log" 2>&1
python3 tests/media_repository_contract.py > "$output_dir/media-repository-contract-tests.log" 2>&1
python3 tests/repository_progress_contract.py > "$output_dir/repository-progress-contract-tests.log" 2>&1
python3 tests/repository_composition_contract.py > "$output_dir/repository-composition-contract-tests.log" 2>&1
python3 tests/repository_flow_contract.py > "$output_dir/repository-flow-contract-tests.log" 2>&1
for package in JellyfinKit MetadataKit MoviePilotKit BangumiKit PlaybackKit DanmakuKit DiagnosticsKit; do
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
python3 tests/public_command_contract.py > "$output_dir/public-command-contract-tests.log" 2>&1
echo "macOS build and package checks passed; complete raw logs: $output_dir"
