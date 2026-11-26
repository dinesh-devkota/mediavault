package com.dineshdevkota.cinevault.plex

import android.content.Context
import android.net.Uri
import android.util.Base64
import androidx.room.Room
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.dineshdevkota.cinevault.data.CineVaultDatabase
import com.dineshdevkota.cinevault.data.SecretBox
import com.dineshdevkota.cinevault.data.SourceEntity
import com.dineshdevkota.cinevault.family.FamilyLibrary
import com.dineshdevkota.cinevault.family.FamilyStore
import com.dineshdevkota.cinevault.family.FolderAccess
import com.dineshdevkota.cinevault.family.HouseholdProfile
import com.dineshdevkota.cinevault.playback.Media3FixturePlayback
import java.io.DataInputStream
import java.io.IOException
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.util.UUID
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.runInterruptible
import okhttp3.OkHttpClient
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PlexTlsIntegrationTest {
    @Test
    fun ownerConnectsOverTlsAndReadsCatalogAndMediaRange() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val certificate = checkNotNull(InstrumentationRegistry.getArguments().getString("plexCertificate")) {
            "Start the disposable Plex fixture before running this test."
        }
        val exchange = fixtureExchange(certificate)
        val device = UUID.randomUUID()
        val owner = UUID.randomUUID()
        val name = "plex-tls-fixture-$device"
        val preferences = context.getSharedPreferences(name, Context.MODE_PRIVATE)
        val secrets = SecretBox()
        val storage = PlexKeystoreConnectionStore(preferences, secrets)
        val account = PlexAccountClient(device, exchange)
        val manager = PlexConnectionManager({ owner }, storage, device, account) { server, connection ->
            PlexMediaClient(server, connection, device, exchange)
        }
        try {
            val code = manager.start()
            assertEquals(4, code.code.length)
            assertEquals(PlexConnectionManager.LinkStatus.AwaitingAuthorization, manager.poll())
            val server = (manager.poll() as PlexConnectionManager.LinkStatus.ChooseServer).servers.single()
            assertEquals("fixture-plex-server", server.id)
            val selection = manager.select(server.id, server.connections.single().endpoint)
            assertEquals(listOf("10", "20", "30"), selection.libraries.map { it.key })
            val saved = checkNotNull(storage.read())
            assertEquals("fixture-plex-server-token", saved.serverToken)
            assertFalse(preferences.all.values.toString().contains(saved.serverToken))

            verifyProductionImport(context, saved, secrets, exchange)

            manager.disconnect()
            assertNull(storage.read())
        } finally {
            context.deleteSharedPreferences(name)
        }
    }

    private suspend fun verifyProductionImport(
        context: Context,
        saved: SavedPlexServer,
        secrets: SecretBox,
        exchange: PlexExchange,
    ) {
        val database = Room.inMemoryDatabaseBuilder(context, CineVaultDatabase::class.java).build()
        val householdPreferences = "plex-household-fixture-${UUID.randomUUID()}"
        val family = FamilyStore(context, secrets, householdPreferences)
        val library = FamilyLibrary(database, family)
        try {
            val encryptedToken = secrets.encrypt(saved.serverToken)
            suspend fun addLibrary(name: String, key: String, count: Int): SourceEntity {
                val source = SourceEntity(
                    name = name, host = saved.endpoint, share = key,
                    username = saved.serverID, encryptedPassword = encryptedToken, sourceType = PLEX,
                )
                database.sources().upsert(source)
                assertEquals(count to count, importPlexLibrary(database, source, secrets, exchange) {})
                return source
            }
            val movies = addLibrary("Fixture Movies", "10", 2)
            val shows = addLibrary("Fixture Shows", "20", 1)
            val photos = addLibrary("Fixture Photos", "30", 1)

            val movie = database.movies().forSource(movies.id).single { it.filePath.endsWith("/101.mp4") }
            val restricted = database.movies().forSource(movies.id).single { it.filePath.endsWith("/102.mp4") }
            assertEquals("G", movie.ageCertification)
            assertEquals("R", restricted.ageCertification)
            database.movies().setWatchlisted(movie.id, true)
            assertEquals(2 to 0, importPlexLibrary(database, movies, secrets, exchange) {})
            assertTrue(checkNotNull(database.movies().get(movie.id)).isWatchlisted)
            val episode = database.movies().forSource(shows.id).single()
            assertEquals("plex/shows/201/203.mp4", episode.filePath)
            assertEquals("Fixture Show", episode.seriesTitle)
            assertEquals(1, episode.seasonNumber)
            assertEquals(2, episode.episodeNumber)
            val photo = database.movies().forSource(photos.id).single()
            assertEquals("plex/photos/301.jpg", photo.filePath)
            assertTrue(photo.isPhoto)

            val pin = "139867"
            family.setup(pin, pin)
            assertNull(family.unlock(HouseholdProfile.ADMIN, pin))
            val viewer = HouseholdProfile("plex-granted-viewer", "Plex granted viewer",
                folders = listOf(FolderAccess(movies.id, "plex/movies", caseSensitive = true)), movieLimit = "G")
            val ungranted = HouseholdProfile("plex-ungranted-viewer", "Plex ungranted viewer")
            family.saveProfile(viewer, newPin = null)
            family.saveProfile(ungranted, newPin = null)
            assertNull(family.unlock(ungranted.id, ""))
            assertTrue(library.available().isEmpty())
            assertNull(family.unlock(viewer.id, ""))
            assertEquals(listOf(movie.id), library.available().map { it.id })
            assertFalse(checkNotNull(library.get(movie.id)).isWatchlisted)

            val session = family.current
            val client = movies.plexClient(secrets, exchange)
            val detail = client.item(checkNotNull(plexItemId(movie.filePath)))
            val part = client.singleFileParts(detail).single()
            val authorize = {
                if (!family.isCurrent(session) || !family.permits(movie)) throw IOException("Plex access denied.")
            }
            val artwork = client.image(detail, backdrop = false, authorize)
            assertArrayEquals(byteArrayOf(0xff.toByte(), 0xd8.toByte()), artwork.copyOfRange(0, 2))
            val subtitle = client.subtitle(part, part.tracks.single(), authorize).decodeToString()
            assertTrue(subtitle.contains("Fixture Plex caption."))
            Media3FixturePlayback.verify(Uri.parse("plex://fixture/101.mp4")) {
                PlexRemoteHandle(client, part, authorize)
            }
            val stream = PlexRemoteHandle(client, part, authorize)
            DataInputStream(stream.stream(4)).use {
                val header = ByteArray(4)
                it.readFully(header)
                assertArrayEquals("ftyp".encodeToByteArray(), header)
            }
            stream.stream(4).use {
                assertEquals('f'.code, it.read())
                family.lock()
                try {
                    it.read()
                    fail("A switched profile reused buffered Plex bytes.")
                } catch (denied: IOException) {
                    assertEquals("Plex access denied.", denied.message)
                }
            }
        } finally {
            database.close()
            context.deleteSharedPreferences(householdPreferences)
        }
    }

    private fun fixtureExchange(base64Certificate: String): PlexExchange {
        val certificate = Base64.decode(base64Certificate, Base64.DEFAULT).inputStream().use {
            CertificateFactory.getInstance("X.509").generateCertificate(it)
        }
        val keyStore = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
            load(null, null)
            setCertificateEntry("plex-fixture", certificate)
        }
        val manager = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(keyStore) }
            .trustManagers.filterIsInstance<X509TrustManager>().single()
        val tls = SSLContext.getInstance("TLS").apply { init(null, arrayOf(manager), null) }
        val client = OkHttpClient.Builder().sslSocketFactory(tls.socketFactory, manager)
            .followRedirects(false).followSslRedirects(false).build()
        return PlexExchange { request, maximumBytes ->
            val original = request.url
            val url = when (original.host) {
                "plex.tv" -> {
                    check(original.encodedPath.startsWith("/api/v2/"))
                    original.newBuilder().host("10.0.2.2").port(18777).build()
                }
                "10.0.2.2" -> original.also { check(it.port == 18777) }
                else -> error("An unexpected host was contacted during the Plex fixture test.")
            }
            check(url.isHttps)
            runInterruptible(Dispatchers.IO) {
                client.newCall(request.newBuilder().url(url).build()).execute().use { response ->
                    val source = response.body?.source()
                    check(source?.request(maximumBytes + 1L) != true) { "Plex fixture response exceeded its limit." }
                    PlexResponse(response.code, source?.readByteArray() ?: byteArrayOf(), response.headers)
                }
            }
        }
    }
}
