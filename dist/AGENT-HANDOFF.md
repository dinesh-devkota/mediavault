# MediaVault — agent handoff

**Current name:** the owner requested **MediaVault** for the app and `mediavault`
for the public repository, now `dinesh-devkota/mediavault`. Local origin
is `https://github.com/dinesh-devkota/mediavault.git`. Historical links and snapshots
below retain their original names. Development work remains on
`dinesh-devkota-sonepar-build-cinevault-tvos-app`; the workspace and private
`CineVaultCommercial` repository retain their existing names.

## Active library/playback work — November 25, 2026

Current public candidate: `d5a9ab6` on `codex/mediavault-library-playback`,
draft PR19. It includes development's `c6d83d2` OneDrive integration, Plex,
WebDAV/Jellyfin, broader playback, local artwork/metadata, collections and versions.
The latest change fixes unreadable Apple TV secondary button labels and exercises
Watchlist changes while preserving the selected edition's resume point. The style
change is tvOS-only; iPhone's existing readable appearance is retained. Apple TV run `45752854370` passed all 251 cases with zero skips; inspected
screenshots show readable secondary labels and preserved Resume 1:30 after
Watchlist add/remove. MKV captions remain clear of controls. iPhone run
`45752854417` passed all 241 cases with zero failures/skips and its unsigned
Release build. Its detail, OneDrive setup and caption screenshots were reviewed.

Verified platform results:
- Apple TV `d5a9ab6`: 251/251, zero failures/skips, run `45752854370`;
  evidence and reviewed screenshots are in `.artifacts/apple-tv-d5a9ab6`.
- iPhone `d5a9ab6`: 241/241, zero failures/skips, run `45752854417`; unsigned
  Release packaging also passed. Evidence: `.artifacts/apple-phone-d5a9ab6`.
- Base Android TV `7bfc5b5`: 113/113, run `45745610565`; Android phone: 16/16,
  run `45745610574`. Android source/tests/workflows are unchanged at `d5a9ab6`.
- Core/unsigned-TV CI `d5a9ab6`: run `45752854407` succeeded.

The Apple OneDrive collection fixture now records ignored files relative to the
saved source root (`Feature.mp4`, not `Movies/Feature.mp4`). Product path guards
were unchanged. All OneDrive/cloud transport suites passed on both Apple targets,
including real scan/seek, exact-path local artwork and the phone setup-form journey.
Android OneDrive tests verify NFO/artwork import, preserved standalone photos,
playback/seek and folder/age access restrictions. Live owner accounts were not used.
Current Apple evidence is under the `d5a9ab6` artifact folders above; the
Android evidence remains attached to its stated successful runs. Never test disposable fixtures on the owner's
installed emulator or real NAS. Do not transfer passing counts to changed code.

### Implementation and earlier validation history

OneDrive imports use the guarded Android provider and exact Apple cloud paths.
Local validation passed 101 core and 151 app Android tests (two existing Jellyfin
cases require their loopback fixture), instrumentation compilation and debug lint.
The phone runner requires 16 Android cases and a real iPhone setup-form journey;
Apple phone and TV require OneDriveClientTests and CloudFileTransportTests.
Seven XCTest-report checks and workflow lint passed. Pre-OneDrive `96df268` passed
Apple TV 242/242, iPhone 231/231 plus unsigned Release, Android TV 110/110 and
Android phone 12/12. The checkpoints below are historical, not current blockers.

Follow-up review found that Plex's synthetic identifiers could be treated as
filenames by the metadata editor. Apple `7363654` and Android `79c5754` hide and
reject that reset, preserve imported server ratings during manual metadata edits,
and retain episode identity. Android also keeps provider rows out of the global
metadata-refresh reset. Three new Android regressions are required by the phone
runner, bringing its required cases to 12; TV executes them in its full suite.
Updated Android app unit checks passed 143 cases (two existing Jellyfin tests need
their loopback fixture), instrumentation compilation and debug lint passed. New
device regressions still need hosted execution. The pre-merge iPhone baseline
`6430a02` completed 223/223 plus unsigned Release in run `45738582653`; screenshots
show the imported Film in Library and its playback details. That run used the
already-visible password-sheet path, so it does not alone prove the narrower
interruption monitor handled an offer arriving inside a tap.

Development advanced to `290b4a6` with Plex support while this candidate was being
validated. The library/playback branch incorporates that pinned revision, retaining
both sets of artwork, playback and test-runner behavior. iPhone now starts and
trusts the synthetic Plex fixture and requires its shared runtime suite; Android
phone retains all seven earlier journeys, adds two Plex journeys, and now includes
the three metadata regressions described above. The merged
candidate needs new hosted validation. Local validation includes four real HTTPS
Plex fixture tests, seven XCTest-report guards, and syntax checks of four workflows
and 27 embedded shell blocks. Earlier platform results below apply to their stated
revisions, not automatically to this merge.

The owner-approved private Apple run `45734118734` at `7420284` completed
successfully: package tests, unsigned tvOS build, simulator test build and full
simulator test command all passed. TestFlight upload was explicitly skipped.
Successful private test output is not published, so exact per-test execution
counts are not independently available. This run uses old trusted-main wiring
and does not validate the new licensed iPhone/VLC integration.

