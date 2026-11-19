#!/usr/bin/env python3
"""Run the ordinary static iOS host against all three file-source fixtures."""
import argparse
import json
import os
from pathlib import Path
import selectors
import shutil
import subprocess

repository = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("simulator", help="Booted iOS simulator UDID")
parser.add_argument("--derived-data", type=Path, default=repository / "artifacts/verification/file-library-ios")
parser.add_argument("--smb-python", default=os.environ.get("OCP_SMB_TEST_PYTHON", "/tmp/ocp-smb-test-venv/bin/python"),
                    help="Python environment containing impacket==0.13.0")
options = parser.parse_args()
subprocess.run([options.smb_python, "-c", "import importlib.metadata; assert importlib.metadata.version('impacket') == '0.13.0'"], check=True)

arguments = ["xcodebuild", "-project", str(repository / "apps/apple/OcPlayer.xcodeproj"),
             "-scheme", "OcPlayer-iOS", "-configuration", "Debug", "-destination",
             "platform=iOS Simulator,id=" + options.simulator, "-derivedDataPath", str(options.derived_data.resolve()),
             "-parallel-testing-enabled", "NO"]
subprocess.run(arguments + ["build-for-testing"], check=True)
app = options.derived_data / "Build/Products/Debug-iphonesimulator/OcPlayer.app"
if (app / "Frameworks/libocp_ffi.dylib").exists():
    raise RuntimeError("iOS test host contains an injected Core dylib; use a clean DerivedData directory")
image = app / "OcPlayer.debug.dylib"
if not image.exists():
    image = app / "OcPlayer"
architectures = subprocess.check_output(["xcrun", "lipo", "-archs", str(image)], text=True).split()
for architecture in architectures:
    symbols = subprocess.check_output(["xcrun", "nm", "-arch", architecture, str(image)], text=True)
    if not any(line.split()[-1:] == ["_ocp_core_create"] for line in symbols.splitlines()):
        raise RuntimeError("iOS test host is missing statically linked Core for " + architecture)

# Pass the original shared fixture as -c, keeping its source intact while
# avoiding runtime Python reads of a Documents checkout.
script = (repository / "core/tests/fixtures/file_library_smb.py").read_text()
media = repository / "apps/apple/AppTests/Fixtures/file-library-three-seconds.mp4"
service = subprocess.Popen([options.smb_python, "-u", "-c", script, str(media)], stdout=subprocess.PIPE)
fixture_directory = None
try:
    with selectors.DefaultSelector() as selector:
        selector.register(service.stdout, selectors.EVENT_READ)
        if not selector.select(timeout=15):
            raise RuntimeError("SMB fixture startup timed out")
        config = json.loads(service.stdout.readline())
    fixture_directory = Path(config["directory"])
    environment = os.environ.copy()
    environment["TEST_RUNNER_OCP_CORE_ENABLED"] = "0"
    environment["TEST_RUNNER_OCP_CORE_LIBRARY_PATH"] = ""
    environment["TEST_RUNNER_OCP_IOS_SMB_FIXTURE"] = json.dumps({key: config[key] for key in ("root", "base")})
    suites = ["FileLibraryIntegrationTests", "FileLibraryPortableIntegrationTests", "FileLibrarySMBHostFixtureTests",
              "AppPlaybackHistoryTests", "ReleaseSessionRegressionTests"]
    subprocess.run(arguments + ["-only-testing:OcPlayerTests-iOS/" + suite for suite in suites] + ["test-without-building"],
                   env=environment, check=True)
    result = max((options.derived_data / "Logs/Test").glob("*.xcresult"), key=lambda path: path.stat().st_mtime)
    summary = json.loads(subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)]))
    (options.derived_data / "file-library-test-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    if summary["failedTests"] or summary["skippedTests"] or not summary["passedTests"]:
        raise RuntimeError("File-library verification requires passing tests with zero skips: " +
                           json.dumps({key: summary[key] for key in ("passedTests", "failedTests", "skippedTests")}))
    print(json.dumps({key: summary[key] for key in ("passedTests", "failedTests", "skippedTests")}), flush=True)
finally:
    service.terminate()
    try:
        service.wait(timeout=10)
    except subprocess.TimeoutExpired:
        service.kill()
        service.wait()
    service.stdout.close()
    if fixture_directory is not None:
        shutil.rmtree(fixture_directory)
