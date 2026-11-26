# Cloud continuation: media sources

## User request and order

The user requested WebDAV on a new branch, then asked to implement all assessed
source integrations in the cloud so work can continue when the Windows PC is
offline. They explicitly asked for at least one more integration. Prioritize a
complete **WebDAV + Jellyfin** implementation on Android TV and tvOS, then Emby,
Plex, NFS, and named cloud providers (OneDrive, Dropbox, Google Drive). Keep
working on independent parts when a provider registration or hardware test is
unavailable. Report those limits precisely; never replace a connector with a
mock or an inert button and call it complete.

Public repository: https://github.com/dinesh-devkota/mediavault

Working branch: `codex/mediavault-webdav`, based on household-profile revision
`d8ed7d0`. The repository's development branch is
`dinesh-devkota-sonepar-build-cinevault-tvos-app`. Keep work on feature branches;
do not merge or release unfinished source integrations. Preserve the user's
existing SMB data, photos, metadata, subtitles, autoplay, and profile controls.

## Original handoff: incomplete Android WebDAV

The new code is an implementation checkpoint, **not a released connector**.

- `android/.../webdav/WebDavService.kt`: bounded PROPFIND XML, endpoint-relative
  paths, origin/root validation, explicit HTTP opt-in, Basic authentication,
  redirect refusal, range validation, streamed reads and reset generations.
- `WebDavMedia.kt`: recursive index with exclusions/content sniffing, progress,
  bounded matching subtitle sidecars. Existing SMB facade routes WebDAV sources
  so photo/player/subtitle callers retain their current access checks.
- Source Room schema 6 adds `sourceType` (existing rows default SMB) and
  `allowInsecureHttp`. Setup offers Connect WebDAV; editor uses the full endpoint
  URL, credentials, existing folder/ignore picker, and connection test.
- Household folder grants add optional/default-false case sensitivity. New
  WebDAV grants use exact case. Ensure other grant/row/path authorization paths
  preserve that distinction.
- New app JVM tests cover URL/path boundaries, XML rejection, multistatus,
  actual local HTTP listing/seeking, reset, redirects and missing range support.
- Android Kotlin compilation passed locally. See the cloud task prompt for
  the final local unit/lint result. No owner emulator was changed.
- **Apple WebDAV has not been implemented yet.**

Review and finish these points before claiming readiness:

1. Review the new transport/parser independently. Enforce valid root responses
   for PROPFIND (including self-only failures), structural XML, response size,
   path encoding/case, source resets, cancellation, redirects and auth scope.
   Verify early EOF, invalid/truncated/changed ranges, zero-byte files, large
   listings, and HTTPS trust failures. Never disable certificate validation.
2. HTTP opt-in exists in the Android UI/config but production network policy
   still needs a deliberate compatible implementation or removal of that
   option. Do not show an option that silently cannot work. Keep HTTPS default.
   Basic auth is implemented; document supported auth and add Digest only if
   properly tested, without silently promising OAuth or arbitrary providers.
3. Avoid duplicated scanning rules by extracting a narrow file-provider
   interface where it improves the architecture. Do not rewrite unrelated code.
4. Finish Apple source migration/config, protocol setup/edit flow, browser,
   scanner, bounded reads and player/photo/subtitle routing. Its existing
   `SMBService` provides listEntries/listFolders/read/fileSize; the players use
   those operations. `SourceConfig` copies in path pickers must retain protocol.
   Apple default SwiftData fields are migration-sensitive; add migration tests.
5. Add real local WebDAV server fixtures and isolated platform integration/UI
   tests for add, bad sign-in recovery, folder choice, exclusions, recursive
   scan, photos, sidecars, seek, reconnect, household restrictions and restart.
6. Update user guide, source comparison and privacy docs with actual supported
   behavior. Current source assessment describes planned work, not completion.

## Source architecture and subsequent connectors

Read `docs/SOURCE-INTEGRATIONS.md` for the assessed protocols and official links.
Use stable provider/source/item identities and capability-based list/read/play
operations. File providers use the scanner; media servers import the catalog,
metadata, movie/show/season/episode hierarchy and playable variants. Separate
provider authentication from local household profiles.

