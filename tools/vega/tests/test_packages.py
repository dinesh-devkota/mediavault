"""Regression tests for the actual fixture staging and packaged-byte validators."""
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parents[1]


def load_script(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), TOOLS / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


staging = load_script("stage-fixture")
packages = load_script("check-package")
PRODUCTION = "com.dineshdevkota.cinevault"
FIXTURE = "com.dineshdevkota.mediavault.vvdfixture"


def manifest(package=PRODUCTION, component=None):
    return (f'[package]\nid = "{package}"\ntitle = "MediaVault"\n'
            f'[components]\n[[components.interactive]]\nid = "{component or package + ".main"}"\n').encode()


def native(target="x86_64", marker=False, symbol=False):
    header = bytearray(64)
    header[:7] = b"\x7fELF" + bytes((1 if target == "armv7" else 2, 1, 1))
    struct.pack_into("<H", header, 18, {"armv7": 40, "aarch64": 183, "x86_64": 62}[target])
    return bytes(header) + (packages.MARKER + b"\0" if marker else b"") + (packages.SYMBOL + b"\0" if symbol else b"")


class FixtureStagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mediavault-stage-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "production"
        self.destination = self.root / "fixture"
        self.source.mkdir()
        (self.source / "manifest.toml").write_bytes(manifest())
        (self.source / "app.json").write_text(json.dumps({"name": PRODUCTION + ".main", "displayName": "MediaVault"}), encoding="utf-8")
        self.config = self.source / "src/generated/buildConfig.ts"
        self.config.parent.mkdir(parents=True)
        self.config.write_text(f"export const BUILD_CONFIG = {{fixtureVault: false, packageId: '{PRODUCTION}'}} as const;\n", encoding="utf-8")
        (self.source / "index.js").write_text("import {name} from './app.json';\n", encoding="utf-8")
        (self.source / "src/App.tsx").write_text("// source preserved\n", encoding="utf-8")

    def snapshot(self):
        return {path.relative_to(self.source).as_posix(): path.read_bytes() for path in self.source.rglob("*") if path.is_file()}

    def test_staging_changes_only_isolated_identity_and_build_config(self):
        before = self.snapshot()
        actual = staging.stage(self.source, self.destination)
        self.assertEqual(actual, self.destination.resolve())
        self.assertEqual(self.snapshot(), before)
        parsed = staging.tomllib.loads((actual / "manifest.toml").read_text(encoding="utf-8"))
        self.assertEqual(parsed["package"]["id"], FIXTURE)
        self.assertEqual(parsed["package"]["title"], "MediaVault Simulator Test")
        self.assertEqual(parsed["components"]["interactive"][0]["id"], FIXTURE + ".main")
        self.assertEqual(json.loads((actual / "app.json").read_text(encoding="utf-8")),
                         {"name": FIXTURE + ".main", "displayName": "MediaVault Simulator Test"})
        config = (actual / "src/generated/buildConfig.ts").read_text(encoding="utf-8")
        self.assertIn("fixtureVault: true", config)
        self.assertIn(FIXTURE, config)
        self.assertNotIn(PRODUCTION, config)
        self.assertEqual((actual / "src/App.tsx").read_bytes(), before["src/App.tsx"])
        self.assertEqual((actual / "index.js").read_bytes(), before["index.js"])

    def test_staging_excludes_outputs_dependencies_secrets_and_host_overrides_at_any_depth(self):
        excluded = ["node_modules/package/index.js", "build/native.so", "dist/app.vpkg", ".git/config",
                    ".artifacts/evidence.json", "__pycache__/module.pyc", ".env", ".env.local",
                    "local.bak", "app.tsbuildinfo", "buildinfo.json", "CMakeUserPresets.json",
                    "kepler-library-manifest.json", "native/node_modules/package/file", "native/build/library.so",
                    "nested/.env.production", "nested/CMakeUserPresets.json", "nested/buildinfo.json"]
        for name in excluded:
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("synthetic forbidden copy", encoding="utf-8")
        (self.source / "native/source.cpp").write_text("// keep source", encoding="utf-8")
        before = self.snapshot()
        staging.stage(self.source, self.destination)
        for name in excluded:
            with self.subTest(path=name):
                self.assertFalse((self.destination / name).exists())
        self.assertTrue((self.destination / "native/source.cpp").is_file())
        self.assertEqual(self.snapshot(), before)

    def test_same_or_overlapping_targets_are_refused_before_writing(self):
        before = self.snapshot()
        for target in (self.source, self.source / "nested", self.root):
            with self.subTest(target=target):
                with self.assertRaisesRegex(ValueError, "separate"):
                    staging.stage(self.source, target)
        self.assertEqual(self.snapshot(), before)
        self.assertFalse((self.source / "nested").exists())

    def test_existing_target_is_refused_without_overwriting(self):
        self.destination.mkdir()
        marker = self.destination / "keep.txt"
        marker.write_text("original", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "new directory"):
            staging.stage(self.source, self.destination)
        self.assertEqual(marker.read_text(encoding="utf-8"), "original")

    def test_wrong_production_package_is_refused(self):
        (self.source / "manifest.toml").write_bytes(manifest(FIXTURE))
        with self.assertRaisesRegex(ValueError, "production package"):
            staging.stage(self.source, self.destination)
        self.assertFalse(self.destination.exists())

    def test_wrong_app_component_is_refused(self):
        (self.source / "app.json").write_text(json.dumps({"name": FIXTURE + ".main"}), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "production application component"):
            staging.stage(self.source, self.destination)
        self.assertFalse(self.destination.exists())

    def test_wrong_manifest_component_is_refused(self):
        (self.source / "manifest.toml").write_bytes(manifest(component="other.application.main"))
        before = self.snapshot()
        with self.assertRaises(ValueError):
            staging.stage(self.source, self.destination)
        self.assertEqual(self.snapshot(), before)

    def test_wrong_production_config_is_refused(self):
        for index, config in enumerate((
            f"export const BUILD_CONFIG = {{fixtureVault: true, packageId: '{PRODUCTION}'}} as const;",
            f"export const BUILD_CONFIG = {{fixtureVault: false, packageId: '{FIXTURE}'}} as const;",
            f"export const BUILD_CONFIG = {{packageId: '{PRODUCTION}'}} as const;",
        )):
            with self.subTest(config=config):
                self.config.write_text(config, encoding="utf-8")
                destination = self.root / f"invalid-config-{index}"
                with self.assertRaises(ValueError):
                    staging.stage(self.source, destination)
                self.assertFalse(destination.exists())

    def test_comment_cannot_disguise_enabled_fixture_storage_as_production(self):
        self.config.write_text(f"// fixtureVault: false\nexport const BUILD_CONFIG = {{fixtureVault: true, packageId: '{PRODUCTION}'}} as const;\n", encoding="utf-8")
        with self.assertRaises(ValueError):
            staging.stage(self.source, self.destination)
        self.assertFalse(self.destination.exists())

    def test_comment_cannot_disguise_wrong_config_package_identity(self):
        self.config.write_text(f"// {PRODUCTION}\nexport const BUILD_CONFIG = {{fixtureVault: false, packageId: '{FIXTURE}'}} as const;\n", encoding="utf-8")
        with self.assertRaises(ValueError):
            staging.stage(self.source, self.destination)
        self.assertFalse(self.destination.exists())


