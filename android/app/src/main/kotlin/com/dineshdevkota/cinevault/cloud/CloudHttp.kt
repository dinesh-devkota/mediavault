package com.dineshdevkota.cinevault.cloud

import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Headers
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resumeWithException

internal const val MAX_CLOUD_RESPONSE = 8 * 1024 * 1024

/** API and content requests contain credentials. They must remain on the original endpoint. */
internal class CloudHttp(client: OkHttpClient = defaultClient) {
    private val http = client.newBuilder().followRedirects(false).followSslRedirects(false).build()

    suspend fun exchange(request: Request, status: Int = 200, limit: Int = MAX_CLOUD_RESPONSE): CloudResponse =
        suspendCancellableCoroutine { continuation ->
            val call = http.newCall(request)
            continuation.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    continuation.resumeWithException(CloudClientException("Could not reach the cloud provider."))
                }

                override fun onResponse(call: Call, response: Response) {
                    continuation.resumeWith(runCatching {
                        response.use { readable ->
                            if (readable.code != status) {
                                throw CloudClientException("The provider returned HTTP ${readable.code}.", readable.code)
                            }
                            val body = readable.body ?: throw CloudClientException("Missing response body.")
                            val source = body.source()
                            if (body.contentLength() > limit || source.request(limit.toLong() + 1)) {
                                throw CloudClientException("The provider response exceeded the expected size.")
                            }
                            CloudResponse(readable.headers, source.readByteArray())
                        }
                    })
                }
            })
        }

    private companion object {
        val defaultClient = OkHttpClient.Builder().connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS).callTimeout(60, TimeUnit.SECONDS).build()
    }
}

internal data class CloudResponse(val headers: Headers, val data: ByteArray) {
    fun verifiedRange(start: Long, end: Long, length: Int): ByteArray {
        val prefix = "bytes $start-$end/"
        val range = headers["Content-Range"]
        val total = range?.takeIf { it.startsWith(prefix) }?.removePrefix(prefix)?.toLongOrNull()
        if (total == null || total <= end || range != "$prefix$total" || data.size != length ||
            headers["Content-Encoding"]?.equals("identity", ignoreCase = true) == false
        ) {
            throw CloudClientException("The provider returned a different byte range.")
        }
        return data
    }
}

internal class CloudClientException(message: String, val statusCode: Int? = null) : IOException(message)

internal fun Request.Builder.bearer(token: String): Request.Builder {
    require(token.isNotEmpty() && token.all { it in '!'..'~' }) { "Invalid cloud authorization." }
    return header("Authorization", "Bearer $token")
}

internal fun rangeEnd(offset: Long, length: Int): Long {
    require(offset >= 0 && length in 1..MAX_CLOUD_RESPONSE && offset <= Long.MAX_VALUE - length) {
        "Invalid cloud media range."
    }
    return offset + length - 1
}
