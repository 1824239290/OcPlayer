import argparse
import json
import re
import subprocess
import xml.etree.ElementTree as ElementTree
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def git(*arguments):
    result = subprocess.run(
        ["git", "-c", "core.quotePath=false", *arguments],
        cwd=ROOT,
        check=True,
        capture_output=True,
    )
    return result.stdout.decode("utf-8").strip()


def tree_entries(revision):
    entries = {}
    for record in git("ls-tree", "-r", revision).splitlines():
        metadata, path = record.split("\t", 1)
        entries[path] = metadata
    return entries


def index_entries():
    entries = {}
    for record in git("ls-files", "--stage").splitlines():
        metadata, path = record.split("\t", 1)
        mode, object_id, stage = metadata.split()
        assert stage == "0", f"Unresolved merge: {path}"
        entries[path] = f"{mode} blob {object_id}"
    return entries


def verify_history(manifest):
    counts = {}
    for name, source in manifest["sources"].items():
        git("merge-base", "--is-ancestor", source["commit"], "HEAD")
        git("merge-base", "--is-ancestor", source["importCommit"], "HEAD")
        assert git("rev-parse", source["commit"] + "^{tree}") == source["tree"]
        entries = tree_entries(source["commit"])
        counts[name] = len(entries)
        if name == "apple":
            imported = tree_entries(source["importCommit"])
            retained = manifest["appleRetainedRoots"]
            for path, metadata in entries.items():
                mapped = path if path.split("/", 1)[0] in retained else source["prefix"] + "/" + path
                assert imported.get(mapped) == metadata, f"Apple import changed content or mode: {path}"
            assert len(entries) == source["fileCount"] == len(imported)
        else:
            assert git("rev-parse", source["importCommit"] + ":" + source["prefix"]) == source["tree"]
    return counts


def verify_unchanged_swift(manifest, revision=None):
    current = tree_entries(revision) if revision else index_entries()
    apple = tree_entries(manifest["sources"]["apple"]["commit"])
    core = tree_entries(manifest["sources"]["core"]["commit"])
    binding_prefix = manifest["swiftBinding"]["originalApplePath"] + "/"
    canonical_prefix = manifest["swiftBinding"]["canonicalPath"] + "/"
    unchanged = 0
    binding_files = 0
    for path, metadata in apple.items():
        if path.startswith(binding_prefix):
            relative = path[len(binding_prefix):]
            core_metadata = core["bindings/apple/OcPlayerCore/" + relative]
            assert core_metadata.split()[2] == metadata.split()[2], f"Original binding content differs: {relative}"
            if relative != "README.md":
                assert current.get(canonical_prefix + relative) == core_metadata, f"Canonical binding changed: {relative}"
            assert "apps/apple/" + path not in current, f"Duplicate binding remains: {path}"
            binding_files += 1
        elif path.endswith(".swift") and not path.endswith("/Package.swift"):
            assert current.get("apps/apple/" + path) == metadata, f"Apple business/platform Swift changed: {path}"
            unchanged += 1
    assert binding_files == manifest["swiftBinding"]["identicalContentFiles"]
    return {"unchangedAppleSwiftFiles": unchanged, "deduplicatedBindingFiles": binding_files}


