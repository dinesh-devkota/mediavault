"""Test the seek probe's React Native registration preflight."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parents[1]
PROBE = TOOLS / "seek-probe"
PROBE_ID = "com.dineshdevkota.mediavault.seekprobe"
RENDER_ID = "com.dineshdevkota.mediavault.renderprobe"
MEDIAVAULT_ID = "com.dineshdevkota.cinevault"


class SeekProbeIdentityTests(unittest.TestCase):
    def verify(self, package_id, manifest, app_config):
        return subprocess.run(
            [sys.executable, PROBE / "check-identity.py", package_id, manifest, app_config],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_probe_matches_the_identity_convention_of_working_vega_apps(self):
        for package_id, project in (
            (PROBE_ID, PROBE),
            (RENDER_ID, TOOLS / "render-probe"),
            (MEDIAVAULT_ID, TOOLS.parents[1] / "vega"),
        ):
            with self.subTest(package_id=package_id):
                result = self.verify(package_id, project / "manifest.toml", project / "app.json")
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_install_package_and_react_registration_are_distinct(self):
        with tempfile.TemporaryDirectory() as work:
            config = Path(work) / "app.json"
            config.write_text(json.dumps({"name": PROBE_ID}), encoding="utf-8")
            result = self.verify(PROBE_ID, PROBE / "manifest.toml", config)
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"must match launch component '{PROBE_ID}.main'", result.stderr)

    def test_build_checks_the_registration_before_requiring_the_sdk(self):
        with tempfile.TemporaryDirectory() as work:
            project = Path(work) / "tools" / "vega" / "seek-probe"
            project.mkdir(parents=True)
            for name in ("app.json", "manifest.toml", "build.sh", "check-identity.py"):
                shutil.copyfile(PROBE / name, project / name)
            config = project / "app.json"
            original = json.loads(config.read_text(encoding="utf-8"))
            config.write_text(json.dumps({**original, "name": "VegaSeekProbe"}), encoding="utf-8")
            result = subprocess.run(["bash", project / "build.sh"], check=False, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"app.json name 'VegaSeekProbe' must match launch component '{PROBE_ID}.main'", result.stderr)
