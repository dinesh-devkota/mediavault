package com.dineshdevkota.cinevault.library

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.dineshdevkota.cinevault.core.MediaKind
import com.dineshdevkota.cinevault.data.*
import com.dineshdevkota.cinevault.family.*
import com.dineshdevkota.cinevault.metadata.LocalMetadataImporter
import com.dineshdevkota.cinevault.photos.NasPhotoLoader
import com.dineshdevkota.cinevault.smb.SmbService
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class LocalLibraryIntegrationTest {
    @Test fun invalidSidecarsClearOldRatingButTemporaryReadFailurePreservesIt() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val db = Room.inMemoryDatabaseBuilder(context, CineVaultDatabase::class.java).build()
        val source = SourceEntity(id = "local", name = "Local fixture", host = "127.0.0.1", share = "fixture")
        var bytes = "<movie><mpaa>PG</mpaa></movie>".toByteArray()
        var offline = false
        val importer = LocalMetadataImporter(db, SecretBox(), list = { listOf(com.dineshdevkota.cinevault.smb.NasEntry("Movie.nfo", false)) },
            open = { _, _ ->
                if (offline) throw java.io.IOException("Synthetic disconnected source")
                val content = bytes
                object : com.dineshdevkota.cinevault.smb.RemoteHandle {
                    override val length = content.size.toLong()
                    override fun stream(position: Long) = content.inputStream().apply { skip(position) }
                    override fun close() = Unit
                }
            })
        try {
            db.sources().upsert(source)
            db.movies().insert(MovieEntity(id = "video", sourceId = source.id, filePath = "Movie.mp4", fileName = "Movie.mp4", fileSize = 1000,
                title = "Movie", parsedTitle = "Movie", year = null, parsedYear = null))
            importer.importSource(source.id)
            assertEquals("PG", db.movies().get("video")!!.ageCertification)
            offline = true; importer.importSource(source.id)
            assertEquals("PG", db.movies().get("video")!!.ageCertification)
            offline = false; bytes = "<movie><mpaa>PG".toByteArray(); importer.importSource(source.id)
            assertNull(db.movies().get("video")!!.ageCertification)
            bytes = "<movie><mpaa>PG</mpaa></movie>".toByteArray(); importer.importSource(source.id)
            assertEquals("PG", db.movies().get("video")!!.ageCertification)
            bytes = ByteArray(com.dineshdevkota.cinevault.core.LocalMetadataParser.MAX_BYTES + 1); importer.importSource(source.id)
            assertNull(db.movies().get("video")!!.ageCertification)
            assertFalse(db.movies().get("video")!!.isMissing)
        } finally { db.close() }
    }

    @Test fun importsRealNasSidecarsGroupsVersionsAndDecodesLocalArtWithoutKey() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val host = requireNotNull(InstrumentationRegistry.getArguments().getString("nasHost")) { "The disposable NAS fixture is required." }
        val db = Room.inMemoryDatabaseBuilder(context, CineVaultDatabase::class.java).build()
        val secrets = SecretBox(); val smb = SmbService()
        val prefs = "library-fixture-${UUID.randomUUID()}"
        val family = FamilyStore(context, secrets, prefs)
        val source = SourceEntity(name = "Local Library", host = host, port = 1445, share = "MEDIALIBRARY", username = "cinevault", encryptedPassword = secrets.encrypt("fixture-only"))
        try {
            db.sources().upsert(source)
            val importer = LocalMetadataImporter(db, secrets)
            val scanner = LibraryScanner(db, secrets, smb::scanVideos, importLocalMetadata = importer::importSource, scanWithProgress = smb::scanMedia)
            scanner.scan(source.id)
            assertFalse(scanner.status.value.orEmpty().contains("failed", true))
            val all = db.movies().forSource(source.id)
            val available = all.filterNot { it.isMissing }
            val versions = available.filter { it.tmdbId == 910001 }
            assertEquals(2, versions.size)
            assertEquals(setOf("Theatrical", "Directors Cut"), versions.map { it.edition }.toSet())
            assertTrue(versions.all { it.title == "Library Feature" && it.ageCertification == "PG" && it.hasLocalMetadata })
            assertEquals(1, groupMovieVersions(versions).size)
            val episode = available.single { it.episodeInfo != null }
            assertEquals("The Local Episode", episode.title); assertEquals("Library Show", episode.seriesTitle)
            assertEquals(920001, episode.seriesTmdbId); assertEquals(MediaKind.TV_SHOW, episode.mediaKind)
            assertEquals("TV Shows/Library Show/season01-poster.png", episode.localSeasonPosterPath)
            assertEquals(listOf("Photos/poster.png"), available.filter { it.isPhoto }.map { it.filePath })
            assertEquals("Invalid Metadata", available.single { it.filePath.startsWith("Invalid/") }.title)
            val loader = NasPhotoLoader(context, db, secrets, family = family)
            val bitmap = loader.loadArtwork(versions.first().id, 342, com.dineshdevkota.cinevault.jellyfin.JellyfinImage.Primary)
            assertTrue(bitmap.width > 0 && bitmap.height > 0)
            db.movies().setWatched(versions.first().id, true)
            db.movies().saveProgress(versions.last().id, 2500, 12000, 1)
            scanner.scan(source.id)
            assertTrue(db.movies().get(versions.first().id)!!.isWatched)
            assertEquals(2500L, db.movies().get(versions.last().id)!!.playbackPositionMs)
            loader.clearMemory()
        } finally {
            smb.reset(source.id); db.close(); context.getSharedPreferences(prefs, Context.MODE_PRIVATE).edit().clear().commit()
        }
    }

    @Test fun customCollectionsPersistButNeverCrossHouseholdProfilesOrRevealRestrictedFranchises() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val db = Room.inMemoryDatabaseBuilder(context, CineVaultDatabase::class.java).build()
        val secrets = SecretBox(); val name = "collection-fixture-${UUID.randomUUID()}"
        val family = FamilyStore(context, secrets, "$name-family")
        val library = FamilyLibrary(db, family); val store = MediaCollections(context, family, library, name)
        val transitions = java.util.Collections.synchronizedList(mutableListOf<Pair<String, List<MediaCollection>>>())
        var observer: Job? = null
        try {
            db.sources().upsert(SourceEntity(id = "source", name = "Fixture", host = "127.0.0.1", share = "fixture"))
            fun movie(id: String, folder: String, rating: String) = MovieEntity(id = id, sourceId = "source", filePath = "$folder/$id.mp4", fileName = "$id.mp4", fileSize = 100,
                title = id, parsedTitle = id, year = 2020, parsedYear = 2020, ageCertification = rating, franchiseName = "Private franchise")
            db.movies().insert(movie("allowed", "Kids", "PG")); db.movies().insert(movie("secret", "Private", "R"))
            val id = store.create("Admin collection", listOf("allowed", "secret"))
            assertEquals(2, store.observeAll().first().first { it.id == id }.movies.size)
            val reloaded = MediaCollections(context, family, library, name)
            assertEquals("Admin collection", reloaded.observeCustom().first().single().name)
            family.setup("123456", "123456"); family.unlock(HouseholdProfile.ADMIN, "123456")
            // Keep one collector alive across the switch: a fresh first() alone misses combine ordering leaks.
            observer = launch(Dispatchers.Unconfined) {
                store.observeAll().collect { transitions += family.current.historyId to it }
            }
            family.saveProfile(HouseholdProfile("child", "Child", folders = listOf(FolderAccess("source", "Kids")), movieLimit = "PG"), null)
            family.lock(); family.unlock("child", "")
            assertTrue(store.observeAll().first().isEmpty())
            val kids = store.create("Child favorites", listOf("allowed", "secret"))
            assertEquals(listOf("allowed"), store.observeAll().first().single().movies.map { it.id })
            family.lock(); assertTrue(store.observeAll().first().isEmpty())
            family.unlock(HouseholdProfile.ADMIN, "123456")
            assertFalse(store.observeAll().first().any { it.id == kids })
            assertTrue(store.observeAll().first().any { it.id == id })
            store.rename(id, "Renamed"); store.setMembers(id, listOf("allowed"), false)
            assertEquals(listOf("secret"), store.observeAll().first().first { it.id == id }.movies.map { it.id })
            store.delete(id); assertTrue(store.observeCustom().first().isEmpty())
            observer.cancelAndJoin()
            assertTrue("A switched profile must never receive the previous profile's collection names",
                transitions.none { (profile, collections) -> profile == "child" && collections.any { it.name == "Admin collection" } })
            assertTrue("Returning to Admin must never retain the child's collections",
                transitions.none { (profile, collections) -> profile == HouseholdProfile.ADMIN && collections.any { it.id == kids } })
        } finally {
            observer?.cancelAndJoin()
            db.close(); listOf(name, "$name-family").forEach { context.getSharedPreferences(it, Context.MODE_PRIVATE).edit().clear().commit() }
        }
    }
}
