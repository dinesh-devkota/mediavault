import SwiftUI

struct MediaGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Button("Back to Settings") { dismiss() }
            }
            Section("One source for your whole library") {
                Text("In Sources, add a NAS, choose a discovered device or enter its address, then sign in if needed. Select your Media share and use its top-level folder. If Media is inside another share, open its Media folder. Choose Use this folder & scan. Scans include every subfolder. A source ending in Media/Movies cannot find sibling Music, TV Shows or Photos folders; select their common parent instead.")
                    .focusable()
            }
            Section("Choose folders and files to ignore") {
                Text("Open Sources → Edit. Browse scan folders, then browse folders and files to ignore. Ignore a whole folder and its subfolders, or one file. Save & Scan applies the exclusions without deleting NAS files or watch history. Stop ignoring and rescan to restore them. TypeScript code and node_modules are skipped; genuine .ts video files are checked before import.")
                    .focusable()
            }
            Section("Names that help matching") {
                Text("""
                Media/Movies/Arrival (2016)/Arrival (2016).mkv
                Media/Documentaries/Title (2020)/Title (2020).mp4
                Media/TV Shows/Show Name (2020)/Season 01/ShowName.S01E01.mkv
                Media/Music/Artist/Album/01-Song.mp3
                Media/Photos/Family Trip/Beach.jpg
                """)
                .font(.system(.caption, design: .monospaced))
                .focusable()
            }
            Section("Posters, details, and categories") {
                Text("Enter your free personal-use TMDB API key or read access token in Settings, then save and fetch missing metadata. Without a key, new items use filename/folder information and placeholder artwork. Matched metadata takes priority over folder guesses. Correct ambiguous matches using the title and year. Keep your key in the app, not in chat.")
                    .focusable()
            }
            Section("TV shows and music") {
                Text("Use S01E01-style episode names. Search for 24 to browse the show by season, or enter 24 S02E03 to open one episode. Back returns you to your results. Keep songs in artist and album folders. TMDB’s Music category covers movies and shows about music.")
                    .focusable()
            }
            Section("Subtitles") {
                Text("Open Subtitles while playing to choose Off, an embedded track, or a local SRT or WebVTT file. Put local subtitles beside the video with the same filename, such as Show.S01E01.en.srt or Movie.es.vtt. Optional .forced and .sdh suffixes are supported. Subtitle timing controls move local and downloaded captions earlier or later; seeking keeps them synchronized. Your Off or language choice carries to the next episode when available.")
                    .focusable()
                Text("For online subtitles, open Settings → Subtitle language & SubDL setup. Scan the QR code or visit subdl.com/panel/api on your phone, sign in, and enter your API key once. Connect & enable checks and securely saves the key. Choose your preferred language from the list. The app uses matching local or embedded tracks first, then checks SubDL for matched titles. An exact release match can be selected automatically; other releases appear in the player for you to choose. Downloads never change NAS files.")
                    .focusable()
            }
            Section("Continuous TV viewing") {
                Text("Enable Play next TV episode automatically in Settings. At the natural end of an episode, the next available unwatched episode appears with a 10-second countdown. Choose Play now, Cancel, or press Back to cancel. Specials stay separate. Movies, playback errors, leaving the app and trial limits do not start another episode. Intro skipping is not available without reliable markers.")
                    .focusable()
            }
            Section("Photo albums") {
                Text("Keep photos in folders such as Media/Photos/Family Trip, include their parent in your NAS source, then scan again. Open Photos, choose an album, and select a thumbnail. Previous and Next move through the album; Back returns to it. Albums follow the NAS source and folder. JPEG, PNG, WebP, HEIC and HEIF files use the device's image decoder; damaged files or unsupported encodings may not open. Photos are read from your NAS and are not sent to TMDB.")
                    .focusable()
            }
            Section("Library filters") {
                Text("Open Genre, Source or Decade, select several choices, then choose Apply. Comedy and Drama shows titles in either genre. Add a decade to narrow the results. Back cancels your edits. Clear filters shows the whole section again. Library remembers your last section, including after restarting the app.")
            }

            Section("Change watched status in bulk") {
                Text("Choose Select in Library, select videos, then choose Mark watched or Mark unwatched. Select all results uses your current filters. Open a show or season and choose Watched status to update all its available episodes, including those outside Watchlist. Review the count before applying. Back cancels selection. Both actions clear the selected files' saved resume positions.")
                    .focusable()
            }

            Section("Supported playback formats") {
                Text("Video: MP4, M4V, and MOV. Audio: MP3, M4A, AAC, FLAC, WAV, and AIFF/AIF. Apple TV checks whether it can play the file before starting. Other media containers can be cataloged but do not have Play controls in this app. TypeScript .ts and .d.ts files are not media.")
                    .focusable()
            }
            Section("Scan and play") {
                Text("Enter NAS credentials only in the app; a read-only account is recommended. Partial results can appear before scanning finishes, so check the status and last successful scan time. For video, Apple TV supports MP4, M4V, and MOV with compatible codecs; Android supports more containers. MediaVault does not transcode. Find the installed version and build in Settings → About.")
                    .focusable()
            }
        }
        .navigationTitle("MediaVault Guide")
    }
}