class PackagedVerificationTests(unittest.TestCase):
    def test_clean_production_architectures_are_accepted_without_hardware_claim(self):
        for target in ("armv7", "aarch64", "x86_64"):
            with self.subTest(target=target):
                result = packages.verify(manifest(), native(target), "production", target)
                self.assertEqual(result["packageId"], PRODUCTION)
                self.assertEqual(result["target"], target)
                self.assertFalse(result["fixtureOnly"])
                self.assertFalse(result["nativeStorageMarker"])
                self.assertFalse(result["hardwareKeystoreVerified"])

    def test_marked_x86_fixture_is_accepted_without_hardware_claim(self):
        result = packages.verify(manifest(FIXTURE), native(marker=True, symbol=True), "fixture", "x86_64")
        self.assertEqual(result["packageId"], FIXTURE)
        self.assertTrue(result["fixtureOnly"])
        self.assertTrue(result["nativeStorageMarker"])
        self.assertFalse(result["hardwareKeystoreVerified"])

    def test_either_or_both_native_markers_are_rejected_in_production(self):
        for marker, symbol in ((True, False), (False, True), (True, True)):
            with self.subTest(marker=marker, symbol=symbol):
                with self.assertRaisesRegex(ValueError, "production package"):
                    packages.verify(manifest(), native(marker=marker, symbol=symbol), "production", "x86_64")

    def test_fixture_requires_both_independent_native_markers(self):
        for marker, symbol in ((True, False), (False, True), (False, False)):
            with self.subTest(marker=marker, symbol=symbol):
                with self.assertRaisesRegex(ValueError, "marked x86_64"):
                    packages.verify(manifest(FIXTURE), native(marker=marker, symbol=symbol), "fixture", "x86_64")

    def test_fixture_storage_is_rejected_on_non_x86_architectures(self):
        for target in ("armv7", "aarch64"):
            with self.subTest(target=target):
                with self.assertRaisesRegex(ValueError, "marked x86_64"):
                    packages.verify(manifest(FIXTURE), native(target, True, True), "fixture", target)

    def test_wrong_binary_architecture_is_rejected_for_every_target(self):
        for target in ("armv7", "aarch64", "x86_64"):
            for binary_target in ("armv7", "aarch64", "x86_64"):
                if target != binary_target:
                    with self.subTest(target=target, binary=binary_target):
                        with self.assertRaisesRegex(ValueError, "architecture"):
                            packages.verify(manifest(), native(binary_target), "production", target)

    def test_production_and_fixture_package_identities_cannot_be_swapped(self):
        for mode, wrong_id in (("production", FIXTURE), ("fixture", PRODUCTION)):
            with self.subTest(mode=mode):
                with self.assertRaisesRegex(ValueError, "package identity"):
                    packages.verify(manifest(wrong_id), native(marker=True, symbol=True), mode, "x86_64")

    def test_component_identity_must_match_the_packaged_variant(self):
        for mode, package in (("production", PRODUCTION), ("fixture", FIXTURE)):
            with self.subTest(mode=mode):
                with self.assertRaisesRegex(ValueError, "component identity"):
                    packages.verify(manifest(package, "other.application.main"), native(marker=True, symbol=True), mode, "x86_64")

    def test_truncated_non_elf_and_wrong_endian_payloads_are_rejected(self):
        wrong_endian = bytearray(native())
        wrong_endian[5] = 2
        for payload in (b"", b"not an ELF library", b"\x7fELF", native()[:19], bytes(wrong_endian)):
            with self.subTest(payload=payload):
                with self.assertRaisesRegex(ValueError, "little-endian native ELF"):
                    packages.verify(manifest(), payload, "production", "x86_64")


if __name__ == "__main__":
    unittest.main()
