#!/usr/bin/env python3
"""Create an isolated, visibly marked VVD fixture tree. Never edit the release tree."""
import argparse
import json
from pathlib import Path
import re
import shutil
try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib  # Ubuntu 22.04 SDK hosts use Python 3.10.

PRODUCTION_ID = "com.dineshdevkota.cinevault"
FIXTURE_ID = "com.dineshdevkota.mediavault.vvdfixture"


def validate_production(source: Path) -> tuple[str, dict]:
    manifest = (source / "manifest.toml").read_text(encoding="utf-8")
    parsed = tomllib.loads(manifest)
    if parsed["package"]["id"] != PRODUCTION_ID:
        raise ValueError("Expected the unchanged production package identity.")
    if parsed["components"]["interactive"][0]["id"] != PRODUCTION_ID + ".main":
        raise ValueError("Expected the production manifest component.")
    app = json.loads((source / "app.json").read_text(encoding="utf-8"))
    if app["name"] != PRODUCTION_ID + ".main":
        raise ValueError("Expected the production application component.")
    config = (source / "src/generated/buildConfig.ts").read_text(encoding="utf-8")
    # This is a deliberately fixed generated schema, not arbitrary TypeScript.
    # Strip whole comment lines only; a comment must never disguise true or a
    # different identity in the actual exported object.
    config = re.sub(r"(?m)^\s*//[^\n]*$", "", config)
    schema = (r"\s*export\s+const\s+BUILD_CONFIG\s*=\s*\{\s*fixtureVault\s*:\s*false\s*,\s*"
              r"packageId\s*:\s*(['\"])" + re.escape(PRODUCTION_ID) + r"\1\s*,?\s*\}\s+as\s+const\s*;\s*")
    if not re.fullmatch(schema, config):
        raise ValueError("Production must not have simulator storage enabled.")
    return manifest, app


def stage(source: Path, destination: Path) -> Path:
    source = source.resolve()
    destination = destination.resolve()
    if source == destination or source in destination.parents or destination in source.parents:
        raise ValueError("Fixture staging must be separate from the source application.")
    if destination.exists():
        raise ValueError("Fixture staging must use a new directory.")
    manifest, app = validate_production(source)
    shutil.copytree(source, destination, ignore=shutil.ignore_patterns(
        "node_modules", "build", "dist", ".git", ".artifacts", "__pycache__",
        ".env", ".env.*", "*.bak", "*.tsbuildinfo", "buildinfo.json",
        "CMakeUserPresets.json", "kepler-library-manifest.json"))
    manifest = manifest.replace(f'id = "{PRODUCTION_ID}"', f'id = "{FIXTURE_ID}"', 1)
    manifest = manifest.replace(f'id = "{PRODUCTION_ID}.main"', f'id = "{FIXTURE_ID}.main"', 1)
    manifest = manifest.replace('title = "MediaVault"', 'title = "MediaVault Simulator Test"', 1)
    parsed = tomllib.loads(manifest)
    if parsed["package"]["id"] != FIXTURE_ID or parsed["components"]["interactive"][0]["id"] != FIXTURE_ID + ".main":
        raise ValueError("Could not produce the isolated fixture identity.")
    (destination / "manifest.toml").write_text(manifest, encoding="utf-8", newline="\n")
    app.update(name=FIXTURE_ID + ".main", displayName="MediaVault Simulator Test")
    (destination / "app.json").write_text(json.dumps(app, indent=2) + "\n", encoding="utf-8", newline="\n")
    (destination / "src/generated/buildConfig.ts").write_text(
        "// Generated only in an isolated Debug/x86_64 simulator fixture tree.\n"
        f"export const BUILD_CONFIG = {{fixtureVault: true, packageId: '{FIXTURE_ID}'}} as const;\n",
        encoding="utf-8", newline="\n")
    return destination


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path, nargs="?")
    parser.add_argument("--check-production", action="store_true")
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[2] / "vega"
    if args.check_production:
        validate_production(source)
        print("Production package and bundled configuration verified.")
    elif args.destination:
        print(stage(source, args.destination))
    else:
        parser.error("Pass a staging destination or --check-production.")
