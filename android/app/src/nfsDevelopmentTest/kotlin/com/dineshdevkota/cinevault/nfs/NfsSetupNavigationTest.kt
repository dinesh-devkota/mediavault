package com.dineshdevkota.cinevault.nfs

import android.content.Context
import android.net.Uri
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasScrollToIndexAction
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isEnabled
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.pressKey
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.dineshdevkota.cinevault.MainActivity
import com.dineshdevkota.cinevault.container
import com.dineshdevkota.cinevault.playback.Media3FixturePlayback
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
@OptIn(ExperimentalTestApi::class)
class NfsSetupNavigationTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test
    fun ownerConnectsChoosesAScopedFolderImportsAndRemovesNativeMedia() = runBlocking<Unit> {
        check(InstrumentationRegistry.getArguments().getString("nfsAppFixture") == "true") {
            "Run only on the disposable NFS emulator with the loopback portmapper fixture."
        }
        val context = ApplicationProvider.getApplicationContext<Context>()
        val app = context.container
        val sources = app.database.sources()
        check(!app.family.current.enabled && app.family.profiles.isEmpty() && sources.all().isEmpty()) {
            "This test requires a fresh disposable app with no existing sources or profiles."
        }
        check(NfsDevelopment.available)
        val name = "Synthetic NFS fixture"
        try {
            val source = ActivityScenario.launch(MainActivity::class.java).use {
                press("Sources")
                press("Connect NFS")
                visible(hasText("Source name") and hasSetTextAction()).performTextReplacement(name)
                visible(hasText("Server hostname or IP") and hasSetTextAction()).performTextReplacement("10.0.2.2")
                visible(hasText("Export path (for example /media)") and hasSetTextAction()).performTextReplacement("/media")
                press("Connect and browse")
                press("Library ▸")
                visible(hasText("Media folder · Library"))
                press("Save Folder & Scan")

                withTimeout(20_000) {
                    var saved = sources.all().singleOrNull { it.name == name && it.lastScanAt != null }
                    while (saved == null) {
                        delay(100)
                        saved = sources.all().singleOrNull { it.name == name && it.lastScanAt != null }
                    }
                    requireNotNull(saved)
                }
            }
            assertEquals(NFS, source.sourceType)
            assertEquals("Library", source.rootPath)
            assertTrue(source.encryptedPassword.isEmpty())
            val movies = app.database.movies().forSource(source.id)
            val video = "Library/Movie.mp4"
            val image = "Library/Photos/01.jpg"
            assertEquals(setOf(video, image), movies.map { it.filePath }.toSet())
            val bitmap = app.photos.load(movies.single { it.filePath == image }.id, thumbnail = true)
            assertTrue(bitmap.width > 0 && bitmap.height > 0)
            val config = source.config(app.secrets)
            assertEquals("Library/Movie.en.srt", app.smb.readSubtitleSidecars(config, video).files.single().match.path)
            // The rendering helper owns its own MainActivity. Avoid overlapping activity scenarios.
            Media3FixturePlayback.verify(Uri.parse("nfs://fixture/Movie.mp4")) { app.smb.open(config, video) }

            ActivityScenario.launch(MainActivity::class.java).use {
                press("Sources")
                visible(hasText(name))
                press("Edit")
                press("Reconnect and browse")
                press("Open saved media folder")
                visible(hasText("Media folder · Library"))
                press("Remove source")
                press("Confirm removal")
                withTimeout(10_000) {
                    while (sources.get(source.id) != null) delay(100)
                }
                assertTrue(app.database.movies().forSource(source.id).isEmpty())
            }
        } finally {
            sources.all().filter { it.sourceType == NFS && it.name == name }.forEach {
                app.smb.reset(it.id)
                app.photos.resetSource(it.id)
                sources.delete(it.id)
            }
        }
    }

    private fun visible(matcher: SemanticsMatcher): SemanticsNodeInteraction {
        compose.waitUntil(timeoutMillis = 15_000) {
            try {
                val node = compose.onNode(matcher)
                try {
                    node.assertIsDisplayed()
                } catch (_: AssertionError) {
                    compose.onNode(hasScrollToIndexAction()).performScrollToNode(matcher)
                    node.assertIsDisplayed()
                }
                true
            } catch (_: AssertionError) { false }
        }
        return compose.onNode(matcher).assertIsDisplayed()
    }

    private fun press(label: String) {
        val button = visible(hasText(label) and hasClickAction() and isEnabled())
        button.performSemanticsAction(SemanticsActions.RequestFocus)
        button.assertIsFocused().performKeyInput { pressKey(Key.DirectionCenter) }
    }
}
