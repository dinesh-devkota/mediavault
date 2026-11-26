@file:OptIn(UnstableApi::class)

package com.dineshdevkota.cinevault.playback

import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSchemeDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.okhttp.OkHttpDataSource
import com.dineshdevkota.cinevault.jellyfin.JellyfinConnection
import com.dineshdevkota.cinevault.jellyfin.JellyfinPlayback
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import okhttp3.OkHttpClient
import java.io.IOException

internal val jellyfinAndroidProfile = Json.parseToJsonElement("""
    {
      "Name": "MediaVault Android TV",
      "MaxStreamingBitrate": 20000000,
      "DirectPlayProfiles": [{"Type":"Video","Container":"mp4","VideoCodec":"h264","AudioCodec":"aac"}],
      "SubtitleProfiles": [
        {"Format":"srt","Method":"External"}, {"Format":"subrip","Method":"External"},
        {"Format":"vtt","Method":"External"}
      ],
      "TranscodingProfiles": [
        {"Type":"Video","Context":"Streaming","Protocol":"hls","Container":"ts",
         "VideoCodec":"h264","AudioCodec":"aac","MaxAudioChannels":"2"}
      ]
    }
""".trimIndent()).jsonObject

internal fun jellyfinDataSources(
    connection: JellyfinConnection,
    playback: JellyfinPlayback,
    fixtureHttp: OkHttpClient? = null,
    authorize: () -> Unit,
): DataSource.Factory {
    val http = (fixtureHttp?.newBuilder() ?: OkHttpClient.Builder()).followRedirects(false).followSslRedirects(false)
        .addInterceptor { chain ->
            authorize()
            val request = chain.request()
            val trusted = connection.client.playbackAssetRequest(connection.session, playback, request.url)
            chain.proceed(request.newBuilder().url(trusted.url)
                .header("Authorization", checkNotNull(trusted.header("Authorization"))).build())
        }.build()
    return guardedJellyfinDataSources("https", OkHttpDataSource.Factory(http), authorize)
}

/** Only already validated app-owned caption bytes use this factory. Jellyfin URLs stay HTTPS-only. */
internal fun jellyfinLocalSubtitleDataSources(authorize: () -> Unit): DataSource.Factory =
    guardedJellyfinDataSources("data", DataSource.Factory { DataSchemeDataSource() }, authorize)

private fun guardedJellyfinDataSources(
    scheme: String, factory: DataSource.Factory, authorize: () -> Unit,
): DataSource.Factory = DataSource.Factory {
    val delegate = factory.createDataSource()
    object : DataSource by delegate {
        override fun open(dataSpec: DataSpec): Long {
            authorize()
            if (dataSpec.uri.scheme != scheme) throw IOException("This Jellyfin asset has an unsupported address.")
            val length = delegate.open(dataSpec)
            try { authorize() }
            catch (error: Exception) {
                try { delegate.close() }
                catch (closeError: Exception) { error.addSuppressed(closeError) }
                throw error
            }
            return length
        }

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            authorize()
            return delegate.read(buffer, offset, length).also { authorize() }
        }
    }
}
