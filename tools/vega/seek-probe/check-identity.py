#!/usr/bin/env python3
"""Verify the install, launch, and React Native registration identities."""
import argparse
import json
from pathlib import Path
import tomllib


def verify(package_id: str, manifest: Path, app_config: Path) -> None:
    declaration = tomllib.loads(manifest.read_text(encoding="utf-8"))
    if declaration["package"]["id"] != package_id:
        raise ValueError(f"Expected install package {package_id}.")
    expected_component = package_id + ".main"
    components = declaration["components"]["interactive"]
    if [component["id"] for component in components] != [expected_component]:
        raise ValueError(f"Expected one launch component, {expected_component}.")
    registered = json.loads(app_config.read_text(encoding="utf-8"))["name"]
    if registered != expected_component:
        raise ValueError(f"app.json name {registered!r} must match launch component {expected_component!r}.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package_id")
    parser.add_argument("manifest", type=Path)
    parser.add_argument("app_config", type=Path)
    args = parser.parse_args()
    try:
        verify(args.package_id, args.manifest, args.app_config)
    except (KeyError, OSError, TypeError, ValueError) as error:
        parser.exit(1, f"Vega seek probe identity: {error}\n")