def verify_dependencies():
    apple_root = ROOT / "apps/apple"
    binding_root = ROOT / "core/bindings/apple/OcPlayerCore"
    assert not (apple_root / "Packages/OcPlayerCore/Package.swift").exists()
    binding_consumers = []
    for manifest in sorted((apple_root / "Packages").glob("*/Package.swift")):
        dependencies = re.findall(r'\.package\(path:\s*"([^"]+)"\)', manifest.read_text(encoding="utf-8"))
        resolved = [(manifest.parent / dependency).resolve() for dependency in dependencies]
        for dependency in resolved:
            assert (dependency / "Package.swift").is_file(), f"Missing local Swift package: {dependency}"
        if binding_root in resolved:
            assert resolved.count(binding_root) == 1
            binding_consumers.append(manifest.parent.name)
    assert binding_consumers == ["BangumiKit", "DanmakuKit", "JellyfinKit", "MetadataKit", "MoviePilotKit", "PlaybackKit"]
    project = (apple_root / "OcPlayer.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
    references = re.findall(r'relativePath\s*=\s*"?([^";]+)"?;', project)
    resolved = [(apple_root / reference.strip()).resolve() for reference in references]
    assert resolved.count(binding_root) == 1
    for dependency in resolved:
        assert (dependency / "Package.swift").is_file(), f"Missing Xcode package: {dependency}"
    windows_root = ROOT / "apps/windows"
    properties = ElementTree.parse(windows_root / "Directory.Build.props")
    core_path = properties.findtext("./PropertyGroup/OcpCoreRoot")
    core_path = core_path.replace("$(MSBuildThisFileDirectory)", str(windows_root) + "/").replace("\\", "/")
    assert Path(core_path).resolve() == ROOT / "core"
    assert (ROOT / "global.json").is_file()
    assert not (windows_root / "global.json").exists()
    return binding_consumers


def verify_pins(manifest, revision=None):
    apple_pin = git("show", revision + ":apps/apple/Config/Erika.version") if revision else (ROOT / "apps/apple/Config/Erika.version").read_text(encoding="utf-8")
    version = re.search(r"^ERIKA_VERSION\s*=\s*(\S+)", apple_pin, re.MULTILINE).group(1)
    assert version == manifest["kernelPins"]["apple"]
    windows_text = git("show", revision + ":apps/windows/Config/Kernel.version.json") if revision else (ROOT / "apps/windows/Config/Kernel.version.json").read_text(encoding="utf-8-sig")
    windows_pin = json.loads(windows_text)
    assert windows_pin["tag"] == manifest["kernelPins"]["windows"]
    assert windows_pin["commit"] == manifest["kernelPins"]["windowsCommit"]


def verify_ignores():
    ignored = [
        "artifacts/verification/layout.json",
        "core/target/debug/ocp-cli.exe",
        "core/artifacts/windows-verification/runtime.log",
        "apps/windows/src/OcPlayer.Windows/bin/Release/app.dll",
        "apps/windows/native/OcPlayerCore/x64/ocp_ffi.dll",
        "apps/apple/.local-build/current/DerivedData/build.log",
        "apps/apple/Packages/ErikaKit/Vendor/Erika.xcframework/test.dylib",
        "apps/apple/Secrets.xcconfig",
    ]
    for path in ignored:
        git("check-ignore", "--no-index", path)
    preserved = [
        "core/docs/validation/2026-11-14-completion-audit/rust-tests.log",
        "core/bindings/apple/OcPlayerCore/Package.swift",
        "apps/windows/Config/Kernel.version.json",
    ]
    for path in preserved:
        result = subprocess.run(["git", "check-ignore", "--no-index", path], cwd=ROOT, capture_output=True)
        assert result.returncode == 1, f"Source or historical evidence was ignored: {path}"


def main():
    parser = argparse.ArgumentParser(description="Verify OcPlayer history, layout, bindings and unchanged Apple Swift behavior")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--migration", action="store_true", help="Require the current candidate's Swift sources and kernel pins to match the original baselines")
    arguments = parser.parse_args()
    manifest = json.loads((ROOT / "docs/migration/source-manifest.json").read_text(encoding="utf-8"))
    report = {"commit": git("rev-parse", "HEAD"), "sourceFileCounts": verify_history(manifest)}
    comparison_revision = None if arguments.migration else manifest.get("validationCommit")
    if arguments.migration or comparison_revision:
        if comparison_revision:
            git("merge-base", "--is-ancestor", comparison_revision, "HEAD")
        report.update(verify_unchanged_swift(manifest, comparison_revision))
        verify_pins(manifest, comparison_revision)
        report["swiftComparisonRevision"] = comparison_revision or "index"
    report["swiftBindingConsumers"] = verify_dependencies()
    verify_ignores()
    report["status"] = "passed"
    output = json.dumps(report, ensure_ascii=False, indent=2)
    if arguments.output:
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(output + "\n", encoding="utf-8")
    print(output)


if __name__ == "__main__":
    main()
