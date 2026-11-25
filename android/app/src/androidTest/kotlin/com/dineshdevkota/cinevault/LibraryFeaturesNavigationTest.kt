package com.dineshdevkota.cinevault

import android.content.Intent
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.UiDevice
import com.dineshdevkota.cinevault.data.SourceEntity
import com.dineshdevkota.cinevault.ui.MediaCollectionsActivity
import com.dineshdevkota.cinevault.ui.MovieDetailActivity
import com.dineshdevkota.cinevault.ui.isTelevision
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

/** The same real UI journey runs with touch on a phone and D-pad activation on TV. */
@RunWith(AndroidJUnit4::class)
@OptIn(ExperimentalTestApi::class)
class LibraryFeaturesNavigationTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val app = ApplicationProvider.getApplicationContext<CineVaultApp>()
    private val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
    private val tv get() = app.resources.configuration.isTelevision()

    @Test fun localArtworkVersionsAndNamedCollectionsUseNativeControls() = runBlocking {
        assertEquals("Only run on a disposable CI emulator", "true", InstrumentationRegistry.getArguments().getString("libraryUiFixture"))
        val host = requireNotNull(InstrumentationRegistry.getArguments().getString("nasHost"))
        val container = app.container
        assertFalse("This journey must not alter household configuration", container.family.current.enabled)
        val source = SourceEntity(id = "library-ui-${UUID.randomUUID()}", name = "Library UI Fixture", host = host, port = 1445,
            share = "MEDIALIBRARY", username = "cinevault", encryptedPassword = container.secrets.encrypt("fixture-only"))
        var collectionId: String? = null
        try {
            container.database.sources().upsert(source); container.scanner.scan(source.id)
            val copies = container.database.movies().forSource(source.id).filter { it.tmdbId == 910001 }
            val original = copies.single { it.edition == "Theatrical" }
            val alternate = copies.single { it.edition == "Directors Cut" }
            val intent = Intent(app, MovieDetailActivity::class.java).putExtra("movie_id", original.id)
            ActivityScenario.launch<MovieDetailActivity>(intent).use { detail ->
                visible(hasText("Library Feature") and !hasClickAction())
                activate(hasTestTag("choose-version"))
                visible(hasText("Choose a version"))
                capture("library-version-picker")
                activate(hasTestTag("version:${alternate.id}"))
                visible(hasText(alternate.filePath))
                device.pressBack()
                visible(hasText(original.filePath))
                activate(hasTestTag("detail-collections"))
                fill("New collection name", "Fixture Favorites")
                activate(hasTestTag("save-collection"))
                collectionId = withTimeout(15000) { container.collections.observeCustom().first { it.any { collection -> collection.name == "Fixture Favorites" } } }
                    .single { it.name == "Fixture Favorites" }.id
                assertEquals(listOf(original.id), container.collections.observeCustom().first().single { it.id == collectionId }.movieIds)
                detail.onActivity { MediaCollectionsActivity.start(it) }
                activate(hasTestTag("collection:Fixture Favorites"))
                visible(hasText("Library Feature"))
                activate(hasText("Edit collection") and hasClickAction())
                fill("Collection name", "Weekend Films")
                activate(hasText("Save name") and hasClickAction())
                visible(hasText("Weekend Films") and !hasClickAction())
                capture("library-custom-collection")
                // Back leaves the collection screen and returns to the original title.
                device.pressBack() // collection detail -> collection list
                device.pressBack() // collection list -> movie detail
                activate(hasTestTag("detail-collections"))
                activate(hasTestTag("collection-choice:Weekend Films"))
                withTimeout(15000) { container.collections.observeCustom().first { it.any { collection -> collection.id == collectionId && collection.movieIds.isEmpty() } } }
                visible(hasText("Library Feature") and !hasClickAction())
            }
        } finally {
            collectionId?.let { container.collections.delete(it) }
            container.database.sources().delete(source.id); container.photos.resetSource(source.id)
        }
    }

    private fun visible(matcher: SemanticsMatcher): SemanticsNodeInteraction {
        val node = compose.onNode(matcher)
        compose.waitUntil(timeoutMillis = 20000) {
            runCatching {
                runCatching { node.performScrollTo() }
                node.assertIsDisplayed(); true
            }.getOrDefault(false)
        }
        return node
    }
    private fun activate(matcher: SemanticsMatcher) {
        val node = visible(matcher)
        if (tv) {
            node.performSemanticsAction(SemanticsActions.RequestFocus)
            compose.waitForIdle(); node.assertIsFocused().performKeyInput { pressKey(Key.DirectionCenter) }
        } else node.performTouchInput { click() }
        compose.waitForIdle()
    }
    private fun fill(label: String, value: String) {
        val node = visible(hasText(label) and hasSetTextAction())
        if (!tv) node.performTouchInput { click() }
        node.performTextReplacement(value)
        if (!tv) device.pressBack() // dismiss the phone keyboard before selecting the save action
    }
    private fun capture(name: String) {
        val directory = File(app.getExternalFilesDir(null), "test-artifacts").apply { mkdirs() }
        assertTrue(device.takeScreenshot(File(directory, "$name-${if (tv) "tv" else "phone"}.png")))
    }
}