The owner explicitly requires feature parity on **Apple TV, iPhone, Android TV,
and Android phones**. Work is isolated on `codex/mediavault-library-playback`,
PR [19](https://github.com/dinesh-devkota/mediavault/pull/19), based on the iPhone
integration branch at `3becf4e` (which includes development's WebDAV, Jellyfin,
and Android phone work). Do not reset the owner's original checkouts.

Public worktree: `D:\CineVault\.worktrees\mediavault-library-playback`.
Public implementation includes `f8282b4`. Version **1.5.0, build 7**. This adds
local NFO/XML and companion artwork, profile-specific custom collections,
NFO/TMDB franchise groups, conservative alternate-version grouping, and an
official pinned VideoLAN fallback on both Apple platforms. Files retain their
individual histories; metadata import is read-only. See `docs/PLAYBACK-ENGINE.md`
and `docs/TESTING.md` for dependency and fixture details.

The same Apple implementation passed on the Fire branch at `2d1ffac`: Apple TV
233/233 (run `45709711906`) and iPhone 223/223 plus unsigned release build (run
`45709712002`). These include real MKV/AVI/WebM decoding, seeking, pause/resume,
local subtitles, audio selection, revoked streams and collection/version journeys.
Screenshots were inspected. Original `ee00db6` iPhone also passed 223/223 and the
release build. Its duplicate Apple TV run had one keyboard-injection failure:
the test saved `Movie N` before all of `Movie Night` had arrived. `9bf7d62` waits
for each field edit before keyboard dismissal; its Apple TV run passed 233/233
(`45713647345`). Repeated iPhone runs exposed an intermittent fixture TLS failure
and controls remaining in the accessibility tree after hiding. `f8282b4` hides
inactive controls from accessibility and keeps controls visible for VoiceOver.
Its full Apple TV run passed 233/233 (`45718498997`) and iPhone passed 223/223
plus unsigned release (`45718499092`). Four fixture tests pass, with explicit
TLS-stage diagnostics. A duplicate iPhone run exposed the system Save Password
sheet arriving before Library became tappable. The latest test waits within one
ten-second navigation budget and repeats a tap only after an observed interruption.
Run `45724101732` at `8a15415` passed 222/223 and its unsigned release build:
the only failure was this navigation helper rejecting an expired budget even
though Library was already selected and the imported Film poster was visible.
The log confirms the real password prompt was declined, then the selected-tab
query consumed the final second. The follow-up evaluates current state before
rejecting a deadline and after a waiter timeout; it adds no extra wait budget.
That narrow test correction remains under hosted validation. Evidence is under
`.artifacts/apple-phone-8a15415` in the original worktree.

Fire duplicate run `45726677750` at `c538b89` also exposed an MKV UI-test race:
after revealing controls, three accessibility preflight queries consumed the
real five-second visibility window before the Pause tap. Its recording confirms
the controls appeared and then hid normally. The test now reveals and immediately
taps the desired playing control; paused-state, actual seeking, option persistence,
and all touch-target checks remain. Production controls and their timeout are
unchanged. Evidence is in `.artifacts/apple-phone-c538` and the full test log in
`.artifacts/apple-phone-c538-full`. The follow-up needs hosted verification.

The same recording exposed a real light-mode contrast issue: the fallback player's
title and time labels inherited dark text on its black overlay. Both Apple
platforms now explicitly use white metadata/time text, with lower emphasis for
the episode caption. Button tint, disabled styling, Dynamic Type, and the hide
timer retain their existing behavior. The phone journey checks the title while
paused and its existing subtitle/control screenshot provides visual evidence.

Run `45727532171` at `5019cc8` passed all 223 phone cases and unsigned release.
Run `45729764030` at `d6e2600` passed 222/223 and release; its MKV journey and
white metadata screenshot passed visual review. Its sole failure was WebDAV TLS:
the fixture log records two handshake timeouts at 5.010 and 5.004 seconds, after
earlier authenticated playback succeeded. The fixture now allows a separate,
bounded 20-second TLS handshake while retaining its five-second HTTP idle limit.
All five real-socket fixture tests pass, including delayed ClientHello, idle-client
isolation, authentication, range reads, and certificate rejection. Production TLS
and retry behavior are unchanged; an independent review found no issue.

The successful phone recording also showed local captions covering the paused
scrubber. The shared Apple fallback now measures its transport panel and places
captions above it while visible, restoring their previous position when controls
hide. Existing phone and TV journeys assert caption Text bounds above the title.
The recorded accessibility frame excludes external padding, so this catches the
actual overlap. This caption/fixture follow-up awaits hosted phone and TV checks.
Full TLS evidence is in `.artifacts/apple-phone-d6e2600-full`; the inspected
metadata screenshot is in `.artifacts/apple-phone-d6e2600/iphone-test-screenshots`.

At `7983719`, Apple TV passed 233/233 (`45733330571`), and iPhone passed
222/223 plus unsigned release (`45733330589`). Both MKV journeys and the new
caption-clearance assertions passed: reviewed Text bounds are phone bottom
617.3 before title 649.3, and TV bottom 810 before title 842. The phone WebDAV
authentication and scan now succeed. Its remaining test failure is a transient
system Save Password offer appearing inside the Library tap: the synthesized
event targets the real tab at (132.25, 822), but the recording shows that touch
dismisses the offer and leaves Manage selected. Between-action sheet queries
miss the entire interruption. The helper now registers XCTest's documented
interruption monitor for this exact offer and permits another tab tap only if
that handler actually declined it. The ten-second budget and actual scan,
selected-tab and imported-poster assertions are retained. This test-only fix
requires hosted iPhone verification. Evidence is in `.artifacts/apple-phone-7983719`,
`.artifacts/apple-phone-7983719-full`, and `.artifacts/apple-tv-7983719`.

Earlier actual defects are corrected: TCP send completion, VLC parser timeout
units, pending-pause acknowledgement, synchronous stream revocation, nested
version navigation, phone collection sizing, focused button contrast and the
bounded TLS fixture accept loop. Do not reintroduce those old approaches.

Android core/app tests, debug lint and APK builds passed. The Fire branch has
101 core and 137 app tests passing, with two existing Jellyfin tests skipped
without their server. Hosted modern Android TV passed 110/110 (run `45709711876`)
and phone passed 7/7 (run `45709711901`). Never run disposable test fixtures
against the owner's installed emulator or real NAS.

The expanded mixed-corrupt/unavailable-sidecar regression in `369c890` passed
on base Android TV (103/103, run `45728286881`), Fire-branch Android TV
(110/110, `45728952433`), and Fire API 22/25/28 (13/13 each, `45728952307`).
It also passed in phone run `45728952327` (6/7 overall). That phone run failed
before tapping Play: `AndroidPhoneNavigationTest.visible()` let the transient
"No compose hierarchies" exception escape during the movie-detail activity
transition. Logcat has no crash/ANR; subsequent collection and MKV tests passed.
The phone helper now retries only that exact missing-root condition within its
existing 30-second budget, rethrows other state errors, and saves timeout
screenshots/tree diagnostics through the existing test-artifacts collection.
Instrumentation compilation passed; hosted verification of this test correction
is pending. Downloaded XML/log evidence is in the Fire worktree's
`.artifacts/android-metadata-audit`.

Repeated Android TV testing found a nested-focus handoff that could keep an
ignored season visible. `643cb35` suspends child focus restoration while removing
content and bounds the handoff. Its full Android TV workflow passed
(`45722101734`), retaining the real ignored-folder/navigation regression.

## Amazon Fire TV work — November 26, 2026

Remote PR20 head `b98f180` is green across Android/Fire OS: modern TV 120/120
(run `45748429035`), phone 16/16 (`45748429096`), and API 22/25/28 22/22 each
(`45748429091`), with zero failures/skips. Build/lint/APK/unsigned bundle passed.
Four library screenshots were reviewed. OneDrive setup, protected credential
storage, NFO/artwork import, folder/age permissions and actual playback/seek ran
on every target. Evidence is in `.artifacts/android-tv-b98f180`,
`.artifacts/android-phone-b98f180` and `.artifacts/fire-compat-b98f180`.

Vega follow-ups are on `codex/mediavault-vega-keyboard-visibility`, not PR20's
remote head. Latest tested `0e21f3a`, run `45768740001`, passed all three production
packages, fixture packaging, native regressions, production startup and stages
01-05. Native cold-start/Back focus, non-first poster restoration, complete bulk
collection create/rename/remove/cancel/persisted selection, show/season/episode
navigation and actual photo loading passed. All four bulk actions fit one row;
612px viewports fully contain the 604px watched cards and their focus borders.
Focused selected tiles are white; other selected tiles remain orange. Show/photo
end captures return to Home, so they are functional evidence, not visual review
of those intermediate screens.

Stage06 plays MKV with actual advancing time and pauses, but native seek fails.
The first application +30s request receives native error50004 before the SDK's
duplicate +10s request. The SDK emits seeked despite rejection, leaving actual
position near1s. The app's pending-seek guard can then prevent all further progress
updates. The follow-up fixes use the documented SDK as the sole owner of remote
media keys (explicit10s both directions), keep on-screen Forward30/Back10, recover
from rejected/timed-out seeks without optimistic position, and protect saved
resume after failed restoration. Harness assertions will separately prove each
remote/on-screen seek, native control focus, paused stability and real advancement.
All 69 app/SDK regressions and typecheck pass; lint has zero errors and 50 existing warnings.
The underlying native rejection is still unresolved; removing duplication does
not establish a fix. Fixture-only bounded numeric relay diagnostics are being
prepared without paths, tokens, credentials or media content. Stages07-09 continuous
TV and household/PIN remain unvisited. Evidence: `.artifacts/vega-ui-45768740001`.

Follow-up `fafb05b` implements the player fixes; `b058e51` adds separate native
remote/on-screen seek assertions and bounded fixture-only video/audio relay traces.
Run `45774417317` passed all three release packages, fixture packaging and native
regressions; its native app journey is running. Local native verification covered
80 cases (five local build guards needed the existing SDK library path and then
passed); all 69 app/SDK tests and 17 harness contracts passed before optimization.
The trace is absent from the compiled production host binary and logs at most
128 fixed-label/numeric records, never paths, tokens, headers or content.

Standalone diagnostic `b7985b8`, run `45775008538`, compares four fresh W3C players:
MKV/MP4, paused/playing, via stock nginx rather than MediaVault's relay. The MP4
copies every coded video/audio packet from the unchanged synthetic MKV generator.
Local SDK build, separate package identity, packet comparisons and exact HTTP
range bytes passed. Native comparison is running. The new manual-only workflow
mode skips normal app jobs; a failed diagnostic remains failed and does not count
as application acceptance. No owner device, NAS or credentials are used.

Earlier `3e4b813`, run `45765161506`, established that FlatList's `library-grid`
ID is absent from the native publisher. Home/lock predicates now use actual
exposed toolbar controls and poster groups, plus prior-route disappearance.
The native return-focus assertion remains mandatory. Initial onboarding now has
one setup card; filtered-empty and restricted-profile grids remain available.

Earlier checkpoint `0590298`, run `45761600966`, passed all
packages/native/startup checks and stages01/02. Reviewed screenshots confirm
Home and collection viewports of 612px (y412..1024); 604px watched cards now fit
entirely with all four white focus-border corners visible. Posters, filled
controls and readable Play remain present. The short collection screenshot pair
captures artwork loading, not an established persistent image failure.
Stage03 still stops before Clear activation: its exact keyboard control is
natively visible, but 21 direct setFocus attempts over about 25 seconds never
receive native focus. The helper's Down-only fallback cannot reach Clear to the
right. The follow-up uses bounded keyboard-only arrow navigation and requires actual
native focus on Clear before Select; prior/empty/final nonsecret acknowledgements
and protected-entry guards remain. All 17 harness contracts pass, including
ineffective direct focus, no movement, stale/ambiguous focus and hidden keyboard.
The app now records route-specific poster/scroll anchors for Home and collections,
requests focus only after the returning item becomes viewable, falls back when
it disappears, and cancels retries on directional input or household changes.
An empty grid can accept first-scan results without reviving user-cancelled focus.
Typecheck and all 60 domain/SDK tests pass (nine focus lifecycle cases).
New native empty-Home and non-first-poster Back assertions use only remote input,
without focus-setting helpers. They still require the next hosted run; offscreen
restoration currently has unit/lifecycle coverage only. Complete playback/profile
journeys remain pending.

Tested baseline `2847a6e` includes Apple `d5a9ab6` and its completed
handoff. Normal run `45756851737` passed all three production architectures,
isolated fixture packaging, native regressions and production startup. Stages01/02
passed without the earlier fatal overlay. Stage03 reached collection creation,
but the driver's clear/setText('') left the seven-character old name unchanged;
strict empty acknowledgement failed. The replacement now uses the observed
keyboard Clear button with a positively visible window and strict native focus.
Nonsecret prior/empty/final checks remain; PIN/password contents are never read.

Home's grid improved from 94px to 580px (y444, five complete cards). Collection
browsing also moves rename/delete to Manage collection, leaving a compact title
and action row over the grid. Detail Add to collection keeps its candidates on
that route instead of replacing the active Home bulk selection. Stage03 tests
return navigation, the renamed collection and all three originally selected files.
The new management field/actions were on-screen in the failed rename evidence;
its poster grid and selection-return assertions still need a completed journey.

The isolated rendering probe succeeded in run `45756854606` at `2847a6e` with
SDK 2.0.15159, simulated x86_64 OS 2.0 TV Ship/102815880, OpenGL acceleration
disabled. Square Views painted 100% expected color, while rounded Views painted
0%. An unclipped bundled PNG painted all four quadrants correctly; the same PNG
inside a rounded clipping parent painted none despite successful load callbacks.
Native/React focus agreed: the rounded focused background was absent, while the
square focused button was visible. A stale first screenshot was separately
identified by consecutive captures. This is a measured virtual-device paint/clip
failure, not evidence of physical-device behavior. See the probe README and
`.artifacts/vega-render-probe-45756854606` for exact package and pixel evidence.

The product follow-up uses the same rectangular surfaces in both production and
fixture Vega builds, retaining spacing, colors, typography, borders and behavior.
It also aborts a stuck native initialization before waiting for startup cleanup,
and sends the SDK's required hidden transition to disable embedded subtitles.
Per-player selection uses stable IDs and explicit Off, so delayed sidecars and
native default-track events cannot replace a viewer's choice. Missing native
tracks are skipped until available, and unchanged choices cause no repeated
native enable/disable calls. Typecheck and all 51 app tests pass. SDK-method
regressions execute the installed initialization, track setters and track-event
code with only native boundaries replaced. These fixes require a new full
hosted app journey and visual review; the isolated probe is not an app pass.

The old URL polyfill called unsupported NativeModules.BlobModule; `77f31cc`
replaced it with Vega's built-in URL API while retaining address guards. The
harness now rejects fatal overlays before/after journeys and captures. Keyboard
closure uses positive native-window visibility, one Back, then that same window
hidden and Done absent; transient publisher absence cannot satisfy closure.

The render probe is manual-only (`rendering_probe_only`); normal jobs are skipped
in that mode. Its separate package contains a known bundled PNG, no MediaVault
native module/libsmb2, no network/accounts, and exact template/dependency provenance.
Production secure storage cannot be validated by this simulator. No physical
Vega device is available; do not ask the owner again. Complete media playback,
continuous viewing and household UI journeys remain unverified on Vega.

The optimization follow-up retains the catalog/group/collection derivations with
standard React useMemo and replaces repeated collection membership searches with
Sets. Source, profile, folder/rating, lock and rescan changes still invalidate the
results immediately; existing resource/session authorization remains independent.
All 76 app/SDK tests pass, including seven real React lifecycle regressions;
typecheck passes and lint remains zero errors/50 existing warnings. The current
immutable update paths were audited. No persistence format or codec change is made.

Synthetic desktop Node22/V8 measurements at 10,000 metadata-rich items and
20 collections of 250 members: full collection recomputation 49.700 -> 11.828ms;
whole parent derivation 60.330 -> 23.432ms. A separate React viewing-update benchmark
(with Sets on both sides) measures 23.181 -> 1.715ms. These isolated measurements
are not physical TV/Hermes/FPS results and their measured boundaries differ.
The preserved baseline SHA256 remains
`ceae9ce031ca3d4ec9493cfed2257ebbb103389bcd79fe4ab44bf990b04d707b`.
Reports and separate before/after results are in `.artifacts/runtime-catalog-optimization-review.md`.

Runtime build setup now installs required Linux packages without optional
recommendations, explicitly retaining the two GUI recommendations, Python and CA
certificates. The measured candidate omits 31,228,552 archive bytes, mostly an
unrelated speech language model. All existing explicit packages and required Mesa
OpenGL dependencies remain; the graphics comparison retains its extra explicit
Mesa/EGL tools. Disposable Ubuntu checks generated all four media fixtures and
opened Xvfb successfully. Full VVD compatibility and elapsed-time savings still
need the optimized cloud trial. Parallel job scheduling and SDK-state caching are
deferred; the current job graph, cold devices and complete checks are retained.

### Earlier Fire validation and investigations

At `3edbd0b`, API 22 and 28 each passed 21/22; only the OneDrive setup-form
assertion failed. The follow-up checks the exact entered UUID, performs the
field's existing Next action and scrolls to Sign in before checking enabled.
It retains invalid-input activation. All targets passed at `b98f180` above.
The earlier Vega keyboard diagnostic showed Done was temporarily absent while
the keyboard window was still opening, causing the conditional Back to be skipped.
Native-window visibility is now the authoritative boundary; strict application
focus assertions have not been relaxed. The checkpoints below are historical.

Fire integration `4b87c31` includes public `96df268` and Plex's secure-storage test
adaptations for API 22. Local checks passed 101 core and 146 app unit cases, with
two pre-existing Jellyfin cases requiring their loopback fixture; instrumentation
compilation and debug lint passed. The Fire matrix now requires 19 cases per API
22/25/28: the original 13, three Plex transport/catalog/storage checks, and three
metadata-rating/reset regressions. At `3d78667`, hosted run `45742006243` passed
19/19 on each of API 22, 25 and 28, with no failures or skips. Fire phone
`45742006199` passed 12/12. Shared base `96df268` passed Android TV 110/110 and
phone 12/12. Modern Fire TV runtime passed 117/117 (run `45742006292`). Its
separate build job hit Maven Central HTTP 429; the single-job retry `139654868437`
passed core/app tests, Debug and Release lint, APK and unsigned bundle builds.
The successful runtime tests were not repeated. Current Fire work additionally
incorporates OneDrive merge `7bfc5b5`. Local Fire checks passed 101 core and 154
app cases, with two existing Jellyfin fixture-dependent skips, instrumentation
compilation and lint. The API 22/25/28 runner now requires 22 cases, adding
OneDrive credential persistence, setup and guarded local artwork/playback.
Those expanded runtime checks still need new hosted validation.

Vega run `45738633627` at `1dad04d` passed every package and native check, but
notification suppression did not fix focus. Everyone, the scroll container, and
Add source all stayed unfocused while Back retained focus. Paired screenshots
alternated between stale Home and current Sources and still omitted rounded
backgrounds. Comparison `45742000030` verified both original package ZIP digests,
booted with SDK-default graphics on Mesa llvmpipe, and reproduced the same focus
failure and byte-identical screenshot pair. This does not establish behavior on
a physical GPU. Evidence is in `.artifacts/vega-ui-45738633627` and
`.artifacts/vega-ui-45742000030`. No library journey has passed; fixture credentials
and runtime diagnostics do not establish physical-device secure storage.

An independent audit found that the app's long-lived, whole-screen focus guide
uses `autoFocus` while its route children change; the SDK template does not.
The current diagnostic candidate removes only that property, retaining the guide,
session key and all strict focus assertions. SDK 2.0.15159 typecheck, lint (zero
errors) and all 42 app tests pass. Hosted `f89640d` run `45744255024` passed all
packages/native checks and production startup. The strict runtime journey now
passes Home to Sources, Add source, NAS/SMB, Source name entry and its first
keyboard dismissal. It then fails focusing the second IME session Done key
while the NAS address field is active. The earlier Sources blocker is absent
in this run, but no complete library journey has passed. Audit the system
keyboard boundary separately; do not loosen app-button native-focus assertions.
The follow-up harness uses one documented Back key only for an observed system
keyboard, then requires it closed, the same field present, and non-secret text
unchanged. Secret fields are never read back. Node syntax and all seven startup
contracts pass; the full journey must establish actual runtime behavior.
Cold-start D-pad focus and return navigation remain to be verified. An ignored
minimal official-template probe is prepared under `.artifacts/vega-focus-probe`;
it was not built or dispatched because the original failure did not recur.

Latest verified checkpoint: Fire `5c88fe8` passed Android TV 110/110 (run
`45735053621`). Android phone 7/7 and Fire compatibility 13/13 on each API
22/25/28 passed at `7e207f2`; their code and dependencies are unchanged at `5c88fe8`.
Base `7983719` passed Apple TV 233/233 (`45733330571`). Its iPhone run
`45733330589` passed 222/223 and unsigned Release: caption clearance and the
authenticated WebDAV scan passed. The remaining Library-navigation test tap
was consumed by a transient system Save Password prompt; the narrow test-only
interruption handling is being corrected, with no change to production navigation.

Vega run `45735053415` at `5c88fe8` passed all production architectures, isolated
fixture packaging, native checks and the production startup probe. Library journey
01 still failed at Add source. This time both screenshots show Sources, and the
native `UiObject:focused` query agrees with XML that Back retains focus despite
successful setFocus responses. No complete library journey has passed. A fixture-only
experiment will follow the pinned SDK template's notification suppression while
retaining console/native diagnostics, uncaught-error screens and strict focus checks.
Do not infer a production rendering defect or hardware readiness from this evidence.
Diagnostics are in `.artifacts/vega-ui-45735053415`.

The owner explicitly approved private revision `7420284` in build-only run
`45734118734`, and that exact approval has been submitted. Package tests and the
unsigned tvOS build passed; simulator tests are running. TestFlight is disabled.
This supersedes the older pending-approval note below; no further approval for
this exact run is needed. The old trusted-main workflow still does not verify
the new licensed iPhone/VLC integration.

Run `45732509539` at `7e207f2` passed all packages/native checks and production
startup. Fixture warning dismissal now works (count 1), but Add source focus was
not acknowledged within 25 seconds despite successful setFocus RPC responses.
XPath/XML retained Back focus; the screenshot showed the prior Home page. Amazon's
community has a reproducible alternating stale/current VVD screenshot report.
No production rendering defect is established. The next harness uses the pinned
driver's documented `UiObject:focused` attribute (native `isFocused`, string true
or null), records native-versus-serialized focus, and retains paired screenshots.
It follows app logs after installation to preserve early diagnostics. Evidence is
under `.artifacts/vega-ui-45732509539`; complete library journeys remain unverified.

