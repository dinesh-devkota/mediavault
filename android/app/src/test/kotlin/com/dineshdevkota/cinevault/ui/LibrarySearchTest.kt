package com.dineshdevkota.cinevault.ui

import com.dineshdevkota.cinevault.data.MovieEntity
import com.dineshdevkota.cinevault.data.SourceEntity
import org.junit.Assert.*
import org.junit.Test

class LibrarySearchTest {
    private fun searchLibrary(items: List<MovieEntity>, query: String) = LibrarySearchCatalog(items).results(query)

    private fun episode(number: Int, season: Int = 1, year: Int = 2001, canonical: String = "Canonical Horizon", seriesId: Int? = 42): MovieEntity {
        val file = "Local.Horizon.S${season.toString().padStart(2, '0')}E${number.toString().padStart(2, '0')}.1080p.mkv"
        return MovieEntity(sourceId = "nas", filePath = "TV/Local Horizon ($year)/Season $season/$file", fileName = file,
            fileSize = 100, parsedTitle = "Local Horizon", parsedYear = year, title = "Chapter $number", year = year,
            seriesTitle = canonical, seriesTmdbId = seriesId, seasonNumber = season, episodeNumber = number, genres = listOf("Drama"))
    }
    private fun media(title: String, extension: String = "mp4") = MovieEntity(sourceId = "nas", filePath = "$title.$extension",
        fileName = "$title.$extension", fileSize = 100, parsedTitle = title, parsedYear = null, title = title, year = null)

    @Test fun canonicalAndLocalAliasesReturnOneCompleteShowAcrossAllSeasons() {
        val episodes = (1..4).map { episode(it) } + episode(1, season = 2).copy(genres = emptyList())
        for (query in listOf("Canonical Horizon", "  local horizon ", "Drama")) {
            val result = searchLibrary(episodes, query).single() as LibrarySearchResult.Show
            assertEquals(episodes.map { it.id }.toSet(), result.show.episodes.map { it.id }.toSet())
            assertEquals(listOf(1, 2), result.show.seasons)
            assertNull(result.matchingEpisodes)
        }
    }

    @Test fun targetedEpisodeTitlesAndNormalizedFilenamesStayDirect() {
        val episodes = (1..6).map { episode(it) }
        for (query in listOf("Chapter 2", "S01E02", "Local Horizon S01E02", "Canonical Horizon S1E2", "Canonical Horizon 1x02")) {
            val result = searchLibrary(episodes, query).single() as LibrarySearchResult.Media
            assertEquals(episodes[1].id, result.item.id)
        }
        val bare = episodes[1].copy(fileName = "S01E02.mkv", filePath = "TV/S01E02.mkv")
        assertEquals(bare.id, (searchLibrary(listOf(bare), "Canonical Horizon S01E02").single() as LibrarySearchResult.Media).item.id)
    }

    @Test fun broadQueriesCountLogicalEpisodesNotDuplicateEncodes() {
        val episodes = (1..4).map { episode(it) }
        val copies = episodes.map { it.copy(id = "copy-${it.id}", sourceId = "backup", filePath = "ZBackup/${it.filePath}") }
        val broad = searchLibrary(episodes + copies, "1080p").single() as LibrarySearchResult.Show
        assertEquals(4, broad.matchingEpisodes)
        assertEquals("4 matching episodes", broad.subtitle)
        assertEquals(8, broad.show.episodes.size)
        val limited = searchLibrary(episodes.take(3) + copies.take(3), "1080p")
        assertEquals(3, limited.size)
        assertTrue(limited.all { it is LibrarySearchResult.Media })
        val first = searchLibrary(listOf(episodes[0], copies[0]), "Chapter 1").single()
        val replacement = searchLibrary(listOf(episodes[0].copy(isHidden = true), copies[0]), "Chapter 1").single()
        assertEquals("Representatives retain a logical result identity", first.id, replacement.id)
    }

    @Test fun numberedSeriesQueriesDoNotMatchPartOfAnUnrelatedYear() {
        val unrelated = episode(1, year = 2024, canonical = "Example").copy(fileName = "Example.2024.S01E01.mkv")
        assertTrue(searchLibrary(listOf(unrelated), "24").isEmpty())
        val twentyFour = episode(1, canonical = "24", seriesId = 24)
        val result = searchLibrary(listOf(unrelated, twentyFour), "24").single() as LibrarySearchResult.Show
        assertEquals(listOf(twentyFour), result.show.episodes)
    }

