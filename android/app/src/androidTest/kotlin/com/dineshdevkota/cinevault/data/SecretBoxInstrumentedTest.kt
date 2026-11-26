package com.dineshdevkota.cinevault.data

import androidx.test.ext.junit.runners.AndroidJUnit4
import android.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SecretBoxInstrumentedTest {
    @Test
    fun encryptedSecretsSurviveNewInstancesAndUseUniqueNonces() {
        val plaintext = "fixture-only: café / 密码"
        val first = SecretBox(androidx.test.core.app.ApplicationProvider.getApplicationContext()).encrypt(plaintext)
        val second = SecretBox(androidx.test.core.app.ApplicationProvider.getApplicationContext()).encrypt(plaintext)
        assertNotEquals(plaintext, first)
        assertNotEquals(first, second)
        assertEquals(plaintext, SecretBox(androidx.test.core.app.ApplicationProvider.getApplicationContext()).decrypt(first))
        assertEquals(plaintext, SecretBox(androidx.test.core.app.ApplicationProvider.getApplicationContext()).decrypt(second))
    }

    @Test
    fun corruptCredentialsFailInsteadOfBecomingAnEmptyPassword() {
        val box = SecretBox(androidx.test.core.app.ApplicationProvider.getApplicationContext())
        val sealed = box.encrypt("fixture-only")
        val prefix = if (sealed.startsWith(LegacySecretEnvelope.PREFIX)) LegacySecretEnvelope.PREFIX else ""
        val bytes = Base64.decode(sealed.removePrefix(prefix), Base64.NO_WRAP)
        bytes[bytes.lastIndex] = (bytes.last().toInt() xor 1).toByte()
        assertThrows(SecretReadException::class.java) {
            box.decrypt(prefix + Base64.encodeToString(bytes, Base64.NO_WRAP))
        }
        assertThrows(SecretReadException::class.java) { box.decrypt("not encrypted") }
        assertEquals("", box.decrypt(""))
    }
}
