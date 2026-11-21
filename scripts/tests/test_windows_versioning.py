import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class WindowsVersioningTests(unittest.TestCase):
    def test_windows_defaults_to_the_apple_marketing_version(self):
        config = (ROOT / "apps/apple/Config/App.xcconfig").read_text(encoding="utf-8")
        version = re.search(r"^MARKETING_VERSION\s*=\s*(\S+)", config, re.MULTILINE).group(1)
        script = (ROOT / "apps/windows/Scripts/package-windows.ps1").read_text(encoding="utf-8-sig")
        wrapper = (ROOT / "scripts/package-windows.ps1").read_text(encoding="utf-8-sig")

        self.assertRegex(version, r"^\d+\.\d+\.\d+(\.\d+)?$")
        self.assertIn("MARKETING_VERSION", script)
        self.assertIn("App.xcconfig", script)
        self.assertNotRegex(script, r"\[string\]\$Version\s*=\s*'[^']+'")
        self.assertNotRegex(wrapper, r"\[string\]\$Version\s*=\s*'[^']+'")

    def test_build_number_uses_mac_order_and_never_scans_old_installers(self):
        script = (ROOT / "apps/windows/Scripts/package-windows.ps1").read_text(encoding="utf-8-sig")
        env_index = script.index("$env:BUILD_NUMBER")
        run_index = script.index("$env:GITHUB_RUN_NUMBER")
        git_index = script.index("git -C $repoRoot rev-list --count HEAD")

        self.assertLess(env_index, run_index)
        self.assertLess(run_index, git_index)
        self.assertNotIn("$maxBuild", script)
        self.assertIn("InformationalVersion=$Version+build.$BuildNumber", script)
        self.assertRegex(script, r"buildNumber\s*=\s*\$BuildNumber")

    def test_about_page_reads_build_metadata_without_changing_market_version(self):
        service = (ROOT / "apps/windows/src/OcPlayer.Windows/Services/AppReleaseService.cs").read_text(encoding="utf-8")

        self.assertIn("InformationalVersion.Split('+')[0]", service)
        self.assertIn('StartsWith("build.", StringComparison.OrdinalIgnoreCase)', service)
        self.assertIn('.Split(\'.\')[0]', service)

    def test_windows_workflows_package_and_publish_exe_installers(self):
        build = (ROOT / ".github/workflows/windows-build.yml").read_text(encoding="utf-8")
        release = (ROOT / ".github/workflows/windows-release.yml").read_text(encoding="utf-8")

        self.assertIn("default: ''", build)
        self.assertIn("innosetup", build)
        self.assertIn("*-Setup.exe", build)
        self.assertIn("release.json", build)
        self.assertIn("find artifacts -name '*-Setup.exe'", release)
        self.assertNotIn("*.msi", build)
        self.assertNotIn("-name '*.msi'", release)

    def test_installer_verification_preserves_scope_during_upgrade(self):
        installer = (ROOT / "apps/windows/installer/OcPlayer.iss").read_text(encoding="utf-8")
        verification = (ROOT / "apps/windows/Scripts/verify-installer.ps1").read_text(encoding="utf-8-sig")

        self.assertIn("PrivilegesRequiredOverridesAllowed=dialog commandline", installer)
        self.assertIn("Invoke-Setup $UpgradeInstaller @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', $scopeFlag,", verification)


if __name__ == "__main__":
    unittest.main()
