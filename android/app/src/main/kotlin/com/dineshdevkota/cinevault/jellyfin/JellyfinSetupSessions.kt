package com.dineshdevkota.cinevault.jellyfin

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/** Keeps setup tokens alive only while a screen owns them or a source has saved them. */
internal class JellyfinSetupSessions(private val appScope: CoroutineScope) {
    private val mutex = Mutex()
    private val active = mutableSetOf<Draft>()

    internal inner class Draft(
        val endpoint: String,
        val connection: JellyfinConnection,
        private val originalToken: Result<String?>,
        private val savedToken: suspend (String) -> Boolean,
    ) {
        suspend fun save(write: suspend () -> Unit) = mutex.withLock {
            check(this in active) { "This Jellyfin sign-in has ended. Sign in again." }
            write()
            active.remove(this)
            Unit
        }

        suspend fun <T> prepare(read: suspend (JellyfinConnection) -> T): T {
            try { return read(connection) }
            catch (error: Exception) {
                abandon()
                throw error
            }
        }

        fun abandon(): Job = appScope.launch {
            mutex.withLock {
                if (!active.remove(this@Draft)) return@withLock
                val token = connection.session.token
                // A reconnect can return the saved token or another open editor's token.
                if (originalToken.isFailure || originalToken.getOrNull() == token ||
                    active.any { it.endpoint == endpoint && it.connection.session.token == token }) return@withLock
                try {
                    withTimeoutOrNull(5_000) {
                        if (!savedToken(token)) connection.client.signOut(connection.session, timeoutMillis = 4_000)
                    }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    // An unavailable server or an unreadable saved credential cannot safely be retried here.
                }
            }
        }
    }

    suspend fun open(
        endpoint: String,
        originalToken: Result<String?>,
        savedToken: suspend (String) -> Boolean,
        authorize: () -> Unit,
        authenticate: suspend () -> JellyfinConnection,
    ): Draft {
        var issued: Draft? = null
        try {
            mutex.withLock {
                currentCoroutineContext().ensureActive()
                authorize()
                // Capture the returned token even if Back closes the screen while authentication is in flight.
                withContext(NonCancellable) {
                    issued = Draft(endpoint, authenticate(), originalToken, savedToken).also(active::add)
                }
            }
            currentCoroutineContext().ensureActive()
            authorize()
            return checkNotNull(issued)
        } catch (error: Exception) {
            issued?.abandon()
            throw error
        }
    }
}
