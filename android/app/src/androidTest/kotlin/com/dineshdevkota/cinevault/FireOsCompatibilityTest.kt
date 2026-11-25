package com.dineshdevkota.cinevault

import android.content.Context
import android.content.res.Configuration
import android.graphics.Bitmap
import android.os.Build
import android.util.Base64
import androidx.exifinterface.media.ExifInterface
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.dineshdevkota.cinevault.core.FilenameParser
import com.dineshdevkota.cinevault.core.LocalMetadataParser
import com.dineshdevkota.cinevault.data.*
import com.dineshdevkota.cinevault.family.*
import com.dineshdevkota.cinevault.photos.NasPhotoLoader
import com.dineshdevkota.cinevault.smb.RemoteHandle
import com.dineshdevkota.cinevault.ui.FIRE_TV_FEATURE
import com.dineshdevkota.cinevault.ui.isTelevision
import com.dineshdevkota.cinevault.ui.usesTelevisionLayout
import java.io.File
import java.security.KeyStore
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Runs unchanged on API22/25 and newer devices; uses only isolated keys, preferences and rows. */
@RunWith(AndroidJUnit4::class)
class FireOsCompatibilityTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()

    @Test fun fireFeatureEnablesRemoteLayoutWithoutChangingPhoneLayout() {
        assertTrue(usesTelevisionLayout(Configuration.UI_MODE_TYPE_NORMAL, true))
        assertTrue(usesTelevisionLayout(Configuration.UI_MODE_TYPE_TELEVISION, false))
        assertFalse(usesTelevisionLayout(Configuration.UI_MODE_TYPE_NORMAL, false))
        assertEquals(context.resources.configuration.isTelevision() || context.packageManager.hasSystemFeature(FIRE_TV_FEATURE), context.isTelevision())
    }

    @Test fun pinAndHouseholdProtectionSurviveRestart() = runBlocking<Unit> {
        val name = "fire-compat-family-${UUID.randomUUID()}"
        try {
            val reference = PinVerifier(Base64.encodeToString(ByteArray(16) { it.toByte() }, Base64.NO_WRAP),
                "bmuOahg6rNoFFAX/Atyu8vESdNqAKep1MFqCoI9zl6U=")
            assertTrue(reference.matches("023456")); assertFalse(reference.matches("023457"))
            val first = FamilyStore(context, SecretBox(context, name), name)
            first.setup("023456", "023456")
            assertNull(first.unlock(HouseholdProfile.ADMIN, "023456"))
            first.saveProfile(HouseholdProfile("viewer", "Viewer", movieLimit = "PG"), "654321")
            val restarted = FamilyStore(context, SecretBox(context, name), name)
            assertTrue(restarted.current.enabled); assertFalse(restarted.current.unlocked)
            assertNotNull(restarted.unlock(HouseholdProfile.ADMIN, "111111"))
            assertNull(restarted.unlock("viewer", "654321")); assertFalse(restarted.current.admin)
            assertEquals("PG", restarted.current.profile?.movieLimit)
            val sealed = context.getSharedPreferences(name, Context.MODE_PRIVATE).getString("record", "")!!
            assertFalse(sealed.contains("023456")); assertFalse(sealed.contains("Viewer"))
        } finally { clean(name) }
    }

    @Test fun keystoreSecretsPersistRejectTamperingAndNeverRecreateMissingKeys() {
        val name = "fire-compat-secrets-${UUID.randomUUID()}"
        val absent = "$name-absent"
        try {
            val plain = "fixture-only: café / 密码"
            val first = SecretBox(context, name).encrypt(plain)
            val second = SecretBox(context, name).encrypt(plain)
            assertNotEquals(first, second)
            val prefs = context.getSharedPreferences(name, Context.MODE_PRIVATE)
            assertTrue(prefs.edit().putString("sealed", first).commit())
            assertEquals(plain, SecretBox(context, name).decrypt(prefs.getString("sealed", "")!!))
            val prefix = if (first.startsWith(LegacySecretEnvelope.PREFIX)) LegacySecretEnvelope.PREFIX else ""
            val bytes = Base64.decode(first.removePrefix(prefix), Base64.NO_WRAP)
            bytes[bytes.lastIndex] = (bytes.last().toInt() xor 1).toByte()
            assertThrows(SecretReadException::class.java) { SecretBox(context, name).decrypt(prefix + Base64.encodeToString(bytes, Base64.NO_WRAP)) }
            assertThrows(SecretReadException::class.java) { SecretBox(context, absent).decrypt(first) }
            val store = keyStore()
            assertFalse(store.containsAlias(absent)); assertFalse(store.containsAlias("$absent-rsa-v1"))
            store.deleteEntry(name); store.deleteEntry("$name-rsa-v1")
            assertThrows(SecretReadException::class.java) { SecretBox(context, name).decrypt(first) }
            assertFalse(keyStore().containsAlias(name)); assertFalse(keyStore().containsAlias("$name-rsa-v1"))
        } finally { clean(name); clean(absent) }
    }

    @Test fun legacyEnvelopesRemainReadableAlongsideNativeSecrets() {
        val name = "fire-compat-upgrade-${UUID.randomUUID()}"
        try {
            val old = LegacySecretEnvelope(context, "$name-rsa-v1").encrypt("before-upgrade")
            val current = SecretBox(context, name)
            assertEquals("before-upgrade", current.decrypt(old))
            val newer = current.encrypt("after-upgrade")
            assertEquals(Build.VERSION.SDK_INT < 23, newer.startsWith(LegacySecretEnvelope.PREFIX))
            assertEquals("after-upgrade", SecretBox(context, name).decrypt(newer))
            assertEquals("before-upgrade", SecretBox(context, name).decrypt(old))
            val bytes = Base64.decode(old.removePrefix(LegacySecretEnvelope.PREFIX), Base64.NO_WRAP)
            // Corrupt wrapped-key and nonce fields independently, not just the trailing GCM tag.
            for (offset in listOf(0, 256)) {
                val tampered = bytes.copyOf().apply { this[offset] = (this[offset].toInt() xor 1).toByte() }
                assertThrows(SecretReadException::class.java) { current.decrypt(LegacySecretEnvelope.PREFIX + Base64.encodeToString(tampered, Base64.NO_WRAP)) }
            }
        } finally { clean(name) }
    }

    @Test fun legacyPhotoDecodePreservesRotationAndRechecksHiddenState() = runBlocking<Unit> {
        val name = "fire-compat-photo-${UUID.randomUUID()}"
        val file = File.createTempFile("fire-compat-", ".jpg", context.cacheDir)
        val database = Room.inMemoryDatabaseBuilder(context, CineVaultDatabase::class.java).build()
        try {
            val original = Bitmap.createBitmap(96, 64, Bitmap.Config.ARGB_8888)
            file.outputStream().use { assertTrue(original.compress(Bitmap.CompressFormat.JPEG, 90, it)) }; original.recycle()
            ExifInterface(file).apply { setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_ROTATE_90.toString()); saveAttributes() }
            val source = SourceEntity(id = name, name = "Fixture", host = "127.0.0.1", share = "fixture")
            database.sources().upsert(source)
            val photo = MovieEntity(id = name, sourceId = name, filePath = "Photos/portrait.jpg", fileName = "portrait.jpg",
                fileSize = file.length(), parsedTitle = "Portrait", parsedYear = null, title = "Portrait", year = null)
            database.movies().insert(photo)
            val secrets = SecretBox(context, name)
            val loader = NasPhotoLoader(context, database, secrets, family = FamilyStore(context, secrets, name), openFile = { _, _ ->
                object : RemoteHandle {
                    override val length = file.length()
                    override fun stream(position: Long) = file.inputStream().apply { skip(position) }
                    override fun close() = Unit
                }
            })
            val decoded = loader.load(photo.id)
            assertEquals(64, decoded.width); assertEquals(96, decoded.height)
            database.movies().setHidden(photo.id, true)
            assertTrue(runCatching { loader.load(photo.id) }.isFailure)
            loader.clearMemory()
        } finally { database.close(); file.delete(); clean(name) }
    }

    @Test fun desugaredFilenameAndSecureXmlParsingWorkOnOldPlatforms() {
        assertEquals(2020, FilenameParser.parse("Movies/Library Feature (2020).mkv").year)
        val metadata = LocalMetadataParser.parse("<movie><title>Feature</title><year>2020</year><mpaa>PG</mpaa></movie>".toByteArray())
        assertEquals("Feature", metadata.title); assertEquals("PG", metadata.certification)
        assertThrows(IllegalArgumentException::class.java) { LocalMetadataParser.parse("<!DOCTYPE movie [<!ENTITY x SYSTEM 'file:///not-used'>]><movie><title>&x;</title></movie>".toByteArray()) }
    }

    private fun keyStore() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private fun clean(name: String) {
        context.getSharedPreferences(name, Context.MODE_PRIVATE).edit().clear().commit()
        keyStore().apply { deleteEntry(name); deleteEntry("$name-rsa-v1") }
    }
}
