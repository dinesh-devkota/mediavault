# Isolated Vega paint diagnostic

This manual diagnostic investigates missing rounded control backgrounds, focus borders, and image pixels observed in Vega SDK 2.0.15159. It has a separate package identity, synthetic bundled artwork, no accounts, network calls, MediaVault native module, navigation, or focus guide. It is never part of normal application builds.

The entry point, Babel config, and Metro config are copied exactly from the official SDK template; `provenance.json` records their hashes with LF line endings, matching committed Git blobs and Linux checkout. The entry retains the template's LogBox handling. Keep native logs: hiding an overlay does not establish that runtime errors are absent. `build.sh` verifies the installed direct dependencies against the application's existing lockfile, creates a symlink view of that installation in a Linux temporary stage (excluding unrequested native turbomodules that the SDK would otherwise autolink), and adds only its real directory to the template Metro watch folders. No dependencies are re-resolved.

The single screen compares object/array styles, square/rounded Views, a rounded clipping parent, the same bundled PNG outside/inside that parent, and rounded/square focus controls. All swatches share one color. The PNG is the exact four-color fixture used for NAS posters. Labels sit outside the measured paint areas.

Build after installing the repository's pinned SDK and running `npm ci` in `vega`:

```sh
bash tools/vega/render-probe/build.sh
```

Output: `.artifacts/vega-render-probe/MediaVault-RENDER-PROBE-x86_64.vpkg`, manifest, contents, package digest, and dependency/template provenance. The build does not start a device.

The isolated runtime wrapper must verify a fresh simulated x86_64 virtual device, launch `com.dineshdevkota.mediavault.renderprobe.main`, and run a local Appium server before:

```sh
GITHUB_ACTIONS=true PROBE_DEVICE_INFO=/path/to/device.json \
  PROBE_OUTPUT=.artifacts/vega-render-probe/runtime \
  node tools/vega/render-probe/render-probe.mjs
python3 tools/vega/render-probe/analyze-pixels.py .artifacts/vega-render-probe/runtime
```

The analyzer needs Pillow. The harness verifies the fixed diagnostic banner and bundled-image load events, saves paired PNG/XML observations, requests native focus on the rounded control, then moves Right to the square control. Native focus and React callback state must agree. No selection, account entry, or production app is involved. It reports `captured`, not a visual pass; the pixel report records expected-color fractions in interior regions without changing screenshots. A missing render path is evidence to investigate, not a reason to weaken the application journey.

Compare round versus square and object versus array before changing product styles. Compare image pixels with native load events; neither alone proves the other. Paired captures expose stale buffers. The current single-session graphics mode is retained explicitly by the runner; a prior identical-package OpenGL comparison already failed to resolve the symptom.

References: [Vega View style props](https://developer.amazon.com/docs/react-native-vega/0.83/view-style-props), [input and focus styling](https://developer.amazon.com/docs/react-native-vega/0.83/handling-touches), [Appium commands](https://developer.amazon.com/docs/vega/2.0/appium-commands).
