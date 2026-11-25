package com.dineshdevkota.cinevault.cloud

import android.content.Context
import com.dineshdevkota.cinevault.data.SecretBox
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import java.util.UUID

@Serializable
internal class SavedOneDriveAccount(
    val sourceId: String,
    val applicationId: String,
    val driveId: String,
    val refreshToken: String,
)

internal interface OneDriveAccountStore {
    fun load(source: UUID): SavedOneDriveAccount?
    fun save(source: UUID, account: SavedOneDriveAccount)
    fun remove(source: UUID)
}

/** Source credentials are sealed with the same device-bound key as NAS credentials. */
internal class AndroidOneDriveAccountStore(context: Context, private val secrets: SecretBox) : OneDriveAccountStore {
    private val preferences = context.applicationContext.getSharedPreferences("onedrive-accounts", Context.MODE_PRIVATE)

    override fun load(source: UUID): SavedOneDriveAccount? =
        preferences.getString(source.toString(), null)?.let {
            try {
                Json.decodeFromString<SavedOneDriveAccount>(secrets.decrypt(it))
            } catch (_: SerializationException) {
                throw CloudClientException("The saved OneDrive connection could not be read. Connect it again.")
            }
        }

    override fun save(source: UUID, account: SavedOneDriveAccount) {
        val encrypted = secrets.encrypt(Json.encodeToString(SavedOneDriveAccount.serializer(), account))
        if (!preferences.edit().putString(source.toString(), encrypted).commit()) {
            throw CloudClientException("The OneDrive connection could not be saved.")
        }
    }

    override fun remove(source: UUID) {
        if (!preferences.edit().remove(source.toString()).commit()) {
            throw CloudClientException("The OneDrive connection could not be removed.")
        }
    }
}

/**
 * Own exactly one instance per configured source. Network work does not hold the state lock,
 * so a disconnect immediately invalidates sign-in, refresh, and reads already in progress.
 */
internal class OneDriveAccount(
    private val source: UUID,
    private val client: OneDriveClient,
    private val store: OneDriveAccountStore,
    private val nowMillis: () -> Long = { System.nanoTime() / 1_000_000 },
) {
    private class Access(val token: String, val expires: Long, val revision: Long)
    private class Refresh(val saved: SavedOneDriveAccount, val revision: Long)

    private val state = Mutex()
    private val renewal = Mutex()
    private var revision = 0L
    private var cached: Access? = null

    suspend fun beginSignIn(): OneDriveClient.Challenge = client.beginSignIn()

    suspend fun link(challenge: OneDriveClient.Challenge) = withContext(Dispatchers.IO) {
        val attempt = state.withLock { ++revision }
        val tokens = client.completeSignIn(challenge)
        val refresh = tokens.refreshToken?.takeIf(String::isNotBlank)
            ?: throw CloudClientException("Microsoft did not grant offline access. Connect OneDrive again.")
        val drive = client.driveIdentity(tokens.accessToken)
        state.withLock {
            requireCurrent(attempt)
            val current = saved()
            if (current != null && current.driveId != drive) {
                throw CloudClientException("Use the same OneDrive account, or add a separate source.")
            }
            store.save(source, SavedOneDriveAccount(source.toString(), client.applicationId, drive, refresh))
            remember(tokens, attempt)
        }
        Unit
    }

    suspend fun disconnect() = withContext(Dispatchers.IO) {
        state.withLock {
            revision++
            cached = null
            store.remove(source)
        }
    }

    suspend fun connectionVersion(): Long = state.withLock { revision }

    suspend fun list(folder: String?, version: Long, onPage: suspend (List<OneDriveClient.Entry>) -> Unit) {
        val access = authorize(version)
        client.listChildren(folder, access.token) { entries ->
            state.withLock { requireCurrent(version) }
            onPage(entries)
        }
        state.withLock { requireCurrent(version) }
    }

    suspend fun read(file: String, offset: Long, length: Int, version: Long): ByteArray {
        val access = authorize(version)
        val bytes = client.read(file, offset, length, access.token)
        state.withLock { requireCurrent(version) }
        return bytes
    }

    private suspend fun authorize(version: Long): Access = withContext(Dispatchers.IO) {
        renewal.withLock {
            val current = state.withLock {
                requireCurrent(version)
                cached?.takeIf { it.revision == version && it.expires - nowMillis() > 60_000L }
            }
            if (current != null) return@withLock current
            val plan = state.withLock {
                requireCurrent(version)
                Refresh(saved() ?: throw CloudClientException("Connect the OneDrive account again."), version)
            }
            val tokens = client.refresh(plan.saved.refreshToken)
            state.withLock {
                requireCurrent(plan.revision)
                val rotated = tokens.refreshToken
                if (!rotated.isNullOrBlank() && rotated != plan.saved.refreshToken) {
                    store.save(source, SavedOneDriveAccount(source.toString(), client.applicationId, plan.saved.driveId, rotated))
                }
                remember(tokens, plan.revision)
            }
        }
    }

    private fun saved(): SavedOneDriveAccount? {
        val account = store.load(source) ?: return null
        if (account.sourceId != source.toString() || account.applicationId != client.applicationId ||
            account.driveId.isBlank() || account.refreshToken.isBlank()
        ) {
            throw CloudClientException("The saved OneDrive account does not match this source.")
        }
        return account
    }

    private fun remember(tokens: OneDriveClient.Credentials, attempt: Long): Access =
        Access(tokens.accessToken, nowMillis() + tokens.expiresIn * 1000L, attempt).also { cached = it }

    private fun requireCurrent(attempt: Long) {
        if (revision != attempt) throw CloudClientException("The OneDrive connection changed during the request.")
    }
}
