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
import com.dineshdevkota.cinevault.core.LibraryFacets
import com.dineshdevkota.cinevault.core.LibraryFilter
import com.dineshdevkota.cinevault.core.LibrarySort
import com.dineshdevkota.cinevault.core.MediaKind
import com.dineshdevkota.cinevault.data.MovieEntity
import com.dineshdevkota.cinevault.data.SourceEntity
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** Disposable local fixtures only; the unreachable loopback source never reads a real NAS. */
@RunWith(AndroidJUnit4::class)
@OptIn(ExperimentalTestApi::class)
class HomeCollectionNavigationTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val application = ApplicationProvider.getApplicationContext<CineVaultApp>()
    private val container get() = application.container
    private val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
    private lateinit var source: SourceEntity

    @Before fun prepare() = runBlocking {
        withTimeout(15_000) { container.scanner.isScanning.first { !it } }
        assumeTrue("Use a disposable empty test library", container.database.sources().all().isEmpty())
        resetPreferences()
        source = SourceEntity(name = "Home browse fixture", host = "127.0.0.1", port = 1, share = "synthetic")
        container.database.sources().upsert(source)
    }

    @After fun cleanup() = runBlocking {
        withTimeout(15_000) { container.scanner.isScanning.first { !it } }
        container.playbackProgress.await { }
        if (::source.isInitialized) {
            container.database.sources().delete(source.id)
            container.smb.reset(source.id)
        }
        resetPreferences()
        container.scanner.clearStatus()
    }

    @Test fun seeAllReachesBeyondTwentyAndPreservesHomeFocusAndLibraryPreferences() = runBlocking<Unit> {
        val films = (1..26).map { movie(it) }
        val facets = LibraryFacets(genres = setOf("Comedy"), sourceIds = setOf(source.id), decades = setOf(1990))
        container.settings.librarySection = MediaKind.MUSIC
        container.settings.libraryFilter = LibraryFilter.WATCHED
        container.settings.librarySort = LibrarySort.YEAR
        container.settings.libraryFacets = facets
        launchHome().use {
            val shelf = hasTestTag("see-all:Movies")
            compose.onNode(hasTestTag("home-shelves")).performScrollToNode(shelf)
            visible(shelf).performSemanticsAction(SemanticsActions.RequestFocus)
            compose.waitForIdle()
            val homeTop = visible(shelf).fetchSemanticsNode().boundsInRoot.top
            visible(shelf).assertIsFocused().performKeyInput { pressKey(Key.DirectionCenter) }
            visible(hasText("26 titles"))
            assertTrue(device.takeScreenshot(File(application.cacheDir, "home-see-all-movies.png")))
            val oldest = hasTestTag("collection-item:movie:${films.first().id}")
            compose.onNode(hasTestTag("home-collection-grid")).performScrollToNode(oldest)
            activate(oldest)
            visible(hasText("Play") and hasClickAction())
            device.pressBack()
            focused(oldest)
            device.pressBack()
            focused(shelf)
            assertEquals(homeTop, visible(shelf).fetchSemanticsNode().boundsInRoot.top, 2f)
            assertEquals(MediaKind.MUSIC, container.settings.librarySection)
            assertEquals(LibraryFilter.WATCHED, container.settings.libraryFilter)
            assertEquals(LibrarySort.YEAR, container.settings.librarySort)
            assertEquals(facets, container.settings.libraryFacets)
        }
    }

    @Test fun mixedWatchlistKeepsOneShowAndRestoresItsCardAfterSeasonNavigation() = runBlocking<Unit> {
        (1..24).forEach { movie(it, watchlisted = true) }
        val episodes = (1..2).map { episode(it) }
        launchHome().use {
            val shelf = hasTestTag("see-all:Watchlist")
            activate(shelf)
            visible(hasText("25 titles"))
            val show = hasTestTag("collection-item:show:tmdb:4242")
            compose.onNode(hasTestTag("home-collection-grid")).performScrollToNode(show)
            activate(show)
            focused(hasTestTag("tv-season:tmdb:4242:1"))
            device.pressDPadCenter()
            focused(hasTestTag("tv-episode:${episodes.first().id}"))
            device.pressBack()
            focused(hasTestTag("tv-season:tmdb:4242:1"))
            device.pressBack()
            focused(show)
            device.pressBack()
            focused(shelf)
        }
    }

    @Test fun markingLastUnwatchedMovieKeepsBackAvailableWhenReturningToAnEmptyGrid() = runBlocking<Unit> {
        val film = movie(1)
        launchHome().use {
            val shelf = hasTestTag("see-all:Unwatched")
            compose.onNode(hasTestTag("home-shelves")).performScrollToNode(shelf)
            activate(shelf)
            activate(hasTestTag("collection-item:movie:${film.id}"))
            activate(hasText("Mark Watched") and hasClickAction())
            visible(hasText("Mark Unwatched") and hasClickAction())
            device.pressBack()
            visible(hasText("Nothing here yet"))
            focused(hasText("Back") and hasClickAction())
            device.pressDPadCenter()
            visible(hasTestTag("home-shelves"))
            assertTrue(container.database.movies().get(film.id)!!.isWatched)
        }
    }

    @Test fun emptyFiltersAndWatchlistExplainRecoveryAndMissingSectionOpensSources() = runBlocking<Unit> {
        movie(1)
        container.settings.libraryFacets = LibraryFacets(genres = setOf("No such genre"))
        launchHome().use {
            device.pressDPadRight()
            visible(hasText("No matching movies"))
            assertTrue(device.takeScreenshot(File(application.cacheDir, "library-empty-filter.png")))
            activate(hasTestTag("library-empty-action"))
            visible(hasText("1 title"))
            focused(hasText("Sort: Title") and hasClickAction())
            assertEquals(LibraryFacets(), container.settings.libraryFacets)
            activate(hasText("Show: All") and hasClickAction())
            activate(hasText("Watchlist") and hasClickAction())
            visible(hasText("No Watchlist titles here"))
            visible(hasText("Open a title and choose Add to Watchlist to save it for later."))
            activate(hasTestTag("library-empty-action"))
            activate(hasText("Section: Movies") and hasClickAction())
            activate(hasText("Music") and hasClickAction())
            visible(hasText("No music yet"))
            activate(hasText("Open Sources") and hasClickAction())
            visible(hasText("Add NAS Source") and hasClickAction())
            visible(hasText(source.name))
        }
    }

    private suspend fun movie(number: Int, watchlisted: Boolean = false): MovieEntity {
        val title = "Film ${number.toString().padStart(2, '0')}"
        return MovieEntity(sourceId = source.id, filePath = "$title.mp4", fileName = "$title.mp4", fileSize = 100,
            parsedTitle = title, parsedYear = 2001, title = title, year = 2001, addedAt = number.toLong(),
            metadataFetched = true, isWatchlisted = watchlisted).also { container.database.movies().insert(it) }
    }

    private suspend fun episode(number: Int): MovieEntity {
        val path = "Zeta.Horizon.S01E${number.toString().padStart(2, '0')}.mp4"
        return MovieEntity(sourceId = source.id, filePath = path, fileName = path, fileSize = 100,
            parsedTitle = "Zeta Horizon", parsedYear = 2001, title = "Chapter $number", year = 2001,
            seriesTitle = "Zeta Horizon", seriesTmdbId = 4242, seasonNumber = 1, episodeNumber = number,
            metadataFetched = true, isWatchlisted = true).also { container.database.movies().insert(it) }
    }

    private suspend fun launchHome(): ActivityScenario<MainActivity> {
        container.scanner.clearStatus()
        val main = ActivityScenario.launch(MainActivity::class.java)
        try {
            withTimeout(15_000) {
                combine(container.scanner.status, container.scanner.isScanning) { status, scanning ->
                    !scanning && status?.startsWith("Scan failed for ${source.name}:") == true
                }.first { it }
            }
            visible(hasText("Welcome to MediaVault"))
            return main
        } catch (failure: Throwable) { main.close(); throw failure }
    }

    private fun resetPreferences() {
        container.settings.librarySection = MediaKind.MOVIE
        container.settings.librarySort = LibrarySort.TITLE
        container.settings.libraryFilter = LibraryFilter.ALL
        container.settings.libraryFacets = LibraryFacets()
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
    private fun focused(matcher: SemanticsMatcher) = visible(matcher and isFocused()).assertIsFocused()
    private fun activate(matcher: SemanticsMatcher) {
        val node = visible(matcher and hasClickAction())
        node.performSemanticsAction(SemanticsActions.RequestFocus)
        node.assertIsFocused().performKeyInput { pressKey(Key.DirectionCenter) }
    }
}
