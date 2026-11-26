@file:OptIn(ExperimentalTvMaterial3Api::class)

package com.dineshdevkota.cinevault.ui

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text

class MediaGuideActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setCineVaultContent { MediaGuideScreen() }
    }

    companion object {
        fun start(context: Context) {
            context.startActivity(Intent(context, MediaGuideActivity::class.java))
        }
    }
}

@Composable
private fun MediaGuideScreen() {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = ScreenPadding, vertical = 24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item { ScreenHeader("Media Guide", kicker = "MEDIAVAULT") }
        item {
            GuideSection(
                "One source for your whole library",
                "In Sources, add a NAS, choose a discovered device or enter its address, then sign in if needed. " +
                    "Select your Media share and use its top-level folder. If Media is inside another share, " +
                    "open its Media folder. Choose Use this folder & scan. Scans include every subfolder. A source ending in Media/Movies " +
                    "cannot find sibling Music, TV Shows or Photos folders; select their common parent instead.",
            )
        }
        item {
            GuideSection(
                "Choose folders and files to ignore",
                "Open Sources → Edit. Choose the scan folder from the dropdown, then open the ignore picker. " +
                    "Ignore a whole folder and its subfolders, or one file. Save & Scan applies the exclusions " +
                    "without deleting NAS files or watch history. Include again and rescan to restore them. " +
                    "TypeScript code and node_modules are skipped; genuine .ts video files are checked before import.",
            )
        }
        item {
            GuideSection(
                "Names that help matching",
                "Media/Movies/Arrival (2016)/Arrival (2016).mkv\n" +
                    "Media/Documentaries/Title (2020)/Title (2020).mp4\n" +
                    "Media/TV Shows/Show Name (2020)/Season 01/ShowName.S01E01.mkv\n" +
                    "Media/Music/Artist/Album/01-Song.mp3\n" +
                    "Media/Photos/Family Trip/Beach.jpg",
                monospaced = true,
            )
        }
        item {
            GuideSection(
                "Posters, details, and categories",
                "Enter your free personal-use TMDB API key or read access token in Settings, then save and " +
                    "fetch missing metadata. Or keep a matching .nfo or .xml file beside a video, such as Arrival (2016).nfo. " +
                    "Local titles, descriptions, genres and age ratings take priority; online matching fills missing details. " +
                    "Use Arrival (2016)-poster.jpg and Arrival (2016)-fanart.jpg for local artwork. " +
                    "PNG and JPEG also work. A single-movie folder can use movie.nfo, poster.jpg and fanart.jpg. Correct " +
                    "ambiguous matches using the title and year. Keep your key in the app, not in chat.",
            )
        }
        item {
            GuideSection(
                "Collections and versions",
                "Open Collections from Home or Library. Create a named collection, then add or remove titles from their details. " +
                    "Select several items in Library to add them together. Collections belong to your current household profile. " +
                    "Movie series appear automatically from an NFO set or TMDB when you have at least two movies; " +
                    "Find movie series checks previously matched titles. Versions with the same movie ID, or the exact same title and year, " +
                    "share one poster. Choose Version in details to select a cut or resolution; each file keeps its own progress. " +
                    "For shows, use tvshow.nfo and poster.jpg in the show folder, season01-poster.jpg for a season, and matching episode NFO files.",
            )
        }
        item {
            GuideSection(
                "TV shows and music",
                "Use S01E01-style episode names. Search for 24 to browse the show by season, or enter " +
                    "24 S02E03 to open one episode. Back returns you to your results. Keep songs in artist " +
                    "and album folders. TMDB’s Music category covers movies and shows about music.",
            )
        }
        item {
            GuideSection(
                "Subtitles and continuous TV viewing",
                "Open Settings → Playback & Subtitles. Choose your language, or turn subtitles Off. " +
                    "Matching SRT and WebVTT files beside each video appear alongside embedded captions in the player. " +
                    "Use the exact video basename, optionally followed by .en, .forced or .sdh; for example Show.S01E01.en.srt. " +
                    "NAS lookup is read-only, limited to 4,096 folder entries and 8 matching captions of at most 2 MiB each. " +
                    "For optional online subtitles, connect your SubDL API key once. Automatic downloads only choose a unique exact release match; " +
                    "Subtitles → Find subtitles online lets you choose other releases. Playback continues if a lookup fails. " +
                    "Play next episode is off by default. Enable it for a 10-second countdown to the next available unwatched episode. " +
                    "Play now advances immediately; Cancel or Back stops. Specials remain separate from regular seasons.",
            )
        }
        item {
            GuideSection(
                "Photo albums",
                "Keep photos in folders such as Media/Photos/Family Trip, include their parent in your NAS source, then scan again. " +
                    "Open Photos, choose an album, and select a thumbnail. Previous and Next move through the album; Back returns to it. " +
                    "Albums follow the NAS source and folder. JPEG, PNG, WebP, HEIC and HEIF files use the device's image decoder; " +
                    "damaged files or unsupported encodings may not open. Photos are read from your NAS and are not sent to TMDB.",
            )
        }
        item {
            GuideSection(
                "Library filters",
                "Open Genre, Source or Decade, select several choices, then choose Apply. " +
                    "Selecting Comedy and Drama shows titles in either genre. Add a decade to narrow the results. " +
                    "Back cancels your edits. Clear filters shows the whole section again.",
            )
        }
        item {
            GuideSection(
                "Change watched status in bulk",
                "Choose Select in Library, select videos, open Watched status, then choose Mark watched or Mark unwatched. " +
                    "Select all results uses your current filters. Open a show or season and choose Watched status " +
                    "to update all its available episodes, including those outside Watchlist. Review the count before applying. Back cancels selection. " +
                    "Both actions clear the selected files' saved resume positions.",
            )
        }
        item {
            GuideSection(
                "Supported playback formats",
                "Video: MP4, M4V, MOV, MKV, WebM, AVI, standard MPEG-TS, MPEG-PS, and FLV. " +
                    "Audio: MP3, M4A, AAC, FLAC, WAV, Ogg, and Opus. The TV must also support the codecs " +
                    "inside the file. WMV, ISO, M2TS, WMA, and AIFF can be cataloged but do not have Play " +
                    "controls in this Android app. TypeScript .ts and .d.ts files are not media.",
            )
        }
        item {
            GuideSection(
                "Scan and play",
                "Enter NAS credentials only in the app; a read-only account is recommended. Partial results " +
                    "can appear before scanning finishes, so check the status and last successful scan time. " +
                    "Playback depends on the device's codecs; MediaVault does not transcode. Use the remote's " +
                    "Back button or the Back control above to return to Settings.",
            )
        }
    }
}

@Composable
internal fun GuideSection(title: String?, body: String, monospaced: Boolean = false) {
    var focused by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(12.dp)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .onFocusChanged { focused = it.isFocused }
            .semantics(mergeDescendants = true) {}
            .focusable()
            .background(SurfaceColor, shape)
            .border(2.dp, if (focused) Accent else Color.Transparent, shape)
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        title?.let { Text(it, style = MaterialTheme.typography.titleMedium) }
        Text(
            body,
            style = MaterialTheme.typography.bodyMedium,
            color = SecondaryText,
            fontFamily = if (monospaced) FontFamily.Monospace else FontFamily.Default,
        )
    }
}
