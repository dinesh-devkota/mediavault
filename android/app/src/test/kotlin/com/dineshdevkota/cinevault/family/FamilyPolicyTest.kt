package com.dineshdevkota.cinevault.family

import com.dineshdevkota.cinevault.data.MovieEntity
import org.junit.Assert.*
import org.junit.Test

class FamilyPolicyTest {
    private fun movie(path: String = "Kids/Film.mp4", rating: String? = "PG") = MovieEntity(
        id = "movie", sourceId = "nas", filePath = path, fileName = path.substringAfterLast('/'),
        fileSize = 1024, parsedTitle = "Film", parsedYear = null, title = "Film", year = null, ageCertification = rating)
    private val child = HouseholdProfile("child", "Child", folders = listOf(FolderAccess("nas", "Kids")), movieLimit = "PG", tvLimit = "TV-G")

    @Test fun newViewerHasNoAccessAndAdminKeepsEverything() {
        assertFalse(FamilyPolicy.allows(HouseholdProfile("new", "New viewer"), movie()))
        assertTrue(FamilyPolicy.allows(HouseholdProfile(HouseholdProfile.ADMIN, "Admin"), movie("Adult/movie.mp4", "R")))
    }
    @Test fun foldersUseWholeComponentsAndSourceIdentity() {
        assertTrue(FamilyPolicy.allows(child, movie("kids/Season 1/Film.mp4")))
        assertTrue(FamilyPolicy.allows(child, movie("Kids\\Film.mp4")))
        assertFalse(FamilyPolicy.allows(child, movie("Kids2/Film.mp4")))
        assertFalse(FamilyPolicy.allows(child, movie("Kids/../Adult/Film.mp4")))
        assertFalse(FamilyPolicy.allows(child, movie().copy(sourceId = "other-nas")))
    }
    @Test fun unknownRatingsNeverBorrowTheReviewScore() {
        assertFalse(FamilyPolicy.allows(child, movie(rating = null).copy(rating = 1.0)))
        assertFalse(FamilyPolicy.allows(child, movie(rating = "NR")))
        assertFalse(FamilyPolicy.allows(child, movie(rating = "PG-13")))
        assertTrue(FamilyPolicy.allows(child.copy(movieLimit = null), movie(rating = null)))
    }
    @Test fun movieAndTVLimitsAreIndependent() {
        val episode = movie("Kids/Show.S01E01.mp4", "TV-Y7")
        assertFalse(FamilyPolicy.allows(child, episode))
        assertTrue(FamilyPolicy.allows(child.copy(tvLimit = "TV-Y7"), episode))
        assertTrue(FamilyPolicy.allowsRating("TV-Y7-FV", "TV-Y7", true))
        assertFalse(FamilyPolicy.allowsRating("TV-Y7", "TV-G", true))
    }
    @Test fun photosAndMusicRespectFoldersButNotVideoRatings() {
        assertTrue(FamilyPolicy.allows(child, movie("Kids/photo.jpg", null)))
        assertTrue(FamilyPolicy.allows(child, movie("Kids/song.mp3", null)))
        assertFalse(FamilyPolicy.allows(child, movie("Private/photo.jpg", null)))
        assertFalse(FamilyPolicy.allows(child, movie("Private/song.mp3", null)))
    }
    @Test fun shareRootRequiresTheSpecificSource() {
        val viewer = child.copy(folders = listOf(FolderAccess("nas", "")))
        assertTrue(FamilyPolicy.allows(viewer, movie("Film.mp4")))
        assertFalse(FamilyPolicy.allows(viewer, movie().copy(sourceId = "new-nas")))
    }
}
