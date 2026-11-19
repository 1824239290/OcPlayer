#!/usr/bin/env python3
"""Compile the exact vendored C/shim for desktop and iOS without Rust target std.

This validates native archives, not Windows host linkage or device execution.
Requires Xcode SDKs and x86_64-w64-mingw32-gcc/ar on macOS.
"""
import os
from pathlib import Path
import subprocess

core = Path(__file__).resolve().parents[1]
out = core.parent / 'artifacts/verification/smb-native'
out.mkdir(parents=True, exist_ok=True)
subprocess.run(['cargo', 'build', '--locked', '-p', 'ocp-smb'], cwd=core, check=True)
script = max(core.glob('target/debug/build/ocp-smb-*/build-script-build'), key=lambda p: p.stat().st_mtime)
host = subprocess.check_output(['rustc', '-vV'], text=True).split('host: ')[1].splitlines()[0]
for name, target in [('macos-arm64', 'aarch64-apple-darwin'), ('ios-arm64', 'aarch64-apple-ios'), ('windows-x64', 'x86_64-pc-windows-gnu')]:
    folder = out / name
    folder.mkdir(exist_ok=True)
    env = dict(os.environ, OUT_DIR=str(folder), TARGET=target, HOST=host, OPT_LEVEL='0', DEBUG='false', PROFILE='debug', NUM_JOBS='4', CARGO_ENCODED_RUSTFLAGS='')
    if name == 'ios-arm64':
        env.update(SDKROOT=subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip(), IPHONEOS_DEPLOYMENT_TARGET='17.0')
    elif name == 'macos-arm64': env['MACOSX_DEPLOYMENT_TARGET'] = '13.0'
    with (out / f'{name}.log').open('w') as log:
        result = subprocess.run([str(script)], cwd=core / 'crates/ocp-smb', env=env, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        print((out / f'{name}.log').read_text()[-5000:])
        raise SystemExit(result.returncode)
    print(f'{name}: compiled {folder / "libocp_smb2.a"}')
