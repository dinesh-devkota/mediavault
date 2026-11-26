"""Prepare synthetic controls without changing the shared fixture generator."""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
repo = Path(__file__).resolve().parents[3]
output = Path(sys.argv[1]).resolve()
media = output / "media"
media.mkdir(parents=True, exist_ok=True)
generator = repo / "scripts/media_library_fixture.py"
spec = importlib.util.spec_from_file_location("seek_probe_shared_fixture", generator)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.format_fixtures(media)
mkv, mp4 = media / "Controls.mkv", media / "Controls.mp4"
subprocess.run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                "-i", str(mkv), "-map", "0", "-c", "copy", "-movflags", "+faststart", str(mp4)],
               check=True, timeout=60)


def inspect(path):
    details = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)], timeout=30))
    packets = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-show_packets", "-show_entries", "packet=stream_index,data_hash,size",
        "-show_data_hash", "sha256", "-of", "json", str(path)], timeout=30))["packets"]
    tracks = {}
    for packet in packets:
        assert packet.get("data_hash", "").startswith("SHA256:"), "Missing coded-packet hash"
        tracks.setdefault(packet["stream_index"], []).append((packet["size"], packet["data_hash"]))
    return details, tracks


source_info, source_tracks = inspect(mkv)
copy_info, copy_tracks = inspect(mp4)
assert source_tracks == copy_tracks, "The MP4 must preserve every coded packet of all three tracks"
assert len(source_tracks) == 3, "Expected one video and two audio tracks"
assert [s["codec_name"] for s in source_info["streams"]] == ["h264", "aac", "aac"]
assert [s["codec_name"] for s in copy_info["streams"]] == ["h264", "aac", "aac"]
assert 59 <= float(source_info["format"]["duration"]) <= 61
assert 59 <= float(copy_info["format"]["duration"]) <= 61
report = {
    "syntheticOnly": True,
    "sharedGeneratorSha256": hashlib.sha256(generator.read_bytes()).hexdigest(),
    "sourceVideoSha256": hashlib.sha256((repo / "CineVaultTests/Fixtures/playback.mp4").read_bytes()).hexdigest(),
    "ffmpegVersion": subprocess.check_output(["ffmpeg", "-version"], text=True).splitlines()[0],
    "remux": "ffmpeg -i Controls.mkv -map 0 -c copy -movflags +faststart Controls.mp4",
    "codedPacketsIdentical": True,
    "tracks": [{"index": index, "packets": len(values),
                "codedPacketSequenceSha256": hashlib.sha256(json.dumps(values).encode()).hexdigest()}
               for index, values in source_tracks.items()],
    "files": [{"name": path.name, "bytes": path.stat().st_size,
               "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "ffprobe": details}
              for path, details in [(mkv, source_info), (mp4, copy_info)]],
}
(output / "fixture-provenance.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({"codedPacketsIdentical": True, "files": [f["name"] for f in report["files"]]}))
