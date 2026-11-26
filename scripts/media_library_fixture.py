"""Read-only synthetic library for local metadata, versions and playback tests."""

import shutil
import subprocess
from pathlib import Path


SAMPLES = Path(__file__).resolve().parents[1] / "CineVaultTests" / "Fixtures"


def library_fixtures(root: Path) -> None:
    movies = [
        ("Library Feature (2020)", "Library Feature (2020)", "Library Feature", 2020, 910001, "Theatrical"),
        ("Library Feature (2020)", "Library Feature (2020) - Directors Cut", "Library Feature", 2020, 910001, "Directors Cut"),
        ("Library Sequel (2022)", "Library Sequel (2022)", "Library Sequel", 2022, 910002, "Theatrical"),
    ]
    for directory, stem, title, year, identifier, edition in movies:
        folder = root / "Movies" / directory
        folder.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(SAMPLES / "playback.mp4", folder / f"{stem}.mp4")
        (folder / f"{stem}.nfo").write_text(
            f"""<?xml version="1.0" encoding="utf-8"?>
<movie><title>{title}</title><year>{year}</year>
<plot>Local details from the fixture NAS, available without a metadata key.</plot>
<tagline>Library fixture</tagline><genre>Adventure</genre><genre>Family</genre>
<mpaa>PG</mpaa><runtime>1</runtime><uniqueid type="tmdb" default="true">{identifier}</uniqueid>
<set><name>Library Saga</name><overview>A locally named franchise.</overview></set>
<edition>{edition}</edition></movie>
""", encoding="utf-8")
        shutil.copyfile(SAMPLES / "Photos" / "02.png", folder / f"{stem}-poster.png")
        shutil.copyfile(SAMPLES / "Photos" / "01.jpg", folder / f"{stem}-fanart.jpg")

    series = root / "TV Shows" / "Library Show"
    season = series / "Season 01"
    season.mkdir(parents=True, exist_ok=True)
    (series / "tvshow.nfo").write_text(
        '<tvshow><title>Library Show</title><plot>A local series.</plot>'
        '<mpaa>TV-G</mpaa><genre>Family</genre>'
        '<uniqueid type="tmdb">920001</uniqueid></tvshow>', encoding="utf-8")
    shutil.copyfile(SAMPLES / "Photos" / "02.png", series / "poster.png")
    shutil.copyfile(SAMPLES / "Photos" / "01.jpg", series / "fanart.jpg")
    shutil.copyfile(SAMPLES / "Photos" / "02.png", series / "season01-poster.png")
    shutil.copyfile(SAMPLES / "Photos" / "02.png", season / "poster.png")
    episode = "Library Show.S01E01"
    shutil.copyfile(SAMPLES / "playback.mp4", season / f"{episode}.mp4")
    (season / f"{episode}.nfo").write_text(
        '<episodedetails><title>The Local Episode</title><showtitle>Library Show</showtitle>'
        '<season>1</season><episode>1</episode><plot>Episode details from NFO.</plot>'
        '<mpaa>TV-G</mpaa><year>2021</year></episodedetails>', encoding="utf-8")
    shutil.copyfile(SAMPLES / "Photos" / "01.jpg", season / f"{episode}.jpg")

    # A photograph named poster must remain visible when there is no companion video.
    photos = root / "Photos"
    photos.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(SAMPLES / "Photos" / "02.png", photos / "poster.png")

    invalid = root / "Invalid"
    invalid.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(SAMPLES / "playback.mp4", invalid / "Invalid Metadata.mp4")
    (invalid / "Invalid Metadata.nfo").write_text(
        '<!DOCTYPE movie [<!ENTITY leak SYSTEM "file:///etc/passwd">]>'
        '<movie><title>&leak;</title></movie>', encoding="utf-8")


def format_fixtures(root: Path) -> None:
    root.mkdir(parents=True, exist_ok=True)
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise RuntimeError("The playback fixture requires ffmpeg. Install it before starting the test NAS.")
    configurations = [
        ("Feature.mkv", ["-c:v", "copy", "-c:a", "aac"]),
        ("Feature.avi", ["-c:v", "mpeg4", "-q:v", "8", "-c:a", "libmp3lame"]),
        ("Feature.webm", ["-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8", "-c:a", "libopus"]),
    ]
    for name, codecs in configurations:
        subprocess.run([ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                        "-i", str(SAMPLES / "playback.mp4"),
                        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=12",
                        "-map", "0:v:0", "-map", "1:a:0", "-t", "12",
                        *codecs, str(root / name)],
                       check=True, timeout=60)
    (root / "Feature.en.srt").write_text(
        "1\n00:00:00,500 --> 00:00:05,000\nA subtitle for the broader player.\n\n"
        "2\n00:00:05,500 --> 00:00:11,500\nA caption after seeking.\n", encoding="utf-8")
    # A longer clip leaves time to exercise actual phone/remote controls. The
    # audio tracks are synthetic test signals, tagged for selection. The source
    # MP4 contains video only; audio must be generated rather than copied.
    subprocess.run([
        ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
        "-stream_loop", "-1", "-i", str(SAMPLES / "playback.mp4"),
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=60",
        "-f", "lavfi", "-i", "sine=frequency=660:sample_rate=48000:duration=60", "-t", "60",
        "-map", "0:v:0", "-map", "1:a:0", "-map", "2:a:0", "-c:v", "copy", "-c:a", "aac",
        "-metadata:s:a:0", "language=eng", "-metadata:s:a:0", "title=English fixture",
        "-metadata:s:a:1", "language=spa", "-metadata:s:a:1", "title=Spanish fixture",
        str(root / "Controls.mkv"),
    ], check=True, timeout=60)
    (root / "Controls.en.srt").write_text(
        "1\n00:00:01,000 --> 00:00:50,000\nLocal subtitle controls fixture.\n", encoding="utf-8")


def add_vega_seek_controls(root: Path) -> None:
    """Give the Vega seek fixture the same coded media in a separate MP4 title."""
    subprocess.run([
        "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error",
        "-i", str(root / "Controls.mkv"), "-map", "0", "-c", "copy",
        "-movflags", "+faststart", str(root / "Seek Controls.mp4"),
    ], check=True, timeout=60)
    shutil.copyfile(root / "Controls.en.srt", root / "Seek Controls.en.srt")
