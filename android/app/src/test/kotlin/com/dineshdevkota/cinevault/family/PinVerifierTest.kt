package com.dineshdevkota.cinevault.family

import org.junit.Assert.*
import org.junit.Test

class PinVerifierTest {
    @Test fun portableDerivationMatchesExistingPlatformPinRecords() {
        val salt = ByteArray(16) { it.toByte() }
        val specification = javax.crypto.spec.PBEKeySpec("023456".toCharArray(), salt, PinVerifier.ROUNDS, 256)
        val expected = javax.crypto.SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(specification).encoded
        assertArrayEquals(expected, PinVerifier.derivePortable("023456", salt))
        assertFalse(expected.contentEquals(PinVerifier.derivePortable("023457", salt)))
    }

    @Test fun sixASCIIDigitsOnly() {
        assertTrue(PinVerifier.valid("023456"))
        listOf("", "12345", "1234567", "１２３４５６", "12345a", " 123456").forEach { assertFalse(PinVerifier.valid(it)) }
    }
    @Test fun saltedVerifierDoesNotStoreOrAcceptWrongPIN() {
        val first = PinVerifier.create("123456")
        val second = PinVerifier.create("123456")
        assertNotEquals(first.salt, second.salt)
        assertNotEquals(first.hash, second.hash)
        assertTrue(first.matches("123456"))
        assertFalse(first.matches("123457"))
        assertFalse(first.matches("12345"))
        assertFalse(first.copy(rounds = 1).matches("123456"))
        assertFalse(first.toString().contains("123456"))
    }
}