Fire `7e207f2` phone run `45732509596` passed all 7 tests, including the formerly
failing touch setup/playback case; compatibility run `45732510580` also passed.
Base `7983719` is now merged: measured Apple caption clearance plus the bounded
20-second fixture TLS handshake allowance (HTTP idle stays five seconds). Five
real-socket fixture tests pass. New Apple runtime checks are pending.

Approved commercial run `45727288957` finished: 28/28 package tests, 41/42 simulator
cases, all six new engine tests passing in both suites, unsigned tvOS build passed,
TestFlight skipped. The single actual StoreKit iterator stall remains unproven.
Private `7420284383009976eaa6121d3d3cc55a9b928427` fixes a separately confirmed
cancelled-waiter retention defect, with three new regressions and independent
review. Five generator tests pass; new Swift tests await hosted validation.
Build-only run `45734118734` pins that private revision and waits for a fresh owner
approval, already requested. Do not reuse the prior approval. Its old trusted-main
workflow still cannot verify the new licensed iPhone/VLC wiring.

Run `45730914333` at `96073fa` passed all packages, native checks and the production
startup probe. Fixture journey 01 still failed before Add source focused. The
warning detector incorrectly queried an XML-only `<text>` node without an object
ID; it now queries the owning text control. Focus acknowledgement also retries
within its existing 25-second overall budget when initial screen focus arrives
late, and records non-sensitive RPC results for diagnosis. Actual runtime remains
pending; no complete library journey has passed. Logs now retain installed app
diagnostics correctly. Evidence: `.artifacts/vega-ui-45730914333`.

The owner confirmed **no Vega device is available**. Do not ask again; production
credential persistence and physical playback remain unverified. The owner also
explicitly approved build-only commercial run `45727288957`. GitHub still showed
it waiting, so that exact approval was submitted through the API. Its private
package tests and unsigned tvOS build passed; licensed simulator tests are running.
TestFlight upload remains disabled.

The current Fire branch also includes base `26078e3`, a narrow Android phone test
wait correction for a confirmed activity-transition race, and `db8cb1e`, which
makes collection posters open their titles while home bulk selection stays active.
The latter extends journey 03 through title details and Back to the same collection.
Typecheck, all 42 app tests and test-script syntax pass; new runtime remains required.

Vega `e40bd26` run `45728952472` again passed all package/native jobs and the
actual production startup probe. Fixture journey 01 reached Sources, then the
Debug SDK LogBox took focus before Add source. Exact screenshot/XML is under
`.artifacts/vega-ui-45728952472`. The new harness dismisses only that observed SDK
warning within the fixture app, records a dismissal count, and reacquires focus
from the live selector. It does not suppress product errors or change production.
Log collection now queries stored app logs after installation; LoggingCtl cannot
see apps that were installed after its session began. Test07 also verifies real
episode-four progress and valid subtitle choices beside a bad subtitle file.

Two further Vega fixes pass 42 app tests: reentrant cleanup shares one teardown
promise, and oversized/malformed subtitle files no longer discard valid siblings.
Profile/source authorization and transport failures still propagate. Hosted
runtime for this next checkpoint remains required. Base `d6e2600` includes the
Apple player metadata contrast fix and immediate reveal/tap test helper; base
`5019cc8` has passed all 223 iPhone tests and unsigned release (`45727532171`).

Run `45726677998` at `c538b89` passed every release architecture, the isolated
fixture package, and all 74 native checks. The actual VVD production startup
probe passed: unsupported keystore, hidden library, enabled Retry. Fixture startup
and its banner passed, and Source name accepted the full typed value. Journey 01
failed because `getText` queried RN's focus wrapper, not its editable child.
Evidence is under `.artifacts/vega-ui-45726677998`. The new harness targets the
editor, dismisses the observed IME with Done, and uses bounded D-pad/focus steps
for off-screen fields. It also suppresses raw driver console RPC bodies.

The following checkpoint fixes actual SDK playback initialization: wait for the
native surface callback before setting src, poll real native state if events are
absent, resume once, and preserve terminal completion during cleanup. Ten new
lifecycle regressions pass; the full app/domain suite is 37/37, typecheck passes,
and lint has no errors. A loopback-only HTTP playback policy passes SDK manifest
validation, and 20 packaged/staging guards plus seven probe tests pass. Actual
playback remains under VVD validation. The mixed invalid/unavailable NFO rating
case is fixed in Vega and Android (`369c890` in PR19); Apple already fails closed.

Fresh private build-only run `45727288957` pins companion `5cd626e` and waits for
the owner's protected `commercial` approval. It can verify standalone private
engine tests and the existing main tvOS integration; full new VLC/iPhone wiring
still requires reviewed public code/workflow promotion and a later approved run.

Latest Vega checkpoint: all 74 native host regressions pass (57 production,
17 isolated fixture). The SDK-built Debug/x86_64 simulator-only VPKG passes
manifest/ABI and actual packaged marker checks. Its package ID is
`com.dineshdevkota.mediavault.vvdfixture`; production remains
`com.dineshdevkota.cinevault`. Nineteen staging/package tests and seven startup
probe tests pass. Production storage is unchanged. Hosted runtime now probes
production startup independently, terminates it, and runs nine library/player
journeys in the synthetic-only fixture build. Secure storage/restart remains a
hardware-required skip. These new device journeys have not passed yet; inspect
their results before claiming runtime coverage. The owner has been asked whether
a physical Vega device is available; do not wait to finish independent testing.

