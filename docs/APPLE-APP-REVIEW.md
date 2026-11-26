# Apple App Review handoff

Use this for the public iPhone and Apple TV targets. Both targets bundle the
[privacy policy](PRIVACY.md), show it in the app, and have unsigned Apple
SDK 26.5 release checks. Apple's current upload minimum is Xcode 26 and the
matching platform SDK. Verify the requirements again when preparing the
signed archive. [Apple upload requirements](https://developer.apple.com/news/upcoming-requirements/)

## Prepare the submission

- Choose the app-record structure with the account holder. The current bundle
  IDs are `com.dineshdevkota.cinevault.ios` for iPhone and
  `com.dineshdevkota.cinevault` for Apple TV. One App Store Connect record
  with universal purchase uses a shared bundle ID. The existing Fastlane
  signing and upload lane targets tvOS. An iPhone upload needs its own
  authorized signing and validation path. [App records and bundle IDs](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/)
- Use an active Apple Developer Program team and an authorized App Store
  Connect role. Register the chosen identifiers, prepare the signing
  certificates and profiles, and validate the signed archive for each
  platform. Test on a physical iPhone and Apple TV. Check first-launch local
  network permission, discovery or manual entry, and Siri Remote navigation.
  Also verify playback, seek, subtitles, household restrictions, source
  reconnect, and removal. [Preparing a build for distribution](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution)
  [Local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- Enter a working public privacy-policy URL, a support URL with current
  contact information, and the actual data-use and age-rating answers.
  Include optional connections and integrated SDKs in the privacy assessment.
  Complete export compliance against the actual linked code. The tvOS
  configuration sets `ITSAppUsesNonExemptEncryption` to false while the iPhone
  configuration leaves it unset. Confirm the appropriate answers for each
  signed build. [App privacy details](https://developer.apple.com/app-store/app-privacy-details/)
  [Export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/)
- Verify the signed archive's privacy manifests and third-party notices.
  Confirm distribution terms for the playback and SMB dependencies. Keep
  evidence for third-party service use, trademarks, and content shown. Confirm
  the terms for optional SubDL subtitle downloads before including that feature
  in a submission. Capture iPhone and Apple TV screenshots in the app using
  owned or licensed media, original artwork, and fictional account details.
  [Playback dependency notices](PLAYBACK-ENGINE.md)
  [Apple's SDK requirements](https://developer.apple.com/support/third-party-SDK-requirements/)
  [Review Guidelines 2.3 and 5.2](https://developer.apple.com/app-store/review/guidelines/)
  [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
- Check the tvOS media transport exception on the signed build. The tvOS
  target sets `NSAllowsArbitraryLoadsForMedia`. Apple requires justification
  for that key, so identify the exact playback path that needs it and
  verify the narrowest working settings on device before submission.
  Both targets declare local networking and SMB Bonjour discovery. Linked
  WebDAV, Jellyfin, Emby, and Plex setup use HTTPS endpoints. The app's
  byte-range and HLS playback relays listen only on device loopback.
  [ATS media exception](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowsarbitraryloadsformedia)

## Reviewer access

Prepare a reachable, read-only HTTPS WebDAV demo with an original MP4 that
supports byte ranges, a matching SRT, and an original JPEG. Use a service
set up for review and isolated from any household NAS. Supply reviewer-only
credentials and any provider test accounts in App Store Connect. Recheck
access from outside the home network and keep the service available during
review. Provide separate steps for LAN-only SMB discovery. If Apple needs a
live hardware demonstration or a substitute for a demo account, coordinate
that with App Review.
[Providing information for a complete review](https://developer.apple.com/help/app-review/before-submitting-for-review/complete-review/)

For linked services in the submitted build, provide approved demo access,
selected libraries and steps for sign-in, reconnect, and removal. Note the
permissions each service grants. Jellyfin and Emby need accessible HTTPS
test servers with demo user accounts. OneDrive needs a compatible
Microsoft Entra public client ID and a test personal account. Dropbox needs a
registered public app key with read scopes, and Plex needs an account with
access to the selected test server. The iPhone Files integration uses the
user's installed Files provider. The Google Drive walkthrough requires the
Drive app with the review account signed in and Drive visible in Files.
Apple TV has no Files picker. Android's opt-in NFS build is outside these
Apple packages. Revisit guideline 4.8 if MediaVault adds its own account
system or uses an external login for that account.
[Provider setup and permissions](SOURCE-INTEGRATIONS.md)
[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

## Draft App Review notes

Replace the bracketed details in App Store Connect. Keep the actual access
details there.

> MediaVault browses and plays personal media from sources and servers you
> connect. It has no MediaVault account service. Household profiles,
> permissions, and viewing history are local to this device.
>
> On iPhone, open Manage → Media sources. On Apple TV, open Sources.
> Choose Add NAS → Connect WebDAV. Enter [review HTTPS WebDAV address] and
> the demo credentials in the review information. Choose [demo folder],
> save the source, and wait for its scan. Play [demo clip], seek within it,
> select its matching subtitle, and open [demo photo]. A metadata API key is
> optional. To check household access, open Settings → Household profiles
> (under Manage on iPhone) and grant the demo folder to a local viewer.
>
> Additional connection steps and test accounts for this build are provided
> in the review attachments. The privacy policy is available in Settings
> and in the household screens.

Apple reviews the submitted build and metadata together.
[App Review information fields](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)
