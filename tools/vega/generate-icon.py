#!/usr/bin/env python3
"""Render the existing MediaVault mark at Amazon's required icon size."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from generate_app_icons import ACCENT, background_row, play_spans, write_png

size = 512
background = background_row(size, size)


def row(y):
    pixels = bytearray(background(y))
    # Vega crops the square icon to 16:9 when sideloaded. Keep the existing mark
    # inside the central 512x288 band so it remains whole in both places.
    for start, end in play_spans(size, 288, y - 112):
        pixels[start * 3:end * 3] = bytes(ACCENT) * (end - start)
    return bytes(pixels)


if __name__ == "__main__":
    destination = ROOT / "vega" / "assets" / "image" / "mediavault.png"
    write_png(str(destination), size, size, row, False)
    print(destination)
