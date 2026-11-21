import json
import os
import plistlib
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
BASH = shutil.which("bash")
if not BASH and os.name == "nt":
    candidate = Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/bin/bash.exe"
    if candidate.is_file():
        BASH = str(candidate)


@unittest.skipUnless(BASH, "Requires Bash for Apple tooling fixture checks")
class AppleAppFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="OcPlayer Apple 中文路径 ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.caller = self.root / "caller with spaces"
        self.caller.mkdir()
        self.tools = self.root / "mock tools"
        self.tools.mkdir()
        self.log = self.root / "commands.jsonl"
        for relative in ["scripts/test-apple-app.sh", "core/Scripts/build-apple-dylib.sh", "core/Scripts/sign-apple-app.sh"]:
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, destination)
            destination.chmod(0o755)
        (self.root / "apps/apple").mkdir(parents=True)
        dispatcher = self.tools / "dispatcher.py"
        dispatcher.write_text(
            '''import json
import os
import sys
from pathlib import Path

tool, *arguments = sys.argv[1:]
record = {"tool": tool, "arguments": arguments,
          "target": os.environ.get("CARGO_BUILD_TARGET"),
          "enabled": os.environ.get("TEST_RUNNER_OCP_CORE_ENABLED"),
          "libraryPath": os.environ.get("TEST_RUNNER_OCP_CORE_LIBRARY_PATH")}
with open(os.environ["MOCK_LOG"], "a", encoding="utf-8") as output:
    output.write(json.dumps(record) + "\\n")
failure = os.environ.get("MOCK_FAILURE")
if tool == "rustc":
    print("host: " + os.environ.get("MOCK_RUST_HOST", "aarch64-apple-darwin"))
elif tool == "cargo":
    if failure == "cargo":
        sys.exit(9)
    target = arguments[arguments.index("--target") + 1]
    library = Path(os.environ["CARGO_TARGET_DIR"]) / target / "release/libocp_ffi.dylib"
    library.parent.mkdir(parents=True, exist_ok=True)
    library.write_text("mock build: " + target)
elif tool == "xcodebuild":
    derived_data = Path(arguments[arguments.index("-derivedDataPath") + 1])
    simulator = arguments[arguments.index("-scheme") + 1] == "OcPlayer-iOS"
    product = "Debug-iphonesimulator" if simulator else "Debug"
    app = derived_data / "Build/Products" / product / "OcPlayer.app"
    if arguments[-1] == "build-for-testing":
        executable = app / ("OcPlayer" if simulator else "Contents/MacOS/OcPlayer")
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_text("mock executable")
        frameworks = app / ("Frameworks" if simulator else "Contents/Frameworks")
        framework = frameworks / "XCUIAutomation.framework"
        nested = framework / "Frameworks/Support.framework"
        nested.mkdir(parents=True)
        (nested / "Support").write_text("mock nested framework executable")
        (framework / "libSupport.dylib").write_text("mock framework dependency")
        test_bundle = app / ("PlugIns/Fixture.xctest" if simulator else "Contents/PlugIns/Fixture.xctest")
        test_bundle.mkdir(parents=True)
    else:
        library = app / ("Frameworks" if simulator else "Contents/Frameworks") / "libocp_ffi.dylib"
        assert library.is_file(), "Tests ran before Core was bundled"
        assert record["enabled"] == "0", "Ordinary tests must retain native policy by default"
        assert record["libraryPath"] == "", "The simulator must load its bundled library"
elif tool == "xcrun":
    if "-archs" in arguments:
        print(os.environ.get("MOCK_ARCH", "arm64"))
    else:
        assert len(arguments) == 4 and arguments[0] == "lipo"
        assert arguments[1].endswith("libocp_ffi.dylib")
        assert arguments[2:] == ["-verify_arch", os.environ.get("MOCK_ARCH", "arm64")]
        if failure == "architecture":
            sys.exit(10)
elif tool == "codesign":
    if failure == "signing":
        sys.exit(11)
    if failure == "verification" and "--verify" in arguments:
        sys.exit(12)
    target = Path(arguments[-1]).resolve()
    earlier = [json.loads(line) for line in Path(os.environ["MOCK_LOG"]).read_text(encoding="utf-8").splitlines()][:-1]
    signed = {Path(item["arguments"][-1]).resolve() for item in earlier
              if item["tool"] == "codesign" and "--force" in item["arguments"]}
    if target.is_dir():
        children = {path.resolve() for path in target.rglob("*")
                    if path.suffix in (".framework", ".xctest", ".dylib")}
        assert children <= signed, "Nested code must be sealed before its parent bundle"
    if "--verify" in arguments:
        assert target in signed, "The root bundle must be sealed before strict verification"
''',
            encoding="utf-8",
        )
        python = shlex.quote(Path(sys.executable).as_posix())
        for name in ["cargo", "rustc", "xcodebuild", "xcrun", "codesign", "python3"]:
            script = self.tools / name
            arguments = ' "$@"' if name == "python3" else f' {shlex.quote(dispatcher.as_posix())} {name} "$@"'
            script.write_text(f"#!/usr/bin/env bash\nexec {python}{arguments}\n", encoding="utf-8", newline="\n")
            script.chmod(0o755)

    def invoke(self, platform, architecture="arm64", failure=""):
        environment = os.environ.copy()
        environment.update(
            PATH=str(self.tools) + os.pathsep + environment["PATH"],
            MOCK_LOG=str(self.log),
            MOCK_ARCH=architecture,
            MOCK_RUST_HOST="aarch64-apple-darwin" if architecture == "arm64" else "x86_64-apple-darwin",
            MOCK_FAILURE=failure,
            PYTHONUTF8="1",
            PYTHONIOENCODING="utf-8",
            CARGO_TARGET_DIR=(self.root / "cargo target with spaces").as_posix(),
            TEST_RUNNER_OCP_CORE_ENABLED="1",
            TEST_RUNNER_OCP_CORE_LIBRARY_PATH="external-host-library.dylib",
        )
        destination = "platform=macOS" if platform == "macos" else "platform=iOS Simulator,id=fixture-udid"
        result = subprocess.run(
            [BASH, "--noprofile", "--norc", (self.root / "scripts/test-apple-app.sh").as_posix(),
             platform, destination, "derived data"],
            cwd=self.caller,
            env=environment,
            capture_output=True,
        )
        records = [json.loads(line) for line in self.log.read_text(encoding="utf-8").splitlines()]
        return result, records

    def assert_success(self, platform, target, architecture="arm64"):
        result, records = self.invoke(platform, architecture)
        self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", errors="replace"))
        build = next(record for record in records if record["tool"] == "cargo")
        self.assertEqual(build["target"], target)
        self.assertEqual(build["arguments"][-2:], ["--target", target])
        commands = [record for record in records if record["tool"] == "xcodebuild"]
        self.assertEqual([record["arguments"][-1] for record in commands], ["build-for-testing", "test-without-building"])
        for command in commands:
            arguments = command["arguments"]
            self.assertEqual(Path(arguments[arguments.index("-derivedDataPath") + 1]).resolve(), self.caller / "derived data")
            self.assertEqual(Path(arguments[arguments.index("-project") + 1]).resolve(), self.root / "apps/apple/OcPlayer.xcodeproj")
        self.assertEqual(commands[-1]["enabled"], "0")
        self.assertEqual(commands[-1]["libraryPath"], "")
        signing = [record for record in records if record["tool"] == "codesign"]
        sealed = [record for record in signing if "--force" in record["arguments"]]
        self.assertEqual(len(sealed), 6)
        targets = [Path(record["arguments"][-1]) for record in sealed]
        nested = next(path for path in targets if path.name == "Support.framework")
        framework = next(path for path in targets if path.name == "XCUIAutomation.framework")
        self.assertLess(targets.index(nested), targets.index(framework))
        self.assertLess(targets.index(framework), len(targets) - 1)
        self.assertTrue(any(path.name == "libocp_ffi.dylib" for path in targets))
        for command in sealed:
            self.assertIn("--preserve-metadata=identifier,entitlements,flags", command["arguments"])
            self.assertIn("--generate-entitlement-der", command["arguments"])
        verified = [Path(record["arguments"][-1]) for record in signing if "--verify" in record["arguments"]]
        self.assertEqual(set(verified), set(targets))
        self.assertEqual(signing[-1]["arguments"][:3], ["--verify", "--deep", "--strict"])
        self.assertLess(records.index(signing[-1]), records.index(commands[-1]))

    def test_macos_host_library_is_bundled_before_tests(self):
        self.assert_success("macos", "aarch64-apple-darwin")

    def test_arm64_simulator_uses_a_simulator_library(self):
        self.assert_success("ios-simulator", "aarch64-apple-ios-sim")

    def test_x86_simulator_uses_its_matching_rust_target(self):
        self.assert_success("ios-simulator", "x86_64-apple-ios", "x86_64")

    def test_fixture_python_output_is_utf8_even_with_a_legacy_encoding(self):
        with patch.dict(os.environ, {"PYTHONUTF8": "0", "PYTHONIOENCODING": "cp1252"}):
            self.assert_success("macos", "aarch64-apple-darwin")

    def test_core_build_failure_stops_before_xcode_tests(self):
        result, records = self.invoke("macos", failure="cargo")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(record["tool"] == "xcodebuild" for record in records))

    def test_architecture_failure_stops_before_tests(self):
        result, records = self.invoke("ios-simulator", failure="architecture")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(record["arguments"][-1] == "test-without-building" for record in records))

    def test_signing_failure_stops_before_tests(self):
        result, records = self.invoke("ios-simulator", failure="signing")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(record["arguments"][-1] == "test-without-building" for record in records))

    def test_strict_verification_failure_stops_before_tests(self):
        result, records = self.invoke("ios-simulator", failure="verification")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(record["arguments"][-1] == "test-without-building" for record in records))


