package com.dineshdevkota.cinevault.plex

import android.content.SharedPreferences
import android.os.SystemClock
import com.dineshdevkota.cinevault.data.SecretBox
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json

@Serializable
internal class SavedPlexServer(
    val name: String,
    val serverID: String,
    val endpoint: String,
    val deviceID: String,
    val serverToken: String,
)

internal interface PlexConnectionStorage {
    fun read(): SavedPlexServer?
    fun save(server: SavedPlexServer)
    fun clear()
}

internal class PlexKeystoreConnectionStore(
    private val preferences: SharedPreferences,
    private val secrets: SecretBox,
) : PlexConnectionStorage {
    override fun read(): SavedPlexServer? {
        val sealed = preferences.getString(KEY, null) ?: return null
        return try {
            Json.decodeFromString<SavedPlexServer>(secrets.decrypt(sealed))
        } catch (_: SerializationException) {
            throw PlexException("The saved Plex server could not be read. Link it again.")
        }
    }

    override fun save(server: SavedPlexServer) {
        val sealed = secrets.encrypt(Json.encodeToString(server))
        if (!preferences.edit().putString(KEY, sealed).commit()) {
            throw PlexException("The Plex server could not be saved.")
        }
    }

    override fun clear() {
        if (!preferences.edit().remove(KEY).commit()) throw PlexException("The Plex server could not be removed.")
    }

    internal companion object {
        const val KEY = "selected_server"
    }
}

/** Manage a Plex connection under one authenticated household owner session. */
internal class PlexConnectionManager(
    private val ownerSession: () -> UUID?,
    private val storage: PlexConnectionStorage,
    private val deviceID: UUID,
    private val account: PlexAccountClient = PlexAccountClient(deviceID),
    private val clockMillis: () -> Long = SystemClock::elapsedRealtime,
    private val mediaClient: (PlexAccountClient.Server, PlexAccountClient.Connection) -> PlexMediaClient =
        { server, connection -> PlexMediaClient(server, connection, deviceID) },
) {
    data class LinkCode(val code: String, val expiresInSeconds: Int)
    data class ConnectionChoice(val endpoint: String, val local: Boolean, val relay: Boolean)
    data class ServerChoice(val name: String, val id: String, val connections: List<ConnectionChoice>)
    data class SelectedServer(val name: String, val id: String, val endpoint: String)
    data class VerifiedSelection(val server: SelectedServer, val libraries: List<PlexMediaClient.Library>)

    sealed interface LinkStatus {
        data object AwaitingAuthorization : LinkStatus
        data class ChooseServer(val servers: List<ServerChoice>) : LinkStatus
    }

    private class Flight(
        val owner: UUID,
        val pin: PlexAccountClient.Pin,
        val startedAt: Long,
        var servers: List<PlexAccountClient.Server>? = null,
    )

    private val operation = Mutex()
    private var linking: Flight? = null

    suspend fun start(): LinkCode = operation.withLock {
        val owner = requireOwner()
        linking = null
        val startedAt = clockMillis()
        val pin = account.beginLink()
        requireOwner(owner)
        val flight = Flight(owner, pin, startedAt)
        requireActive(flight)
        linking = flight
        LinkCode(pin.code, pin.expiresIn)
    }

    suspend fun poll(): LinkStatus = operation.withLock {
        val flight = activeFlight()
        flight.servers?.let { return@withLock LinkStatus.ChooseServer(it.map(::serverChoice)) }
        val accountToken = account.pollLink(flight.pin)
        requireActive(flight)
        if (accountToken == null) return@withLock LinkStatus.AwaitingAuthorization
        val servers = account.servers(accountToken)
        requireActive(flight)
        if (servers.map { it.clientIdentifier }.toSet().size != servers.size) {
            throw PlexException("Plex returned duplicate server identifiers.")
        }
        flight.servers = servers
        LinkStatus.ChooseServer(servers.map(::serverChoice))
    }

    suspend fun select(serverID: String, endpoint: String): VerifiedSelection = operation.withLock {
        val flight = activeFlight()
        val server = flight.servers?.firstOrNull { it.clientIdentifier == serverID }
            ?: throw PlexException("Choose a server from this Plex linking session.")
        val connection = server.secureConnections.firstOrNull { it.uri == endpoint }
            ?: throw PlexException("Choose an HTTPS connection listed for this Plex server.")
        val libraries = mediaClient(server, connection).libraries()
        requireActive(flight)
        val saved = SavedPlexServer(
            name = server.name,
            serverID = server.clientIdentifier,
            endpoint = connection.uri,
            deviceID = deviceID.toString(),
            serverToken = checkNotNull(server.accessToken),
        )
        withContext(Dispatchers.IO) {
            requireActive(flight)
            storage.save(saved)
        }
        linking = null
        requireOwner(flight.owner)
        VerifiedSelection(saved.summary(), libraries)
    }

    suspend fun cancelLink() = operation.withLock {
        requireOwner()
        linking = null
    }

    suspend fun selected(): SelectedServer? = operation.withLock {
        val owner = requireOwner()
        val saved = withContext(Dispatchers.IO) { storage.read() }
        requireOwner(owner)
        saved?.summary()
    }

    suspend fun disconnect() = operation.withLock {
        val owner = requireOwner()
        linking = null
        withContext(Dispatchers.IO) {
            requireOwner(owner)
            storage.clear()
        }
    }

    private fun activeFlight(): Flight {
        val owner = requireOwner()
        val flight = linking ?: throw PlexException("Start linking Plex again.")
        if (flight.owner != owner) {
            linking = null
            throw PlexException("Start linking Plex again from the active owner profile.")
        }
        requireActive(flight)
        return flight
    }

    private fun requireActive(flight: Flight) {
        requireOwner(flight.owner)
        val age = clockMillis() - flight.startedAt
        if (age < 0 || age >= flight.pin.expiresIn * 1_000L) {
            linking = null
            throw PlexException("The Plex link code expired. Request a new code.")
        }
    }

    private fun requireOwner(expected: UUID? = null): UUID {
        val current = ownerSession()
        if (current == null || (expected != null && current != expected)) {
            linking = null
            throw PlexException("The active household owner must manage Plex connections.")
        }
        return current
    }

    private fun SavedPlexServer.summary() = SelectedServer(name, serverID, endpoint)

    private fun serverChoice(server: PlexAccountClient.Server) =
        ServerChoice(server.name, server.clientIdentifier, server.secureConnections.map {
            ConnectionChoice(it.uri, it.local, it.relay)
        })
}
