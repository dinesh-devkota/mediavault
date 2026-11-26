@file:Suppress("DEPRECATION")

package com.dineshdevkota.cinevault.data

import android.content.Context
import android.security.KeyPairGeneratorSpec
import android.util.Base64
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.SecureRandom
import java.util.Calendar
import java.util.Date
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import javax.security.auth.x500.X500Principal

/**
 * Android 5.1 supports Keystore RSA but not Keystore AES. Each value gets an independent random
 * AES-256 key. Only its RSA-wrapped form is persisted alongside the authenticated ciphertext.
 * The native RSA private key never leaves Android Keystore; no software/plaintext fallback exists.
 */
internal class LegacySecretEnvelope(private val context: Context, private val alias: String) {
    private fun wrappingKey(create: Boolean): KeyStore.PrivateKeyEntry = synchronized(lock) {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val entry = store.getEntry(alias, null)
        if (entry != null) return@synchronized entry as? KeyStore.PrivateKeyEntry
            ?: error("The saved credentials' wrapping key is invalid.")
        check(create) { "The saved credentials' wrapping key is unavailable." }
        val expiry = Calendar.getInstance().apply { add(Calendar.YEAR, 30) }.time
        val spec = KeyPairGeneratorSpec.Builder(context)
            .setAlias(alias).setKeySize(2048)
            .setSubject(X500Principal("CN=MediaVault credentials"))
            .setSerialNumber(BigInteger.ONE)
            .setStartDate(Date(0)).setEndDate(expiry).build()
        KeyPairGenerator.getInstance("RSA", "AndroidKeyStore").apply { initialize(spec) }.generateKeyPair()
        store.getEntry(alias, null) as? KeyStore.PrivateKeyEntry
            ?: error("The credentials' wrapping key could not be created.")
    }

    fun encrypt(plain: String): String {
        val rawKey = ByteArray(32).also(random::nextBytes)
        return try {
            // PKCS#1 wrapping is supported by API22's Keystore. The envelope uses AES-GCM for
            // authentication, including the wrapped bytes and format version as associated data.
            val wrapper = Cipher.getInstance("RSA/ECB/PKCS1Padding")
            wrapper.init(Cipher.ENCRYPT_MODE, wrappingKey(create = true).certificate.publicKey)
            val wrapped = wrapper.doFinal(rawKey)
            check(wrapped.size == WRAPPED_BYTES)
            val nonce = ByteArray(IV_BYTES).also(random::nextBytes)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(rawKey, "AES"), GCMParameterSpec(TAG_BITS, nonce))
            cipher.updateAAD(PREFIX.toByteArray(Charsets.US_ASCII) + wrapped)
            PREFIX + Base64.encodeToString(wrapped + nonce + cipher.doFinal(plain.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP)
        } finally { rawKey.fill(0) }
    }

    fun decrypt(sealed: String): String {
        require(sealed.startsWith(PREFIX))
        val bytes = Base64.decode(sealed.substring(PREFIX.length), Base64.NO_WRAP)
        require(bytes.size >= WRAPPED_BYTES + IV_BYTES + TAG_BITS / 8) { "Invalid encrypted credentials." }
        val wrapped = bytes.copyOfRange(0, WRAPPED_BYTES)
        val wrapper = Cipher.getInstance("RSA/ECB/PKCS1Padding")
        wrapper.init(Cipher.DECRYPT_MODE, wrappingKey(create = false).privateKey)
        val rawKey = wrapper.doFinal(wrapped)
        return try {
            require(rawKey.size == 32) { "Invalid credentials' encryption key." }
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(rawKey, "AES"), GCMParameterSpec(TAG_BITS, bytes, WRAPPED_BYTES, IV_BYTES))
            cipher.updateAAD(PREFIX.toByteArray(Charsets.US_ASCII) + wrapped)
            val offset = WRAPPED_BYTES + IV_BYTES
            String(cipher.doFinal(bytes, offset, bytes.size - offset), Charsets.UTF_8)
        } finally { rawKey.fill(0) }
    }

    companion object {
        const val PREFIX = "rsa1:"
        private const val WRAPPED_BYTES = 256
        private const val IV_BYTES = 12
        private const val TAG_BITS = 128
        private val lock = Any()
        private val random = SecureRandom()
    }
}