Jellyfin next: server URL, TV-friendly login/Quick Connect, library selection,
paginated catalog, secure tokens, playback negotiation, subtitles, transcoding
when direct play is unsupported, seeks, session/reporting cleanup and clear
connection errors. Add Emby as a separately tested adapter. Plex requires real
account/device linking, server discovery and playback negotiation; subscriptions
may apply. NFS requires native packaging/licensing review and explicit read-only
operations. Cloud drives require each provider's approved OAuth/PKCE or supported
device flow, secure refresh, pagination, temporary download URL renewal, scoped
range reads and revoke/sign-out. Never embed a client secret in a TV app. Missing
app registration must be documented and requested without blocking other work.

Provider items must respect family allowlists in every view and byte-read path,
including metadata images, search, photos, subtitles, playback and next episode.
New sources must not automatically become available to viewers. Per-profile
history must remain separate; commercial trials/purchases are device-wide.

## Validation / current family baseline

Local Windows host has Java21/Android tools, no Xcode. Cloud can run Linux core
tests and provision Android tools; Apple simulator/build validation uses existing
GitHub Actions workflows. Inspect the workflows before dispatching.

Family baseline before WebDAV:

- Public core/release run `45549705200` at `a9574d6`: 76 core tests and unsigned
  tvOS release passed.
- Full Apple simulator run `45549702348` at `a9574d6`: was executing at handoff.
  Check its final result before reusing claims.
- Android run `45549887612` at `d8ed7d0`: 92 baseline runtime tests passed.
  Isolated family UI journey failed because nested ActivityScenario launches
  replaced its task. The subsequent corrected `FamilyNavigationTest` is included
  in this WebDAV checkpoint and compiles; it still needs hosted execution.
- `scripts/test_android_runtime.sh` runs baseline and family fixture in separate
  phases, retains installed APKs, and now pulls screenshots before validating
  family XML even on failure. Never weaken its executed-test evidence checks.

Run appropriate unit/lint/build/runtime checks; inspect actual counts and UI
screenshots. Do not install, reset, seed, or run tests on the owner's emulator.
The owner's NAS is private LAN-only; cloud tests must use synthetic local servers,
not tunnel/expose the home network. User has Windows + Apple TV, no Mac or active
Apple Developer membership. Physical TV/NAS validation remains a separate limit.

The private commercial package is pinned at
`f92d3539054e9177abe0d28477abf598cf6f4a2d`. Do not access/change private package or
copy credentials for this work. Commercial CI requires fresh protected-environment
approval for each updated run. Never bypass it; no store/TestFlight upload.

## Cloud execution and delivery

Use the selected runnable cloud environment, clone the public repository if not
mounted, fetch/checkout the exact feature branch and verify HEAD. Do not use the
unrelated OpenSweep checkout. Confirm repository write access via approved
GitHub connection/normal git tools; never copy local CLI credentials to cloud.
If writes are unavailable, preserve patches in cloud and report the exact missing
connection while continuing implementation and tests. Push reviewable checkpoints
and create draft PRs when supported. Track completion and real blocked items in
this document. Work through independent phases instead of stopping after a plan,
scaffold or first error. Do not promise that the full matrix finishes overnight.

## Cloud implementation checkpoint, November 25, 2026

