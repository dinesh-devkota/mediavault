# MediaVault and Infuse: usability comparison

Reviewed **2026-11-23** against MediaVault development baseline `3aa0f4b` (1.1.1, build 3). This is a source review and an official-documentation comparison, not a claim that either app has been tested on every device. Infuse's Apple TV behavior is used where its documentation distinguishes platforms; iPhone-only features are not counted as TV gaps.

## What MediaVault already does

Both MediaVault TV apps already provide recursive NAS scanning, folder/file exclusions, movie and TV metadata, show → season → episode grouping, search, Watchlist, saved multi-select genre/source/decade filters, and bulk watched controls. Continue Watching chooses the paused file or next available episode, including numbering gaps. Source setup has discovery, manual entry, share/folder browsing, saved credentials, connection testing, and scan status. Photos are grouped by source and folder with a full-screen viewer.

These are existing features, not proposed additions. The review used the shared library logic, Home/Library views, show browsers, source editors, playback controls, and regression tests.

## Comparison

| User task | Infuse reference | MediaVault at the review baseline | Practical next step |
|---|---|---|---|
| Reach a collection from Home | Apple TV supports category Favorites and content Lists. [Favorites & Lists](https://support.firecore.com/hc/en-us/articles/360003184653-Managing-Favorites-Lists) | Home shelves preview at most 20 grouped cards, without a full-shelf destination. | Add a visible **See all** action. Open the complete shelf without changing the user's saved Library filters. |
| Return to a favorite category | Categories can be pinned to Home. [Favorites & Lists](https://support.firecore.com/hc/en-us/articles/360003184653-Managing-Favorites-Lists) | Library remembers its latest section and filters, but has no named Home shortcuts. | Later, let users pin a saved filter combination with a readable default name. |
| Avoid episode spoilers | A setting hides unwatched episode descriptions and thumbnails. [Settings](https://support.firecore.com/hc/en-us/articles/360015608854-Settings-Overview) | Episode artwork and descriptions display normally. | Add an optional spoiler preference and an explicit reveal action. Apply consistently to search, shelves, episodes, and details. |
| Continue a series | Automatic next selection and continuous playback are available. [Settings](https://support.firecore.com/hc/en-us/articles/360015608854-Settings-Overview) | One Continue Watching card per active show; next-episode links exist. Playback does not automatically queue the next file. | Keep current suggestions; evaluate opt-in continuous playback separately with cancellation and entitlement checks. |
| Organize related movies | Automatic TMDB sequel collections and custom collections are supported. [Collections](https://support.firecore.com/hc/en-us/articles/13692816354839-Collections) | Series grouping and Watchlist exist; movie franchises and named collections do not. | Add later after defining grouping, duplicate handling, and editing behavior. |
| Choose another copy of a movie | Smart Groups combine versions under one item. [Settings](https://support.firecore.com/hc/en-us/articles/360015608854-Settings-Overview) | Files remain distinct; episode suggestions avoid selecting an arbitrary duplicate when a paused copy exists. | A future version picker needs clear source/format labels and progress rules. |
| Use local artwork/metadata | Local artwork and NFO/XML overrides are supported. [Overrides](https://support.firecore.com/hc/en-us/articles/4405042929559-Overriding-Artwork-and-Metadata) | TMDB fetching and manual match/title correction exist; sidecar metadata is not imported. | Useful future work for home videos and offline libraries; it needs filename and precedence rules. |
| Continue on another device | iCloud sync includes shares and selected library state; watched history and playback position require Pro. [iCloud Sync](https://support.firecore.com/hc/en-us/articles/115000070773-iCloud-Sync) | Saved libraries and progress are local to each installation. | Larger project: identity, media matching, conflict handling, and secure cross-platform sync. |
| Connect a media server or cloud drive | Native Plex/Emby/Jellyfin integration; cloud connections created on iOS/Mac can sync to Apple TV. [Media servers](https://support.firecore.com/hc/en-us/articles/360006462093-Streaming-from-Plex-Emby-and-Jellyfin), [Cloud services](https://support.firecore.com/hc/en-us/articles/360058061093-Streaming-From-Cloud-Services) | Direct SMB sources. | Separate connector projects, not a small UI change. |

Infuse's [release notes](https://firecore.com/releases) repeatedly address focus, list refresh, watched-state consistency, grouping, and network recovery. For MediaVault, correctness in those ordinary journeys should take priority over adding more settings.

## Recommended small improvements

The **1.2.0, build 4** implementation adds complete Home collections through
**See all**, direct recovery actions on empty Library screens, and remaining-time
estimates beside Resume. Home browsing preserves saved Library choices; collection
counts reflect grouped shows, and returning from a removed item has a usable focus
fallback. Spoiler hiding and the larger gaps below remain future work.

1. **Complete Home shelves.** Give Movies, TV Shows, Documentaries, Music, Watchlist, and Unwatched a discoverable route to all their items. Keep TV shows grouped. Back should return to the same shelf and control, including after a title disappears from a filtered collection.
2. **Useful empty states.** Distinguish an empty library, an empty saved list, and filters that hide everything. Offer the relevant action in place: connect a source, browse the Library, or clear filters. Do not silently clear saved choices.
3. **Show current state clearly.** Use collection counts and explicit scope labels, stable focus, selected checkmarks, and visible completion/error feedback. Verify that counts describe grouped shows rather than mistakenly counting episodes as shows.
4. **Protect story surprises.** Consider a single spoiler preference with predictable reveal behavior; it should not obscure episode numbering or whether something has been watched.

## Design and acceptance rules

Apple's [design principles](https://developer.apple.com/design/human-interface-guidelines/design-principles) favor clear hierarchy, recognizable controls, concise wording, user agency, and deliberate behavior. For this app that means making the next useful action visible, keeping routine tasks short, and preserving the user's place and choices.

Use native remote conventions and restore focus after dialogs and navigation. Avoid relying on color alone for focus or selection. Allow space for focused controls to grow without covering adjacent content. [Remotes](https://developer.apple.com/design/human-interface-guidelines/remotes), [Color](https://developer.apple.com/design/human-interface-guidelines/color), [Layout](https://developer.apple.com/design/human-interface-guidelines/layout)

For each improvement, verify Android TV and tvOS remote navigation, Back behavior, empty/one/many-item collections, live watched-state changes, removed sources, and persistence where relevant. Preserve library records and credentials. Simulator checks support these tests; physical TV/NAS playback remains a separate validation step.
