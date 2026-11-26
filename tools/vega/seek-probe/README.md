# Isolated native seek diagnostic

This separate application tests the Vega 2.0.15159 W3C media player without MediaVault's source adapter, HTTP relay, media session, or remote handlers. It never accesses a household device, credentials, or media. Its package is `com.dineshdevkota.mediavault.seekprobe`; the runner refuses physical devices and runs only in GitHub Actions.

The shared fixture generator creates the existing 60-second `Controls.mkv` (H.264 video, two AAC audio tracks). A stream-copy remux creates `Controls.mp4`. Before testing, ffprobe must prove that every coded packet of each track is identical across containers. File hashes, codec/format metadata, generator and source hashes, and the exact ffmpeg version are retained. The shared generator is unchanged.

Stock nginx serves these two files through a loopback reverse port. Preflight checks require correct HEAD length/type and byte-exact initial, middle, and suffix 206 responses. Access logs contain only numbers: time, fixture (1 MKV / 2 MP4), case (1–4 in the order below), method (1 GET / 2 HEAD), status, body bytes, requested range start/end, and returned range start/end/total. `-1` means an absent range component; a suffix request has no start. Preflight requests have case 0. Requests never log URLs or arbitrary headers.

The runner attaches Appium, launches the installed component once with the Vega CLI, and verifies its static banner before pressing Start. A startup failure retains the device hierarchy and bounded native startup log. The playback matrix begins only after the probe accepts Start.

Each case initializes a fresh native player and attaches a fresh surface:

1. MKV, paused after decoding begins.
2. MKV, playing.
3. MP4, paused after decoding begins.
4. MP4, playing.

Each case directly sets `currentTime` to 31 and 11 seconds. A pass requires the actual clock to reach and retain the target with seeking complete; playing cases must subsequently advance, and paused cases must remain paused and later resume. A `seeked` event alone is insufficient: the observed failing application run emitted that event after native error 50004. If the forward seek fails, the backward attempt is explicitly skipped: otherwise natural playback could reach 11 seconds and impersonate a successful seek. Ordinary case failures are recorded and the remaining fresh-player cases continue. Failed or timed-out native teardown stops the matrix because subsequent players could no longer be considered isolated. Incomplete cases or any failure make the diagnostic fail; no fallback or lowered assertion makes it green.

Build with the existing application lock and SDK:

```sh
cd vega && npm ci && cd ..
bash tools/vega/seek-probe/build.sh
xvfb-run -a bash tools/vega/run-seek-probe.sh .artifacts/vega-seek-probe/MediaVault-SEEK-PROBE-x86_64.vpkg
```

The runner also needs ffmpeg/ffprobe, nginx, Python 3.11+, curl, Appium and its pinned Kepler driver, and the virtual-device system dependencies used by the existing workflow. No pip package is required. Output is retained under `.artifacts/vega-seek-probe/`, including the standalone package, build provenance, fixture hashes, HTTP preflight, per-case samples/events/failures, paired screenshots/hierarchy, stock-server request telemetry, and bounded native logs.

Build provenance reuses the official SDK 2.0.15159 React Native template source hashes recorded by the render probe. Direct dependencies resolve against `vega/package-lock.json`. The isolated dependency view omits only the unused `@mediavault/native` module; the three declared SDK media packages remain present. Before building and on the packaged assets, the installer package stays separate and the React Native registration must match the launch component. The final VPKG is also checked for the absence of `libMediaVaultNative` and `libsmb2`.

Interpret this as a controlled virtual-device diagnosis, not physical Fire TV certification. MKV versus MP4 isolates the container with identical coded tracks; paused versus playing isolates player state. A failure on stock nginx demonstrates that the custom relay is not required for that failure. A successful stock case does not by itself prove a relay bug. Compare native errors, actual clock samples, and observed range requests with the separate application journey before choosing a product change.