@unittest.skipUnless(sys.platform == "darwin", "Requires real macOS codesign and Xcode test frameworks")
class AppleAppNativeSigningTests(unittest.TestCase):
    def test_reseals_xcode_framework_with_requirements_for_the_current_identity(self):
        platform = Path(subprocess.check_output(
            ["xcrun", "--sdk", "macosx", "--show-sdk-platform-path"], text=True
        ).strip())
        original_framework = platform / "Developer/Library/Frameworks/XCUIAutomation.framework"
        self.assertTrue(original_framework.is_dir(), "The full Xcode macOS test framework is required")
        with tempfile.TemporaryDirectory(prefix="OcPlayer native signing 中文路径 ") as temporary:
            app = Path(temporary) / "OcPlayer.app"
            executable = app / "Contents/MacOS/OcPlayer"
            executable.parent.mkdir(parents=True)
            source = Path(temporary) / "fixture.c"
            source.write_text("int main(void) { return 0; }\n", encoding="utf-8")
            subprocess.run(["xcrun", "clang", str(source), "-o", str(executable)], check=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleExecutable": "OcPlayer",
                "CFBundleIdentifier": "org.ocplayer.signing-fixture",
                "CFBundlePackageType": "APPL",
                "CFBundleVersion": "1",
            }))
            framework = app / "Contents/Frameworks/XCUIAutomation.framework"
            shutil.copytree(original_framework, framework, symlinks=True,
                            ignore=shutil.ignore_patterns("Headers", "PrivateHeaders", "Modules", "*.tbd"))
            result = subprocess.run(
                [BASH, str(ROOT / "core/Scripts/sign-apple-app.sh"), str(app), "-"],
                text=True, capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
            requirements = subprocess.run(
                ["codesign", "--display", "--requirements", "-", str(framework)],
                text=True, capture_output=True, check=True,
            )
            self.assertIn("designated =>", requirements.stdout + requirements.stderr)
            self.assertNotIn("anchor apple", requirements.stdout + requirements.stderr)


class AppleAppWorkflowTests(unittest.TestCase):
    def test_embedding_scripts_use_lipo_input_before_architecture_flags(self):
        for relative in ["scripts/test-apple-app.sh", "core/Scripts/embed-macos-core.sh"]:
            script = (ROOT / relative).read_text(encoding="utf-8")
            with self.subTest(script=relative):
                self.assertIn('xcrun lipo "$library" -verify_arch "$architecture"', script)
                self.assertNotIn('lipo -verify_arch "$architecture" "$library"', script)

    def test_both_embedding_paths_share_bottom_up_signing(self):
        for relative in ["scripts/test-apple-app.sh", "core/Scripts/embed-macos-core.sh"]:
            script = (ROOT / relative).read_text(encoding="utf-8")
            with self.subTest(script=relative):
                self.assertIn("/Scripts/sign-apple-app.sh", script)
        signer = (ROOT / "core/Scripts/sign-apple-app.sh").read_text(encoding="utf-8")
        self.assertIn('find "$app" -depth', signer)
        self.assertIn('codesign --verify --deep --strict --verbose=4 "$app"', signer)
        self.assertIn("--preserve-metadata=identifier,entitlements,flags", signer)
        self.assertNotIn("entitlements,requirements,flags", signer)
        workflow = (ROOT / ".github/workflows/test.yml").read_text(encoding="utf-8")
        apple_core = workflow.split("  apple-core:\n", 1)[1].split("\n  apple-packaging:\n", 1)[0]
        self.assertLess(apple_core.index("test_apple_app_fixture.py"),
                        apple_core.index("Verify actual Core activation and Apple parity"))

    def test_both_ordinary_app_jobs_supply_the_real_core_fixture(self):
        workflow = (ROOT / ".github/workflows/test.yml").read_text(encoding="utf-8")
        self.assertIn("../../scripts/test-apple-app.sh macos", workflow)
        self.assertIn("../../scripts/test-apple-app.sh ios-simulator", workflow)
        self.assertIn("targets: aarch64-apple-ios-sim,x86_64-apple-ios", workflow)
        script = (ROOT / "scripts/test-apple-app.sh").read_text(encoding="utf-8")
        self.assertNotIn("OcpCoreEnabled", script)
        parity = (ROOT / "apps/apple/AppTests/CoreRuntimePreferenceParityTests.swift").read_text(encoding="utf-8")
        self.assertIn('"fixture requires the real Rust library"', parity)
        self.assertIn('31, "every getter must execute Core"', parity)
        self.assertNotIn("XCTSkip", parity)


if __name__ == "__main__":
    unittest.main()
