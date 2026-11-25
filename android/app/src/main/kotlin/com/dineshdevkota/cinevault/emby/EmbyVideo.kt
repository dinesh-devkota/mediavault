package com.dineshdevkota.cinevault.emby

import com.dineshdevkota.cinevault.smb.RemoteHandle
import java.io.InputStream

internal class EmbyVideo(
    private val connection: EmbyConnection,
    val playback: EmbyClient.DirectPlayback,
    override val length: Long,
    private val authorize: () -> Unit,
) : RemoteHandle {
    // The Video owns no server file handles. A seek opens a new range at its exact position.
    override fun close() = Unit

    override fun stream(position: Long): InputStream {
        require(position in 0..length)
        return object : InputStream() {
            private var cursor = position
            private var chunk = byteArrayOf()
            private var consumed = 0
            private var closed = false

            override fun read(): Int {
                val byte = ByteArray(1)
                return if (read(byte, 0, 1) == -1) -1 else byte[0].toInt() and 0xff
            }

            override fun read(buffer: ByteArray, offset: Int, requested: Int): Int {
                if (offset < 0 || requested < 0 || offset > buffer.size - requested) throw IndexOutOfBoundsException()
                if (requested == 0) return 0
                check(!closed)
                authorize()
                if (cursor == length) return -1
                if (consumed == chunk.size) {
                    val size = minOf(MAX_CHUNK.toLong(), length - cursor).toInt()
                    val read = connection.client.readBlocking(connection.account, playback, cursor, size)
                    authorize()
                    if (read.totalLength != length) throw EmbyException("This Emby media changed. Reopen it and try again.")
                    chunk = read.bytes
                    consumed = 0
                }
                val count = minOf(requested, chunk.size - consumed)
                chunk.copyInto(buffer, offset, consumed, consumed + count)
                consumed += count
                cursor += count
                return count
            }

            override fun close() {
                closed = true
                chunk = byteArrayOf()
            }
        }
    }

    private companion object {
        const val MAX_CHUNK = 512 * 1024
    }
}
