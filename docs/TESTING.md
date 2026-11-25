# Validation and regression coverage

Run the portable tests and Android build checks from the repository checkout:

```bash
swift test --package-path Packages/CineVaultCore
python3 -B -m unittest discover -s scripts/tests -p 'test_commercial_*.py'
cd android
./gradlew --no-daemon --max-workers=4 :core:test :app:testDebugUnitTest \
  :app:lintDebug :app:assembleDebug :app:lintRelease :app:assembleRelease :app:bundleRelease
```

The managed Linux environment has cache and tool activation instructions in
[CLOUD-DEVELOPMENT.md](CLOUD-DEVELOPMENT.md); use its Swift wrapper there.

## Tests requiring an Android runtime

`android/app/src/androidTest` runs against actual Android APIs. It covers:

- D-pad access to all five tabs, Back navigation, and activity recreation.
- Watchlist actions and saved source/genre/decade filters using the remote, including source deletion fallback.
- Android Keystore encryption, unique nonces, and corrupt credential errors.
- Room foreign-key deletion and metadata updates preserving manual titles and progress.
- File-backed Room v1-to-v2 migration preserving existing library data and encrypted credentials; Watchlist persistence through updates and reopening.
- Delayed metadata responses racing with manual matches and resets.
- NAS source edits/deletion while a scan is suspended.
- Media3 DataSource byte-range/EOF behavior and cleanup after a failed open.
- Authenticated SMB scans, range reads, bad credentials, and reconnection.
- Media3 playback over SMB, with rendered frames, advancing video, and resumed playback after seeking.
- Matching SRT/WebVTT sidecars, invalid/oversized caption rejection, subtitle language/Off persistence, and continuous-episode countdown cancellation/transition against the separate MEDIAPLAYBACK share.

The `Android TV` workflow uses an Android TV API 36 x86_64 emulator
and a synthetic SMB share. The fixture has no access to a user's NAS or secrets.
For an emulator on your machine:

```bash
python3 -m pip install -r scripts/nas-test-requirements.txt
python3 scripts/nas_fixture.py /tmp/cinevault-nas-fixture
# In another terminal, with the Android TV emulator running:
cd android
./gradlew --no-daemon --max-workers=4 :app:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.nasHost=10.0.2.2
```

`10.0.2.2` reaches the emulator host's loopback interface. SMB-only tests skip when
`nasHost` is omitted during a manual device run; CI requires every runtime suite
to execute with no failures or skips. Reports are uploaded as
`cinevault-android-runtime-tests`.

## Apple validation

The public workflows build the tvOS app on macOS, run XCTest with the synthetic
SMB fixture, and check screenshots for stable Home/detail content. Regression
tests cover invalidated connections, cancelled scans, byte-range validation,
late playback callbacks, concurrent manual/automatic matches, metadata reset,
and responses or queued matches after source deletion. A frozen legacy SwiftData
schema tests opening an existing library with the new Watchlist field, preserving
source identity, metadata, visibility, and playback state. Additional tests cover
combined browse filters and saved preferences.

Remote tests exercise search, grouped shows, bulk watched changes, Continue
Watching, and complete Home collections, including Back/focus restoration and
removing the last saved item. For a focused navigation regression run, manually
dispatch **NAS integration** with **ui_only** enabled. It runs the remote UI
suite and Home collection logic tests; the default push/PR run still executes
the full simulator suite. This option does not substitute for NAS validation
when scanning, connections, or playback code changes.

Subtitle and continuous-playback changes require the full simulator suite. The
synthetic SMB fixture now includes a **MEDIAPLAYBACK** share with three twelve-second
episodes, English SRT/Spanish WebVTT cues, a wrong-episode filename, and invalid or
oversized sidecars. The debug-only playback preview uses this share and isolated
preferences; it must never be pointed at an owner's NAS or saved library.

SubDL client tests use injected responses for account validation, exact title/episode
identity, malformed responses, request limits, bounded raw downloads, redirects,
and cancellation. They do not use a real API key or consume a user's download quota.
A live account connection still needs a key entered by its owner in the app.

## OneDrive source fixtures

Android JVM tests cover Microsoft device-code polling, refresh rotation,
pagination, exact signed download ranges, and rejection of a scan or read
after access is revoked. The Android runtime suite checks that the refresh
record is encrypted on disk and remains readable after reopening the store.
The tvOS client fixtures cover device authorization, Graph pagination, and
download requests that keep the Graph token on Graph.

For a live account test, register a public Microsoft Entra application that
accepts personal Microsoft accounts. Enable public client flows, configure
delegated Files.Read, and use the public application ID with a dedicated
OneDrive test account. The client requests offline_access for refresh.
[Microsoft device authorization](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-device-code)
[Drive item downloads](https://learn.microsoft.com/en-us/graph/api/driveitem-get-content)

The Android catalog takes an admin-selected root and separate browse and
read permission checks. The app still needs to bind these checks to the
active household profile and connect the catalog to TV setup, the library,
and the player before exposing OneDrive in Sources.

## Further device testing

Automated checks do not establish compatibility with every NAS or codec. Before
a release, test real Synology/QNAP/Windows shares, disconnect/reconnect during
playback, seeking in large files, subtitle/audio selection, and remote focus
behavior on real Apple TV and Android TV hardware. Simulator remote tests do not
replace these device checks. The private commercial package and
store purchases/signing have their own protected validation workflow.

## Online sources consulted

- [AndroidX Media3 DataSource contract](https://github.com/androidx/media/blob/release/libraries/datasource/src/main/java/androidx/media3/datasource/DataSource.java): bounded requests, EOF, and failed-open cleanup.
- [Official Media3 player sample](https://github.com/androidx/media/blob/release/demos/main/src/main/java/androidx/media3/demo/main/PlayerActivity.java): lifecycle state and playback restoration.
- [Google Room test sample](https://github.com/android/architecture-components-samples/blob/main/BasicSample/app/src/androidTest/java/com/example/android/persistence/db/ProductDaoTest.java): database tests on an Android runtime.
- [Google UI Automator sample](https://github.com/android/testing-samples/blob/main/ui/uiautomator/BasicSample/app/src/androidTest/java/com/example/android/testing/uiautomator/BasicSample/ChangeTextBehaviorTest.java): device-level UI testing.
- [Kotlin cancellation guidance](https://github.com/Kotlin/kotlinx.coroutines/blob/master/docs/topics/coroutines-cancellation.md): cooperative cancellation and resource cleanup.
- [Android TV SDK image catalog](https://dl.google.com/android/repository/sys-img/android-tv/sys-img2-1.xml) and [emulator runner](https://github.com/ReactiveCircus/android-emulator-runner): available TV images and CI setup.
