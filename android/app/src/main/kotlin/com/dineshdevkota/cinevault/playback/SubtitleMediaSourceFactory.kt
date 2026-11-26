@file:OptIn(UnstableApi::class)

package com.dineshdevkota.cinevault.playback

import androidx.annotation.OptIn
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.MergingMediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.extractor.ExtractorOutput
import androidx.media3.extractor.ExtractorsFactory
import androidx.media3.extractor.SeekMap
import androidx.media3.extractor.text.DefaultSubtitleParserFactory
import androidx.media3.extractor.text.SubtitleExtractor

/** Native sidecar extraction with the real final cue end, rather than its start plus 10 ms. */
internal class SubtitleMediaSourceFactory(
    private val primary: MediaSource.Factory,
    private val dataSources: DataSource.Factory,
    private val subtitles: () -> List<PreparedSubtitle>,
) : MediaSource.Factory by primary {
    override fun createMediaSource(mediaItem: MediaItem): MediaSource {
        val configurations = mediaItem.localConfiguration?.subtitleConfigurations.orEmpty()
        if (configurations.isEmpty()) return primary.createMediaSource(mediaItem)
        val preparedByConfiguration = subtitles().associateBy { it.configuration }
        // Only already validated captions use the bounded local data source.
        val prepared = configurations.mapNotNull(preparedByConfiguration::get)
        if (prepared.isEmpty()) return primary.createMediaSource(mediaItem)
        val remote = configurations.filterNot(preparedByConfiguration::containsKey)
        val video = primary.createMediaSource(mediaItem.buildUpon().setSubtitleConfigurations(remote).build())
        val sidecars = prepared.map { subtitle ->
            val extractors = ExtractorsFactory { arrayOf(extractor(subtitle)) }
            ProgressiveMediaSource.Factory(dataSources, extractors)
                .setLoadErrorHandlingPolicy(SmbDataSource.loadErrorPolicy)
                .createMediaSource(MediaItem.fromUri(subtitle.configuration.uri))
        }
        // The video defines the timeline; a short caption file must never clip the movie.
        return MergingMediaSource(video, *sidecars.toTypedArray())
    }

    companion object {
        internal fun extractor(subtitle: PreparedSubtitle): SubtitleExtractor {
            val configuration = subtitle.configuration
            val format = Format.Builder().setId(configuration.id).setSampleMimeType(configuration.mimeType)
                .setLanguage(configuration.language).setLabel(configuration.label)
                .setSelectionFlags(configuration.selectionFlags).setRoleFlags(configuration.roleFlags).build()
            return object : SubtitleExtractor(DefaultSubtitleParserFactory().create(format), format) {
                override fun init(output: ExtractorOutput) {
                    super.init(object : ExtractorOutput by output {
                        override fun seekMap(seekMap: SeekMap) {
                            // Media3 1.8 lazy sidecars infer duration from the final cue's START and
                            // classify the unknown-length source as live, dropping that cue on seeks.
                            output.seekMap(object : SeekMap by seekMap {
                                override fun getDurationUs(): Long = subtitle.durationUs
                            })
                        }
                    })
                }
            }
        }
    }
}
