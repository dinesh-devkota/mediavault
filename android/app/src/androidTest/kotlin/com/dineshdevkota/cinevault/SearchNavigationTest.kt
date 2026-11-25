package com.dineshdevkota.cinevault

import androidx.compose.ui.input.key.Key
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.UiDevice
import com.dineshdevkota.cinevault.data.MovieEntity
import com.dineshdevkota.cinevault.data.SourceEntity
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Seeded local rows and a refused loopback port; no NAS or metadata account required. */
@RunWith(AndroidJUnit4::class)
@OptIn(ExperimentalTestApi::class)
class SearchNavigationTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val application = ApplicationProvider.getApplicationContext<CineVaultApp>()
    private val container get() = application.container
    private val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())

    @Test
    fun groupedGenreResultOpensCompleteSeasonsAndRestoresQueryScrollAndRemoteFocus() = runBlocking<Unit> {
        val source = fixtureSource()
        try {
            repeat(15) { movie(source, "Drama Film ${it.toString().padStart(2, '0')}") }
            val episodes = (1..4).map { episode(source, 1, it) } + (1..2).map { episode(source, 2, it) }
            launchSearch(source).use {
                query("Drama")
                visible(hasText("16 results"))
                val show = hasTestTag("search-result:show:tmdb:4242")
                compose.onNode(hasTestTag("library-search-results")).performScrollToNode(show)
                val result = visible(show)
                result.performSemanticsAction(SemanticsActions.RequestFocus)
                result.assertIsFocused()
                val originalTop = result.fetchSemanticsNode().boundsInRoot.top
                result.performKeyInput { pressKey(Key.DirectionCenter) }
                focused(hasTestTag("tv-season:tmdb:4242:1"))
                device.pressDPadRight()
                focused(hasTestTag("tv-season:tmdb:4242:2"))
                device.pressDPadCenter()
                focused(hasTestTag("tv-episode:${episodes[4].id}"))
                visible(hasTestTag("tv-episode:${episodes[5].id}")).assertTextContains("E2 · Chapter 2")
                device.pressBack()
                focused(hasTestTag("tv-season:tmdb:4242:2"))
                device.pressBack()
                focused(show)
                compose.onNode(hasTestTag("library-search-field")).assertTextContains("Drama")
                assertEquals(originalTop, compose.onNode(show).fetchSemanticsNode().boundsInRoot.top, 2f)
                // Repeat the focused result transition: it must not fall back to the Home tab.
                device.pressDPadCenter()
                focused(hasTestTag("tv-season:tmdb:4242:1"))
                device.pressBack()
                focused(show)
            }
        } finally { cleanup(source) }
    }

    @Test
    fun aliasesTargetedEpisodesMoviesAndPhotosKeepTheirExpectedRoutes() = runBlocking<Unit> {
        val source = fixtureSource()
        try {
            val episodes = (1..4).map { episode(source, 1, it) }
            val film = movie(source, "Separate Film")
            val photo = movie(source, "Family Snapshot", extension = "jpg", genre = "")
            launchSearch(source).use { main ->
                query("Local Horizon")
                visible(hasText("1 result"))
                visible(hasTestTag("search-result:show:tmdb:4242"))
                query("Zeta Horizon S1E2")
                visible(hasText("1 result"))
                val episodeResult = hasTestTag("search-result:episode:tmdb:4242:1:2")
                activate(episodeResult)
                visible(hasText("Zeta Horizon · Season 1 · Episode 2"))
                device.pressBack()
                focused(episodeResult)
                query("1080p")
                visible(hasText("4 matching episodes"))
                query("Separate Film")
                activate(hasTestTag("search-result:media:${film.id}"))
                visible(hasText("Play") and hasClickAction())
                device.pressBack()
                focused(hasTestTag("search-result:media:${film.id}"))
                main.recreate()
                visible(hasTestTag("library-search-field")).assertTextContains("Separate Film")
                visible(hasText("1 result"))
                query("Family Snapshot")
                activate(hasTestTag("search-result:media:${photo.id}"))
                visible(hasText("Couldn't open photo"))
                visible(hasText("1 of 1"))
                compose.onNode(hasText("Play") and hasClickAction()).assertDoesNotExist()
                device.pressBack()
                focused(hasTestTag("search-result:media:${photo.id}"))
                // A source-root edit hides stale TV and photo results even if the rescan failed.
                container.database.sources().upsert(source.copy(rootPath = "Other"))
                visible(hasText("No results"))
                focused(hasTestTag("library-search-field"))
                query("Zeta Horizon")
                visible(hasText("No results"))
                assertEquals(4, episodes.size)
            }
        } finally { cleanup(source) }
    }

    @Test
    fun openSeasonSurvivesRecreationAndMetadataChangeThenReturnsToSearchWhenIgnored() = runBlocking<Unit> {
        val source = fixtureSource()
        try {
            val item = episode(source, 2, 1)
            launchSearch(source).use { main ->
                query("Zeta Horizon")
                activate(hasTestTag("search-result:show:tmdb:4242"))
                focused(hasTestTag("tv-season:tmdb:4242:2"))
                device.pressDPadCenter()
                focused(hasTestTag("tv-episode:${item.id}"))
                main.recreate()
                focused(hasTestTag("tv-episode:${item.id}"))
                container.database.movies().update(item.copy(seriesTmdbId = 9876))
                device.pressBack()
                focused(hasTestTag("tv-season:tmdb:9876:2"))
                device.pressBack()
                val renamed = hasTestTag("search-result:show:tmdb:9876")
                focused(renamed)
                device.pressDPadCenter()
                focused(hasTestTag("tv-season:tmdb:9876:2"))
                container.database.sources().upsert(source.copy(ignoredFolders = listOf("TV")))
                // Ignored media must disappear even if the nested season browser
                // was restoring focus when the new source policy arrived.
                visible(hasText("No results"))
                compose.onNode(hasTestTag("tv-season:tmdb:9876:2")).assertDoesNotExist()
                focused(hasTestTag("library-search-field"))
                compose.onNode(hasTestTag("library-search-field")).assertTextContains("Zeta Horizon")
            }
        } finally { cleanup(source) }
    }

    private suspend fun fixtureSource(): SourceEntity {
        assumeTrue("Use a disposable empty test library", container.database.sources().all().isEmpty())
        return SourceEntity(name = "Local search fixture", host = "127.0.0.1", port = 1, share = "synthetic")
            .also { container.database.sources().upsert(it) }
    }

    private suspend fun episode(source: SourceEntity, season: Int, number: Int): MovieEntity {
        val file = "Local.Horizon.S${season.toString().padStart(2, '0')}E${number.toString().padStart(2, '0')}.1080p.mkv"
        return MovieEntity(sourceId = source.id, filePath = "TV/Local Horizon/Season $season/$file", fileName = file,
            fileSize = 100, parsedTitle = "Local Horizon", parsedYear = 2001, title = "Chapter $number", year = 2001,
            seriesTitle = "Zeta Horizon", seriesTmdbId = 4242, seasonNumber = season, episodeNumber = number,
            genres = listOf("Drama"), metadataFetched = true).also { container.database.movies().insert(it) }
    }
    private suspend fun movie(source: SourceEntity, title: String, extension: String = "mp4", genre: String = "Drama") =
        MovieEntity(sourceId = source.id, filePath = "$title.$extension", fileName = "$title.$extension", fileSize = 100,
            parsedTitle = title, parsedYear = null, title = title, year = null, genres = listOf(genre).filter(String::isNotBlank),
            metadataFetched = true).also { container.database.movies().insert(it) }

    private suspend fun launchSearch(source: SourceEntity): ActivityScenario<MainActivity> {
        container.scanner.clearStatus()
        val main = ActivityScenario.launch(MainActivity::class.java)
        try {
            withTimeout(15_000) { combine(container.scanner.status, container.scanner.isScanning) { status, scanning ->
                !scanning && status?.startsWith("Scan failed for ${source.name}:") == true
            }.first { it } }
            visible(hasText("Welcome to MediaVault"))
            repeat(3) { device.pressDPadRight() }
            visible(hasTestTag("library-search-field"))
            return main
        } catch (failure: Throwable) { main.close(); throw failure }
    }
    private suspend fun cleanup(source: SourceEntity) {
        withTimeout(15_000) { container.scanner.isScanning.first { !it } }
        container.database.sources().delete(source.id)
        container.photos.resetSource(source.id)
        container.smb.reset(source.id)
    }
    private fun query(text: String) {
        val field = visible(hasTestTag("library-search-field"))
        field.performSemanticsAction(SemanticsActions.RequestFocus)
        field.performTextReplacement(text)
        field.assertIsFocused()
    }
    private fun visible(matcher: SemanticsMatcher): SemanticsNodeInteraction {
        try {
            compose.waitUntilExactlyOneExists(matcher, timeoutMillis = 15_000)
            return compose.onNode(matcher).assertIsDisplayed()
        } catch (failure: Throwable) {
            val tree = runCatching { compose.onRoot(useUnmergedTree = true).printToString(maxDepth = 12) }.getOrDefault("No Compose root")
            throw AssertionError("Expected $matcher\n${tree.take(20_000)}", failure)
        }
    }
    private fun focused(matcher: SemanticsMatcher) {
        visible(matcher and isFocused()).assertIsFocused()
    }
    private fun activate(matcher: SemanticsMatcher) {
        val node = visible(matcher)
        node.performSemanticsAction(SemanticsActions.RequestFocus)
        node.assertIsFocused().performKeyInput { pressKey(Key.DirectionCenter) }
    }
}
