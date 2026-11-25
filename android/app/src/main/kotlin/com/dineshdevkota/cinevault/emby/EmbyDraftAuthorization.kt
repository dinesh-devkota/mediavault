package com.dineshdevkota.cinevault.emby

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/** A setup token belongs to the form until it is saved in the source store. */
internal class EmbyDraftAuthorization(val connection: EmbyConnection) {
    private var cleanup: Job? = null

    @Synchronized
    fun discard(scope: CoroutineScope, savedToken: suspend () -> String?): Job =
        cleanup ?: scope.launch(Dispatchers.IO) {
            try {
                // Emby can return the same token on reconnect. Never revoke the saved session.
                if (savedToken() != connection.account.AccessToken) connection.client.signOut(connection.account)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                // A failed lookup or an offline server leaves existing sources usable.
            }
        }.also { cleanup = it }
}
