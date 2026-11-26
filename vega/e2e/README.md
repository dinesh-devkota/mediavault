# Vega device checks

`library-journey.mjs` uses one real Appium session and Amazon's documented Vega automation endpoints. Run it only against a fresh disposable installation with synthetic media. `MEDIA_VAULT_E2E_FIXTURE_ONLY=1` is mandatory in every mode; it does not alter app behavior or credential storage.

## Production startup probe

Set `MEDIA_VAULT_E2E_STARTUP_CHECK_ONLY=1` and `MEDIA_VAULT_E2E_PACKAGE_ID=com.dineshdevkota.cinevault`, then run `node vega/e2e/library-journey.mjs`. No NAS endpoint is required. A fixture package ID is rejected before starting a session.

The probe requires the fixture banner to be absent. It accepts exactly two observed outcomes:

- The fresh production app reaches the home library, reporting `native-storage-available`. This proves startup availability only, not PIN writes, restart protection, or saved credentials.
- The app displays the exact `MV06:not-supported` error, exposes no home library, and offers an enabled Retry action. This reports `unsupported-on-virtual-device` and `hardwareRequired: true`.

Any other error, exposed home behind a storage error, disabled Retry, fixture banner, or timeout fails. The probe captures a screenshot and UI tree, runs no NAS journeys, and never marks secure-storage persistence verified. The caller terminates this production app before installing and launching the isolated fixture package.

## Library journeys

Leave `MEDIA_VAULT_E2E_STARTUP_CHECK_ONLY` unset. Set `MEDIA_VAULT_E2E_NAS_ENDPOINT` to the synthetic, device-accessible `smb://.../MEDIALIBRARY` share. The workflow forwards its loopback NAS explicitly.

`MEDIA_VAULT_E2E_PACKAGE_ID` defaults to production. For the isolated Debug/x86_64 virtual-device build, explicitly set it to `com.dineshdevkota.mediavault.vvdfixture`. The runner verifies the persistent visible fixture banner before scanning. Journeys 01–09 exercise real NAS, metadata, library, photo, playback, continuous TV, and in-session profile/PIN behavior. Journey 10 is recorded as a hardware-required skip with `passed: null`; synthetic in-memory credentials cannot verify the production keystore or restart persistence. A missing/mismatched fixture banner fails and records that check as not run.

Journey 01 first observes native focus on the empty library's Add source action,
opens its form with Select, then uses hardware Back and requires that action's
native focus again. These checks precede any focus-setting navigation helper.
Journey 02 observes the scanned library's first poster focus, moves Right twice
to the non-first Library Sequel poster, verifies native focus at each move,
opens its detail with Select, and uses hardware Back. The same sequel must
regain native focus before normal helpers resume. These added flows use only
arrow/Select/Back input; they do not call setFocus or scroll commands. They
verify this visible-row route, not restoration of an off-screen poster.

Home route checks use the exposed section/search toolbar controls and require
the prior form/detail marker to disappear. The native publisher omits the
FlatList container's testID, so it is not a route or privacy predicate.
Secure-storage, failed-PIN and locked-restart checks require every exposed Home
toolbar/source action and every poster group to be absent.

Collection return waits for Done selecting, the exact three-file count, both
selected poster descriptions, and absence of the collection form before the
final exact count and group assertions.
Profile collection isolation waits for the destination collections heading and
form before checking that another profile's collection is absent. These waits
acknowledge rendered route state; they do not insert fixed delays.

Journey `06-mp4-remote-playback` requires native focus on the ready player's
Pause control before any helper can assign it. It uses `Seek Controls.mp4`,
a fast-start stream copy of the original H.264 video and both AAC tracks from
`Controls.mkv`. The same English sidecar must stay selected through the seeks.
One remote press must move the native clock 10 seconds in each direction. The
Forward 30 and Back 10 controls must move it 30 and 10 seconds respectively.
Each action requires one matching accepted native request, a paused clock within
two seconds of the requested time, and both seek controls enabled again. The
harness rechecks native focus before each press and retains dispatch times and
numeric outcomes in `mp4-seek-actions.json`. The clock must stay stopped while
paused and advance after resuming.
Journey 07 still uses the separate MP4 episodes for captions and autoplay.

