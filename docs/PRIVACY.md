# MediaVault privacy policy

This policy applies to the official MediaVault app. Independently modified or distributed
versions may behave differently.

## Your library and playback

MediaVault reads your library from the file sources and media servers you connect. Library entries,
watched status, resume positions, personal collections, and playback usage are stored locally on your device.
The official commercial version also stores local playback allowance information.
MediaVault does not operate a user-account service or send your viewing history or
playback time to developer-operated servers. Profiles and history do not sync
between devices.

SMB and WebDAV passwords, provider tokens, and optional TMDB and SubDL API credentials
are saved in Keychain on Apple devices or encrypted with keys held in Android Keystore.
MediaVault reads media from the selected source and does not upload those files.
SMB sends authentication and read requests to the configured file server. WebDAV sends
credentials and media paths to the configured server over HTTPS. Your source provider
and network administrator may maintain their own connection logs.

## Linked Jellyfin libraries

When you link a Jellyfin library, MediaVault sends sign-in and catalog requests to
the server you enter and saves the server token in protected device storage.
Playback, subtitle requests, and Jellyfin session reports go directly to that server.
A report includes the item, playback position, and player state, so the Jellyfin
server may retain viewing data under its connected account. MediaVault keeps its
own resume positions and Watchlist separate for each household profile.

## Linked Emby libraries

When you link an Emby library, MediaVault sends sign-in, catalog, artwork,
subtitle, and playback requests to the HTTPS server you choose. It stores the
server token in protected device storage. For Admin playback, MediaVault can
report the item, position, and player state to the connected Emby server, which
may retain that information under the linked account. Viewing history in
MediaVault stays separate for each local household profile. The server can
also keep its own connection logs.

## Linked Plex libraries

Plex account linking sends a device identifier and link-code requests to Plex.
After you approve the code through Plex, MediaVault uses the account token during
setup to discover which servers you can access. MediaVault stores the selected
server credential in protected storage. Library, artwork, subtitle, and playback
requests go to the selected Plex server over HTTPS. If you choose a Relay connection
on Android, these requests can pass through Plex Relay.

## Connected cloud folders

OneDrive links a personal Microsoft account using Microsoft sign-in. MediaVault
uses the Microsoft Graph read permission to identify the account’s drive and browse
folders and files. Microsoft Graph and its download endpoints handle requests for
selected items, including media, artwork, and subtitles. MediaVault saves an
authorization token to renew access without asking you to sign in again.

Where Dropbox is available, it uses Dropbox sign-in and asks for permission to read
file metadata and contents. Dropbox receives the authorization requests, then file
and folder identifiers for browsing and reading the items you select. MediaVault
saves an authorization token to renew access. Both cloud providers can see your
network address and handle account and file requests under their own privacy policies.

On iPhone, MediaVault uses Apple Files for read-only access to the folders or files
you select. It stores security-scoped bookmarks in Keychain until you disconnect the
source. Your Files provider, such as Google Drive, manages its own account, storage,
and downloads. On Android, MediaVault uses the system document picker when a Drive
provider is available. Android retains the read-only grants for the files or folder
you select until you disconnect. The Drive provider manages sign-in and downloads
on that platform as well.

You can remove a cloud source in MediaVault to clear its saved authorization. You
can also manage the app’s access to your cloud files in the provider’s account settings.

## Optional household profiles

Household profiles are local to this installation. Names, allowed folders and
rating restrictions are stored on the device. PINs are verified using salted,
derived values; plaintext PINs are not stored. Profile permissions and PIN verifiers
use protected local storage: Keychain on Apple devices and Keystore-backed encryption
on Android. Failed-attempt delays survive app restarts.

Each viewer has separate local watched status, resume positions and Watchlist.
The existing library history belongs to Admin. Profile switching does not reset
commercial playback allowances or purchases. Viewer access rules hide restricted
library content and apply to media access within MediaVault; they do not change
NAS permissions or restrict other apps on the device.

When an age limit is selected, MediaVault uses US movie or series certifications from local NFO files or TMDB and
keeps unknown or unrated video hidden. Photos and audio use folder permissions.
Ratings lookup uses the optional TMDB connection described below. No household
profile names or PINs are sent to TMDB.

Turning off household profiles requires the Admin PIN and keeps saved profiles
and viewer histories for later use. Removing an individual viewer is a separate,
confirmed action in the Admin section.

## Optional metadata

If you configure a TMDB credential, MediaVault sends movie search terms, identifiers,
and that credential to TMDB to obtain metadata. Artwork is downloaded from TMDB.
These requests disclose your network address to those services. TMDB's own
[privacy policy](https://www.themoviedb.org/privacy-policy) governs its processing.
You can use your NAS library without configuring TMDB.
Photo files are read from your NAS for display and are not sent to TMDB for matching.

Local NFO/XML metadata and artwork are read from the source folders you allow.
MediaVault does not upload these files, rewrite them, or follow remote links
contained in them. These details work without a TMDB connection. Personal
collections are stored separately for each local household profile and do not
sync to a server or another installation.

Additional Apple playback formats use a bundled VideoLAN library. It receives
a temporary address on the device for the authorized file, rather than NAS
credentials. Its streaming access ends when playback is stopped or the profile
loses access. The playback library does not require a VideoLAN account.

## Optional subtitles

Matching SRT and WebVTT subtitle files are read from the video’s source folder.
MediaVault leaves those files on the source unmodified.

If you connect SubDL, MediaVault sends your API key to SubDL to verify the
connection and search for subtitles. The download request sends the key with the
selected subtitle identifier to SubDL’s download service. Searches include the TMDB
title identifier, media type, requested language, and season and episode for television.
Automatic searches run only after you enable them. Choosing an online search in the
player also sends a request. These requests reveal your network address to SubDL.
NAS passwords, NAS folder paths, and video files are not sent to SubDL.

Saved subtitle links and cache identifiers exclude API credentials. Downloaded
subtitles stay in app memory or a bounded local cache. SubDL uses its
own account and service terms; MediaVault does not collect your SubDL password.
You can turn off automatic searches or disconnect SubDL in Settings. Local and
embedded subtitles continue to work without connecting an online provider.

## Purchases

Apple processes App Store purchases, billing, and subscription management. The
official commercial version uses Apple's StoreKit framework to check purchase
entitlements and restore purchases.
MediaVault does not receive or store your payment-card details. Apple may retain
purchase history separately from the app's local library and usage data.
See [Apple's privacy policy](https://www.apple.com/legal/privacy/).

## Control and retention

Library sources and individual entries can be managed in the app. Local files and
Keychain items have different system retention rules; removing an app does not
necessarily erase every Keychain item. App Store purchases can be restored using the
Apple Account that owns them. Removing MediaVault does not cancel an Apple subscription;
manage subscriptions through your Apple Account settings.

## Questions

Contact the maintainer through the
[MediaVault issue tracker](https://github.com/dinesh-devkota/mediavault/issues).
Do not post NAS addresses, passwords, API keys, purchase receipts, or private viewing
history in a public issue.
