#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" != 3 ]]; then
  echo 'Usage: test-apple-app.sh <macos|ios-simulator> <destination> <derived-data-path>' >&2
  exit 2
fi
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
apple_root="$repo_root/apps/apple"
platform="$1"
destination="$2"
derived_data="$3"
host_target="$(rustc -vV | awk '/^host:/ {print $2}')"
case "$host_target" in
  aarch64-apple-darwin|x86_64-apple-darwin) ;;
  *) echo 'Apple AppTests require a macOS Rust host' >&2; exit 2 ;;
esac
case "$platform" in
  macos)
    scheme=OcPlayer-macOS
    target="$host_target"
    product_directory=Debug
    executable_relative=Contents/MacOS/OcPlayer
    frameworks_relative=Contents/Frameworks
    ;;
  ios-simulator)
    scheme=OcPlayer-iOS
    case "$host_target" in
      aarch64-apple-darwin) target=aarch64-apple-ios-sim ;;
      x86_64-apple-darwin) target=x86_64-apple-ios ;;
    esac
    product_directory=Debug-iphonesimulator
    executable_relative=OcPlayer
    frameworks_relative=Frameworks
    export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-16.0}"
    ;;
  *) echo "Unsupported Apple test platform: $platform" >&2; exit 2 ;;
esac
mkdir -p "$derived_data"
derived_data="$(cd "$derived_data" && pwd -P)"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$repo_root/core/target}"
library_directory="$derived_data/CoreTestLibrary"
if [[ "$platform" == macos ]]; then
  echo "==> Building real Core for $platform ($target)"
  CARGO_BUILD_TARGET="$target" "$repo_root/core/Scripts/build-apple-dylib.sh" "$library_directory"
fi

build_arguments=(
  -project "$apple_root/OcPlayer.xcodeproj"
  -scheme "$scheme"
  -configuration Debug
  -destination "$destination"
  -derivedDataPath "$derived_data"
)
xcodebuild "${build_arguments[@]}" build-for-testing
app="$derived_data/Build/Products/$product_directory/OcPlayer.app"
executable="$app/$executable_relative"
[[ -f "$executable" ]] || { echo 'Built test host is required' >&2; exit 1; }
if [[ "$platform" == macos ]]; then
  library="$library_directory/libocp_ffi.dylib"
  for architecture in $(xcrun lipo -archs "$executable"); do
    xcrun lipo "$library" -verify_arch "$architecture"
  done
  mkdir -p "$app/$frameworks_relative"
  cp "$library" "$app/$frameworks_relative/libocp_ffi.dylib"
  "$repo_root/core/Scripts/sign-apple-app.sh" "$app" -
else
  # Test the ordinary statically linked app. A copied dylib would mask a
  # missing archive, dead-stripped ABI, or a loader-only Swift dependency.
  [[ ! -e "$app/$frameworks_relative/libocp_ffi.dylib" ]] || {
    echo 'iOS test host must use static Core without an injected dylib' >&2; exit 1;
  }
  # Xcode's Debug executable can be a launcher for the app's own debug image.
  core_image="$executable"
  if [[ -f "$app/OcPlayer.debug.dylib" ]]; then core_image="$app/OcPlayer.debug.dylib"; fi
  for architecture in $(xcrun lipo -archs "$executable"); do
    xcrun nm -arch "$architecture" "$core_image" | awk '$NF == "_ocp_core_create" { found=1 } END { exit !found }'
  done
fi

TEST_RUNNER_OCP_CORE_ENABLED=0 TEST_RUNNER_OCP_CORE_LIBRARY_PATH='' \
  xcodebuild "${build_arguments[@]}" test-without-building
