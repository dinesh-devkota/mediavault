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

- Jellyfin merged into development at
  `942b1f289715d4b66650acc7dda8da038a5794a4` after both TV suites passed on
  `5e4890c7be62328bd7f00c2192e5a25ba275e0bc`. It includes HTTPS setup,
  password and Quick Connect, protected credentials, selectable libraries,
  profile-scoped imports, server photos and artwork, direct playback, HLS
  fallback and seeking, text subtitle streams, and optional SubDL searches
  by movie or parent-series identity. Android TV passed 98 cases and Apple TV
  passed 206, with zero failures or skips. The Android phone regression suite
  also passed.
  [Merged Jellyfin PR](https://github.com/dinesh-devkota/mediavault/pull/15)
  · [Android TV](https://github.com/dinesh-devkota/mediavault/actions/runs/45672958713)
  · [Apple TV](https://github.com/dinesh-devkota/mediavault/actions/runs/45676870744)
- Emby has TV setup and secure storage, household-scoped catalog import,
  direct-play range reads, photos and artwork, and provider text captions.
  Android TV passed the photos and captions checkpoint. The unsigned Apple
  build passed on Xcode 26 after restoring the required household core.
  The Apple TV simulator ran 199 tests with zero failures or skips, including
  Emby source entry, catalog and range validation, and household photo access.
  Authenticated Android HLS passed rendering and seek and has been ported into
  the draft. Its combined Android TV suite passed 97 tests with zero failures
  or skips. The port to current development has separate hosted checks.
  Apple TV transcoding remains open.
  [Emby](https://github.com/dinesh-devkota/mediavault/pull/3)
  · [Current development port](https://github.com/dinesh-devkota/mediavault/pull/17)
  · [Android TV](https://github.com/dinesh-devkota/mediavault/actions/runs/45680172178)
  · [Apple build](https://github.com/dinesh-devkota/mediavault/actions/runs/45678384113)
  · [Apple TV](https://github.com/dinesh-devkota/mediavault/actions/runs/45678390628)
  · [Android HLS](https://github.com/dinesh-devkota/mediavault/actions/runs/45677454484)
- Plex uses Plex device PIN linking, discovered servers and selected libraries.
  The Android and Apple TV drafts import movies, episodes and photos, and use
  protected ranges for direct play and seek. Matching server text tracks are
  available when published by the server. Local testing checked the library
  identifier and range contract against an isolated official Plex Media Server.
  The Apple TV simulator ran 212 cases with zero failures or skips, including
  Plex setup by remote, protected catalog and playback. The combined Android
  and Apple TV candidate passed both TV suites, the Android phone suite and
  Swift core tests, then merged to development at
  `290b4a6110f7805e8953c0d1cc4a3503c2284277`. The separate Apple-only branch
  passed an unsigned tvOS release build with identical Apple inputs.
  Android Plex passed 102 TV cases and all four phone cases, including
  authenticated native playback and seek. Live account linking needs a signed-in Plex QA account and an eligible reachable server.
  The preview currently supports direct play and requires a reachable direct
  server connection.
  [Android TV and phone](https://github.com/dinesh-devkota/mediavault/pull/5)
  · [Apple TV](https://github.com/dinesh-devkota/mediavault/pull/21)
  · [iPhone](https://github.com/dinesh-devkota/mediavault/pull/25)
  · [Merged development PR](https://github.com/dinesh-devkota/mediavault/pull/28)
  · [212 Apple TV cases on the combined draft](https://github.com/dinesh-devkota/mediavault/actions/runs/45735035580)
  · [Android TV](https://github.com/dinesh-devkota/mediavault/actions/runs/45734670331)
  · [Android phone](https://github.com/dinesh-devkota/mediavault/actions/runs/45734664627)
- NFS has loopback tests and an opt-in Android debug bridge for four ABIs.
  The app source, both TV playback journeys, tvOS packaging and distribution
  licensing review remain open.
  [NFS](https://github.com/dinesh-devkota/mediavault/pull/8)
- OneDrive uses Microsoft device codes for personal accounts. The owner
  chooses a source folder, and MediaVault stores the refresh credential in
  the device's protected storage. Reconnection verifies the original drive
  and folder. The drafts cover scans, range playback and seek, photos and
  matching sidecars. Android passed 101 TV cases and all five phone cases.
  Live use requires an Entra public client ID configured
  for personal accounts, public client flows and delegated Files.Read. A
  Microsoft test account is required for live validation.
  [Android TV and phone](https://github.com/dinesh-devkota/mediavault/pull/4)
  · [Apple TV](https://github.com/dinesh-devkota/mediavault/pull/22)
  · [iPhone](https://github.com/dinesh-devkota/mediavault/pull/24)
  · [Android TV](https://github.com/dinesh-devkota/mediavault/actions/runs/45734675726)
  · [Android phone](https://github.com/dinesh-devkota/mediavault/actions/runs/45734675767)
  · [Combined OneDrive candidate on Plex-enabled development](https://github.com/dinesh-devkota/mediavault/pull/29)
- Dropbox uses a public app key, a PKCE browser approval and a code entered
  in MediaVault. The Android draft links a folder, protects the refresh
  credential, and imports and reads media over read-only ranges. A real
  Dropbox API app key with Full Dropbox access and the read scopes
  account_info.read, files.metadata.read and files.content.read is needed
  for a live account test, subject to the Dropbox app's access and
  production approval limits. The Android TV run passed all 100 cases and
  the phone run passed all three, with Dropbox cases on both. The Apple TV
  fixture passed on the iPhone branch's shared Apple TV run, with 218 cases
  and zero failures or skips. It covered Dropbox and OneDrive seeking, and
  subtitle discovery at an exact viewer folder grant boundary.
  [Android TV and phone](https://github.com/dinesh-devkota/mediavault/pull/6)
  · [Apple TV](https://github.com/dinesh-devkota/mediavault/pull/26)
  · [iPhone](https://github.com/dinesh-devkota/mediavault/pull/27)
  · [Android TV](https://github.com/dinesh-devkota/mediavault/actions/runs/45735171288)
  · [Android phone](https://github.com/dinesh-devkota/mediavault/actions/runs/45735178417)
  · [Shared Apple TV fixture run](https://github.com/dinesh-devkota/mediavault/actions/runs/45737000473)
- Google Drive uses the platform picker on Android TV and phone when the
  signed-in Google Drive document provider and picker are available, and the
  Files picker on iPhone. Owners can grant a folder when the provider
  supports folder selection or choose individual media and caption files.
  Google handles authentication. The app stores the platform read grant
  or bookmark locally, and uses it for selected-file library and playback.
  The current Android candidate passed all 100 TV and five phone cases,
  including range playback, photos, captions, scoped file reads, and the
  phone source editor.
  Apple TV still needs a compliant companion picker with authorized
  Google OAuth registration before it can offer this provider.
  [Android TV and phone](https://github.com/dinesh-devkota/mediavault/pull/7)
  · [iPhone](https://github.com/dinesh-devkota/mediavault/pull/23)
  · [100 Android TV cases](https://github.com/dinesh-devkota/mediavault/actions/runs/45734155288)
  · [Five Android phone cases](https://github.com/dinesh-devkota/mediavault/actions/runs/45734155291)
  · [Google's limited-input device scopes](https://developers.google.com/identity/protocols/oauth2/limited-input-device)

The user authorized provider merges to development after the exact source
branch passes its hosted emulator and simulator suites, including its named
provider tests. The OneDrive, Dropbox and Google Drive Android drafts now
include Plex-enabled development as a merge parent and have fresh gates for
their combined trees. Earlier provider results remain linked above. Retain draft status while implementation or coverage remains
incomplete. The Windows checkout was unavailable from cloud. The verified
Git bundle contains development and the separate provider and platform refs.

## Subtitle files and downloads

For SMB and WebDAV, place an SRT or WebVTT file next to its video with the same
base name. Use names such as `Movie.en.srt` and `Movie.es.vtt`. For Jellyfin,
MediaVault can play text tracks that the server publishes. Optional SubDL
downloads use the key linked in Settings and require matched metadata. The app
prefers available local or server tracks and caches downloads in the player.
Automated SubDL verification used synthetic search and download responses.

## tvOS submission readiness

The development merge gate is the hosted device-emulation suites. App Store
submission also needs a signed archive built with Apple's current SDK,
physical-device validation, active Apple Developer membership and current
provider approvals. Apple decides approval. The public tvOS release checkpoint
passed on the current SDK and verified the bundled privacy manifest and policy.
[Apple release build with merged Jellyfin](https://github.com/dinesh-devkota/mediavault/actions/runs/45681021201)
· [Privacy and release readiness PR](https://github.com/dinesh-devkota/mediavault/pull/14)

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
[App Store SDK requirements](https://developer.apple.com/news/upcoming-requirements/)
[Export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/)

## Android phone branch

`codex/mediavault-android-phone` branches from Android TV WebDAV/household checkpoint `1cbd47977ed07222cf6a44400c10a5757b3d5221`. The same Android app exposes a phone launcher and a TV launcher. Phone layouts use touch Material buttons, persistent navigation, compact library and form layouts, and safe areas for the system bars and keyboard. Existing TV navigation and transport are covered by their existing checks.

The separate Android phone workflow runs a clean API 36 phone emulator against the synthetic SMB fixture. It verifies launcher discovery, touch source-form validation, credential entry, folder selection and scan, opening the imported movie and seeking through native playback controls. Phone WebDAV reuses the shared implementation and source editor. This phone smoke covers SMB; WebDAV transport has its existing Android TV fixture. Physical phone testing and app distribution remain separate.


The phone branch merged at `97478bae735f6822789d7d8922fdf0d70a053ad3` after
two Pixel 6 touch journeys and 94 Android TV emulator tests passed. The
merged Jellyfin branch also passed the phone regression suite.
[Phone PR](https://github.com/dinesh-devkota/mediavault/pull/12)
· [Phone emulator run](https://github.com/dinesh-devkota/mediavault/actions/runs/45667689612)

## iPhone

The iPhone draft has an iOS target sharing the existing source and playback
services, with touch navigation, native AVPlayer controls and household
authorization. The unsigned iOS 26.5 build passed. The previous simulator
checkpoint passed 188 of 189, including native playback and seeking, household
access and the underlying HTTPS WebDAV transport. The WebDAV touch journey is
being verified again against the current library accessibility fixes. Keep the
branch in draft through the iPhone checks on the Jellyfin-inclusive
development base. The same candidate passed all 206 Apple TV simulator
cases with zero failures or skips. The draft uses a separate iPhone bundle ID.
[Current iPhone PR](https://github.com/dinesh-devkota/mediavault/pull/16)
· [iPhone simulator](https://github.com/dinesh-devkota/mediavault/actions/runs/45680750211)
· [Apple TV regression](https://github.com/dinesh-devkota/mediavault/actions/runs/45680750202)

## Repository display name

The app displays MediaVault. GitHub rejected the case-only repository rename
because the integration lacks Administration write permission.