The owner answered **Do it for all**, including both Fire OS and Vega OS.
Worktree `D:\CineVault\.worktrees\mediavault-fire-tv`, branch
`codex/mediavault-fire-tv`, draft PR [20](https://github.com/dinesh-devkota/mediavault/pull/20)
is based on PR 19. Fire OS uses the Android APK with minimum API 22. The API
22/25/28 compatibility matrix passed 13 tests per version (run `45709712064`),
including encrypted secrets, PINs, photos, remote controls and MKV playback.
Physical Fire TV compatibility and codec/memory performance are not certified.

The separate `vega/` app uses actual Amazon SDK 2.0.15159, React Native 0.83 and
Vega OS 2 (rolled out across current Vega devices). Visible name MediaVault;
internal ID matches Android's `com.dineshdevkota.cinevault`. Type checking and
25 app/contract tests pass. The actual SDK native module compiles; all three
release architectures and 57 native host cases pass in the latest cloud build.
These include real transport fixtures, error-response classification and fixed
platform-error categories. VVD installed/launched the real application but stops
at `MV06`, opening the private keystore, before any library journey can pass.
Amazon's [Crypto documentation](https://developer.amazon.com/docs/vega-api/2.0/README.amazon-devices_keplercrypto)
says its API is unsupported in the simulator. Typed error diagnostics are being
checked before choosing the next test approach. Keep PR 20 draft; physical-device
credential persistence and playback remain unverified.

Rejected SMB sign-ins now have bounded socket/authentication negotiation and
can be cancelled. System hostname resolution still precedes that loop and can
wait for the system resolver; do not describe the deadline as covering DNS.

`tools/vega/Dockerfile` provides a pinned Linux compiler host. VVD is unsupported
inside Docker, so `.github/workflows/vega.yml` runs it directly on Ubuntu with
KVM and a disposable synthetic NAS. See `docs/FIRE-TV.md` for reproducible commands,
license sources and current Vega parity gaps (TMDB/SubDL settings, NAS discovery,
editing existing profiles). Native host tests do not verify the device keystore.

The private companion branch is `codex/mediavault-playback-engines` at
`5cd626eba6ce3b534ec1f0b3e74cc7cbfe0bb6c0`, in
`D:\CineVaultCommercial\.worktrees\mediavault-playback-engines`. It adds genuine
engine-neutral usage accounting and iPhone build/test support. Its five project
generator checks pass; Swift and licensed simulator validation remain pending.
The commercial workflow keeps its trusted-main and required-review safeguards;
use a fresh exact-revision, build-only approval. Do not enable store upload.

The owner has Windows and an Apple TV, without a Mac or active Apple Developer
membership. Do not ask for those details again or claim installation on physical
Apple hardware. No production NAS files, app data, or credentials were reset.

## Historical handoffs

Current updates are appended chronologically below. The original November 1
snapshot is retained for history and is superseded by later owner decisions.

A snapshot written by the previous Copilot agent. Check the live state (`git log` and the Actions tab) before acting on it.

**Latest code:** branch `dinesh-devkota-sonepar-build-cinevault-tvos-app`, which is `main` (`5fdc02d`) plus 6 Android TV commits plus this file.
- `main` contains neither the Android work nor this file. Merging requires the owner's approval.
- The repository has no pull requests.
- The working tree was clean at handoff (nothing uncommitted, untracked, or stashed). This commit adds only this file.

## Goal

Original request (verbatim): "Build a plex like app to range and manage movies but that loads the media files directly from network location like NAS for apple TV"

Follow-ups (verbatim): "start andriod tv version as well" and "I am stepping out and you have permission to build everything."

## Current state

| Area | Where | State | Evidence |
|---|---|---|---|
| tvOS app (community build) | `main` `5fdc02d` | All requested features implemented | CI run 41150270899 and NAS integration run 41150270974 passed |
| tvOS official (commercial) build | `main` + pinned private package | 12 of 13 simulator tests pass; one regression | Commercial build run 41156608641 failed |
| Android TV app | branch `5c5bc12` | Stages 1–6 of 7 done; Stage 7 not started | Android TV run 41339324494 passed |
| Devices and stores | — | Never tested on a real Apple TV, Android TV, or NAS. Nothing uploaded to TestFlight, the App Store, or Google Play | — |

## Owner decisions (do not re-ask)

- **No server:** the apps read the NAS directly over SMB. The app plays only movies from the NAS; YouTube support was declined.
- **No Mac:** the owner uses Windows. Apple builds and tests run on GitHub macOS runners, and the app is installed through TestFlight.
- **Style:** an Infuse-inspired UI; small commits, one per stage; commits and pushes as `dinesh-devkota`.
- **Official build pricing:** about US$1/month or US$12 lifetime through StoreKit, with usage tracked locally.
  - Three trial plays: plays 1–2 are unrestricted, and play 3 stops at 90%.
  - Resume continues the same play; Start Over uses a new one.
- **Commercial code:** lives in the private repo `dinesh-devkota/CineVaultCommercial`.
  - Developer access is granted manually after payment.
  - There is no CI in the private repo. Official builds run through the public `commercial.yml` with a pinned private SHA.
  - The community build must work without the private package.
- **Authorizations:**
  - Unsigned commercial validation runs are allowed.
  - TestFlight uploads are **not** authorized without the owner's explicit approval.
  - Do not push or merge to `main` without explicit approval. The owner did approve fast-forwarding `main` to `5fdc02d`.
- **Repo:** stays public. Once Android is on `main`, update the repo description to mention Android.

## Architecture

### tvOS (`main`)
- The project is defined in XcodeGen `project.yml`.
- `CineVault/` is a SwiftUI app using SwiftData and AVKit.
  - SMB access uses AMSMB2, a dynamic framework because it is LGPL.
  - An AVPlayer resource loader streams SMB byte ranges.
  - Passwords are stored in the Keychain; TMDB uses the user's own key.
  - Plays MP4, M4V, and MOV only.
- `Packages/CineVaultCore` holds the pure logic and its tests.
- `CineVaultTests/` includes tests against a local SMB test server (`scripts/nas_fixture.py`).
- The commercial build uses the `PlaybackServices` interface, the `CINEVAULT_COMMERCIAL` flag, and the `project.commercial.yml` overlay. `fastlane/Fastfile` handles signing.

### Android TV (`android/`, on the branch)
- Gradle project: AGP 8.13.2, Kotlin 2.2.21, JVM 17, minSdk 26, targetSdk 36. App ID is `com.dineshdevkota.cinevault`.
- `:core` is a pure-Kotlin port of the core logic: parser, library rules, TMDB helpers, scan diff, and edit rules.
- `:app` uses Compose for TV:
  - Room database, with secrets protected by the Android Keystore.
  - smbj for SMB, using the BouncyCastle provider; a library scanner.
  - OkHttp TMDB client.
  - Media3 ExoPlayer with an SMB data source. Resume position is saved every 10 s, and a movie counts as watched past 92%.
  - An edit screen.
- Plays mp4, m4v, mov, mkv, webm, avi, ts, m2ts, mpg, mpeg, and flv, depending on device codecs. wmv and iso files are listed in the library but cannot be played.
- Release minification is off because of smbj.

### Private module (high level)
StoreKit purchases plus the trial and usage rules for the official tvOS app. Never copy its source, tokens, or diagnostics into this repo.

### Workflows
- `ci.yml` and `nas-integration.yml` run on macOS for pushes to `main`, pull requests, and manual runs.
- `ui-preview.yml` runs manually.
- `commercial.yml` runs manually in the protected `commercial` environment.
- `android.yml` runs on Ubuntu for `android/**` changes or manually, and uploads the debug APK.

## Android stages (each passed CI)

| Stage | Commit | Contents | CI run |
|---|---|---|---|
| 1 | `a2ed045` | Gradle setup, `:core` port and tests, Android CI | 41152456391 |
| 2 | `865b56f` | Room, Keystore secrets, smbj service, scanner | 41153520674 |
| 3 | `1e3af13` | TV UI: tabs, movie detail, source editor | 41154615716 |
| 4 | `f9aa1a8` | ExoPlayer SMB playback, resume and watched state | 41156077485 |
| 5 | `973face` | TMDB metadata | 41338625536 |
| 6 | `5c5bc12` | Edit screen: rename, fix match, reset progress, reset to file name | 41339324494 |

## Exact last activity

1. Pushed Android Stage 6 (`5c5bc12`), and CI passed. The local build ran 41 JVM tests, reported only the 3 known lint warnings, and built the APK.
2. Started a read-only investigation of commercial run 41156608641, which used private pin `5f1a48a`.
   - Package tests passed 21/21 and the unsigned build succeeded.
   - Simulator tests passed 12/13. The failure was the slow-App-Store-catalog playback test, which timed out after 20 s waiting for the catalog request. It passed with the previous pin, `d36c8e3`.
   - Unconfirmed hypothesis: at launch, the app refresh waits on entitlement verification before requesting the catalog. The new retry for stalled entitlement reads may keep that wait running under StoreKitTest.
   - No fix was sent, and no private changes were made.
3. Stage 7 was not started. The owner then asked for this handoff.

## Not committed (by design)
- Build caches and outputs: `android/**/build`, `.gradle`, `.kotlin`.
- The debug APK. Download the `cinevault-androidtv-debug` artifact from run 41339324494 instead.
- `local.properties`, keystores, Apple signing files, and the generated `.xcodeproj`.
- The private module checkout (`/commercial/`).
- The previous agent's local session files: screenshots, diagnostics, a temporary diagnostics key, and a copy of private test source.

## Build and test
- **tvOS:** pushes and pull requests run CI and NAS integration. On a Mac:
  1. `brew install xcodegen && python3 scripts/generate_app_icons.py && xcodegen generate`
  2. `cd Packages/CineVaultCore && swift test`
  3. Build as in `ci.yml`.
- **Android (PowerShell):**
  1. Set `JAVA_HOME` (JDK 17 or later) and `ANDROID_HOME`.
  2. Run `cd android; .\gradlew.bat :core:test :app:testDebugUnitTest :app:lintDebug :app:assembleDebug`.
  3. Expect 41 tests (28 in `:core`, 13 in `:app`) and exactly 3 lint warnings: VectorRaster, DataExtractionRules, ObsoleteSdkInt.
- **Commercial (owner or authorized developer only):**
  1. Run `gh workflow run commercial.yml -R dinesh-devkota/CineVault --ref main -f commercial_sha=<40-char SHA> -f upload_testflight=false`.
  2. Approve the `commercial` environment when prompted.

## Blockers
- **Commercial regression:** the failing test above blocks the official release.
- **Signing:** the `commercial` environment has only `COMMERCIAL_REPO_TOKEN`; Apple signing secrets are not set. Google Play setup has not started.
- **Testing:** nothing has run on a real device or NAS. The Android app has never been launched.
- **Platform:** there is no Mac or Swift on the owner's PC, so Apple validation runs only through Actions.
- **Merge:** Android needs the owner's approval before it can go to `main`.

## Next steps
1. **Owner:** decide whether to fast-forward `main` to this branch, then update the repo description.
2. **Private repo:** fix the slow-catalog regression, then rerun `commercial.yml` without signing.
3. **Android smoke test:** install the APK on an Android TV emulator or device (`adb install -r app-debug.apk`) and test with a real SMB share.
4. **Android Stage 7:**
   - Play Billing that mirrors the trial rules, probably kept private.
   - Release signing, an AAB, and the Play internal testing track.
   - A README section for Android.
5. **Apple release:** follow the README sections "One-time Apple setup", then TestFlight, then the App Store.
6. **Cleanup:**
   - Delete the encrypted diagnostics artifacts 13023439587, 13024633969, and 13026151087. They expire on 2026-11-07.
   - Replace or remove the temporary `COMMERCIAL_DIAGNOSTICS_CERT_BASE64` environment variable.
   - Never remove `COMMERCIAL_REPO_TOKEN`.

## References
- `README.md`: project layout, commercial builds, Apple setup, TestFlight, App Store, and tests.
- `docs/PRIVACY.md` and `.github/workflows/`.
- The private repo `dinesh-devkota/CineVaultCommercial` (authorized access only).
- The Copilot app session "Private commercial module".

## Continuation — 2026-11-03 (America/Chicago)

The owner requested continued work on the development branch. The Windows
checkout is now on `dinesh-devkota-sonepar-build-cinevault-tvos-app`, based on
`8534ab9`; `main` has not been changed. The earlier sections above remain a
historical snapshot, rather than a current release approval.

- GitHub CLI access is working as `dinesh-devkota`.
- Local Android validation passed all 41 JVM tests, lint (zero errors and the
  same three documented warnings), and the debug APK build using JDK 21 and
  the installed Android SDK. No Android device is connected.
- GitHub CI run `41762816806` passed the unsigned tvOS build, Swift core tests,
  and commercial build-helper tests. The Windows shell could not run three
  Bash-dependent helper tests; those tests passed on the macOS CI runner.
- UI preview run `41762822328` passed; its home/detail screenshots were inspected.
- NAS integration run `41762819399` exposed heap corruption after playback
  cleanup. Commit `cc280ca` removes forced SMB disconnection during a source
  reset so acquired reads retain their connection until completion. It adds a
  deterministic regression for both reset paths. NAS run `41764155265` passed
  all 20 simulator tests, and CI run `41764157884` passed the updated tvOS build
  and core/helper tests.
- Another active task added development validation in `0c97b64`; it was merged
  without discarding either task's changes (`8e32c7f`).
- The private fix is on `codex/fix-catalog-refresh`, commit `976a454`. Catalog
  loading now starts independently of playback authorization, with a gated
  regression test. The hosted slow-catalog test uses deterministic entitlement
  data; real StoreKit purchase/refund/restore tests are retained. Unsigned
  commercial run `41764500086` was approved by the owner and **passed** package
  tests, the app build, and the commercial simulator suite for that exact
  private revision using the existing trusted `main` workflow. TestFlight upload
  was disabled. The fix remains on the private development branch, not `main`.
- Android release preparation now includes an unsigned community AAB, explicit
  environment-based signing opt-in, and [build/NAS test instructions](../docs/ANDROID.md).
  Local tests/lint/debug APK/release AAB passed. Missing and partial settings,
  an invalid opt-in, and a missing keystore were rejected as intended. A bundle
  signed with a temporary validation key passed signature verification; the key
  was removed and the default output rebuilt and verified as unsigned.
  Billing, the commercial Android trial, Play upload, and real-device tests
  remain unfinished; this does not complete Android Stage 7.
- Public implementation revision `e82d53e` passed Android TV run `41765150142`
  and all five jobs in Development validation run `41765150044`: core/helpers,
  tvOS build, all 20 NAS simulator tests, Android tests/lint/APK/AAB, and UI
  previews. Documentation-only follow-ups do not change those tested sources.
- The owner has an Apple TV and **does not yet have an active Apple Developer
  membership**. TestFlight remains blocked on membership, app/account setup,
  signing credentials, and explicit upload approval. Unsigned simulator
  validation can continue.
- The `commercial` environment still has only `COMMERCIAL_REPO_TOKEN` as a
  secret. Do not ask the owner to paste signing credentials into chat.

## Continuation — 2026-11-04 (UTC), cloud review and library upgrades

This section supersedes earlier branch/readiness statements. The owner requested
a deep review of both public TV apps, fixes, Infuse-inspired improvements, GitHub
pushes, and merging development into `main` after both platforms pass validation.
The owner explicitly chose to **leave GitHub's repository description unchanged**;
do not follow the older instruction to edit that description.

### Completed reliability review

The reviewed reliability baseline `926992277097299effb7f39541e8e3944aa94887`
was fast-forwarded to `main` after all development and Android checks passed.
Its post-merge CI (`41772046761`), NAS integration (`41772046731`), and Android
(`41772046660`, 21 runtime tests) also passed.

- Both platforms: filename/release-tag parsing, folder TMDB tags, sample/trailer
  exclusion, old release years, and empty automatic-match input are corrected.
- tvOS: source-generation checks reject stale SMB/scanner results without
  disconnecting acquired reads; playback stop is idempotent and ignores late
  callbacks. Metadata intent tracking preserves manual selections, reset restores
  explicit filename/folder tags, and deleted movies cannot receive late responses.
- Android: failed credential decryption reports an actionable error instead of
  silently using an empty password or replacing its key. Room metadata/scanning
  mutations preserve manual choices and reject changed/deleted source state.
  Ref-counted SMB sessions retain active reads and invalidate stale setup/retries;
  Media3 byte ranges, EOF, and failed-open cleanup follow the DataSource contract.
- Android progress saves, manual edits, and resume reads share ordering. Player
  recreation preserves pause state. TV tab restoration waits for layout and
  acquires window/view focus before restoring the selected tab.

### Personal library upgrades

Both tvOS and Android TV now support a persistent local Watchlist with a detail
action, Home shelf, and Movies filter. Watching/resetting progress does not remove
an item from the Watchlist. Movies also saves genre, NAS source, and decade filters;
deleting a selected source safely falls back to All sources.

Android uses an explicit non-destructive Room 1-to-2 migration with a default-false
Watchlist column. tvOS uses an additive default-false SwiftData property. Migration
tests reopen frozen legacy stores and preserve existing metadata, progress, and
source/credential mappings. Field-specific updates prevent later scans/metadata
from overwriting Watchlist state.

Android filter controls remain composed outside the recycled poster grid when
results become empty, preserving D-pad focus. The Movies layout fits a full row
below the expanded filters; Home/Search retain their existing poster size.

Official Firecore GitHub sources were accessible, including InfuseSync. Firecore's
website/support pages and the App Store listing were blocked by this environment's
network policy, so a complete current Infuse feature comparison was not verified.
No Firecore artwork/code, cloud sync, Trakt, or new media-server integration was added.

### Validation and branch result

Upgrade source revision `b206a00de35be1eb5a3d99c78ec9e8ff089f65f7` passed all
five Development validation jobs in [run 41778573506](https://github.com/dinesh-devkota/CineVault/actions/runs/41778573506)
and both Android jobs in [run 41778573525](https://github.com/dinesh-devkota/CineVault/actions/runs/41778573525).
All 26 Android runtime tests executed successfully, with zero failures or skips.
The following handoff-only commit fast-forwards this reviewed history to `main`
and keeps the development branch at the same commit. Post-merge results are
available from the main CI, NAS integration, and Android workflows.

The final source coverage is 67 JVM tests (38 core, 29 app), 19 Swift core tests,
41 tvOS app tests, 26 Android instrumentation tests, and 5 Python helper tests.
Android debug/release lint has zero errors and the same three documented warnings.
Debug/release APKs and the unsigned community AAB build successfully. Hosted Android
tests include H.264 frames and an 8-second seek over the synthetic SMB share,
credentials, migration, persistence, and remote-control navigation.

One hosted emulator attempt timed out before boot with zero tests. The Android
runtime job now pins Ubuntu 24.04 and waits for udev device-permission updates
before checking KVM access; a premature KVM check was corrected. These failed
infrastructure runs do not count as executed application tests.

The Watchlist UI test refreshes API 34+ accessibility caches before querying exact
visible text. UIAutomator 2.3 otherwise searched stale Compose labels, while its
diagnostic getters refreshed those same nodes. This produced a false failure
despite the expected text, focused button, and saved filter being present. The
test keeps its D-pad sequence and timeout, requires nonempty visible bounds,
and lets lookup exceptions fail instead of treating them as absent text.

### Environment and remaining limits

The Linux toolchain and helpers are in `/workspace/.cinevault-env`; follow
`docs/CLOUD-DEVELOPMENT.md`. Keep the existing checkout and preserve current work.
Use the activation script and `flock /tmp/cinevault-gradle.lock` for shared Gradle
runs. This machine has no Android emulator or macOS/Xcode; platform runtime tests
run through GitHub Actions. Git HTTPS reads/pushes work with existing injected
authentication. GitHub API access remains blocked here; do not proxy API requests
through CI or ask for a token solely because `gh` cannot reach the API.

Physical Apple/Android TV, real NAS variants, broad codec coverage, signing,
TestFlight/Play publication, and Android billing remain separate work. The private
commercial validation described above is historical and was not repeated by this
public review. No signing/store upload or repository description edit occurred.
Saving the onboarding configuration does not publish the environment or prove
restoration in a fresh task; publication remains a user action in environment settings.

## Continuation — 2026-11-04 (America/Chicago)

- Installed an API 36 x86_64 Android TV emulator on the owner's Windows PC.
  Hardware acceleration is available. Reduced the virtual display to 720p,
  enabled touch input and host GPU rendering, and installed the development APK.
- Android now has a guided NAS setup: ten-second Bonjour/mDNS discovery,
  address/port autofill, guest share enumeration with sign-in and manual-share
  fallbacks, folder browsing, and validation before saving encrypted credentials
  and starting the scan. TV Material controls now also accept pointer taps.
- Local core/app tests, lint, and debug APK build passed. Lint still reports
  zero errors and the same three warnings. User Escape interrupted desktop UI
  validation; pointer behavior, authenticated NAS access, and playback are not
  yet verified. Do not describe these as completed real-device tests.
- The physical NAS answered an SMB Bonjour query from Windows, and direct
  TCP access to its SMB port from the emulator succeeded. The emulator's NSD
  search returned no devices: physical LAN announcements are not reaching this
  emulator setup. Use manual address entry for the local NAS test; do not
  hardcode the owner's address or credentials in the app.
- The owner requested pushing this work to the development branch and adding
  the same NAS setup experience to Apple TV. No main merge or store upload was
  requested. Apple Developer membership remains unavailable.

### Cine-Media library and playback update

- Display name is now Cine-Media; app IDs and existing library data stay compatible.
- Both platforms scan video and audio recursively, save discovered items in batches,
  report progress, and mark absent items missing only after traversal completes.
  Swift final-save failures restore missing flags and the previous scan date.
- TV filenames (S01E02, 1x02, or numbered files in Season folders) produce local
  show → season → episode browsing. TMDB TV endpoints provide show/season posters
  and episode details/stills with cached lookups. Matched genres determine film
  categories; audio remains Music. Room v3 adds nullable episode fields using
  non-destructive migrations. SwiftData fields are additive and optional.
- Added playback title/details and visible Back controls, manual TV matching, and
  Settings → Media Guide & Help on Android and Apple TV. Read docs/MEDIA-GUIDE.md.
- A read-only check of the owner's emulator confirmed the Media-root source
  completed with 24,722 present items and a saved last-scan timestamp. A second
  Movies-only source contains 503 overlapping items; neither source was removed.
  No online title matches existed at this check. The owner must enter their own
  free personal TMDB key in Settings; never request the key in chat.
- Android core/app tests passed during development. Final APK installation,
  focused runtime checks, and hosted Apple validation are tracked in the chat.
  Do not run the entire Android instrumentation suite on the owner's emulator:
  navigation tests clear app data. Use isolated CI for the full suite.
- Prior development run 41875619174 exhausted GitHub macOS arm64 runner capacity;
  no Apple job executed. Development validation now uses supported macos-15-intel
  runners. Windows cannot compile or run tvOS locally; physical Apple TV testing
  and signing remain outstanding until Apple account/device prerequisites exist.

### TV grouping correction — 2026-11-04

- Fixed Android and Swift recognition of bracketed `1x02`, spaced `S01 E02`,
  and `S01xE02` markers, plus prefixed/repeated season directories. The nearest
  series folder takes precedence, so intermediate folders such as `Completed`
  do not merge unrelated shows. Local grouping needs no metadata key or rescan.
- Home Watchlist and Unwatched rows now collapse episodes into one show tile
  before limiting the row to 20 items. Each tile opens seasons and episodes;
  row filters remain intact. Continue Watching and Search retain episode results.
- Read-only validation against the owner's existing library found all 192 `24`
  episode files grouped into one show with eight seasons of 24 episodes each.
  Two unnumbered bonus clips remain separate; the media guide explains Specials.
- Local Android validation passed 96 JVM tests (54 core, 42 app), debug lint
  with zero errors and three existing warnings, and both debug APK builds.
  The updated app was installed without clearing the user's library. The owner
  confirmed grouping looks fixed and requested a push and merge to the default
  branch, which is `main`. Hosted Apple and Android validation must be checked
  before that merge; do not infer success from the local Android results.
- The user stopped desktop control with Escape before the automated visual
  navigation check completed. Do not describe that click-through as verified.
- TVNavigationTest now refreshes API 34+ accessibility caches before polling
  visible labels, matching the existing Watchlist test and preserving D-pad
  actions and all screen assertions. Run the full suite only in isolated CI.

### Validated merge baseline

Source revision `36c3cde36f27d18563f5677f410e580800b69c53` passed every job in
[Development validation 41940552196](https://github.com/dinesh-devkota/CineVault/actions/runs/41940552196)
and [Android validation 41940552154](https://github.com/dinesh-devkota/CineVault/actions/runs/41940552154).
Swift core passed 38 tests plus five build-helper tests. The unsigned tvOS build,
Apple TV simulator NAS/runtime tests, and Home/detail/NAS preview captures passed.
Android passed all 32 runtime tests with zero failures or skips, plus unit tests,
lint, debug/release builds, and unsigned AAB packaging. These results validate the
earlier scan/share fixes as well as the TV grouping correction.

The owner explicitly authorized merging development into the default branch
after these checks. `main` is an ancestor of this revision, so a fast-forward
preserves all existing main history. This final handoff update changes only
documentation; its application source is identical to the validated revision.

### NAS exclusions, first-search timing, and media validation — 2026-11-04

- Android and Apple TV source editors now browse the scan root and let the user
  ignore whole folders (including descendants) or individual files. Rules are
  relative to the selected root. Saving hides matching entries immediately,
  preserves watch history, and scans again; including them restores them after
  a successful scan. Connection/share/root changes clear relative rules with a
  notice. Android Room v4 migrates existing source rows without data deletion;
  SwiftData fields are additive and optional. Late scans/metadata cannot revive
  ignored entries.
- NAS discovery now starts its 15-second browsing window after the system's
  discovery-start callback, allows bounded resolution grace, and retries failed
  resolution once. Results publish as they resolve; another scan cannot cancel
  an active search. A delayed synthetic advertisement test exercises first-scan
  discovery after the old 10-second cutoff. Physical emulator/LAN multicast
  forwarding is still network-dependent; do not claim every real NAS was tested.
- Scanning rejects `.d.ts` and `node_modules`, and reads at most 1024 bytes for
  ambiguous `.ts` candidates to distinguish transport streams from TypeScript.
  Existing bad entries disappear after a successful rescan; no NAS files are
  deleted. Real 188/192/204-byte transport streams remain recognizable for the
  catalog, but Android playback accepts only its extractor's 188-byte layout.
- Audited official Android Media3 documentation and the pinned 1.8.0 extractors.
  M2TS, WMA, and AIFF/AIF are not playable in this Android build. Both platforms
  gate Play controls by their actual container candidates and reject code paths;
  Android rechecks legacy `.ts` content before playback. Apple TV asynchronously
  loads asset playability, protects history on failure/cancellation, and surfaces
  native-player failures. Actual codec support still depends on the device.
  See `docs/MEDIA-GUIDE.md` for the audited table and primary-source links.
- Local Android build passed 118 JVM tests, debug lint (0 errors, 3 existing
  warnings), and debug/test APK assembly. Both APKs were installed with `-r` on
  the owner's emulator without clearing app data after the owner confirmed the
  metadata fetch had finished. All 18 isolated scanner, migration, metadata, and
  late-discovery runtime tests passed. Never run the full instrumentation suite
  on this emulator: other navigation tests clear the actual library.
- Five Python build-helper tests passed using Git Bash on Windows. The system
  `bash.exe` points to unavailable WSL and fails these helpers with exit 127;
  prefix the test process PATH with Git's `bin` when running them locally.
- Source revision `9be5bfb7fc8274928dd928f6cc51d7f6393e2f4f` was pushed to the
  development branch. [Android validation 41952554309](https://github.com/dinesh-devkota/CineVault/actions/runs/41952554309)
  passed both jobs: 40 runtime tests executed, zero failures or skips, plus unit
  tests, lint, debug/release builds, and unsigned AAB packaging.
- [Development validation 41952554325](https://github.com/dinesh-devkota/CineVault/actions/runs/41952554325)
  passed 54 Swift core tests, five helper tests, the unsigned tvOS build, all 70
  Apple simulator tests (including real SMB playback/seek through asynchronous
  asset preparation), and the Android build. All three OCR-verified preview
  screens passed (Home, detail, NAS). The preview job then failed only because
  GitHub's artifact upload service timed out after five retries; diagnostic
  upload also timed out. Do not call the whole workflow green or treat this as
  an app/capture failure. No duplicate workflow was dispatched for the upload.
- Reopening the installed app started its normal NAS rescan. The source editor
  visibly contains the new scan-folder control; folder controls stay disabled
  during scanning. No source values or exclusion selections were changed in the
  visual check. A later read-only database count confirmed the rescan completed
  at 2026-11-05 02:11:06 UTC: 9,026 items remain present, with zero present `.d.ts`
  files and zero present `node_modules` entries. Old records remain missing to
  preserve history; NAS files were not deleted. No credentials were selected or
  printed during the count check.
- The default branch remains at the prior TV-grouping baseline. No signing,
  TestFlight, store upload, or new physical Apple TV test occurred.

### November 10, 2026 — NAS picker and device testing

- The failed preview upload recovered on the second attempt. All five jobs in
  [development validation](https://github.com/dinesh-devkota/CineVault/actions/runs/41952554325)
  passed. The [downloadable screenshots](https://github.com/dinesh-devkota/CineVault/actions/runs/41952554325/artifacts/13797961908)
  contain the Home, detail and NAS screens at 1920 × 1080.
- The owner has Windows and a physical Apple TV. The README now covers the
  Windows-to-TestFlight installation and NAS playback check. Apple Developer
  Program enrollment and signing setup are still needed for this route.
- `SourceEditorPickerTest` exercises Edit NAS against the disposable Android CI
  share. It selects `MediaChecks`, excludes one folder and one individual file,
  and checks the scan results and the saved settings after reopening the editor.
- On development revision `e4559ee`, the [Android TV run](https://github.com/dinesh-devkota/CineVault/actions/runs/42894313012)
  passed the build, unit tests, lint and packaging. All 41 device tests passed
  with zero skips. The [runtime report](https://github.com/dinesh-devkota/CineVault/actions/runs/42894313012/artifacts/13799713150)
  confirms the editor test completed the scan and indexed only `MediaChecks/clip.ts`.
- All five [development checks](https://github.com/dinesh-devkota/CineVault/actions/runs/42894312382)
  passed on the same revision, including 70 Apple TV simulator tests with zero
  failures and the [Home, detail and NAS previews](https://github.com/dinesh-devkota/CineVault/actions/runs/42894312382/artifacts/13800816235).
  The public app is ready to fast-forward to `main`. Physical Apple TV playback
  remains pending the owner's TestFlight setup.

### November 10, 2026 — library browsing update

- Public development and main were brought to `d0a1415`. All three default-branch
  workflows passed, including [CI](https://github.com/dinesh-devkota/CineVault/actions/runs/42896103979),
  [NAS integration](https://github.com/dinesh-devkota/CineVault/actions/runs/42896103732), and
  [Android TV](https://github.com/dinesh-devkota/CineVault/actions/runs/42896103888).
- The owner requested friendlier browsing and classification, and explicitly
  chose multiple selections per filter. Genre, Source and Decade now use lists
  with checked selections and Apply/Cancel. Sort, Show and Section allow direct
  selection. Clear filters preserves the chosen section and sorting.
- Existing single selections load into the new sets. Multiple choices match
  any selected value in one field and must satisfy each active field. Option
  lists include the current section's available genres and decades, including
  hidden titles when browsing Hidden.
- The classification rules recognize documentary-film, concert and music-video
  folders, preserve folder hints when matched metadata has no genres, and accept
  explicit episode-only names inside numbered season folders. Concert videos
  remain eligible for film metadata. Automatic matching requires sufficient
  title similarity before using a year bonus and exact normalized titles for
  names of three characters or fewer.
- Reviewed [Infuse releases](https://firecore.com/releases) and
  [Jellyfin Android TV 0.20](https://jellyfin.org/posts/androidtv-v0.20.0/) for
  browsing improvements. The owner specified
  [OpenSweep](https://github.com/yashrajnayak/OpenSweep) as a coding/build reference.
  Its explicit checklists, focused self-tests and packaged-app validation informed
  the implementation and validation.
- The Android filter navigation checks passed on a separate empty test TV,
  including multiple selections, saved preferences, Back cancellation, source
  removal and applying with the remote. Apple preview workflows now capture the
  production Genre picker with Adventure and Drama checked.
- Revision `64ec2d7` passed [Android TV validation](https://github.com/dinesh-devkota/CineVault/actions/runs/42900395813)
  with 42 runtime tests, zero failures and zero skips. All five
  [development checks](https://github.com/dinesh-devkota/CineVault/actions/runs/42900395028)
  passed, including 59 Swift core tests, five build-helper tests and 72 Apple TV
  simulator tests. Local Android unit tests passed all 125 cases.
- The configured `CineVault_TV` emulator received the tested APK with `install -r`.
  Its installed checksum matched the local build. The temporary empty emulator
  used for destructive navigation tests was removed afterward.
- Both filter screens were visually checked. The
  [Apple preview archive](https://github.com/dinesh-devkota/CineVault/actions/runs/42900395028/artifacts/13803401021)
  contains Home, details, NAS and the selected Genre list.

### November 10, 2026 — NAS connection polish

- The owner requested a polished NAS connection flow on both TV platforms.
  Setup now separates discovery/address, sign-in, shared-folder selection and
  media-folder selection, tries guest access first, and offers manual shares for
  NAS devices that restrict enumeration. Folder failures retain context with
  retry and parent navigation. Optional ports and manual paths stay collapsed.
- Both platforms validate pasted SMB/Windows addresses, hostnames, IPv4/IPv6 and
  custom ports consistently. Authentication failures request credentials;
  ordinary connectivity and missing-folder failures do not.
- Editing freezes connection fields while checking/saving, clears obsolete
  success messages after edits, cancels stale requests, and confirms removal.
  Android save-to-scan handoff survives screen disposal. Apple request-specific
  connections prevent a canceled check from invalidating a newer retry.
- Added address, error-classification and Apple form regression tests plus
  `NasSetupNavigationTest` for remote navigation, validation, known-share recovery
  and actual persistence/scanning against the hosted synthetic NAS. The required
  Android runtime set includes this test. Apple previews include the ready media
  folder screen in addition to live discovery.
- Initial local Android checks passed all 131 unit tests, debug lint and APK/test
  assembly. The new form/sign-in emulator test passed on isolated
  `CineMediaNasUITest`; visual review also found the NAS on the first discovery.
  Hosted validation and final deployment evidence will be recorded below.
- Revision `ce5d067` passed all five
  [development checks](https://github.com/dinesh-devkota/CineVault/actions/runs/42905475679),
  including unsigned Apple device/simulator builds, NAS integration, core tests
  and the [five-screen preview archive](https://github.com/dinesh-devkota/CineVault/actions/runs/42905475679/artifacts/13806070574).
  Discovery and media-folder screenshots were visually reviewed.
- Final review also made Android folder/ignore browsing use the same normalized
  validation as Save/Test; invalid nonempty ports no longer fall back to 445.
  Its targeted editor test passed locally. The first hosted setup-navigation test
  sent a second Back before its child folder finished opening; synchronization
  now waits for the expected folder and successful listing without increasing
  timeouts or removing navigation coverage.
- Final Android revision `5f21395` passed
  [Android TV validation](https://github.com/dinesh-devkota/CineVault/actions/runs/42907195500):
  build, unit tests, lint, packaging and **45 runtime tests, zero failures or skips**.
  Both new local form/picker regressions also passed on the disposable TV.
- Installed the final APK on the owner's `CineVault_TV` using `install -r` after
  confirming its device identity. The installed SHA-256 matched the tested APK
  (`2ce75b8ec39ea75c5b3ec2f231b29456b3636da5eb33639d114578a16a5e1506`).
  No app data was cleared. The owner emulator was closed normally afterward;
  the isolated test AVD was removed. Other project emulators were not changed.
- The final revision also passed all five
  [development checks](https://github.com/dinesh-devkota/CineVault/actions/runs/42907195486),
  including Apple device/simulator builds, NAS integration and preview capture.
  Public development and main are ready to receive the validation-notes commit
  together. Physical Apple TV installation/playback remains pending signing and
  the owner's device setup; no TestFlight or store upload was performed.

## CoveShelf name and NAS photos (2026-11-10, validation in progress)

- Owner selected **CoveShelf** and authorized renaming the public repository.
  The public repository is now `dinesh-devkota/CoveShelf`, and the local origin
  points to it. The local workspace, existing development branch, private
  package, app/bundle IDs, database and credential keys remain unchanged.
- Both TV apps add a dedicated Photos tab, albums grouped by NAS source and
  parent folder, native-decoded thumbnails and a full-screen viewer with
  Previous, Next, Back and Try again. Photos never enter TMDB matching or the
  video player. Source edits, ignored paths and rescans invalidate photo views.
- Image loading has bounded file size, decoded size, concurrency and cache use.
  JPEG, PNG, WebP, HEIC and HEIF are candidates; actual decoder support is
  device-dependent. EXIF orientation is honored. The guide covers photo setup.
- Synthetic photo fixture share `COVEPHOTOS` is separate from the existing video
  share. It includes JPEG/PNG/WebP, an EXIF-rotated JPEG, corrupt data and a sparse
  oversized file. Hosted tests must exercise the authenticated share; do not
  retry the previously quarantined Windows Impacket installation.
- Two Apple photo preview screens were added to hosted preview validation.
  Android runtime validation requires `NasPhotoIntegrationTest` with no skips.
- Local Android validation passed 137 JVM tests (zero failures/skips), lint and
  debug/app-test packaging. Both `TVNavigationTest` remote-navigation and
  activity-recreation tests passed on the isolated TV emulator.
- Photo/name batch is public development revision `3de3bf0`, with hosted
  [development validation](https://github.com/dinesh-devkota/CoveShelf/actions/runs/42912918780)
  and [Android runtime validation](https://github.com/dinesh-devkota/CoveShelf/actions/runs/42912918784).
  Both app builds, core tests and all seven Apple previews passed. Apple ran
  91 simulator tests with one old scan-summary assertion failure; Android ran
  47 runtime tests with one album-navigation failure and no skips. Native photo
  decoding and SMB photo tests passed on both platforms. Do not merge yet.
- Follow-up validation reproduces Android album clicks falling back to the Home
  tab when the focused card is removed. A local synthetic `PhotoNavigationTest`
  covers opening/Back while source observations change. The scan-summary test
  now includes photo counts and injects its metadata dependency. Retry and queued
  cancellation tests wait for observable state transitions, rather than accepting
  a previous result. Apple photo cards are being refined after visual review.
- The Android focus repair keeps a stable focus target during album/grid changes,
  then restores the selected card after layout, with snapshots rejecting stale
  requests. Offscreen fallback targets scroll into view. The local album
  regression and both tab-navigation/recreation checks passed together (3 tests).
  Apple photo-card contrast and singular counts are corrected; updated Home and
  detail documentation screenshots show CoveShelf. Final hosted rerun is pending.
- Private companion revision `7649f3f51f48788628c06439249ae4c7d5b86055`
  on `codex/fix-catalog-refresh` updates only visible app names and the public
  privacy link. Package, purchase, credential and repository IDs are preserved.
  It has not been through a new protected commercial build or merged to main.
- Root owns Gradle and the isolated `CoveShelfPhotoTest` AVD on emulator-5584.
  The owner's `CineVault_TV` is stopped and has not yet received this update.
- Follow-on usability priorities from the Infuse review: one continuation card
  per TV show, explicit next-episode actions, series-aware grouped search and
  reliable remote focus restoration. These are not included in this batch yet.

## Photo validation follow-up (2026-11-15)

Revision `54cc008` passed all five [development checks](https://github.com/dinesh-devkota/mediavault/actions/runs/42916421418).
All 12 Apple TV photo tests passed, including reading from the authenticated
fixture share. The [Android TV run](https://github.com/dinesh-devkota/mediavault/actions/runs/42916421208)
passed 48 emulator tests with zero skips. The earlier photo navigation and
scan-summary failures are resolved.

## Home and TV search (2026-11-15)

- Home opens NAS setup on first launch. A connected, empty library links to
  Sources with scan feedback. A photo-only library links to its albums.
- On both platforms, a series title or genre returns one card per matching show.
  A specific episode title or `24 S02E03` can open an episode directly. A digit
  query such as `24` skips standalone media whose only match is the year `2024`.
- Remote Back restores the search context. A show tracks available episodes
  when metadata or source rules change. The in-app and repository media guides
  include the new navigation and search examples.
- Local Android validation on the final matching change passed 146 unit tests,
  lint and packaging. The isolated emulator passed seven Home, search and photo
  navigation tests, plus two repeat runs of all three search tests. A manual
  first-launch remote check opened NAS setup from Home.
- The final [Android TV validation](https://github.com/dinesh-devkota/mediavault/actions/runs/43802132668)
  passed all 52 runtime tests with zero skips. The saved `CineVault_TV` emulator
  received the in-place update. Its installed SHA-256 matched the tested APK
  (`cf51def5b6fe7bc71d882ee47694c380cae1d55ab40a55fbf68eb1523042e872`).
  The emulator was closed after verification.
- Public development revision `1c157f8` passed all five [development checks](https://github.com/dinesh-devkota/mediavault/actions/runs/43803766845).
  The Apple TV simulator passed 104 tests with zero skips. The UI test entered
  `24` through the native search field, opened Season 2 and Episode 2, then
  used Menu three times to return focus to the original search result. All
  eight [TV previews](https://github.com/dinesh-devkota/mediavault/actions/runs/43803766845/artifacts/14198100237)
  passed visual text checks. The grouped result is in `docs/screenshots/search.png`.
  Physical Apple TV playback still requires the owner's device and signing setup.

## Continue Watching by series (2026-11-16)

- Public development revision `72507b9` adds one Home card per active series
  on both TV platforms. The card opens the exact paused copy or the next
  unwatched episode. Numbering gaps display **Next available** and the target
  episode number. A button on episode details opens the next episode's details.
- Suggestions use played time and current source rules. Specials stay in their
  own sequence. Progress is specific to the selected file. Playback still
  goes through the existing player and authorization checks.
- Local Android validation passed 151 unit tests, lint and packaging. All nine
  Home, search and watchlist remote tests passed on the disposable emulator.
  The new test opens `S01E03` after a numbering gap, navigates to `S01E04` and
  back, and verifies the Home card resumes the fourth episode at 2:05.
- The [Apple TV simulator](https://github.com/dinesh-devkota/mediavault/actions/runs/43889101794)
  passed all 110 tests. The remote opened the suggested episode, selected its
  successor and returned to the original detail screen. All eight previews
  passed their visual checks. `docs/screenshots/home.png` shows the gap in *24*.
- Development revision `cbbf604` also restores Android TV remote focus when a
  folder rule removes the show open in Search. All three search navigation
  cases passed on four consecutive emulator runs with this fix.
- Both hosted suites passed on `cbbf604` with zero skips, including all 110
  [Apple TV tests](https://github.com/dinesh-devkota/mediavault/actions/runs/43891556566)
  and 53 [Android TV tests](https://github.com/dinesh-devkota/mediavault/actions/runs/43891556583).
  Android needed a fresh emulator after a boot failure and a test-runner layout
  error while waiting for a NAS folder. The completed run verified that the
  selected folder, ignored files and scan results persisted.
- The owner's saved `CineVault_TV` emulator received an in-place update. Its
  installed APK matched the locally tested build, SHA-256
  `ec288e6d9e9d5b2e1b6f5855dd62df9ea905bea67ee0ff4b4db80952e179cddc`.
  The emulator was closed after verification. Physical Apple TV playback is
  still unverified.

## Bulk watched controls (2026-11-17)

- Work starts from public development revision `55c694e` in the isolated
  `codex/bulk-watched` checkout. The original workspace has the separate
  `codex/mediavault-web-video` branch, whose changes are independent.
- Both TV apps offer Library **Select**, **Select all results**, selection
  counts and watched/unwatched actions. Whole-show and season shortcuts resolve
  all available episodes, including those outside a filtered Watchlist.
  Library selection applies to its current filtered results.
- Bulk changes clear resume positions and preserve last-played timestamps.
  Android serializes an atomic, chunked transaction behind queued player saves.
  Apple uses the existing commercial resume-reset pathway, restores local
  progress on save failure and reports any per-file secure-reset failures.
- Android's persistent Select control keeps focus during show/season changes
  and when watched filters remove every selected card. Its two new remote
  tests and all three existing Search navigation tests passed locally, along
  with the bulk database regressions, 151 unit tests, lint and APK packaging.
  Sample selection and season-dialog screenshots are in `docs/screenshots/`.
- [Android runtime validation](https://github.com/dinesh-devkota/mediavault/actions/runs/44182944633)
  passed all 57 tests with zero skips. The saved `CineVault_TV` emulator
  received the tested Android APK, verified installed SHA-256
  `221eeb852684e8a76fc37f7d83a41db4c99f3da1ae58c6c71e847695bf7db37b`.
- The new Apple remote test exposed a debug-preview lifetime bug: saving a
  season recreated its in-memory store while the screen retained old models.
  The preview now owns the store through `@StateObject`. Production scenes
  continue to use SwiftUI's managed model container. The Search remote test
  waits for a stable card to appear and then gain focus during navigation.
- The user guide includes verified selection screenshots for both platforms.
- Revision `0edff81` passed all 116 [Apple TV simulator tests](https://github.com/dinesh-devkota/mediavault/actions/runs/44189313739),
  with zero failures or skips. Both bulk remote journeys passed, including
  saving one season while leaving the other season unwatched. The final
  Android source passed all 57 [runtime tests](https://github.com/dinesh-devkota/mediavault/actions/runs/44184967734)
  with zero skips. The unsigned Apple release build, 66 core tests, five
  helper tests and eight visual previews had also passed on the feature.
  Physical Apple TV playback remains unverified.

## Media Vault naming and browsing polish (2026-11-17)

- The public app is **Media Vault**, version **1.1.0**, build **2**. Launcher,
  welcome/detail screens, help, privacy text and build display names use it.
  App identifiers, stored credentials and library database names stay stable
  so this is an in-place update. The public repository remains `mediavault`.
- Both platforms remember the last Library section. Unknown saved sections
  and the separate Photos section fall back to Movies. Clearing filters keeps
  the selected section. Existing preference tests cover restoration and fallback;
  Android also exercises tab changes, activity recreation and app relaunch.
- Android Settings shows version/build in its header. Apple Settings includes
  a remote-focusable version/build under About. Bulk selection says Cancel on
  Apple TV, and single-item library counts use singular wording.
- Licensed builds can use private revision
  `a42199e22ba41761831b4aa614a01560a6df0f54` for the new visible name, including
  license errors and StoreKit test display text. Product IDs and Keychain keys
  are unchanged. This revision retains the existing catalog-refresh branch.
- Private main has the independent branding-only revision
  `cc9d2dc772693446eeb7531ba5b3a265aa96a843`; it adds no catalog-refresh changes.
- Local Android validation passed 151 unit tests, lint and packaging. The new
  remote test passed section restoration across tabs, recreation and relaunch,
  preference fallback, and visible version/build. The saved emulator received
  the verified in-place update, installed SHA-256
  `ff52b48cb62158e182d6fbeeef89b7c1fdf69dc586680aa1bf9e0bedc4c32b8f`.
- [Android runtime validation](https://github.com/dinesh-devkota/mediavault/actions/runs/44221498464)
  passed all 58 tests with zero skips. The Apple release build, core tests and
  all eight visual previews passed on `f22b089`. Home and detail screenshots
  were refreshed from that build and checked for the Media Vault name.
- All five [development checks](https://github.com/dinesh-devkota/mediavault/actions/runs/44221499877)
  passed on `f22b089`, including all 116 Apple TV simulator tests with zero
  failures or skips. Refreshed screenshots also show the Cancel label and
  corrected singular count. Physical Apple TV validation remains outstanding.
- The separate `codex/mediavault-web-video` feature branch predates this rename.
  When integrating it, retain these UI changes and update its companion-browser
  instruction to the current app name.

## Exact MediaVault name (2026-11-17)

- The owner clarified the exact display name is **MediaVault**, without a
  space. Version **1.1.1**, build **3**, applies that spelling to public UI,
  launcher labels, current documentation and preview checks. Identifiers,
  credentials and behavior are unchanged from the verified browsing update.
- Private main revision `a5ef1d78b22426b5dfbe2f8cc65f83730560fc39` applies the
  same literal name correction to license UI, messages and test-store labels.
- Local Android build and lint passed; the packaged launcher label was verified
  as MediaVault. The saved emulator received version 1.1.1/build 3 in place,
  with installed SHA-256
  `445d2a27afbd550a97acae232163a65e0a4508a4886060c2bcd027a727e911c4`.
- [Android validation](https://github.com/dinesh-devkota/mediavault/actions/runs/44224505144)
  passed all 58 runtime tests without failures or skips. The Apple build and
  exact-name Home check passed; all-caps detail OCR was inconsistent despite
  correct screenshots. The preview now asserts CFBundleDisplayName exactly,
  retains the Home name check, and checks the detail title and playback action.
- Final [Apple preview verification](https://github.com/dinesh-devkota/mediavault/actions/runs/44226562020)
  passed on `864c5cf`, including the exact packaged name and all eight previews.
  Standalone previews now use the same validated Intel runner as development
  checks. The Home and detail guide images were refreshed from that successful
  run when the work resumed on 2026-11-23.
- OAuth was discussed as a possible future feature. No account service or
  authentication flow has been implemented; the intended OAuth use case is
  still to be selected. Current NAS access continues through SMB credentials.

## Infuse comparison and everyday browsing (2026-11-23)

- The owner deferred OAuth and requested easy usability wins from an Infuse
  comparison. `docs/INFUSE-COMPARISON.md` records existing coverage, official
  references, small improvements, and larger remaining gaps. No OAuth work was added.
- Version **1.2.0**, build **4**, adds **See all** to Home shelves on both TVs.
  Complete collections retain show/season/episode grouping, observe current
  source exclusions, and do not overwrite saved Library filters or sections.
  Back restores the launching shelf/card, with a usable fallback if it vanished.
- Empty Library states offer **Clear filters** or **Open Sources** and explain
  how to add a title to Watchlist. Resume details show an approximate remaining
  time, preferring measured file duration over metadata and omitting unknowns.
- Work was isolated in `.worktrees/mediavault-easy-wins` on
  `codex/mediavault-easy-wins`, based on development `3aa0f4b`. Root's separate
  `codex/mediavault-web-video` checkout and the private repository were untouched.
- Local Android validation passed 157 unit tests, lint, packaging, and all
  related remote journeys. The new restoration test initially measured scroll
  position before focus scrolled the button into view; its corrected baseline
  passed. [Hosted Android validation](https://github.com/dinesh-devkota/mediavault/actions/runs/45222164883)
  passed all 62 runtime tests with no failures or skips, plus debug/release builds.
- The owner's `CineVault_TV` emulator received the update with `install -r`,
  preserving app data. The installed version/build and SHA-256 were verified:
  `5e314a96e753930b22df828dbd53932fc2fda5e41d4a5d534c9483b92968087b`.
  Both the owner emulator and separate disposable test emulator were closed.
- [Initial Apple validation](https://github.com/dinesh-devkota/mediavault/actions/runs/45221452741)
  passed release compilation, core/helper tests, all eight visual previews, and
  124 of 126 simulator tests. The two new Home journeys exposed a first-visit
  bug: Watchlist/Unwatched rows tried to populate state from an empty view.
  Revision `5b33ace` derives their grouped contents directly before rendering.
- The [second full simulator run](https://github.com/dinesh-devkota/mediavault/actions/runs/45224649692)
  again passed 124/126 tests. The shelf was present; recordings then exposed
  skipped header focus and a title immediately returning from its detail screen.
  Revision `63de3ca` uses full-width focus sections and one persistent Home
  NavigationPath. Collection origins are consumed once, so ordinary Home movie
  returns retain native focus. A new model regression covers that distinction.
- [Focused Apple navigation validation](https://github.com/dinesh-devkota/mediavault/actions/runs/45228660043)
  passed 11/12 tests without skips, including last-Watchlist removal. The remaining
  failure came after three consecutive Menu presses in the show journey. Revision
  `67fa97a` now waits for, and asserts, episode and season focus after each press,
  matching the existing Search remote test. No production code changed.
- [Final Apple navigation validation](https://github.com/dinesh-devkota/mediavault/actions/runs/45231530641)
  passed all **12 tests**, with zero failures or skips, on `67fa97a`: all seven
  remote UI journeys and five Home collection model regressions. The show journey
  now verifies restored episode, season, show, and Home focus at each transition.
  The manual `ui_only` option runs all remote UI tests and Home collection tests;
  default push/PR validation continues running the full simulator suite.
  The final change after `63de3ca` was test-only; the earlier full suites covered
  the unrelated simulator tests. Do not report the focused run as a full-suite
  pass. Physical Apple TV playback remains unverified.
- Sample Android full-collection and remaining-time images were inspected and
  added to the guide. Apple Home/detail images came from the passing preview run.

## Subtitles and continuous TV viewing (2026-11-24, validated and merged)

- Work is isolated in `.worktrees/mediavault-subtitles` on
  `codex/mediavault-subtitles`, based on development/main `c78d821`. The root
  `codex/mediavault-web-video` checkout remains separate. Version **1.3.0**, build **5**.
- Both players discover sibling SRT/WebVTT files, offer embedded/local/Off
  choices, and carry subtitle preferences across episodes. Reads are bounded;
  source roots and ignored files/folders remain enforced. Subtitles are not
  scanned into the movie library, and the app never writes them to the NAS.
- The owner approved optional **SubDL** downloads. Setup verifies and securely
  saves a one-time API key, preferred language and automatic-download setting.
  Apple TV offers a QR link to the official account panel. SubDL password login
  and OAuth were not implemented: the verified public API uses API keys.
- The provider clients use the documented v2 API, exact TMDB/episode identity,
  bounded authenticated SRT/VTT downloads from the documented host, and no archive
  extraction. Automatic selection requires an exact release filename match;
  users choose other results manually. Local/embedded captions take priority.
- Direct YIFY lookup was not added: no working official API could be verified.
  User-downloaded YIFY SRT/VTT files can be placed beside the matching video.
- Continuous TV is opt-in, default off. Natural episode completion offers a
  10-second next-available-episode countdown with Play now and Cancel/Back.
  The next file/source is rechecked and receives a new playback session.
  Movies, errors, manual stops and backgrounding must not trigger advancement.
- Private work is isolated in
  `D:\CineVaultCommercial\.worktrees\mediavault-continuation` on
  `codex/mediavault-continuation`, pinned revision
  `f92d3539054e9177abe0d28477abf598cf6f4a2d`. It exposes verified successful
  completion after the final saved checkpoint and allows the public playback
  owner to preserve a licensed session while showing subtitles. The public commercial build
  requires this API. Final protected commercial validation passed on
  `45497639483`; signing and TestFlight upload were disabled.
- Initial public revision `78a544f` passed Android unit tests, lint and builds.
  Hosted checks exposed an Apple compile error, a sidecar filename edge case,
  and an Android JUnit method-signature error that prevented the new continuous
  playback test class from executing. Those issues are fixed; subsequent full
  runtime results are recorded below.
- Live SubDL account verification succeeded in the installed Android app; the
  saved connection and automatic-download flags are true. The emulator clock
  was stuck on November 10; synchronizing it to the host's November 24 time
  resolved the TLS connection failure. A separate authenticated provider search
  and raw download succeeded (83,285-byte SRT, 1,292 timed cues). No credentials
  are included in source, screenshots, or retained provider diagnostics.
  Physical Apple TV testing
  remains unavailable: the owner has Windows and Apple TV, no Mac or active
  Apple Developer membership. Do not re-ask those setup questions.

### Android validation and installation

- [Android validation on `7b82612`](https://github.com/dinesh-devkota/mediavault/actions/runs/45480792759)
  passed **73 runtime tests**, zero failures or skips, plus unit tests, lint,
  debug/release packaging and the unsigned bundle. Local unit checks passed
  **172 tests** (90 core, 82 app).
- Runtime coverage includes real NAS SRT/WebVTT discovery, visible English cues
  before and after a seek, explicit Off surviving player recreation, all six
  subtitle/continuous-playback journeys and all Watchlist navigation regressions.
- Tests exposed two production issues now fixed: `singleTop` prevented creation
  of the next player, and Media3's default sidecar source inferred its duration
  from the final cue's start. `SubtitleMediaSourceFactory` retains the parsed
  final cue end and preserves the primary video's timeline and native parsers.
  Sidecar memory is bounded to eight local tracks plus one selected download.
- The saved `CineVault_TV` emulator received **1.3.0/build 5** with `install -r`.
  The installed APK hash matched the local package:
  `8848f0094f9d295c7970286cf9b93a4584558d672ff39201662f43be74e03efc`.
  Startup and both subtitle settings screens were inspected; saved library cards
  remained present. The saved NAS at `192.168.1.101:445` was unreachable from the
  PC during this check, so no claim of current owner-NAS playback is made.

### Apple validation

- Apple release/core/previews passed. Full
  [Apple validation on `f4fb621`](https://github.com/dinesh-devkota/mediavault/actions/runs/45484118998)
  passed **159/160 simulator tests**. Local caption selection and rendering,
  Off, Automatic, Back cancelling the countdown, and Play now into episode two
  all passed, along with Search/Back focus and the new modal-lifecycle regression.
  Revision `f4fb621` prevents subtitle-sheet presentation from prematurely
  stopping the Apple player. That run's sole failure was reaching the native
  transport's subtitle action with the remote, before action activation.
- [Focused Apple validation on `8f566ac`](https://github.com/dinesh-devkota/mediavault/actions/runs/45488013883)
  passed **15/15 tests**, with zero failures or skips. It verifies the actual
  native controls → Subtitles → English → Done → visible caption journey,
  along with the previous navigation and continuous-playback journeys. Community
  production playback is unchanged from `f4fb621`; the focused iteration changed
  only tests and the DEBUG fixture. The separate commercial lifecycle integration
  in `eb9fd28` still requires protected validation. Together these runs cover
  community Apple validation; the focused run is not a full
  160-test suite pass. Subsequent findings and validation are recorded below.
- The clean countdown from full run `45484118998` and subtitle picker from the
  final focused run were inspected and added to the user guide. Final native
  controls and rendered-caption screenshots were also inspected; caption test
  images remain validation artifacts.
- Public main/development were advanced to `7f9a8fe`. Both post-merge Android
  runs (`45490618424`, `45490618056`) passed all 73 runtime tests plus build,
  lint and unit checks. The initial protected commercial
  run `45490617866` tested public `7f9a8fe` with private `8f45aff`; the owner
  approved the build-only run, and TestFlight upload is disabled.
  Its package tests and unsigned app/simulator builds passed, but licensed
  simulator tests failed; the exact assertion could not be recovered from the
  old encrypted diagnostics.
  The original temporary diagnostics key was not recoverable. A new public
  certificate is configured; its private key is Windows-account encrypted in
  the ignored `.local-diagnostics` directory of the private workspace, with
  recovery instructions there. An encryption round trip passed.
- The current private baseline omitted previously approved catalog fix
  `976a454`, which passed protected run `41764500086`. Its exact patch was
  restored alone as `f92d353`, preserving current branding and playback changes.
  The failed run's precise assertion remains unconfirmed; the combined private
  revision passed fresh protected validation and is now on private main.
- Post-merge development run `45490618030` passed 159/160 Apple tests. The
  remaining native-entry test waited for a private remaining-time element even
  though the transport was visibly open. The revised test keeps actual remote
  focus, action activation, and subtitle-sheet assertions, removing that layout
  assumption. Captions remain covered by the separate playback journey.
- Main NAS run `45490618639` reported success but executed **zero tests**:
  macOS Bash 3.2 rejected an empty selection array under `nounset`. Do not count
  that run as validation. The workflow now keeps its invocation array nonempty;
  both Apple reporting steps fail on missing results, inconsistent counts,
  zero execution, failures, or skipped tests. Six reporting regressions pass.
- Live SubDL responses append an API-key query to raw download links. Both
  clients need to strip that query before retaining results and construct the
  authorized download request from the caller's secure key. The documented
  query-authenticated download succeeded; anonymous and header-authenticated
  requests were challenged by the provider. Movie queries also omit the TV
  season-pack filter, which otherwise hid valid releases. These compatibility
  fixes are committed on `codex/mediavault-subtitles` at `3261ea3`; full Apple
  run `45494772477`, core/release run `45494775738`, and Android run `45494780043`
  were requested. Core/release run `45494775738` passed (71 core tests), and
  Android run `45494780043` passed all 73 runtime tests without failures or skips,
  plus lint, unit and packaging checks. Full Apple run `45494772477` passed
  **163/163 tests**, with no failures or skips, including all three subtitle and
  continuous-playback remote journeys. The hosted reporting regressions passed
  **6/6**. Public main/development include `3261ea3` and the final documentation;
  final licensed validation must use private pin `f92d353`. Local Android
  validation passed 176 unit tests (90 core, 86 app),
  lint, debug packaging, and instrumentation compilation.
- The download fix is now installed in the saved Android emulator. Its APK hash
  was verified as `a12b87928e12fcac604f65b8f3ae55c427dc89293aaedcee7e715d467d39b543`.
  The update preserved the saved SubDL connection and automatic-download flags.
  Actual online captions during owner-NAS playback remain unverified because the
  saved NAS is currently unreachable. The emulator is open for the owner.

### Final state

- Public main and development contain the validated code from `3261ea3` plus
  documentation. Both full post-merge Apple suites on `ab5091f` passed **163/163**
  without failures or skips: main NAS `45497640277` and development `45497640013`.
  Main CI `45497640557` and both Android runs (`45497640425`, `45497639967`)
  also passed. The six XCTest reporting regressions passed in the hosted jobs.
- [Final protected commercial run](https://github.com/dinesh-devkota/mediavault/actions/runs/45497639483)
  passed with public `ab5091f548d8129ebb42d50154c33363f3f5ba86` and private
  `f92d3539054e9177abe0d28477abf598cf6f4a2d`: package tests, unsigned app build,
  purchase identifiers, simulator-test build, and simulator tests. Signing and
  TestFlight upload were skipped. Private main was fast-forwarded to that pin.
- The final follow-up change is documentation only; no application source
  changed after these validations. The original root workspaces remain on
  `codex/mediavault-web-video` and `codex/fix-catalog-refresh` respectively.
- No further account setup is needed for the current Android emulator. Its
  SubDL connection is saved and automatic downloads are enabled. Owner-NAS
  playback and physical Apple TV playback remain the device checks still needed.
