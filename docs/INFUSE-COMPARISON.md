# MediaVault and Infuse: usability comparison

Updated **2026-11-25** for the MediaVault **1.5.0, build 7 feature branch**. Implementation coverage below applies to Apple TV, iPhone, Android TV, and Android phones unless stated otherwise. This is a source review and an official-documentation comparison, not a claim that either app has been tested on every device. See the handoff for completed checks and remaining validation.

## What MediaVault already does

Both MediaVault TV apps already provide recursive NAS scanning, folder/file exclusions, movie and TV metadata, show → season → episode grouping, search, Watchlist, saved multi-select genre/source/decade filters, and bulk watched controls. Continue Watching chooses the paused file or next available episode, including numbering gaps. Source setup has discovery, manual entry, share/folder browsing, saved credentials, connection testing, and scan status. Photos are grouped by source and folder with a full-screen viewer.

These are existing features, not proposed additions. The review used the shared library logic, Home/Library views, show browsers, source editors, playback controls, and regression tests.

## Comparison

| User task | Infuse reference | MediaVault feature branch | Practical next step |
|---|---|---|---|
| Reach a collection from Home | Apple TV supports category Favorites and content Lists. [Favorites & Lists](https://support.firecore.com/hc/en-us/articles/360003184653-Managing-Favorites-Lists) | **See all** opens the complete grouped collection and preserves saved Library filters. | Keep Back/focus restoration and live collection membership covered by remote tests. |
| Return to a favorite category | Categories can be pinned to Home. [Favorites & Lists](https://support.firecore.com/hc/en-us/articles/360003184653-Managing-Favorites-Lists) | Library remembers its latest section and filters, but has no named Home shortcuts. | Later, let users pin a saved filter combination with a readable default name. |
| Avoid episode spoilers | A setting hides unwatched episode descriptions and thumbnails. [Settings](https://support.firecore.com/hc/en-us/articles/360015608854-Settings-Overview) | Episode artwork and descriptions display normally. | Add an optional spoiler preference and an explicit reveal action. Apply consistently to search, shelves, episodes, and details. |
| Continue a series | Automatic next selection and continuous playback are available. [Settings](https://support.firecore.com/hc/en-us/articles/360015608854-Settings-Overview) | Opt-in continuous TV viewing offers the next available unwatched episode with a ten-second **Play now / Cancel** countdown. Specials remain separate; availability and licensed playback are checked again. | Physical-device testing, particularly app switching and NAS interruptions. Intro/credits skipping remains separate future work. |
| Use subtitles | Embedded/local subtitles and OpenSubtitles downloads are available. [Subtitles](https://support.firecore.com/hc/en-us/articles/215090967-Using-Subtitles) | Sibling SRT/WebVTT files, embedded track selection, remembered language/Off, and optional SubDL search/download after one-time secure key setup. Automatic downloads require an exact release match. | More subtitle formats and provider integrations can follow; direct YIFY download access could not be verified. |
| Play varied NAS formats | Broader containers and audio codecs are supported. [Playback specifications](https://firecore.com/infuse) | Native Apple playback plus a pinned VideoLAN engine for additional formats; Android uses Media3 and device decoders. | Validate real file playback and seeking on all four platforms. Physical HDR, audio passthrough and performance remain separate checks. |
| Organize related movies | Automatic TMDB sequel collections and custom collections are supported. [Collections](https://support.firecore.com/hc/en-us/articles/13692816354839-Collections) | Profile-specific named collections and automatic NFO/TMDB movie series, filtered by current access. | Confirm create, rename, membership and deletion using phone touch and TV remote controls. |
| Choose another copy of a movie | Smart Groups combine versions under one item. [Settings](https://support.firecore.com/hc/en-us/articles/360015608854-Settings-Overview) | Matching movies share one poster and offer a labeled version picker. Each file keeps its own watched state and resume point. | Conservative matching avoids title-only grouping without a known year. Files remain unchanged. |
| Use local artwork/metadata | Local artwork and NFO/XML overrides are supported. [Overrides](https://support.firecore.com/hc/en-us/articles/4405042929559-Overriding-Artwork-and-Metadata) | Read-only local movie/show/season/episode details and images on SMB/WebDAV, without a TMDB key. Manual corrections take precedence; online lookup can fill missing fields. | Verify rescan changes, restricted paths, malformed XML and standalone photos. Jellyfin supplies its own catalog metadata. |
| Continue on another device | iCloud sync includes shares and selected library state; watched history and playback position require Pro. [iCloud Sync](https://support.firecore.com/hc/en-us/articles/115000070773-iCloud-Sync) | Saved libraries and progress are local to each installation. | Larger project: identity, media matching, conflict handling, and secure cross-platform sync. |
| Control family access | PIN restrictions and movie/TV rating limits are available. [Settings](https://support.firecore.com/hc/en-us/articles/360015608854-Settings-Overview) | Optional local household profiles with Admin PIN, allowed folders, US movie/TV limits, hidden restricted content and separate viewer history. | Physical TV validation; regional rating systems and cross-device profiles remain separate work. |
| Connect a media server or cloud drive | Native Plex/Emby/Jellyfin integration; cloud connections created on iOS/Mac can sync to Apple TV. [Media servers](https://support.firecore.com/hc/en-us/articles/360006462093-Streaming-from-Plex-Emby-and-Jellyfin), [Cloud services](https://support.firecore.com/hc/en-us/articles/360058061093-Streaming-From-Cloud-Services) | SMB, HTTPS WebDAV, and Jellyfin libraries, including server-negotiated streams. | Plex, Emby, NFS, and native cloud-drive sign-in remain separate integrations. [Effort and setup assessment](SOURCE-INTEGRATIONS.md). |

Infuse's [release notes](https://firecore.com/releases) repeatedly address focus, list refresh, watched-state consistency, grouping, and network recovery. For MediaVault, correctness in those ordinary journeys should take priority over adding more settings.

## Recommended small improvements

The **1.2.0, build 4** implementation adds complete Home collections through
**See all**, direct recovery actions on empty Library screens, and remaining-time
estimates beside Resume. Home browsing preserves saved Library choices; collection
counts reflect grouped shows, and returning from a removed item has a usable focus
fallback. Spoiler hiding and the larger gaps below remain future work.

The **1.3.0, build 5** update adds local/online subtitles and cancellable continuous
TV viewing. SubDL connection validates and stores a key once; explicit Off and
manual track choices take precedence over late downloads. Neither app rewrites NAS
subtitle files. Cross-device sync, spoiler hiding, and intro skipping remain
future work; collections, versions, and additional sources are covered above.

The **1.4.0, build 6** update adds local household profiles. New viewers have no
folder access until Admin grants it. Rating limits use actual US certifications;
unknown video remains hidden when a limit is active. Watch history stays separate
without changing device-wide commercial allowances. Later integration work adds
WebDAV and Jellyfin; this feature branch also includes the phone interfaces.

1. **Complete Home shelves.** Give Movies, TV Shows, Documentaries, Music, Watchlist, and Unwatched a discoverable route to all their items. Keep TV shows grouped. Back should return to the same shelf and control, including after a title disappears from a filtered collection.
2. **Useful empty states.** Distinguish an empty library, an empty saved list, and filters that hide everything. Offer the relevant action in place: connect a source, browse the Library, or clear filters. Do not silently clear saved choices.
3. **Show current state clearly.** Use collection counts and explicit scope labels, stable focus, selected checkmarks, and visible completion/error feedback. Verify that counts describe grouped shows rather than mistakenly counting episodes as shows.
4. **Protect story surprises.** Consider a single spoiler preference with predictable reveal behavior; it should not obscure episode numbering or whether something has been watched.

## Design and acceptance rules

Apple's [design principles](https://developer.apple.com/design/human-interface-guidelines/design-principles) favor clear hierarchy, recognizable controls, concise wording, user agency, and deliberate behavior. For this app that means making the next useful action visible, keeping routine tasks short, and preserving the user's place and choices.

Use native remote conventions and restore focus after dialogs and navigation. Avoid relying on color alone for focus or selection. Allow space for focused controls to grow without covering adjacent content. [Remotes](https://developer.apple.com/design/human-interface-guidelines/remotes), [Color](https://developer.apple.com/design/human-interface-guidelines/color), [Layout](https://developer.apple.com/design/human-interface-guidelines/layout)

For each improvement, verify Android TV and tvOS remote navigation, Back behavior, empty/one/many-item collections, live watched-state changes, removed sources, and persistence where relevant. Preserve library records and credentials. Simulator checks support these tests; physical TV/NAS playback remains a separate validation step.
