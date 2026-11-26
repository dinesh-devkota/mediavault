# Validation and regression coverage

## Library and playback parity

The feature branch targets Apple TV, iPhone, Android TV, and Android phones.
The four runtime workflows must pass for the same source revision before the
new features are considered validated. A successful compile is insufficient.

| Coverage | Apple TV and iPhone | Android TV and phones |
| --- | --- | --- |
| Local NFO/artwork, real source reads, versions and franchise | `LocalLibrarySMBIntegrationTests` | `LocalLibraryIntegrationTest` |
| Create/rename collection, change membership, choose edition | `LibraryFeaturesNavigationTests` | `LibraryFeaturesNavigationTest` |
| Actual additional-format decoding and seeking | `AlternativePlaybackIntegrationTests` (MKV, AVI, WebM) | `SmbPlaybackTest.mkvPlaybackAndSeekFromNas` |
| Real additional-player transport, subtitle/audio sheets, Back | `AlternativePlaybackRemoteTests`, `AlternativePlaybackPhoneTests` | Existing native playback controls journeys |
| Profile isolation and safe metadata | `LibraryCollectionsTests`, `LocalMetadataImportTests`, core parser tests | Local library integration and core/app unit tests |
| Stream ranges, revocation and cancellation | `MediaByteRelayTests` | Existing data-source contract tests |
| Plex linking, imported catalog, restricted reads and direct playback | `PlexFixtureTests`, account/media client tests | Plex provider, TLS and setup tests |

The NAS fixture now exposes separate read-only `MEDIALIBRARY` and
`FORMATPLAYBACK` shares. They contain synthetic NFO/images and real short videos,
not private user media. `scripts/media_library_fixture.py` creates the fixtures;
`ffmpeg` is required to remux/encode the format samples. Existing fixture shares
remain separate so unrelated tests keep their original catalog.
`Controls.mkv` is a separate 60-second synthetic clip with two selectable audio
tracks and a local SRT file for the Apple phone/remote controls journeys. The
shorter format samples still test natural completion.

Both Android runners are restricted to disposable hosted emulators. The phone
runner requires twelve executed cases, including the library journey, MKV playback,
Plex setup, authenticated Plex range reads, and preservation of server ratings and
episode identity during metadata edits. Apple workflows also start and trust
the isolated Plex HTTPS fixture and require its shared test suite. They check the
expected cases explicitly and reject skipped
or missing results. Screenshots from the collection/version journeys are retained
on successful runs as well as failures. Review them for clipping, remote focus,
phone touch controls and readable source/version labels.

Commercial engine metering has separate private tests and a protected build.
Simulator checks cannot establish physical-device HDR, audio passthrough,
maximum bitrate, or NAS reliability. See [playback limits](PLAYBACK-ENGINE.md).

## Local checks

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
  -Pandroid.testInstrumentationRunnerArguments.nasHost=10.0.2.2 \
  -Pandroid.testInstrumentationRunnerArguments.notClass=com.dineshdevkota.cinevault.FamilyNavigationTest
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

Android JVM fixtures cover device authorization, refresh rotation, Graph pagination,
and scoped download ranges. Both hosted Android variants exercise source form
validation and Android Keystore storage with a synthetic account record. The
integrated fixture drives staged Microsoft sign-in, folder selection, a Room import,
household restrictions, photo decoding, matching subtitle sidecars, rendered
Media3 playback, and seeking. It verifies that Graph bearer tokens never reach
the download host. Test media and OAuth responses stay within the test fixtures.

For a live test, register a public Microsoft Entra application that accepts
personal Microsoft accounts. Enable public client flows, add the Microsoft Graph
delegated `Files.Read` permission, and test with a dedicated OneDrive account.
Admin enters the public Application (client) ID in Sources. An Android build
can prefill it through `-Pmediavault.oneDriveClientId=<application-uuid>`.
The app requests `offline_access` for token refresh. Microsoft handles passwords
and user approval on its device-code verification page. With Household Profiles
enabled, leave MediaVault open and complete sign-in on a second device.
[Microsoft device authorization](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-device-code)
[OneDrive item addressing](https://learn.microsoft.com/en-us/graph/onedrive-addressing-driveitems)
[Drive item downloads](https://learn.microsoft.com/en-us/graph/api/driveitem-get-content)

Verify an Android source can rename, rescan, ignore and restore relative folders
and files, reconnect the original account, and disconnect. Selecting a different
root requires a new source and fresh viewer grants. Disconnect removes local
credentials and indexed history. Microsoft permissions can be withdrawn separately
from the Microsoft account. Work or school accounts and Shared Shortcuts are
outside the personal OneDrive connector. Real account and device verification
requires owner-provided registration and account access.

## Household profile acceptance

Family controls affect authorization, not just layout. Validate both platforms
using synthetic libraries and isolated profile stores. Never enable test controls,
seed histories or reset the owner's installed app for instrumentation.

- Enable profiles without altering existing sources, credentials, metadata or owner
  history. New viewers have empty histories and no access until granted a folder.
- Check complete path-component matching, source identity, nested folders, aliases,
  deleted sources and newly connected sources. Similar folder names must not match.
- Verify movie and TV certifications separately, restrictive selection when TMDB
  reports multiple US ratings, unknown/unrated handling and photo/audio folder rules.
  A manual metadata rematch must not retain an old title's certification.
- Exercise Admin/protected-viewer PIN entry, cancellation, persisted retry delays,
  damaged or missing secure storage, relaunch and background relocking. A late PIN
  calculation must not unlock a session that was locked while it was running.
- Assert restricted titles, artwork, counts and photos are absent from Home, Library,
  Search, grouped shows, Watchlist, Continue Watching and bulk actions. Direct detail,
  photo and playback routes must enforce the same policy.
- Switch or lock during playback, photo reads, subtitle work and the next-episode
  countdown. Late work must not display old-profile content or save history to the
  next profile. Back must not reveal the previous person's navigation stack.
- Check separate Watchlist/watched/resume state, Admin legacy history, migration
  preservation, and viewer inability to edit sources, metadata or access rules.
- Keep commercial playback allowance device-wide. Profile switching, deleting a
  profile or editing watch history must not reset trial usage or purchases.

Run the full Android runtime suite and full Apple simulator suite for these changes;
UI-only checks are insufficient. The hosted Android workflow first runs the baseline
suite excluding `FamilyNavigationTest`, archives its results, then clears only the
disposable emulator's app data and runs that explicit household journey. Both suites
are required, with zero failures or skips. `scripts/test_android_runtime.sh` refuses
to run outside GitHub Actions and verifies an emulator before clearing fixture data.
The journey itself requires `familyUiFixture=true` and an empty app. Do not run that
journey on an owner's TV or emulator.

Keep synthetic remote screenshots for the profile
picker and permission editor so focus, readable labels and empty states are reviewed.

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
