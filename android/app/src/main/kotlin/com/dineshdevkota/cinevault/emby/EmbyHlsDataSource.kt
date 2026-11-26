package com.dineshdevkota.cinevault.emby

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSpec

/** Reads only the resources of one negotiated Emby conversion under the current household session. */
@UnstableApi
internal class EmbyHlsDataSource(
    private val connection: EmbyConnection,
    private val playback: EmbyClient.TranscodedPlayback,
    private val authorize: () -> Unit,
) : BaseDataSource(true) {
    private var uri: Uri? = null
    private var resource = ByteArray(0)
    private var cursor = 0
    private var end = 0
    private var opened = false

    override fun open(dataSpec: DataSpec): Long {
        transferInitializing(dataSpec)
        authorize()
        val (resolved, bytes) = connection.client.readHls(connection.account, playback, dataSpec.uri.toString())
        authorize()
        if (dataSpec.position < 0 || dataSpec.position > bytes.size) {
            throw EmbyException("The selected Emby HLS resource changed.")
        }
        uri = Uri.parse(resolved.toString())
        cursor = dataSpec.position.toInt()
        resource = bytes
        val available = (bytes.size - cursor).toLong()
        end = cursor + (if (dataSpec.length == C.LENGTH_UNSET.toLong()) available else minOf(available, dataSpec.length)).toInt()
        opened = true
        transferStarted(dataSpec)
        return (end - cursor).toLong()
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0
        authorize()
        if (cursor >= end) return C.RESULT_END_OF_INPUT
        val count = minOf(end - cursor, length)
        resource.copyInto(buffer, offset, cursor, cursor + count)
        cursor += count
        bytesTransferred(count)
        return count
    }

    override fun getUri(): Uri? = uri

    override fun close() {
        uri = null
        resource = ByteArray(0)
        cursor = 0
        end = 0
        if (opened) {
            opened = false
            transferEnded()
        }
    }
}