Journey `06-mkv-seek-constraint` opens the original MKV and requires the
decoder to advance. The pinned Vega virtual device rejects its in-range
seek with native code 50004. The app must warn about that seek, keep its
actual paused position, continue decoding on Play, and reopen without
requesting the failed target as its saved position. A future SDK can pass
with successful MKV seeking when native acceptance and the paused target
clock agree. The independent stock seek probe still runs the original
paused and playing cases for both containers.
[Stock probe evidence](https://github.com/dinesh-devkota/mediavault/actions/runs/45781527800)

On a production installation, journey 10 additionally restarts the app, unlocks with the saved PIN, and rescans using saved NAS credentials. Physical Vega hardware is required when the virtual device lacks the native secure-storage service.

## Environment and evidence

- `APPIUM_URL`: defaults to `http://127.0.0.1:4723`.
- `VEGA_DEVICE`: defaults to `vda://default`.
- `MEDIA_VAULT_E2E_OUTPUT` uses different evidence directories for the production probe and fixture journeys.
- `MEDIA_VAULT_E2E_NATIVE_LOG` points to the live, package-filtered decoder log during the full fixture journey. The virtual-device runner supplies it automatically. When setting up a separate disposable device, start the synthetic NAS with `--vega-seek-controls` and collect the app's live native log before starting the journey.
- App component: the explicitly selected package ID plus `.main`.

`results.json` records `mode`, `packageId`, `buildKind`, `executedOnDevice`, `fixtureBannerVerified`, `startupProbe`, `libraryJourneyCount`, `secureStorageVerification`, and per-step `results`. A successful probe has one `production-startup-probe` result and zero library journeys. `startupProbe` describes the observed availability/error outcome. `secureStorageVerification` remains `not-verified` unless the full production journey 10 passes. A supported startup outcome alone must not be reported as secure-storage verification.

Screenshots and UI trees are omitted while protected input fields are present. The runner uses only synthetic credentials and redacts those values from its own error results. Appium server logging must also redact request bodies or use a safe log level.

The system keyboard is also treated as protected entry. Only an allowlisted
layout/focus snapshot is retained in that state; text, descriptions and pixel
captures are omitted. Amazon's pinned driver prints raw RPC parameters outside
Appium's logger, so the workflow discards its console output and retains only the
filtered warning log. App-specific stored native logs are collected after the
journeys, with a 2 MiB result cap and 15-second query deadline per app. LoggingCtl
must start after installation to obtain access to the newly installed packages.

Form entry targets the actual editable child of React Native's focus wrapper.
After text acknowledgement, the harness waits for Done and a positively
visible Silverstone keyboard window, retains that window's ID, then sends
exactly one Back key (158). Temporary publisher absence cannot skip Back.
Closure requires valid native visibility for that same window to become false
and the Silverstone Done control to disappear within 30 seconds. The driver's
displayed endpoint converts a missing result to false. The fixture runner makes
the read-only `visibilityOf` query on a separate loopback VDA forward with a
two-second request deadline so a stalled read cannot occupy Appium's session
queue. Unsupported, stale, malformed, or timed-out replies remain unknown.
The harness requires the same form field to remain and verifies that
non-secret text stays unchanged. Password and PIN
values are never read back. [Amazon's Vega 2.0 release notes](https://developer.amazon.com/docs/vega/2.0/vega-release-notes#textinput-done-and-back-behavior-will-match-stock-react-native)
document Back as keyboard dismissal; these controlled fields store edits through
`onChangeText`, so dismissal does not depend on a submit callback. This does not
claim that the system Done key passed its focus check.

The fixture retains a bounded `input-focus-diagnostic.json` trace for name and
address dismissal and the first three username-reveal navigation keys. It
records timestamps, the original window ID, scoped Done observations and request
durations from the validation itself. It makes no extra UI queries and retains
no editor text, descriptions, raw hierarchy or images.

The harness still uses bounded D-pad navigation to reveal off-screen controls
and requires actual native focus before selecting application buttons. Text
acknowledgement uses the actual editor, not the wrapper's empty `getText` result.
Category changes open the Home section chooser, select the desired section,
and return to the library through the same remote actions available to users.
For a nonsecret replacement, the harness requires the expected old value and
native editor focus. It then confirms a displayed keyboard window and exactly
one visible Clear control scoped to the keyboard app. The keyboard accepted
direct focus requests without moving focus, so its dedicated helper uses real
arrows from the observed key bounds instead. It requires exactly one natively
focused key, verified movement after each arrow, and native focus on visible,
enabled Clear before Select. Missing/unknown visibility, ambiguous focus, no
movement or a repeated navigation edge fails within the 25-second bound.
Application-button focus checks remain unchanged. Nonsecret replacement then
requires an empty editor before sending the new value. The pinned driver's clear/setText('') path
left the previous value unchanged on the device. The final exact-value assertion
remains. `input-replacement-diagnostic.json` records only lengths/comparison
flags at those three phases; password/PIN contents are never read or recorded.
Protected replacements use the same focused Clear action and write without text
readback or replacement diagnostics; the PIN-unlock/source journey must verify
the new credential through actual behavior.

The Debug fixture can show the SDK's focus-stealing development LogBox. The
harness dismisses only its exact observed "Open debugger to view warnings."
overlay, within the fixture app, using the visible Dismiss control. The number
is recorded in `fixtureWarningsDismissed`. Production startup and application
errors are never dismissed by this helper. An observed same-app LogBox
`Uncaught Error` heading fails immediately before navigation and before a
journey can be marked passed, even if app controls remain queryable behind it.
The guard records a static error rather than reading the error body.

## Harness contract tests

Run `node --test vega/e2e/*.test.mjs`. These tests provide a local simulated Appium transport to check accepted/rejected startup states and report fields. They do not execute the app, emulate native storage, or count as device evidence.

The keyboard transport contracts exercise directional Clear activation when direct focus is ineffective, and reject stale/no movement, ambiguous native focus, keyboard disappearance, and unknown visibility. These contracts never read editor text and are not device evidence.
