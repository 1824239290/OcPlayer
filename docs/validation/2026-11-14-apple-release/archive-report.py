from pathlib import Path
import hashlib,json,shutil,subprocess
r=Path('/tmp/ocp-apple-delivery');c=Path('/Volumes/Backup/软件/OcPlayer-Core');out=c/'docs/validation/2026-11-14-apple-release'
out.mkdir(exist_ok=False)
# Preserve every authoring/build/verification attempt without copying binary or
# dependency caches into Git. Final libraries and app ZIP remain in artifacts/.
for p in r.rglob('*'):
 if not p.is_file():continue
 if 'xcuserdata' in p.parts:continue
 relative=p.relative_to(r)
 if any(part in ('toolchain','target','clean-target','clean checkout','NativeRelease','SwiftPackageBuild','dynamic-binding','host-probe-build','ProductionArchiveCheck') for part in relative.parts):continue
 if relative.parts[0] in ('first','host-probe','remapped-reference','clean-release','final-reference','canonical-reference'):continue
 if p.suffix in ('.log','.json','.py','.diff','.sha256','.pbxproj','.xcscheme','.xcworkspacedata','.resolved'):
  destination=out/relative;destination.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,destination)
for p in (c/'artifacts/apple-2026-11-14/Package/release-manifest.json',):shutil.copy2(p,out/'final-release-manifest.json')
for p in ('Scripts/build-apple-dylib.sh','Scripts/build-apple-xcframework.sh','Scripts/apple-release-manifest.py','Scripts/verify-apple-release.sh','tests/apple_release_probe.swift'):
 destination=out/'verification-source'/p;destination.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(c/p,destination)
summary=json.loads((r/'acceptance-pending-production.json').read_text())
summary['productionApp']=json.loads((r/'production-app-receipt.json').read_text())
summary['nativeSource']=json.loads((r/'native-source-manifest.json').read_text())
summary['nativeSourceUnchanged']=True
summary['nativeCommit']=subprocess.check_output(['git','-C','/Users/jumusu/Documents/project/OcPlayer','rev-parse','HEAD'],text=True).strip()
(out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
(out/'README.md').write_text('''# Apple release acceptance — 2026-11-14

The complete Apple library delivery is verified from clean source at Core commit
`e705d2e77b62d799301a7b5e13320f3906926054`; the native adapter is at
`69207ad`. This closes the Apple slice/package/release delivery item. The overall
OcPlayer-Core goal remains active for the finite Windows adapter and public
command/ownership audit; Windows runtime testing remains deferred.

## Final artifacts

- `artifacts/apple-2026-11-14/Package/`: complete local Swift package, static
  XCFramework, matching ten Swift sources, tests/fixtures, C module map, system
  linker settings, GPL license, README and SHA-256 manifest.
- `artifacts/apple-2026-11-14/macOS/libocp_ffi.dylib`: universal macOS library.
- `artifacts/apple-2026-11-14/OcPlayer-macOS.zip`: ordinary universal Release app;
  selftest entry point absent. ZIP extraction passes strict deep ad-hoc signature
  verification and preserves the executable bytes.

Artifacts are intentionally outside Git, with hashes/receipts stored here.
No distribution identity or notarization is claimed by these local checks.

## Verified delivery

An isolated official Rust 1.99.1 toolchain was installed under the validation
folder without changing the user's Homebrew compiler or shell configuration.
The installer was SHA-256 checked against its official download. Five standard
library targets and matching Xcode SDKs build all slices offline with Cargo.lock:
macOS arm64/x86_64, iOS arm64, and simulator arm64/x86_64. Minimum versions are
macOS 13 and iOS 16. Each architecture exports all twelve C ABI functions.

A complete clean Git clone, deliberately in a path containing a space, and the
original clean checkout each independently build the package with different
Cargo target directories. All 143 recorded input files match; all 33 delivered
files, including the three archives and canonical metadata, are byte-identical.
Both builds record clean source and the exact same commit. Checkout source paths
are remapped using encoded rustc arguments. Existing output is refused.

The delivered static package runs all 35 Swift contracts in Release mode with
zero skips/failures and no dynamic library environment override. All five
platform/architecture combinations compile and link the full Swift adapter.
Both arm64 and Intel macOS optimized executable probes run with all dynamic Core
exports hidden and linker dead stripping enabled; ping, events, playback,
settings backup and diagnostic trace redaction pass. Intel execution uses Rosetta;
iOS runtime execution is not claimed. Standalone and native dynamic adapter
runs also each pass 35 tests, with source/test equivalence verified.

The ordinary universal native Release app builds and signs. Its existing
`OCPLAYER_SELFTEST` channel is intentionally absent, as verified in the executable.
For actual optimized display-chain testing, a temporary project copy changes
only the macOS application's Release compilation condition to include that
channel; a structural plist comparison proves all other original project values
unchanged. Its signed, bundled Core uses no path/feature environment override.
Ten-second H.264/AAC controls and eight-second natural EOF each exit zero with
zero render/audio failures. Both architectures' twelve runtime sections match
the input universal library after embedding and signing. Actual native playback
runs on arm64. The 687 frozen tracked native build inputs remain unchanged.

The prior complete behavioral regression remains the settings-backup report:
Rust 212, ABI 203 in 31 suites, eight native packages 1387, AppTests 1026
(1007 passed, 19 platform skips, zero failures). These full AppTests are baseline
results, not a claim that 1026 cases reran in this packaging-only verification.

## Preserved preliminary failures

The first `nm` scan tried reading LLVM 23 embedded standard-library bitcode with
Xcode's older bitcode reader. Native Mach-O symbol scanning with `--no-llvm-bc`
fixes that compatibility issue; real native/static linking independently passes.

The first stripped release probe incorrectly expected export to redact ordinary
log sink contents. Native sinks redact before writing; export redacts imported
trace tails. The corrected probe exercises that existing contract. All attempts
are preserved; no application redaction policy was changed.

Xcode initially serialized slice metadata in different orders. Canonical plist
key/array ordering makes the complete delivery byte-identical across builds.

A direct selftest launch of the ordinary Release app timed out because the
existing compilation condition correctly disables that channel. The subsequent
temporary optimized verification project follows the native source's documented
method. The production executable is reconstructed from the unchanged original
project after verification and archived separately.

Direct ditto copying to the SMB backup volume failed on metadata temporary-file
creation, while a simultaneous verification rebuild shared the product directory.
The incomplete copy and original error logs are preserved. Final operations are
sequenced; ZIP creation and extraction preserve file contents, Unix executable
modes and symlinks without relying on that unsupported metadata-copy operation.

See summary.json, reproducibility.json, final-release-manifest.json, native
runtime/coverage receipts and the raw build/test/process logs in this directory.
''')
files=[p for p in out.rglob('*') if p.is_file()]
print(json.dumps({'reportFiles':len(files),'report':str(out/'README.md')}))
