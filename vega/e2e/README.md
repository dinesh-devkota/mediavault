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

On a production installation, journey 10 additionally restarts the app, unlocks with the saved PIN, and rescans using saved NAS credentials. Physical Vega hardware is required when the virtual device lacks the native secure-storage service.

## Environment and evidence

- `APPIUM_URL`: defaults to `http://127.0.0.1:4723`.
- `VEGA_DEVICE`: defaults to `vda://default`.
- `MEDIA_VAULT_E2E_OUTPUT`: evidence directory; use different directories for the production probe and fixture journeys.
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
After text acknowledgement, the harness dismisses an observed system keyboard
with exactly one Back key (158). It checks closure using the observed Done
control's disappearance, requires the same form field to remain, and verifies
that non-secret text stays unchanged. Window removal is not asserted because a
hidden keyboard window may persist. Password and PIN values are never read back. [Amazon's Vega 2.0 release notes](https://developer.amazon.com/docs/vega/2.0/vega-release-notes#textinput-done-and-back-behavior-will-match-stock-react-native)
document Back as keyboard dismissal; these controlled fields store edits through
`onChangeText`, so dismissal does not depend on a submit callback. This does not
claim that the system Done key passed its focus check.

The harness still uses bounded D-pad navigation to reveal off-screen controls
and requires actual native focus before selecting application buttons. Text
acknowledgement uses the actual editor, not the wrapper's empty `getText` result.

The Debug fixture can show the SDK's focus-stealing development LogBox. The
harness dismisses only its exact observed "Open debugger to view warnings."
overlay, within the fixture app, using the visible Dismiss control. The number
is recorded in `fixtureWarningsDismissed`. Production startup and application
errors are never dismissed by this helper.

## Harness contract tests

Run `node --test vega/e2e/startup-probe.test.mjs`. These tests provide a local simulated Appium transport to check accepted/rejected startup states and report fields. They do not execute the app, emulate native storage, or count as device evidence.
