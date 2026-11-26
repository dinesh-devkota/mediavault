package com.dineshdevkota.cinevault.plex

import com.dineshdevkota.cinevault.smb.RemoteHandle
import java.io.InputStream
import kotlinx.coroutines.runBlocking

/** Media3 can reopen this exact part at each seek, without exposing a Plex credential in its URI. */
internal class PlexRemoteHandle(
    private val client: PlexMediaClient,
    private val part: PlexMediaClient.MediaPart,
    private val authorize: () -> Unit,
) : RemoteHandle {
    override val length: Long get() = part.size

    override fun stream(position: Long): InputStream {
        require(position in 0..length)
        return object : InputStream() {
            private var next = position
            private var buffer = ByteArray(0)
            private var index = 0
            private var closed = false

            override fun read(): Int {
                val one = ByteArray(1)
                return if (read(one, 0, 1) == -1) -1 else one[0].toInt() and 0xff
            }

            override fun read(destination: ByteArray, offset: Int, size: Int): Int {
                require(offset >= 0 && size >= 0 && offset <= destination.size - size)
                check(!closed) { "The Plex media stream is closed." }
                authorize()
                if (size == 0) return 0
                if (index == buffer.size) {
                    if (next == length) return -1
                    val count = minOf(512 * 1024L, length - next).toInt()
                    buffer = runBlocking { client.read(part, next, count) }
                    authorize()
                    next += count
                    index = 0
                }
                val count = minOf(size, buffer.size - index)
                buffer.copyInto(destination, offset, index, index + count)
                index += count
                return count
            }

            override fun close() {
                closed = true
                buffer = ByteArray(0)
            }
        }
    }

    override fun close() = Unit
}
