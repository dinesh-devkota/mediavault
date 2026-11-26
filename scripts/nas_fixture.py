import argparse
import logging
import shutil
from pathlib import Path

from impacket import smbserver
from impacket.ntlm import compute_lmhash, compute_nthash
from media_library_fixture import add_vega_seek_controls, format_fixtures, library_fixtures


MOVIE_SIZE = 60 * 1024 * 1024


def sparse_file(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as stream:
        stream.truncate(MOVIE_SIZE)


def playable_movie(path: Path) -> None:
    sample = Path(__file__).resolve().parents[1] / "CineVaultTests" / "Fixtures" / "playback.mp4"
    path.parent.mkdir(parents=True, exist_ok=True)
    with sample.open("rb") as source, path.open("wb") as destination:
        shutil.copyfileobj(source, destination)
        free_size = MOVIE_SIZE - destination.tell()
        if free_size < 8:
            raise ValueError("The playback sample is too large for the fixture.")
        destination.write(free_size.to_bytes(4, byteorder="big") + b"free")
        destination.truncate(MOVIE_SIZE)


def playback_fixtures(root: Path) -> None:
    """An isolated share keeps subtitle/episode tests out of scan-count fixtures."""
    folder = root / "TV Shows" / "Fixture Show" / "Season 01"
    for episode in (1, 2, 4):
        basename = f"Fixture Show.S01E{episode:02d}"
        playable_movie(folder / f"{basename}.mp4")
        (folder / f"{basename}.en.srt").write_text(
            "1\n00:00:00,500 --> 00:00:05,000\n"
            f"Episode {episode}: English subtitle.\n\n"
            "2\n00:00:05,500 --> 00:00:11,500\n"
            "The next caption follows a seek.\n", encoding="utf-8")
        (folder / f"{basename}.es.vtt").write_text(
            "WEBVTT\n\n00:00:00.500 --> 00:00:11.500\n"
            f"Episodio {episode}: subtitulo de prueba.\n", encoding="utf-8")
    (folder / "Fixture Show.S01E01.fr.srt").write_text(
        "This is deliberately not a subtitle file.", encoding="utf-8")
    with (folder / "Fixture Show.S01E01.de.srt").open("wb") as oversized:
        oversized.truncate(2 * 1024 * 1024 + 1)
    (folder / "Fixture Show.S01E010.en.srt").write_text(
        "1\n00:00:00,500 --> 00:00:11,500\nWrong episode, never select this.\n",
        encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description="Serve the synthetic MediaVault test library over SMB.")
    parser.add_argument("fixture_directory", type=Path)
    parser.add_argument("--vega-seek-controls", action="store_true",
                        help="Add the stream-copy MP4 beside the original MKV controls fixture.")
    args = parser.parse_args()
    root = args.fixture_directory.resolve()
    feature = root / "Movies" / "Feature (2020)"
    playable_movie(feature / "Feature (2020).mp4")
    (feature / "bytes.bin").write_bytes(b"0123456789")
    sparse_file(root / "Movies" / "Extras" / "Ignored.mp4")
    sparse_file(root / "Movies" / "@eaDir" / "Ignored.mp4")
    (root / "Movies" / "Too Small.mp4").write_bytes(b"small")

    # Small, non-playback fixtures for scanner type detection and exclusion rules.
    checks = root / "MediaChecks"
    checks.mkdir(parents=True, exist_ok=True)
    (checks / "code.ts").write_bytes(b"export const title: string = 'fixture';\n")
    (checks / "types.d.ts").write_bytes(b"declare const title: string;\n")
    packet = bytes([0x47, 0x1F, 0xFF, 0x10]) + bytes(184)
    (checks / "clip.ts").write_bytes(packet * 6)
    (checks / "Keep.mp4").write_bytes(b"scan-fixture-only")
    (checks / "Ignored").mkdir(exist_ok=True)
    (checks / "Ignored" / "Hidden.mp4").write_bytes(b"scan-fixture-only")
    (checks / "node_modules").mkdir(exist_ok=True)
    (checks / "node_modules" / "Not Media.mp4").write_bytes(b"scan-fixture-only")

    # A separate share keeps existing video scan expectations unchanged.
    photo_root = root.with_name(root.name + "-photos")
    trip = photo_root / "Photos" / "Trip"
    family = photo_root / "Photos" / "Family"
    validation = photo_root / "Validation"
    for folder in (trip, family, validation):
        folder.mkdir(parents=True, exist_ok=True)
    samples = Path(__file__).resolve().parents[1] / "CineVaultTests" / "Fixtures" / "Photos"
    for name in ("01.jpg", "02.png", "03.webp"):
        shutil.copyfile(samples / name, trip / name)
    shutil.copyfile(samples / "portrait.jpg", family / "portrait.jpg")
    (trip / "broken.jpg").write_bytes(b"This is a corrupt image fixture, not a photograph.")
    with (validation / "TooLarge.jpg").open("wb") as oversized:
        oversized.truncate(65 * 1024 * 1024)

    playback_root = root.with_name(root.name + "-playback")
    playback_fixtures(playback_root)

    library_root = root.with_name(root.name + "-library")
    library_fixtures(library_root)
    formats_root = root.with_name(root.name + "-formats")
    format_fixtures(formats_root)
    if args.vega_seek_controls:
        add_vega_seek_controls(formats_root)

    logging.basicConfig(level=logging.INFO)
    server = smbserver.SimpleSMBServer(listenAddress="127.0.0.1", listenPort=1445)
    server.addShare("CINEVAULT", str(root), readOnly="yes")
    server.addShare("COVEPHOTOS", str(photo_root), readOnly="yes")
    server.addShare("MEDIAPLAYBACK", str(playback_root), readOnly="yes")
    server.addShare("MEDIALIBRARY", str(library_root), readOnly="yes")
    server.addShare("FORMATPLAYBACK", str(formats_root), readOnly="yes")
    server.setSMB2Support(True)
    server.addCredential("cinevault", 0, compute_lmhash("fixture-only"), compute_nthash("fixture-only"))
    server.start()


if __name__ == "__main__":
    main()
