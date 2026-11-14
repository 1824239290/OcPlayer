#!/usr/bin/env python3
"""Validate all Apple slices and record the exact source/delivery bytes."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


repo, output = (Path(value).resolve() for value in sys.argv[1:])
framework = output / "OcPlayerCore.xcframework"
info = plistlib.loads((framework / "Info.plist").read_bytes())
expected = {
    ("macos", ""): ["arm64", "x86_64"],
    ("ios", ""): ["arm64"],
    ("ios", "simulator"): ["arm64", "x86_64"],
}
header = (repo / "include/ocplayer_core.h").read_text()
symbols = sorted(set(re.findall(r"\b(ocp_\w+)\s*\(", header)))
assert len(symbols) == 12, symbols
slices = []
for item in info["AvailableLibraries"]:
    key = (item["SupportedPlatform"], item.get("SupportedPlatformVariant", ""))
    architectures = sorted(item["SupportedArchitectures"])
    assert key in expected and architectures == expected.pop(key), item
    directory = framework / item["LibraryIdentifier"]
    library = directory / item["LibraryPath"]
    assert sorted(run("xcrun", "lipo", "-archs", str(library)).split()) == architectures
    headers = directory / item["HeadersPath"]
    assert "module OcPlayerCoreFFI" in (headers / "module.modulemap").read_text()
    delivered_symbols = set(re.findall(r"\b(ocp_\w+)\s*\(", (headers / "ocplayer_core.h").read_text()))
    assert delivered_symbols == set(symbols)
    for architecture in architectures:
        # Read Mach-O symbol tables, rather than the std archive's embedded LLVM
        # IR, whose producer may be newer than Xcode's bitcode reader.
        exported = run("xcrun", "nm", "--no-llvm-bc", "-g", "-U", "-arch", architecture, str(library))
        for symbol in symbols:
            assert re.search(r"\b_" + re.escape(symbol) + r"$", exported, re.M), (key, architecture, symbol)
    slices.append({"identifier": item["LibraryIdentifier"], "platform": key[0],
                   "variant": key[1], "architectures": architectures,
                   "abiSymbols": symbols, "sha256": sha(library)})
assert not expected, expected
inputs = []
for directory in ("crates", "bindings/apple/OcPlayerCore", "include", "Scripts", "tests", "fixtures"):
    for path in (repo / directory).rglob("*"):
        if path.is_file() and not any(part in (".build", "__pycache__") for part in path.parts):
            if path.suffix in (".rs", ".toml", ".swift", ".h", ".sh", ".py", ".sql", ".json", ".lock"):
                inputs.append(path)
inputs += [repo / name for name in ("Cargo.toml", "Cargo.lock", "cbindgen.toml", "LICENSE")]
artifact_files = [path for path in output.rglob("*") if path.is_file() and path.name != "release-manifest.json"]
manifest = {
    "formatVersion": 1, "abiVersion": 1,
    "sourceCommit": run("git", "-C", str(repo), "rev-parse", "HEAD"),
    "sourceDirty": bool(run("git", "-C", str(repo), "status", "--porcelain", "--untracked-files=no")),
    "rustc": run("rustc", "-vV"), "cargo": run("cargo", "--version"),
    "xcode": run("xcodebuild", "-version"),
    "rustFlags": os.environ.get("CARGO_ENCODED_RUSTFLAGS", "").split("\x1f"),
    "deploymentTargets": {"macos": os.environ.get("MACOSX_DEPLOYMENT_TARGET", "13.0"),
                          "ios": os.environ.get("IPHONEOS_DEPLOYMENT_TARGET", "16.0")},
    "slices": slices,
    "inputs": {str(path.relative_to(repo)): sha(path) for path in sorted(set(inputs))},
    "files": {str(path.relative_to(output)): sha(path) for path in sorted(artifact_files)},
}
(output / "release-manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
print(json.dumps({"slices": len(slices), "architectures": sum(len(item["architectures"]) for item in slices),
                  "abiExportsPerArchitecture": len(symbols), "deliveryFiles": len(artifact_files)}))
