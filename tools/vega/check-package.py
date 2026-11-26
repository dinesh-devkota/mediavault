#!/usr/bin/env python3
"""Check the actual packaged identity, architecture and fixture-storage marker."""
import argparse
import json
from pathlib import Path
import struct
try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib  # Ubuntu 22.04 SDK hosts use Python 3.10.

PRODUCTION_ID = "com.dineshdevkota.cinevault"
FIXTURE_ID = "com.dineshdevkota.mediavault.vvdfixture"
MARKER = b"MEDIAVAULT_VVD_FIXTURE_ONLY_V1"
SYMBOL = b"mediaVaultVVDFixtureOnly"


def verify(manifest: bytes, native: bytes, mode: str, target: str) -> dict:
    data = tomllib.loads(manifest.decode("utf-8"))
    expected_id = FIXTURE_ID if mode == "fixture" else PRODUCTION_ID
    if data["package"]["id"] != expected_id:
        raise ValueError("Unexpected package identity.")
    if data["components"]["interactive"][0]["id"] != expected_id + ".main":
        raise ValueError("Unexpected application component identity.")
    cleartext = data.get("network-traffic-policy", {}).get("cleartext", {})
    if cleartext.get("allowed-domains") != ["127.0.0.1"] or cleartext.get("blocked-domains"):
        raise ValueError("Native playback must allow only its loopback media relay over HTTP.")
    if native[:4] != b"\x7fELF" or len(native) < 20 or native[5] != 1:
        raise ValueError("Expected a little-endian native ELF library.")
    if struct.unpack_from("<H", native, 18)[0] != {"armv7": 40, "aarch64": 183, "x86_64": 62}[target]:
        raise ValueError("Packaged native architecture does not match its target.")
    markers = (MARKER in native, SYMBOL in native)
    if mode == "fixture":
        if target != "x86_64" or not all(markers):
            raise ValueError("The simulator package must contain the marked x86_64 fixture storage.")
    elif any(markers):
        raise ValueError("Simulator-only storage was found in a production package.")
    return {"packageId": expected_id, "target": target, "fixtureOnly": mode == "fixture",
            "nativeStorageMarker": all(markers), "cleartextDomains": ["127.0.0.1"],
            "hardwareKeystoreVerified": False}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("production", "fixture"))
    parser.add_argument("target", choices=("armv7", "aarch64", "x86_64"))
    parser.add_argument("manifest", type=Path)
    parser.add_argument("native", type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.manifest.read_bytes(), args.native.read_bytes(), args.mode, args.target), indent=2))
