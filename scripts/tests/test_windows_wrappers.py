import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
POWERSHELL = shutil.which("powershell") or shutil.which("pwsh")


@unittest.skipUnless(os.name == "nt" and POWERSHELL, "Requires Windows PowerShell")
class WindowsWrapperTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="OcPlayer 中文路径 ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.caller = self.root / "caller with spaces"
        self.caller.mkdir()
        (self.root / "scripts").mkdir()
        (self.root / "apps/windows/Scripts").mkdir(parents=True)
        (self.root / "core/Scripts").mkdir(parents=True)
        self.output = self.root / "result.json"

    def invoke(self, name, arguments, component="apps/windows"):
        wrapper = self.root / "scripts" / name
        shutil.copyfile(SCRIPTS / name, wrapper)
        component_script = self.root / component / "Scripts" / name
        if name == "verify-core.ps1":
            component_script = self.root / component / "Scripts/verify-windows.ps1"
        component_script.write_text(
            """param(
    [string]$CoreRoot, [string]$KernelRoot, [string]$NativeArchiveCache,
    [string]$KernelCargoHome, [string]$LibClangPath, [string]$OutputDirectory,
    [string]$VcRuntimeDirectory, [string]$BuildDirectory, [string]$DataDirectory,
    [string]$Configuration, [string]$Python, [string]$Version, [string]$Open,
    [switch]$SkipNative, [switch]$SkipManaged, [switch]$PrepareOnly
)
@{ parameters = $PSBoundParameters; directory = (Get-Location).Path } |
    ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $env:OCP_WRAPPER_RESULT -Encoding UTF8
""",
            encoding="utf-8-sig",
        )
        environment = os.environ.copy()
        environment["OCP_WRAPPER_RESULT"] = str(self.output)
        command = "Set-Location -LiteralPath $env:OCP_WRAPPER_CALLER; & $env:OCP_WRAPPER_SCRIPT " + arguments
        environment["OCP_WRAPPER_CALLER"] = str(self.caller)
        environment["OCP_WRAPPER_SCRIPT"] = str(wrapper)
        result = subprocess.run(
            [POWERSHELL, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", command],
            cwd=self.root,
            env=environment,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", errors="replace"))
        result = json.loads(self.output.read_text(encoding="utf-8-sig"))
        self.assertEqual(Path(result["directory"]).resolve(), self.root / component)
        return result["parameters"]

    def assert_caller_paths(self, parameters, names):
        for name in names:
            self.assertEqual(Path(parameters[name]), self.caller / name)

    def test_build_paths_resolve_before_changing_directory(self):
        names = ["CoreRoot", "KernelRoot", "LibClangPath", "KernelCargoHome"]
        arguments = " ".join(f'-{name} "{name}"' for name in names)
        parameters = self.invoke("build-windows.ps1", arguments + " -SkipNative -SkipManaged")
        self.assert_caller_paths(parameters, names)
        self.assertTrue(parameters["SkipNative"]["IsPresent"])

    def test_build_defaults_use_this_repository(self):
        parameters = self.invoke("build-windows.ps1", "-SkipNative -SkipManaged")
        self.assertEqual(Path(parameters["CoreRoot"]), self.root / "core")
        if not os.environ.get("OCP_ERIKA_ROOT"):
            self.assertEqual(Path(parameters["KernelRoot"]), self.root / "apps/windows/artifacts/liberika-v0.3.7")

    def test_prepare_paths_preserve_caller_location(self):
        names = ["KernelRoot", "NativeArchiveCache", "KernelCargoHome"]
        parameters = self.invoke("prepare-kernel.ps1", " ".join(f'-{name} "{name}"' for name in names))
        self.assert_caller_paths(parameters, names)

    def test_prepare_only_is_forwarded_to_the_pinned_kernel_checkout(self):
        parameters = self.invoke("prepare-kernel.ps1", "-PrepareOnly")
        self.assertTrue(parameters["PrepareOnly"]["IsPresent"])

    def test_package_output_and_inputs_preserve_caller_location(self):
        names = ["CoreRoot", "VcRuntimeDirectory", "OutputDirectory"]
        parameters = self.invoke("package-windows.ps1", " ".join(f'-{name} "{name}"' for name in names) + " -Version 1.2.3")
        self.assert_caller_paths(parameters, names)
        self.assertEqual(parameters["Version"], "1.2.3")

    def test_start_paths_preserve_caller_location(self):
        names = ["BuildDirectory", "DataDirectory"]
        parameters = self.invoke("start-windows.ps1", " ".join(f'-{name} "{name}"' for name in names) + " -PrepareOnly")
        self.assert_caller_paths(parameters, names)

    def test_verification_output_preserves_caller_location(self):
        parameters = self.invoke("verify-core.ps1", '-OutputDirectory "OutputDirectory" -Python "tools/python.exe" -Configuration release', component="core")
        self.assert_caller_paths(parameters, ["OutputDirectory"])
        self.assertEqual(Path(parameters["Python"]), self.caller / "tools/python.exe")
        self.assertEqual(parameters["Configuration"], "release")

    def test_start_local_media_path_preserves_caller_location(self):
        parameters = self.invoke("start-windows.ps1", '-Open "movie with spaces.mkv" -PrepareOnly')
        self.assertEqual(Path(parameters["Open"]), self.caller / "movie with spaces.mkv")

    def test_start_media_url_is_not_reinterpreted_as_a_path(self):
        parameters = self.invoke("start-windows.ps1", '-Open "https://example.invalid/video.mp4" -PrepareOnly')
        self.assertEqual(parameters["Open"], "https://example.invalid/video.mp4")


if __name__ == "__main__":
    unittest.main()