    @Test fun numericQueriesMatchWholeNumbersInMovieAndPhotoNames() {
        val movie = media("24 Hour Film").copy(fileName = "feature.mp4")
        val photo = media("At the lake", "jpg").copy(fileName = "trip-24.jpg")
        val otherFilm = media("Evening").copy(fileName = "Evening.2024.mp4", genres = listOf("Drama"))
        val otherPhoto = media("Hike 124", "jpg").copy(fileName = "trip-240.jpg")
        val library = LibrarySearchCatalog(listOf(movie, photo, otherFilm, otherPhoto))
        assertEquals(setOf(movie.id, photo.id), library.results("24").map { (it as LibrarySearchResult.Media).item.id }.toSet())
        assertEquals(otherFilm.id, (library.results("Drama").single() as LibrarySearchResult.Media).item.id)
        assertEquals(otherPhoto.id, (library.results("trip-240").single() as LibrarySearchResult.Media).item.id)
    }

    @Test fun sourceEditsExcludeStaleEpisodesBeforeSeriesIdentityAndMatchesAreBuilt() {
        val source = SourceEntity(id = "nas", name = "NAS", host = "nas", share = "media", rootPath = "TV")
        val allowed = episode(1)
        val outside = episode(2).copy(filePath = "Old/Local.Horizon.S01E02.mkv")
        assertEquals(listOf(allowed), searchableItems(listOf(allowed, outside), listOf(source)))
        val ignored = source.copy(ignoredFiles = listOf(allowed.filePath.removePrefix("TV/")))
        assertTrue(searchableItems(listOf(allowed), listOf(ignored)).isEmpty())
        assertTrue(searchableItems(listOf(allowed), emptyList()).isEmpty())
    }

    @Test fun remakeYearsAndAmbiguousAliasesRemainSeparate() {
        val older = episode(1, year = 1990, canonical = "Example", seriesId = null).copy(
            filePath = "TV/Example (1990)/Season 1/Example.S01E01.mkv", seriesTitle = "Example")
        val newer = older.copy(id = "new", year = 2020, parsedYear = 2020,
            filePath = "TV/Example (2020)/Season 1/Example.S01E01.mkv")
        assertEquals(2, searchLibrary(listOf(older, newer), "Example").size)
        val selected = searchLibrary(listOf(older, newer), "Example (1990)").single() as LibrarySearchResult.Show
        assertEquals(listOf(older), selected.show.episodes)
    }

    @Test fun sourcePathAndIgnoreEditsApplyToEveryMediaKind() {
        val source = SourceEntity(id = "nas", name = "NAS", host = "nas", share = "media", rootPath = "Library")
        val files = listOf("Movies/Film.mkv", "Documentaries/Reef.mp4", "Music/Track.flac",
            "Photos/Trip.jpg", "TV/Example/Season 1/Example.S01E01.mkv")
        val items = files.map { file -> media(file.substringAfterLast('/')).copy(filePath = "Library/$file") }
        assertEquals(items, searchableItems(items, listOf(source)))
        assertTrue(searchableItems(items, listOf(source.copy(rootPath = "Library 2"))).isEmpty())
        assertTrue(searchableItems(items, listOf(source.copy(ignoredFiles = files))).isEmpty())
        assertTrue(searchableItems(items, listOf(source.copy(ignoredFolders = files.map { it.substringBefore('/') }))).isEmpty())
        assertTrue(searchableItems(items, emptyList()).isEmpty())
    }

    @Test fun moviePhotoAndShowResultsCoexistWithoutUnavailableRowsOrEmptyQueries() {
        val movie = media("Canonical Horizon")
        val photo = media("Canonical Horizon", "jpg")
        val show = episode(1)
        val missing = episode(2).copy(isMissing = true)
        val hidden = media("Canonical Horizon Hidden").copy(isHidden = true)
        val results = searchLibrary(listOf(movie, photo, show, missing, hidden), "Canonical Horizon")
        assertEquals(3, results.size)
        assertEquals(listOf(show), (results.single { it is LibrarySearchResult.Show } as LibrarySearchResult.Show).show.episodes)
        assertEquals(setOf(movie.id, photo.id), results.filterIsInstance<LibrarySearchResult.Media>().map { it.item.id }.toSet())
        for (query in listOf("", "  ", "...")) assertTrue(searchLibrary(listOf(movie, show), query).isEmpty())
    }
}
