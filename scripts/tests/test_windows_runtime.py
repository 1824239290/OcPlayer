import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
POWERSHELL = shutil.which("powershell") or shutil.which("pwsh")


@unittest.skipUnless(os.name == "nt" and POWERSHELL, "Requires Windows PowerShell")
class WindowsRuntimeTests(unittest.TestCase):
    def invoke_discovery(self, folder_names, platform="x64"):
        script = (ROOT / "apps/windows/Scripts/package-windows.ps1").read_text(encoding="utf-8-sig")
        discovery = script.split("    $runtimeDirectory = ", 1)[1].split("\n}", 1)[0]
        temporary = tempfile.TemporaryDirectory(prefix="OcPlayer CRT 中文 ")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name).resolve()
        (root / platform).mkdir()
        for folder_name in folder_names:
            (root / platform / folder_name).mkdir()
        output = root / "result.json"
        environment = os.environ.copy()
        environment["OCP_RUNTIME_FIXTURE"] = str(root)
        environment["OCP_RUNTIME_PLATFORM"] = platform
        environment["OCP_RUNTIME_RESULT"] = str(output)
        command = (
            "$ErrorActionPreference = 'Stop'; "
            "$redistVersion = Get-Item -LiteralPath $env:OCP_RUNTIME_FIXTURE; "
            "$crtPlatform = $env:OCP_RUNTIME_PLATFORM; $runtimeDirectory = " + discovery + "; "
            "@{ directory = $VcRuntimeDirectory } | ConvertTo-Json -Compress | "
            "Set-Content -LiteralPath $env:OCP_RUNTIME_RESULT -Encoding UTF8"
        )
        result = subprocess.run(
            [POWERSHELL, "-NoProfile", "-NonInteractive", "-Command", command],
            env=environment,
            capture_output=True,
        )
        directory = Path(json.loads(output.read_text(encoding="utf-8-sig"))["directory"]) if output.exists() else None
        return result, directory, root / platform

    def test_packaging_accepts_official_v14_crt_folder_versions(self):
        for platform in ["x64", "arm64"]:
            for folder_name in ["Microsoft.VC143.CRT", "Microsoft.VC145.CRT"]:
                with self.subTest(platform=platform, folder=folder_name):
                    result, directory, platform_root = self.invoke_discovery(
                        [folder_name, "Microsoft.VC145.DebugCRT"], platform
                    )
                    self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", errors="replace"))
                    self.assertTrue(directory.samefile(platform_root / folder_name))

    def test_packaging_selects_newest_official_release_crt(self):
        result, directory, platform_root = self.invoke_discovery(
            ["Microsoft.VC143.CRT", "Microsoft.VC145.CRT", "Microsoft.VC145.DebugCRT"]
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", errors="replace"))
        self.assertTrue(directory.samefile(platform_root / "Microsoft.VC145.CRT"))

    def test_packaging_rejects_debug_or_non_v14_runtime(self):
        result, directory, platform_root = self.invoke_discovery(
            ["Microsoft.VC145.DebugCRT", "Microsoft.VC120.CRT"]
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(directory)
        self.assertIn("Official MSVC v14 release CRT is missing for x64", result.stderr.decode("utf-8", errors="replace"))


if __name__ == "__main__":
    unittest.main()