The cloud checkout started on WebDAV commit
`96b818a45b0768779d09a26e6be1a56a5469fdca`. WebDAV was merged into the
development branch at `0aa5435becece6fcf8e1ee0b15c41e267bce5f8a` after
the checks on `1cbd47977ed07222cf6a44400c10a5757b3d5221` passed.
It supports HTTPS with guest or Basic authentication, source folder selection,
edit/reconnect/removal, scans and exclusions, photos, recognized subtitle
sidecars, and validated range reads with case-sensitive viewer grants.
Android TV ran 94 tests and the Apple TV simulator ran 199, all passing.
Both ran the respective HTTPS WebDAV playback and seek test.
[WebDAV pull request](https://github.com/dinesh-devkota/mediavault/pull/1)
· [Android TV run](https://github.com/dinesh-devkota/mediavault/actions/runs/45662322559)
· [Apple TV run](https://github.com/dinesh-devkota/mediavault/actions/runs/45662323021)

- Jellyfin has TV setup with password or Quick Connect, encrypted provider
  credentials, selectable libraries, protected catalog import, server photos,
  artwork and captions, and separate local profile history. Hosted tests
  played and sought the direct stream on both platforms. The Android setup
  and artwork checkpoint passed 97 emulator tests. tvOS HLS and optional
  SubDL search using imported provider IDs have independent draft checkpoints.
  [Jellyfin](https://github.com/dinesh-devkota/mediavault/pull/2)
  · [Android TV run](https://github.com/dinesh-devkota/mediavault/actions/runs/45662973340)
  · [Apple TV direct playback run](https://github.com/dinesh-devkota/mediavault/actions/runs/45660978470)
  · [Apple TV HLS](https://github.com/dinesh-devkota/mediavault/pull/10)
- Emby has client fixtures for both platforms and Android app wiring for source
  setup, library import and protected direct playback. Apple app integration,
  HLS, and other provider media types still need work.
  [Emby](https://github.com/dinesh-devkota/mediavault/pull/3)
- The Android Plex draft connects an owner’s Plex account by PIN, then stores
  only the selected HTTPS server credential encrypted for each local library.
  Android TV and phone share the setup, catalog, and player. Imports support
  movies, episode grouping and photos. Reading video, artwork and text subtitles
  rechecks the household session. Playback supports single-file direct streams.
  Hosted emulator checks use a disposable HTTPS fixture. Signed-in QA on a real
  Plex server and provider transcoding remain open.
  [Plex](https://github.com/dinesh-devkota/mediavault/pull/5)
- NFS has loopback tests and an opt-in Android debug bridge for four ABIs.
  The app source, both TV playback journeys, tvOS packaging and distribution
  licensing review remain open.
  [NFS](https://github.com/dinesh-devkota/mediavault/pull/8)
- OneDrive, Dropbox and Google Drive have separate provider clients and tests.
  The Android OneDrive draft includes encrypted refresh records, scoped catalog
  and a per-read authorization hook. Account registrations and TV setup/import/
  playback still need completion. Live OneDrive needs an Entra public client
  ID and test account. Dropbox needs a registered app key with the documented
  scopes. Google Drive needs an approved TV-compatible OAuth client and scope;
  verify access before distributing.
  [OneDrive](https://github.com/dinesh-devkota/mediavault/pull/4)
  · [Dropbox](https://github.com/dinesh-devkota/mediavault/pull/6)
  · [Google Drive](https://github.com/dinesh-devkota/mediavault/pull/7)

The user authorized provider merges to development after the exact source
branch passes both hosted emulator/simulator suites, including its named
provider tests. Retain draft status while implementation or coverage remains
incomplete. Android phone and iPhone support have their own branches and
touch-screen test requirements. Keep the Windows handoff as a verified Git
bundle when the Windows checkout is unavailable.

## Cloud implementation checkpoint, November 26, 2026

The development branch includes WebDAV, Jellyfin, Plex, personal OneDrive,
and Dropbox for Android TV, Android phone, and Apple TV. The combined library
and playback PR also adds the iPhone target to development. It passed 115
Android TV cases, 17 Android phone cases, 256 Apple TV cases, and 245 iPhone
cases against disposable synthetic services. The Android package, Swift core,
and both unsigned Apple release builds also passed at the tested merge tree.
[Dropbox #30](https://github.com/dinesh-devkota/mediavault/pull/30)
· [Library and playback #19](https://github.com/dinesh-devkota/mediavault/pull/19)

OneDrive and Plex touch journeys have passed on the separate iPhone provider
branch. The latter exact checkpoint ran 211 iPhone and 219 Apple TV cases.
A focused local port for development preserves the current app's routes and
adds native provider import and seek validation. Dropbox iPhone uses its own
draft. Its exact unchanged retry passed all 217 iPhone and 224 Apple TV cases.
GitHub confirmed the PR merge after the iPhone feature branch was
fast-forwarded to the exact tested `a0210bfb` tree.
[OneDrive iPhone #24](https://github.com/dinesh-devkota/mediavault/pull/24)
· [Plex iPhone #25](https://github.com/dinesh-devkota/mediavault/pull/25)
· [Dropbox iPhone #27](https://github.com/dinesh-devkota/mediavault/pull/27)

Android Google Drive uses the system file picker and checks that each actual
entry stays within the persisted grant. The Android TV fixture at `f8b279d`
passed 117 cases. All three named phone Drive cases passed. The phone test
revision `0bb9033` keeps the actual Back action and checks that it returns to the
selected movie with its playback action available. The corrected head passed
117 Android TV and 20 Android phone emulator cases, with every Drive case
executed. Apple TV passed 259 cases including the shared Swift range client.
One iPhone regression run stopped at a WebDAV TLS handshake. Its unchanged
retry imported the film and then encountered a late system Save Password
sheet over the Library. The Android app and its required TV and phone
journeys are green. The Google Drive iPhone draft passed 221 iPhone and 224 Apple TV
simulator tests, the two unsigned builds, and all four Files-access gates.
It merged into the iPhone feature branch at `0d84915`. Live Drive use
depends on a signed-in Google Drive app enabled in Files. PR #16 ports the
verified iPhone provider flows onto current development at `4d43086`, keeps
the existing offline policy, and adds the Files data flow to that policy.
The exact combined development tree has its own simulator and build checks.
[Development iPhone port #16](https://github.com/dinesh-devkota/mediavault/pull/16) Private Drive on Apple TV needs a registered
Google OAuth/Picker flow and a reviewable HTTPS companion.
[Android Drive #7](https://github.com/dinesh-devkota/mediavault/pull/7)
· [iPhone Drive #23](https://github.com/dinesh-devkota/mediavault/pull/23)

The isolated Emby reconciliation builds both Android app and instrumentation
Kotlin and passed 101 core and 167 app tests. Three other cases require a
configured synthetic service. Exact `de2d54c` passed 119 Android TV cases
across the two reports and 268 Apple TV simulator tests, including native
Emby direct play, authenticated HLS and seeking. The iPhone simulator passed
its native Emby test and failed a separate WebDAV post-import screen check.
The unsigned iPhone and tvOS releases passed.
The NFS pilot passed all five disposable macOS host fixture tests plus both
arm64 tvOS ABI checks at `8c6df87`. A local Android adapter passed six guarded
reader tests, including a real JNI read of a disposable export. App-level NFS
still needs the source workflow, device validation, and distribution packaging
and licensing review.
[Emby #17](https://github.com/dinesh-devkota/mediavault/pull/17)
· [NFS #8](https://github.com/dinesh-devkota/mediavault/pull/8)

Apple privacy PR #14 merged into development at `2157a415` after both
simulators opened the bundled policy from the locked profile picker. Both
unsigned Apple releases verified the manifest and the bundled policy.
Distribution requires an active Apple Developer team, signed archives,
App Store Connect metadata, provider rights, and review access to test media.
The names visible in the apps are MediaVault. Renaming the existing GitHub
repository requires a connection with Administration write permission.
[Apple readiness #14](https://github.com/dinesh-devkota/mediavault/pull/14)

Post-merge validation of `1f819609` found an iPhone WebDAV poster test that
timed out before touching the visible tile and a legacy Apple TV preview
which reached the secure-storage error screen when built unsigned.
The reliability draft keeps the real Film-and-Play check, moves the full
Apple TV development fixture job to the supported macOS runner, and shares
one ad hoc signed preview and OCR script between both preview workflows.
[Apple simulator reliability #31](https://github.com/dinesh-devkota/mediavault/pull/31)

## tvOS submission readiness

The development merge gate is the hosted device-emulation suites. App Store
submission also needs a signed archive, physical Apple TV validation, active
Apple Developer membership and current provider approvals. Apple makes the
App Review decision. This work covers unsigned public builds and documented
checks.

- Give reviewers a reachable, dedicated test service with temporary least-
  privilege credentials and synthetic media the project is authorized to
  distribute. Include steps to add a source, test a bad sign-in, select a
  library, scan, seek, open photos and switch household profiles. The owner's
  NAS and credentials must stay private.
- List the permissions, scopes and connection lifecycle for each provider in
  App Review notes. When a user links an external provider, explain that
  authentication grants access to their existing media. MediaVault household
  profiles are local. Recheck guideline 4.8 if app-level account behavior changes.
- Verify each provider's access, streaming, artwork and branding terms before
  shipping. Save evidence of provider app registration, any required approval and
  redistribution terms for bundled dependencies. Review the intended App Store
  packaging against the NFS library's license before adding it to Apple builds.
- Keep the bundled policy reachable in the app and set its public URL in App
  Store Connect. Update the policy and App Store privacy details before each
  connector ships. Cover token retention, sign-out, provider-visible playback reports,
  library and artwork requests, and any new SDK. Validate the final signed
  binary's privacy manifests and export-compliance declaration.

[App Review guidelines](https://developer.apple.com/app-store/review/guidelines/)
[App privacy details](https://developer.apple.com/app-store/app-privacy-details/)
[Export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/)

## Android phone branch

`codex/mediavault-android-phone` branches from Android TV WebDAV/household checkpoint `1cbd47977ed07222cf6a44400c10a5757b3d5221`. The same Android app exposes a phone launcher and a TV launcher. Phone layouts use touch Material buttons, persistent navigation, compact library and form layouts, and safe areas for the system bars and keyboard. Existing TV navigation and transport are covered by their existing checks.

The separate Android phone workflow runs a clean API 36 phone emulator against the synthetic SMB fixture. It verifies launcher discovery, touch source-form validation, credential entry, folder selection and scan, opening the imported movie and seeking through native playback controls. Phone WebDAV reuses the shared implementation and source editor. This phone smoke covers SMB; WebDAV transport has its existing Android TV fixture. Physical phone testing and app distribution remain separate.

## iPhone

The iPhone integration candidate is on `codex/mediavault-ios-integration`.
It shares the public app’s SMB, HTTPS WebDAV, Jellyfin, and Plex setup, household
rules, database, and native playback code. The iPhone target uses iOS 17 and
later, with touch navigation for administrative settings and
subtitle controls. The app treats each device’s household and library as local.
It does not sync profiles or progress across devices.

Generate the iPhone Xcode project with `xcodegen generate --spec project.ios.yml`.
The `CineVaultPhone` scheme builds the app and runs shared tests and iPhone UI
tests. The hosted `iPhone simulator` workflow builds an unsigned release with iOS SDK 26 or later and runs
simulator setup and playback tests against temporary SMB, WebDAV, Jellyfin, and Plex fixtures.
This app branch needs a green simulator run before merge. Physical iPhone testing,
signing, export-compliance confirmation, App Store Connect setup, and App Review
are separate release steps.

[Original iPhone draft pull request](https://github.com/dinesh-devkota/mediavault/pull/11)

## Plex on Apple TV

The isolated `codex/mediavault-plex-tvos` branch starts at development commit `942b1f2`.
An owner can link using the code shown in Sources, choose an advertised Plex Media Server and choose one movie, TV, or photo library. Reconnect preserves the server and library identity. The source stores its server token in Keychain. Removing the source clears its local catalog and credential. Household profiles need an explicit whole-library grant and keep their local watched, resume and Watchlist records separate from the Plex account.

The implementation supports protected Plex artwork, photo thumbnails, native MP4/M4V/MOV direct play with byte-range seeking, and matching external SRT or WebVTT tracks. A disposable HTTPS fixture covers Plex linking, discovery, catalog groups, paging, media ranges, restricted artwork, and caption playback. The branch also adds a remote navigation test for the owner's setup entry. Local cloud checks use Python transport tests and Swift source parsing. The Apple TV hosted jobs are the compile and runtime gate.

Before shipping, validate a real Plex server and account against Apple TV hardware. Plex transcoding, Relay-only connections, and full-size original Plex photos are pending. Apple simulator and unsigned release checks require no distribution credentials. App Store submission and approval require the owner's separate Apple process.

### Android OneDrive application checkpoint

[Android OneDrive PR #4](https://github.com/dinesh-devkota/mediavault/pull/4)
and [Apple OneDrive PR #22](https://github.com/dinesh-devkota/mediavault/pull/22)
track their platform runtime checks independently.

The Android OneDrive feature branch integrates a personal account through Microsoft's
device authorization, a public client ID, and a read-only Graph connection.
Admin selects the drive root or an explicit folder before saving. The app stages
credentials in memory until approval and folder selection complete. Android
Keystore seals the device refresh record under the local source UUID. Reconnect
checks that the Microsoft drive still matches. Disconnect clears local credentials,
invalidates open handles, and removes the source and its indexed history.

Android TV and phone share the existing scanner, photo viewer, playback,
subtitle and household paths. OneDrive uses exact relative names inside the
selected folder. Each media range resolves the current path to the expected
Graph item ID before following a fresh download grant without the Graph bearer.
The household UI can grant selected subfolders. New sources require explicit
viewer grants. The scanner keeps the existing Android file-path history behavior.

Hosted fixtures are synthetic. Live testing still requires an Entra public
application configured for personal Microsoft accounts and public client device
flow with delegated Files.Read, plus a dedicated OneDrive test account. See
`docs/TESTING.md` for the app setting and build property.
