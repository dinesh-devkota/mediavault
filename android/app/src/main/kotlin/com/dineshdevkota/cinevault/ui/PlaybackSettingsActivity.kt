@file:OptIn(ExperimentalTvMaterial3Api::class)

package com.dineshdevkota.cinevault.ui

import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import com.dineshdevkota.cinevault.container
import com.dineshdevkota.cinevault.subtitles.SubDlClient
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.Locale

class PlaybackSettingsActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setCineVaultContent { PlaybackSettingsScreen() }
    }
    companion object {
        fun start(context: Context) { context.startActivity(Intent(context, PlaybackSettingsActivity::class.java)) }
    }
}

internal fun languageName(code: String): String = Locale.forLanguageTag(code).getDisplayName(Locale.getDefault())

/** A scrollable native list works with TV remotes, touch, and accessibility. */
internal fun chooseSubtitleLanguage(context: Context, selected: String, onSelected: (String) -> Unit): AlertDialog {
    val languages = (Locale.getISOLanguages().toList() + listOf("pt-BR", "zh-Hans", "zh-Hant"))
        .distinct().sortedBy { languageName(it).lowercase(Locale.getDefault()) }
    return AlertDialog.Builder(context).setTitle("Preferred subtitle language")
        .setSingleChoiceItems(languages.map(::languageName).toTypedArray(), languages.indexOfFirst { it.equals(selected, true) }) { dialog, index ->
            onSelected(languages[index]); dialog.dismiss()
        }.setNegativeButton("Cancel", null).show()
}

@Composable
private fun PlaybackSettingsScreen() {
    val context = LocalContext.current
    val settings = context.container.settings
    val scope = rememberCoroutineScope()
    var continuous by remember { mutableStateOf(settings.continuousPlay) }
    var language by remember { mutableStateOf(settings.subtitleLanguage) }
    var preference by remember { mutableStateOf(settings.subtitlePreference) }
    var automatic by remember { mutableStateOf(settings.automaticSubtitles) }
    var connected by remember { mutableStateOf(settings.subDlConnected) }
    var apiKey by remember { mutableStateOf(runCatching { settings.subDlApiKey }.getOrDefault("")) }
    var busy by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    LazyColumn(contentPadding = PaddingValues(horizontal = ScreenPadding, vertical = 24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item { ScreenHeader("Playback & Subtitles", kicker = "MEDIAVAULT") }
        item { Text("Continuous TV viewing", style = MaterialTheme.typography.titleLarge) }
        item {
            OutlinedButton(onClick = { continuous = !continuous; settings.continuousPlay = continuous }) {
                Text("Play next episode: ${if (continuous) "On" else "Off"}")
            }
        }
        item { Text("At the end of an episode, play the next available unwatched episode after 10 seconds. " +
            "Choose Play now to continue sooner, or Cancel / Back to stop. Specials stay separate. Movies never advance automatically.", color = SecondaryText) }
        item { Text("Subtitles", style = MaterialTheme.typography.titleLarge) }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                OutlinedButton(onClick = { chooseSubtitleLanguage(context, language) {
                    language = it; settings.subtitleLanguage = it; settings.subtitlePreference = it; preference = it
                } }) { Text("Language: ${languageName(language)}") }
                OutlinedButton(onClick = {
                    preference = if (preference == "off") language else "off"
                    settings.subtitlePreference = preference
                }) { Text("Subtitles: ${if (preference == "off") "Off" else "On"}") }
            }
        }
        item { Text("Embedded captions and matching .srt / .vtt files beside your video are available in the player's CC menu. " +
            "Your language or Off choice carries across episodes. Name sidecars like Show.S01E01.en.srt or Movie.en.sdh.vtt.", color = SecondaryText) }
        item { Text("Online subtitles · SubDL", style = MaterialTheme.typography.titleLarge) }
        item { Text(if (connected) "Connected · API key saved securely on this device" else "Connect once to find online subtitles", color = SecondaryText) }
        item { Text("Sign in to your SubDL account on a phone or computer at https://subdl.com/panel/api. " +
            "Copy your API key below. Automatic downloads prefer a matching local caption and only choose an exact release match; " +
            "other releases are yours to choose. Searches send the title's TMDB ID, episode and language to SubDL.", color = SecondaryText) }
        item { TvTextField(apiKey, { apiKey = it }, "SubDL API key", Modifier.width(640.dp), isPassword = true, enabled = !busy) }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                Button(enabled = !busy && apiKey.isNotBlank(), onClick = {
                    busy = true; message = "Checking your SubDL connection…"
                    val key = apiKey.trim()
                    scope.launch {
                        try {
                            SubDlClient().validateKey(key)
                            withContext(Dispatchers.IO) { settings.subDlApiKey = key }
                            settings.subDlConnected = true
                            settings.automaticSubtitles = true
                            settings.subtitlePreference = language
                            connected = true; automatic = true; preference = language
                            message = "Connected. Automatic subtitles are enabled."
                        } catch (e: CancellationException) { throw e }
                        catch (e: Exception) { message = e.message ?: "Could not connect to SubDL. Check the key and try again." }
                        finally { busy = false }
                    }
                }) { Text(if (busy) "Connecting…" else "Connect & enable automatic subtitles") }
                if (connected) OutlinedButton(enabled = !busy, onClick = {
                    settings.subDlApiKey = ""; apiKey = ""; connected = false; automatic = false; message = "SubDL disconnected."
                }) { Text("Disconnect") }
            }
        }
        item {
            OutlinedButton(enabled = connected && !busy, onClick = {
                automatic = !automatic; settings.automaticSubtitles = automatic
            }) { Text("Automatic downloads: ${if (automatic) "On" else "Off"}") }
        }
        message?.let { note -> item { Text(note, color = SecondaryText) } }
        item { Text("Online captions are optional. A failed search or unavailable subtitle never stops your video. " +
            "Downloads stay in this app's cache; no NAS files are changed.", color = SecondaryText) }
    }
}
