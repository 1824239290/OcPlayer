#!/usr/bin/env bash
set -euo pipefail

# Embed into a built application, then sign from the library outwards.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="${1:?Usage: embed-macos-core.sh /path/OcPlayer.app [library.dylib]}"
library="${2:-$repo_root/artifacts/apple/libocp_ffi.dylib}"
identity="${OCP_SIGNING_IDENTITY:--}"
plist="$app/Contents/Info.plist"
[[ -f "$plist" && -f "$library" ]] || { echo 'Built macOS app and core library are required' >&2; exit 1; }
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")"
[[ -f "$app/Contents/MacOS/$executable" ]] || { echo 'App executable is missing' >&2; exit 1; }
for architecture in $(xcrun lipo -archs "$app/Contents/MacOS/$executable"); do
  xcrun lipo "$library" -verify_arch "$architecture"
done
# Verify every required export before changing the application.
python3 - "$library" <<'PY'
import ctypes, sys
core = ctypes.CDLL(sys.argv[1])
for symbol in ['ocp_core_create', 'ocp_core_destroy', 'ocp_core_abi_version', 'ocp_call',
               'ocp_snapshot', 'ocp_poll_event', 'ocp_string_free', 'ocp_last_error_message',
               'ocp_attach_surface', 'ocp_resize_surface', 'ocp_detach_surface', 'ocp_render_tick']:
    getattr(core, symbol)
core.ocp_core_abi_version.restype = ctypes.c_uint32
assert core.ocp_core_abi_version() == 1, 'Unsupported core ABI'
PY
mkdir -p "$app/Contents/Frameworks"
cp "$library" "$app/Contents/Frameworks/libocp_ffi.dylib"
/usr/libexec/PlistBuddy -c 'Delete :OcpCoreEnabled' "$plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :OcpCoreEnabled bool true' "$plist"
"$repo_root/Scripts/sign-apple-app.sh" "$app" "$identity"
echo "$app"
