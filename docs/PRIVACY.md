# MediaVault privacy policy

This policy applies to the official MediaVault app. Independently modified or distributed
versions may behave differently.

## Your library and playback

MediaVault connects directly to the network shares you configure. Library entries,
watched status, resume positions, and playback usage are stored locally on your device.
The official commercial version also stores local playback allowance information.
MediaVault does not operate a user-account service or send your viewing history or
playback time to developer-operated servers. Local usage is not a cross-device profile.

NAS passwords and the optional TMDB and SubDL API credentials use the Keychain on Apple TV.
On Android, they are encrypted with a key held in the Android Keystore.
Media is read directly from your NAS for playback, not uploaded to a MediaVault server.
Your NAS provider and network administrator may maintain their own connection logs.

## Optional metadata

If you configure a TMDB credential, MediaVault sends movie search terms, identifiers,
and that credential to TMDB to obtain metadata. Artwork is downloaded from TMDB.
These requests disclose your network address to those services. TMDB's own
[privacy policy](https://www.themoviedb.org/privacy-policy) governs its processing.
You can use your NAS library without configuring TMDB.
Photo files are read from your NAS for display and are not sent to TMDB for matching.

## Optional subtitles

Local SRT and WebVTT subtitles are read from the video's NAS folder. MediaVault
does not upload those files or change them on your NAS.

If you connect SubDL, MediaVault sends your API key to SubDL to verify the
connection, search for subtitles, and authorize subtitle downloads. Searches include the TMDB title identifier,
media type, requested language, and season/episode for television. Automatic
searches run only after you enable them; choosing an online search in the player
also sends a request. These requests reveal your network address to SubDL.
NAS passwords, NAS folder paths, and video files are not sent to SubDL.

Saved subtitle links and cache identifiers exclude API credentials. Downloaded
subtitles stay in app memory or a bounded local cache. SubDL uses its
own account and service terms; MediaVault does not collect your SubDL password.
You can turn off automatic searches or disconnect SubDL in Settings. Local and
embedded subtitles continue to work without connecting an online provider.

## Purchases

Apple processes App Store purchases, billing, and subscription management. MediaVault
uses Apple's StoreKit framework to check purchase entitlements and restore purchases.
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
