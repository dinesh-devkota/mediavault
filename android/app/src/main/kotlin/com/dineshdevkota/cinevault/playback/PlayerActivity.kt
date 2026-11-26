@file:OptIn(UnstableApi::class)

package com.dineshdevkota.cinevault.playback

import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import android.util.Pair
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.addCallback
import androidx.annotation.OptIn
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import androidx.room.withTransaction
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.Tracks
import androidx.media3.common.TrackSelectionParameters
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.extractor.DefaultExtractorsFactory
import androidx.media3.ui.PlayerView
import com.dineshdevkota.cinevault.container
import com.dineshdevkota.cinevault.core.WatchRules
import com.dineshdevkota.cinevault.data.MovieEntity
import com.dineshdevkota.cinevault.data.SourceEntity
import com.dineshdevkota.cinevault.jellyfin.JELLYFIN
import com.dineshdevkota.cinevault.jellyfin.JellyfinConnection
import com.dineshdevkota.cinevault.jellyfin.JellyfinException
import com.dineshdevkota.cinevault.jellyfin.JellyfinPlayback
import com.dineshdevkota.cinevault.jellyfin.JellyfinPlaybackEvent
import com.dineshdevkota.cinevault.jellyfin.jellyfinConnection
import com.dineshdevkota.cinevault.jellyfin.jellyfinItemID
import com.dineshdevkota.cinevault.plex.PLEX
import com.dineshdevkota.cinevault.plex.PlexException
import com.dineshdevkota.cinevault.plex.PlexMediaClient
import com.dineshdevkota.cinevault.plex.PlexRemoteHandle
import com.dineshdevkota.cinevault.plex.plexClient
import com.dineshdevkota.cinevault.plex.authorizedItem
import com.dineshdevkota.cinevault.ui.ContinueWatchingItem
import com.dineshdevkota.cinevault.ui.nextEpisodeFor
import com.dineshdevkota.cinevault.ui.PlaybackSettingsActivity
import com.dineshdevkota.cinevault.ui.languageName
import com.dineshdevkota.cinevault.ui.isTelevision
import com.dineshdevkota.cinevault.ui.chooseSubtitleLanguage
import com.dineshdevkota.cinevault.subtitles.SubDlClient
import com.dineshdevkota.cinevault.subtitles.subtitleQuery
import com.dineshdevkota.cinevault.subtitles.SubDlSubtitle
import com.dineshdevkota.cinevault.smb.SmbException
import com.dineshdevkota.cinevault.smb.SmbService
import com.dineshdevkota.cinevault.smb.SourceConfig
import com.dineshdevkota.cinevault.webdav.DavAddress
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.combine
import java.io.IOException
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.withContext

/**
 * Full-screen ExoPlayer for one movie, streamed straight from the NAS. Saves the resume point every
 * 10 seconds, on pause and on exit, and marks the movie watched past [WatchRules.WATCHED_FRACTION].
 */
class PlayerActivity : ComponentActivity() {
    private class Target(
        val movie: MovieEntity, val config: SourceConfig?, val source: SourceEntity,
        val connection: JellyfinConnection? = null,
        val plex: PlexPlaying? = null,
    )

    private class PlexPlaying(val client: PlexMediaClient, val part: PlexMediaClient.MediaPart, val rating: String?)
    private class JellyfinPlaying(val connection: JellyfinConnection, val playback: JellyfinPlayback)

    private lateinit var playerView: PlayerView
    private lateinit var rootView: FrameLayout
    private lateinit var information: LinearLayout
    private lateinit var titleLabel: TextView
    private lateinit var detailLabel: TextView
    @Volatile private var target: Target? = null
    private var jellyfinPlaying: JellyfinPlaying? = null
    private var jellyfinReportJob: Job? = null
    private var jellyfinFallbackJob: Job? = null
    private var retriedJellyfinPlayback = false
    private lateinit var householdSession: com.dineshdevkota.cinevault.family.FamilySession
    private var player: ExoPlayer? = null
    private var progressJob: Job? = null
    private var startPositionMs = C.TIME_UNSET
    private var playWhenReady = true
    private var finishedPlayback = false
    private var warnedAboutTracks = false
    private var endHandled = false
    private var playbackFailed = false
    private var countdownJob: Job? = null
    private var transitionJob: Job? = null
    private var nextCard: LinearLayout? = null
    private var pendingNext: ContinueWatchingItem? = null
    private var preparedSubtitles = emptyList<PreparedSubtitle>()
    private var onlineJob: Job? = null
    private var onlineAttempted = false
    private var subtitleNotice: String? = null
    private var subtitleDialog: AlertDialog? = null
    private var pendingSubtitleId: String? = null
    private var subtitleChoiceGeneration = 0L
    private val programmaticTrackChanges = mutableListOf<TrackSelectionParameters>()
    private data class SubtitleIdentity(val id: String, val path: String, val source: String, val fileName: String,
        val movieTmdb: Int?, val seriesTmdb: Int?, val season: Int?, val episode: Int?)
    private data class SubtitleRequest(val identity: SubtitleIdentity, val generation: Long, val language: String)

    private val listener = object : Player.Listener {
        override fun onIsPlayingChanged(isPlaying: Boolean) {
            // Paused, the TV may dim or start its screensaver as usual.
            playerView.keepScreenOn = isPlaying
            if (!isPlaying) record()
        }

        override fun onPlaybackStateChanged(playbackState: Int) {
            if (playbackState == Player.STATE_ENDED) {
                handleNaturalEnd()
            }
        }

        override fun onTracksChanged(tracks: Tracks) {
            warnAboutUnsupportedTracks(tracks)
            if (container.settings.subtitlePreference == "off") pendingSubtitleId = null
            pendingSubtitleId?.let { id ->
                player?.let { exo ->
                    SubtitleTracks.selectById(exo.trackSelectionParameters, tracks, id)?.let { parameters ->
                        pendingSubtitleId = null
                        setProgrammaticTrackParameters(parameters)
                    }
                }
            }
            considerAutomaticSubtitles()
        }

        override fun onPlayerError(error: PlaybackException) {
            playbackFailed = true
            cancelNext()
            if (error.errorCode in jellyfinFallbackErrors) retryJellyfinWithTranscoding()
        }

        override fun onTrackSelectionParametersChanged(parameters: TrackSelectionParameters) {
            if (programmaticTrackChanges.remove(parameters)) return
            val preference = SubtitleTracks.explicitPreference(parameters) ?: return
            invalidateSubtitleRequest()
            container.settings.subtitlePreference = preference
            // Native None otherwise leaves forced captions enabled. Explicit Off must remain Off.
            if (preference == "off" && C.TRACK_TYPE_TEXT !in parameters.disabledTrackTypes) {
                setProgrammaticTrackParameters(SubtitleTracks.applyPreference(parameters, preference))
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        householdSession = container.family.current
        if (!householdSession.unlocked) { finish(); return }
        lifecycleScope.launch {
            container.family.session.collect { session ->
                if (session != householdSession) {
                    if (::rootView.isInitialized) rootView.visibility = View.INVISIBLE
                    cancelNext(); invalidateSubtitleRequest(); subtitleDialog?.dismiss()
                    stopPlayer(); target = null; finish()
                }
            }
        }
        playerView = PlayerView(this).apply {
            id = com.dineshdevkota.cinevault.R.id.playback_view
            setShowBuffering(PlayerView.SHOW_BUFFERING_ALWAYS)
            setShowNextButton(false)
            setShowPreviousButton(false)
            setShowSubtitleButton(true)
            setErrorMessageProvider { error -> Pair.create(0, errorMessage(error)) }
            // Focused, the view gets D-pad presses (first one shows the controls) and remote media keys.
            isFocusable = true
        }
        // One menu keeps online choices and NAS lookup notices accessible from both subtitle controls.
        playerView.findViewById<View>(androidx.media3.ui.R.id.exo_subtitle)?.setOnClickListener { showSubtitleMenu() }
        val isTv = resources.configuration.isTelevision()
        val spacing = ((if (isTv) 24 else 12) * resources.displayMetrics.density).toInt()
        titleLabel = TextView(this).apply { setTextColor(Color.WHITE); textSize = 24f; maxLines = 2 }
        detailLabel = TextView(this).apply { setTextColor(Color.LTGRAY); textSize = 15f; maxLines = 3 }
        information = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(spacing, spacing, spacing, spacing)
            background = GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, intArrayOf(0xD9000000.toInt(), Color.TRANSPARENT))
            isFocusable = false
            addView(LinearLayout(this@PlayerActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                addView(titleLabel, LinearLayout.LayoutParams(0, -2, 1f))
                addView(Button(this@PlayerActivity).apply {
                    id = com.dineshdevkota.cinevault.R.id.playback_subtitles
                    text = "Subtitles"
                    setOnClickListener { showSubtitleMenu() }
                })
                addView(android.widget.Button(this@PlayerActivity).apply {
                    setText(com.dineshdevkota.cinevault.R.string.back)
                    contentDescription = "Back to media details"
                    setOnClickListener { finish() }
                })
            })
            addView(detailLabel)
        }
        rootView = FrameLayout(this).apply {
            addView(playerView, FrameLayout.LayoutParams(-1, -1))
            addView(information, FrameLayout.LayoutParams(-1, -2, Gravity.TOP))
        }
        if (!isTv) {
            ViewCompat.setOnApplyWindowInsetsListener(rootView) { view, insets ->
                val safe = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
                view.setPadding(safe.left, safe.top, safe.right, safe.bottom)
                insets
            }
        }
        setContentView(rootView)
        playerView.setControllerVisibilityListener(PlayerView.ControllerVisibilityListener { visibility -> information.visibility = visibility })
        playerView.requestFocus()
        val movieId = intent.getStringExtra(EXTRA_MOVIE_ID) ?: return finish()
        val resume = intent.getBooleanExtra(EXTRA_RESUME, false)
        savedInstanceState?.let {
            startPositionMs = it.getLong(STATE_POSITION, C.TIME_UNSET)
            playWhenReady = it.getBoolean(STATE_PLAY_WHEN_READY, true)
        }
        onBackPressedDispatcher.addCallback(this) {
            // First Back hides the on-screen controls, the next one leaves the player.
            if (!isTv || endHandled) finish()
            else if (playerView.isControllerFullyVisible && player?.playerError == null) playerView.hideController() else finish()
        }
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                val loaded = try {
                    load(movieId)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    Toast.makeText(this@PlayerActivity, if (e is JellyfinException || e is PlexException) e.message else SmbService.describe(e), Toast.LENGTH_LONG).show()
                    finish()
                    return@repeatOnLifecycle
                }
                if (startPositionMs == C.TIME_UNSET) startPositionMs = if (resume) loaded.movie.playbackPositionMs else 0
                target = loaded
                showInformation(loaded.movie)
                val downloaded = preparedSubtitles.filter { it.configuration.id?.startsWith("subdl:") == true }
                preparedSubtitles = when {
                    loaded.plex != null -> discoverPlexSubtitles(loaded) + downloaded
                    loaded.connection == null -> discoverSubtitles(loaded) + downloaded
                    else -> downloaded
                }
                val jellyfin = try {
                    loaded.connection?.let { connection ->
                        val itemID = jellyfinItemID(loaded.movie.filePath)
                            ?: throw JellyfinException("This Jellyfin item is invalid. Scan the source again.")
                        // Start the manifest at zero and let the player seek on the common timeline.
                        // Passing the resume position here as well can apply it twice for HLS.
                        JellyfinPlaying(connection, connection.client.playback(connection.session, itemID, jellyfinAndroidProfile))
                    }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Exception) {
                    Toast.makeText(this@PlayerActivity, (error as? JellyfinException)?.message
                        ?: "Could not open the Jellyfin stream.", Toast.LENGTH_LONG).show()
                    finish()
                    return@repeatOnLifecycle
                }
                onlineAttempted = false
                if (isFinishing) return@repeatOnLifecycle
                // Captions can suspend while a metadata correction changes the age rating.
                val refreshed = container.library.get(movieId)
                val refreshedSource = container.database.sources().get(loaded.source.id)
                if (refreshed == null || !container.family.isCurrent(householdSession) ||
                    !sameSource(refreshedSource, loaded.source) || refreshed.sourceId != loaded.movie.sourceId ||
                    refreshed.filePath != loaded.movie.filePath || PlaybackValidator.rejectionReason(refreshed, loaded.config) != null) {
                    rootView.visibility = View.INVISIBLE; target = null; finish()
                    return@repeatOnLifecycle
                }
                target = Target(refreshed, loaded.config, loaded.source, loaded.connection, loaded.plex)
                showInformation(refreshed)
                startPlayer(jellyfin)
                combine(container.library.observe(movieId), container.database.sources().observe(loaded.source.id)) {
                    current, source -> current to source
                }.collect { (current, source) ->
                    if (current == null || !sameSource(source, loaded.source) ||
                        PlaybackValidator.rejectionReason(current, loaded.config) != null) {
                        rootView.visibility = View.INVISIBLE
                        stopPlayer()
                        target = null
                        Toast.makeText(this@PlayerActivity, "This item is no longer available for playback.", Toast.LENGTH_LONG).show()
                        finish()
                    } else {
                        if (target?.movie?.subtitleIdentity() != current.subtitleIdentity()) invalidateSubtitleRequest()
                        target = Target(current, loaded.config, source ?: loaded.source, loaded.connection, loaded.plex)
                        showInformation(current)
                    }
                }
            }
        }
    }

    private suspend fun load(movieId: String): Target {
        check(container.family.isCurrent(householdSession)) { "Your household session has locked." }
        val database = container.database
        val movie = container.playbackProgress.await { container.library.get(movieId) }
            ?: throw SmbException("This movie is no longer in the library.")
        PlaybackValidator.rejectionReason(movie)?.let { throw SmbException(it) }
        val source = database.sources().get(movie.sourceId) ?: throw SmbException("This movie's NAS source was removed.")
        val connection = withContext(Dispatchers.IO) {
            if (source.sourceType == JELLYFIN) source.jellyfinConnection(container.secrets) else null
        }
        val plex = if (source.sourceType == PLEX) {
            check(container.family.isCurrent(householdSession) && container.family.permits(movie)) { "Your household session has locked." }
            val client = source.plexClient(container.secrets)
            val authorized = client.authorizedItem(movie, source.share) {
                if (!container.family.isCurrent(householdSession) || !container.family.permits(it)) {
                    throw PlexException("This Plex item is no longer available for this profile.")
                }
            }
            val part = client.singleFileParts(authorized.item).firstOrNull()
                ?: throw PlexException("Plex did not provide a supported single-file stream.")
            PlexPlaying(client, part, authorized.rating)
        } else null
        val config = if (connection == null && plex == null) withContext(Dispatchers.IO) { source.config(container.secrets) } else null
        if (config != null) PlaybackValidator.validate(movie, config, container.smb::hasPlayableContent)
        if (connection != null && jellyfinItemID(movie.filePath) == null) {
            throw JellyfinException("This Jellyfin item is invalid. Scan the source again.")
        }
        // A source edit or ignore action can complete while the NAS header read is suspended.
        return database.withTransaction {
            val currentSource = database.sources().get(source.id)
            if (currentSource?.copy(name = source.name, lastScanAt = source.lastScanAt) != source) {
                throw SmbException("The NAS source changed. Reopen this item to play it.")
            }
            val current = container.library.get(movieId) ?: throw SmbException("This item was removed from the library.")
            if (current.filePath != movie.filePath || current.sourceId != movie.sourceId) {
                throw SmbException("This item's source changed. Reopen it to play.")
            }
            PlaybackValidator.rejectionReason(current, config)?.let { throw SmbException(it) }
            check(container.family.isCurrent(householdSession)) { "Your household session has locked." }
            Target(current, config, source, connection, plex)
        }
    }

    override fun onStop() {
        jellyfinFallbackJob?.cancel()
        jellyfinFallbackJob = null
        cancelNext()
        invalidateSubtitleRequest()
        subtitleDialog?.dismiss()
        subtitleDialog = null
        stopPlayer()
        target = null
        if (endHandled) finish()
        super.onStop()
    }

    override fun finish() {
        cancelNext()
        super.finish()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putLong(STATE_POSITION, player?.currentPosition ?: startPositionMs)
        outState.putBoolean(STATE_PLAY_WHEN_READY, player?.playWhenReady ?: playWhenReady)
    }

    private fun retryJellyfinWithTranscoding() {
        val previousPlayer = player ?: return
        val previousStream = jellyfinPlaying?.takeIf { it.playback.method == "DirectPlay" } ?: return
        val previousTarget = target ?: return
        if (retriedJellyfinPlayback || !container.family.isCurrent(householdSession) ||
            !container.family.permits(previousTarget.movie)) return
        retriedJellyfinPlayback = true
        jellyfinFallbackJob = lifecycleScope.launch {
            val connection = previousStream.connection
            val stream = try {
                connection.client.playback(connection.session, previousStream.playback.itemId, jellyfinAndroidProfile, allowDirect = false)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                return@launch
            }
            val active = target ?: return@launch
            if (isFinishing || player !== previousPlayer || active.movie.id != previousTarget.movie.id ||
                !sameSource(active.source, previousTarget.source) || !container.family.isCurrent(householdSession) ||
                !container.family.permits(active.movie)) return@launch
            val position = maxOf(previousPlayer.currentPosition, 0).takeIf { it > 0 } ?: startPositionMs
            stopPlayer()
            startPositionMs = position
            playbackFailed = false
            warnedAboutTracks = false
            startPlayer(JellyfinPlaying(connection, stream))
        }
    }

    private fun startPlayer(jellyfin: JellyfinPlaying?) {
        val target = target ?: return
        if (player != null || isFinishing) return
        val smb = container.smb
        if (!container.family.isCurrent(householdSession) || !container.family.permits(target.movie)) { finish(); return }
        val authorizeProvider = {
            val active = this.target?.movie
            if (active == null || active.id != target.movie.id || active.isHidden || active.isMissing ||
                !container.family.isCurrent(householdSession) || !container.family.permits(active) ||
                target.plex?.let { !container.family.permits(active.copy(ageCertification = it.rating)) } == true) {
                throw IOException("This item is no longer available for playback.")
            }
        }
        val files = if (jellyfin != null) jellyfinDataSources(jellyfin.connection, jellyfin.playback, authorize = authorizeProvider)
        else DataSource.Factory { SmbDataSource(authorize = {
            val active = this.target?.movie
            check(active != null && container.family.isCurrent(householdSession) && container.family.permits(active)) { "Your household session has locked." }
        }) {
            check(container.family.isCurrent(householdSession) && container.family.permits(target.movie)) { "Your household session has locked." }
            target.plex?.let { PlexRemoteHandle(it.client, it.part, authorizeProvider) }
                ?: smb.open(checkNotNull(target.config), target.movie.filePath)
        } }
        // Only the scoped HTTP transport can resolve paths from a Jellyfin manifest.
        val dataSources = if (jellyfin != null) files else DefaultDataSource.Factory(this, files)
        val primarySources = DefaultMediaSourceFactory(dataSources,
            DefaultExtractorsFactory().setConstantBitrateSeekingEnabled(true))
            .setLoadErrorHandlingPolicy(SmbDataSource.loadErrorPolicy)
        val localCaptions = if (jellyfin == null) dataSources else jellyfinLocalSubtitleDataSources(authorizeProvider)
        val mediaSources = SubtitleMediaSourceFactory(primarySources, localCaptions) { preparedSubtitles }
        val exo = ExoPlayer.Builder(this, DefaultRenderersFactory(this).setEnableDecoderFallback(true))
            .setMediaSourceFactory(mediaSources)
            .setAudioAttributes(
                AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(),
                /* handleAudioFocus = */ true,
            )
            .setHandleAudioBecomingNoisy(true)
            .setSeekBackIncrementMs(SEEK_BACK_MS)
            .setSeekForwardIncrementMs(SEEK_FORWARD_MS)
            .build()
        exo.trackSelectionParameters = SubtitleTracks.applyPreference(exo.trackSelectionParameters, container.settings.subtitlePreference)
        exo.addListener(listener)
        val remoteSubtitles = jellyfin?.playback?.subtitles.orEmpty().map { subtitle ->
            MediaItem.SubtitleConfiguration.Builder(Uri.parse(subtitle.url.toString()))
                .setMimeType(MimeTypes.TEXT_VTT).setLanguage(subtitle.language)
                .setSelectionFlags(if (subtitle.forced) C.SELECTION_FLAG_FORCED else 0).build()
        }
        exo.setMediaItem(
            MediaItem.Builder()
                .setUri(jellyfin?.playback?.url?.let { Uri.parse(it.toString()) }
                    ?: target.plex?.let { Uri.Builder().scheme("smb").authority("plex").appendPath(it.part.url.pathSegments.last()).build() }
                    ?: filePlaybackUri(checkNotNull(target.config), target.movie.filePath))
                .setMimeType(if (jellyfin?.playback?.method == "Transcode") MimeTypes.APPLICATION_M3U8 else null)
                .setMediaId(target.movie.id)
                .setSubtitleConfigurations(preparedSubtitles.map { it.configuration } + remoteSubtitles)
                .setMediaMetadata(MediaMetadata.Builder().setTitle(target.movie.title)
                    .setDescription(target.movie.overview)
                    .setArtworkUri(com.dineshdevkota.cinevault.core.Tmdb.imageUrl(target.movie.posterPath)?.let(Uri::parse))
                    .build())
                .build(),
            startPositionMs.coerceAtLeast(0),
        )
        exo.playWhenReady = playWhenReady
        exo.prepare()
        playerView.player = exo
        player = exo
        jellyfinPlaying = jellyfin
        reportJellyfin(JellyfinPlaybackEvent.STARTED, startPositionMs.coerceAtLeast(0), !playWhenReady)
        progressJob = lifecycleScope.launch {
            while (isActive) {
                delay(PROGRESS_INTERVAL_MS)
                if (exo.isPlaying) record()
                reportJellyfin(JellyfinPlaybackEvent.PROGRESS, exo.currentPosition, !exo.isPlaying)
            }
        }
    }

    private fun reportJellyfin(event: JellyfinPlaybackEvent, position: Long, paused: Boolean = false) {
        val playing = jellyfinPlaying ?: return
        val previous = jellyfinReportJob
        // Avoid an unbounded backlog when the server's reporting endpoint is slow.
        if (event == JellyfinPlaybackEvent.PROGRESS && previous?.isCompleted == false) return
        val failed = playbackFailed
        jellyfinReportJob = container.scope.launch {
            previous?.join()
            if (event != JellyfinPlaybackEvent.STOPPED && !container.family.isCurrent(householdSession)) return@launch
            try {
                playing.connection.client.report(playing.connection.session, playing.playback, event,
                    position.coerceAtLeast(0), paused, failed)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { /* A failed report must not interrupt local playback or history. */ }
        }
    }

    private suspend fun discoverPlexSubtitles(loaded: Target): List<PreparedSubtitle> {
        val plex = loaded.plex ?: return emptyList()
        val authorize = {
            check(container.family.isCurrent(householdSession) &&
                container.family.permits(loaded.movie.copy(ageCertification = plex.rating))) {
                "This Plex item is unavailable for this profile."
            }
        }
        return withTimeoutOrNull(2_500) {
            plex.part.tracks.asSequence().filter { it.streamType == 3 && it.key != null }.take(8).toList()
                .mapNotNull { track ->
                    val type = when (track.codec?.lowercase()) {
                        "srt", "subrip" -> MimeTypes.APPLICATION_SUBRIP
                        "vtt", "webvtt" -> MimeTypes.TEXT_VTT
                        else -> return@mapNotNull null
                    }
                    try {
                        val bytes = plex.client.subtitle(plex.part, track, authorize)
                        SubtitleTracks.configuration(bytes, type, track.languageCode,
                            track.language ?: track.languageCode ?: "Plex subtitle", "plex:${track.key}", track.forced)
                    } catch (cancelled: CancellationException) { throw cancelled }
                    catch (_: Exception) { null }
                }
        }.orEmpty()
    }

    private suspend fun discoverSubtitles(loaded: Target): List<PreparedSubtitle> {
        // Independent worker: a blocking NAS call cannot hold up video startup past this deadline.
        val smb = container.smb
        val language = container.settings.subtitleLanguage
        val discovery = container.scope.async(Dispatchers.IO) {
            try {
                val found = smb.readSubtitleSidecars(checkNotNull(loaded.config), loaded.movie.filePath, language) {
                    check(container.family.isCurrent(householdSession) && container.family.permits(loaded.movie)) {
                        "This caption is unavailable for this profile."
                    }
                }
                found.files.mapNotNull(SubtitleTracks::configuration) to found.truncated
            } catch (e: CancellationException) { throw e }
            catch (_: Exception) { emptyList<PreparedSubtitle>() to false }
        }
        return try {
            val result = withTimeoutOrNull(2_500) { discovery.await() }
            subtitleNotice = when {
                result == null -> "NAS subtitle lookup took too long. Reopen this video to try again."
                result.second -> "Some NAS captions were omitted. Lookup checks 4,096 folder entries and loads up to 8 matching files."
                else -> null
            }
            result?.first.orEmpty()
        } finally { discovery.cancel() }
    }

    private fun showSubtitleMenu() {
        val exo = player ?: return
        invalidateSubtitleRequest()
        val options = mutableListOf("Off")
        val actions = mutableListOf<() -> Unit>({
            invalidateSubtitleRequest()
            container.settings.subtitlePreference = "off"
            exo.trackSelectionParameters = SubtitleTracks.applyPreference(exo.trackSelectionParameters, "off")
        })
        exo.currentTracks.groups.filter { it.type == C.TRACK_TYPE_TEXT }.forEach { group ->
            for (index in 0 until group.length) {
                if (!group.isTrackSupported(index)) continue
                val format = group.getTrackFormat(index)
                val label = format.label ?: format.language?.let(::languageName) ?: "Embedded subtitles"
                options += (if (group.isTrackSelected(index)) "✓ " else "") + label
                actions += {
                    invalidateSubtitleRequest()
                    exo.trackSelectionParameters = exo.trackSelectionParameters.buildUpon()
                        .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
                        .setOverrideForType(TrackSelectionOverride(group.mediaTrackGroup, index)).build()
                }
            }
        }
        options += "Find subtitles online · ${languageName(container.settings.subtitleLanguage)}"
        actions += { searchOnlineSubtitles(automatic = false) }
        options += "Preferred language"
        actions += { subtitleDialog = chooseSubtitleLanguage(this, container.settings.subtitleLanguage) {
            invalidateSubtitleRequest()
            container.settings.subtitleLanguage = it
            container.settings.subtitlePreference = it
            exo.trackSelectionParameters = SubtitleTracks.applyPreference(exo.trackSelectionParameters, it)
        } }
        options += "Subtitle settings"
        actions += { PlaybackSettingsActivity.start(this) }
        subtitleNotice?.let { notice ->
            options += "NAS subtitle lookup details"
            actions += { subtitleDialog = AlertDialog.Builder(this).setTitle("NAS subtitles").setMessage(notice).setPositiveButton("OK", null).show() }
        }
        subtitleDialog = AlertDialog.Builder(this).setTitle("Subtitles")
            .setItems(options.toTypedArray()) { _, index -> actions[index]() }
            .setNegativeButton("Close", null).show()
    }

    private fun considerAutomaticSubtitles() {
        val exo = player ?: return
        val settings = container.settings
        if (onlineAttempted || onlineJob != null || !settings.automaticSubtitles || !settings.subDlConnected ||
            settings.subtitlePreference in setOf("off", "und") || exo.currentTracks.isEmpty) return
        onlineAttempted = true
        val desired = settings.subtitleLanguage
        val matching = exo.currentTracks.groups.any { group ->
            group.type == C.TRACK_TYPE_TEXT && (0 until group.length).any { index ->
                group.isTrackSupported(index) && SubtitleTracks.sameLanguage(group.getTrackFormat(index).language, desired)
            }
        }
        if (!matching) searchOnlineSubtitles(automatic = true)
    }

    private fun MovieEntity.subtitleIdentity(): SubtitleIdentity = SubtitleIdentity(id, filePath, sourceId, fileName,
        tmdbId, seriesTmdbId, episodeInfo?.season, episodeInfo?.episode)

    private fun invalidateSubtitleRequest() {
        subtitleChoiceGeneration++
        pendingSubtitleId = null
        onlineJob?.cancel()
        onlineJob = null
    }

    private fun setProgrammaticTrackParameters(parameters: TrackSelectionParameters) {
        val exo = player ?: return
        if (exo.trackSelectionParameters == parameters) return
        programmaticTrackChanges += parameters
        exo.trackSelectionParameters = parameters
    }

    private suspend fun currentSubtitleMovie(): MovieEntity? {
        val playing = target ?: return null
        return container.database.withTransaction {
            if (!sameSource(container.database.sources().get(playing.source.id), playing.source)) return@withTransaction null
            container.library.get(playing.movie.id)?.takeIf {
                it.filePath == playing.movie.filePath && PlaybackValidator.rejectionReason(it, playing.config) == null
            }
        }
    }

    private suspend fun subtitleRequestIsCurrent(request: SubtitleRequest): Boolean {
        if (request.generation != subtitleChoiceGeneration || isFinishing || endHandled ||
            !lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) return false
        val current = currentSubtitleMovie() ?: return false
        return request.generation == subtitleChoiceGeneration && current.subtitleIdentity() == request.identity &&
            player?.currentMediaItem?.mediaId == request.identity.id
    }

    private fun searchOnlineSubtitles(automatic: Boolean) {
        if (isFinishing || endHandled) return
        if (!automatic) invalidateSubtitleRequest()
        else if (onlineJob != null) return
        val settings = container.settings
        if (!settings.subDlConnected) {
            if (!automatic) subtitleDialog = AlertDialog.Builder(this).setTitle("Connect SubDL once")
                .setMessage("Save your SubDL API key in Playback & Subtitles to find online captions.")
                .setPositiveButton("Open settings") { _, _ -> PlaybackSettingsActivity.start(this) }
                .setNegativeButton("Cancel", null).show()
            return
        }
        val generation = subtitleChoiceGeneration
        onlineJob = lifecycleScope.launch {
            try {
                val movie = currentSubtitleMovie() ?: return@launch
                val request = SubtitleRequest(movie.subtitleIdentity(), generation, settings.subtitleLanguage)
                val query = subtitleQuery(movie, request.language)
                if (query == null) {
                    if (!automatic) {
                        val detail = if (target?.connection != null)
                            "Add this movie or series' TMDB ID in Jellyfin, then rescan the source."
                        else "Match this movie or show with TMDB first, then try online subtitles."
                        showSubtitleError(detail, retry = false)
                    }
                    return@launch
                }
                if (!automatic) Toast.makeText(this@PlayerActivity, "Finding ${languageName(query.language)} subtitles…", Toast.LENGTH_SHORT).show()
                val apiKey = withContext(Dispatchers.IO) { settings.subDlApiKey }
                val results = SubDlClient().search(query, apiKey)
                if (!subtitleRequestIsCurrent(request)) return@launch
                if (results.isEmpty()) {
                    if (!automatic) showSubtitleError("No matching subtitles were found for this language.")
                    return@launch
                }
                val exact = if (target?.connection != null && movie.fileName == "${movie.parsedTitle}.mp4") emptyList()
                    else results.filter { result ->
                        (result.releaseNames + result.releaseName).any { SubtitleTracks.exactRelease(movie.fileName, it) }
                    }
                if (automatic && exact.size == 1 && settings.subtitlePreference != "off") {
                    downloadSubtitle(exact.single(), request, automatic = true)
                } else if (!automatic) showOnlineResults(results, request)
                else {
                    subtitleNotice = "Online subtitles are available. Choose a release in Find subtitles online."
                    Toast.makeText(this@PlayerActivity, subtitleNotice, Toast.LENGTH_LONG).show()
                }
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) {
                if (!automatic && generation == subtitleChoiceGeneration) showSubtitleError(e.message ?: "Could not find subtitles. Try again.")
            } finally { if (onlineJob == coroutineContext[Job]) onlineJob = null }
        }
    }

    private fun showOnlineResults(results: List<SubDlSubtitle>, request: SubtitleRequest) {
        subtitleDialog = AlertDialog.Builder(this).setTitle("Choose subtitle release")
            .setItems(results.map { subtitle ->
                "${languageName(subtitle.language)} · ${subtitle.releaseName}" + if (subtitle.hearingImpaired) " · SDH" else ""
            }.toTypedArray()) { _, index ->
                invalidateSubtitleRequest()
                val selectedRequest = request.copy(generation = subtitleChoiceGeneration)
                onlineJob = lifecycleScope.launch {
                    try { downloadSubtitle(results[index], selectedRequest, automatic = false) }
                    catch (e: CancellationException) { throw e }
                    catch (e: Exception) {
                        if (selectedRequest.generation == subtitleChoiceGeneration)
                            showSubtitleError(e.message ?: "Could not load this subtitle. Try another release.")
                    } finally { if (onlineJob == coroutineContext[Job]) onlineJob = null }
                }
            }.setNegativeButton("Cancel", null).show()
    }

    private suspend fun downloadSubtitle(subtitle: SubDlSubtitle, request: SubtitleRequest, automatic: Boolean) {
        if (!subtitleRequestIsCurrent(request)) return
        val cache = SubtitleCache(applicationContext)
        val key = "${request.identity.id}|${subtitle.id}|${subtitle.downloadUrl}"
        val bytes = cache.read(key) ?: SubDlClient().download(subtitle,
            withContext(Dispatchers.IO) { container.settings.subDlApiKey })
        val preparedSubtitle = withContext(Dispatchers.Default) {
            SubtitleTracks.configuration(bytes, if (subtitle.format == "vtt") "text/vtt" else "application/x-subrip",
                subtitle.language, "${languageName(subtitle.language)} · SubDL · ${subtitle.releaseName}",
                "subdl:${subtitle.id}", hearingImpaired = subtitle.hearingImpaired)
        } ?: throw IllegalArgumentException("This subtitle is empty or damaged. Try another release.")
        if (!subtitleRequestIsCurrent(request) || (automatic && container.settings.subtitlePreference == "off")) return
        cache.write(key, bytes)
        // Cache writes suspend too: re-check the latest user choice and metadata before touching playback.
        if (!subtitleRequestIsCurrent(request)) return
        val exo = player ?: return
        val position = exo.currentPosition
        val playing = exo.playWhenReady
        val configuration = preparedSubtitle.configuration
        // Keep at most eight local tracks and the active downloaded release in memory.
        // Previously chosen downloads remain available through the bounded disk cache.
        val mediaItem = exo.currentMediaItem ?: return
        val priorCaption = preparedSubtitles.firstOrNull { it.configuration.id?.startsWith("subdl:") == true }
        val existing = mediaItem.localConfiguration?.subtitleConfigurations.orEmpty()
            .filterNot { it == priorCaption?.configuration }
        preparedSubtitles = preparedSubtitles.filterNot { it == priorCaption } + preparedSubtitle
        container.settings.subtitlePreference = subtitle.language
        setProgrammaticTrackParameters(SubtitleTracks.applyPreference(exo.trackSelectionParameters, subtitle.language))
        pendingSubtitleId = configuration.id
        exo.setMediaItem(mediaItem.buildUpon().setSubtitleConfigurations(existing + configuration).build(), position)
        exo.prepare()
        exo.playWhenReady = playing
        if (!automatic) Toast.makeText(this, "Subtitles ready", Toast.LENGTH_SHORT).show()
    }

    private fun showSubtitleError(message: String, retry: Boolean = true) {
        if (isFinishing) return
        subtitleDialog = AlertDialog.Builder(this).setTitle("Online subtitles").setMessage(message)
            .setPositiveButton(if (retry) "Try again" else "OK") { _, _ -> if (retry) searchOnlineSubtitles(false) }
            .setNegativeButton("Close", null).show()
    }

    private fun sameSource(current: SourceEntity?, original: SourceEntity): Boolean =
        current?.copy(name = original.name, lastScanAt = original.lastScanAt) == original

    private suspend fun nextAvailable(): ContinueWatchingItem? {
        val playing = target ?: return null
        val database = container.database
        return container.playbackProgress.await {
            database.withTransaction {
                if (!sameSource(database.sources().get(playing.source.id), playing.source)) return@withTransaction null
                val current = container.library.get(playing.movie.id) ?: return@withTransaction null
                if (current.filePath != playing.movie.filePath || PlaybackValidator.rejectionReason(current, playing.config) != null)
                    return@withTransaction null
                nextEpisodeFor(current, container.library.available(), database.sources().all())
            }
        }
    }

    private fun handleNaturalEnd() {
        if (endHandled) return
        endHandled = true
        markFinished()
        // An open subtitle/provider dialog owns the user's attention; never advance behind it.
        if (subtitleDialog?.isShowing == true) return
        if (!container.settings.continuousPlay || target?.movie?.episodeInfo == null || playbackFailed || isFinishing ||
            !lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) return finish()
        countdownJob = lifecycleScope.launch {
            val next = try { nextAvailable() }
            catch (e: CancellationException) { throw e }
            catch (_: Exception) { null }
            if (next == null) return@launch finish()
            if (isFinishing) return@launch
            pendingNext = next
            playerView.hideController()
            playerView.useController = false
            val label = TextView(this@PlayerActivity).apply { setTextColor(Color.WHITE); textSize = 23f }
            val card = LinearLayout(this@PlayerActivity).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(dp(28), dp(24), dp(28), dp(24))
                background = GradientDrawable().apply { setColor(0xF21B2030.toInt()); cornerRadius = dp(18).toFloat() }
                addView(TextView(this@PlayerActivity).apply { text = next.label; setTextColor(0xFF8EBBFF.toInt()); textSize = 17f })
                addView(label)
                addView(TextView(this@PlayerActivity).apply {
                    text = "${next.title} · ${next.movie.title}"; setTextColor(Color.LTGRAY); textSize = 18f; maxLines = 2
                })
                addView(LinearLayout(this@PlayerActivity).apply {
                    orientation = LinearLayout.HORIZONTAL
                    addView(Button(this@PlayerActivity).apply {
                        id = com.dineshdevkota.cinevault.R.id.playback_play_next
                        text = "Play now"; setOnClickListener { playNext() }
                    })
                    addView(Button(this@PlayerActivity).apply {
                        id = com.dineshdevkota.cinevault.R.id.playback_cancel_next
                        text = "Cancel"; setOnClickListener { finish() }
                    })
                })
            }
            nextCard = card
            rootView.addView(card, FrameLayout.LayoutParams(dp(600), -2, Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply {
                bottomMargin = dp(48)
            })
            card.findViewWithText("Play now")?.requestFocus()
            for (seconds in 10 downTo 1) {
                label.text = "Playing in $seconds seconds"
                delay(1_000)
            }
            playNext()
        }
    }

    private fun LinearLayout.findViewWithText(text: String): View? {
        for (index in 0 until childCount) {
            val child = getChildAt(index)
            if (child is Button && child.text == text) return child
            if (child is LinearLayout) child.findViewWithText(text)?.let { return it }
        }
        return null
    }

    private fun playNext() {
        val candidate = pendingNext ?: return
        if (transitionJob != null || isFinishing) return
        countdownJob?.cancel()
        transitionJob = lifecycleScope.launch {
            try {
                if (!container.settings.continuousPlay || nextAvailable()?.movie?.id != candidate.movie.id) {
                    Toast.makeText(this@PlayerActivity, "The next episode is no longer available.", Toast.LENGTH_LONG).show()
                    return@launch finish()
                }
                val loaded = load(candidate.movie.id)
                // Re-evaluate after the optional NAS probe; edits can finish while it was suspended.
                if (nextAvailable()?.movie?.id != loaded.movie.id || isFinishing || playbackFailed ||
                    !lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) return@launch finish()
                start(this@PlayerActivity, loaded.movie.id, loaded.movie.isInProgress)
                finish()
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) {
                Toast.makeText(this@PlayerActivity, "Could not play the next episode. ${SmbService.describe(e)}", Toast.LENGTH_LONG).show()
                finish()
            }
        }
    }

    private fun cancelNext() {
        pendingNext = null
        countdownJob?.cancel()
        countdownJob = null
        transitionJob?.cancel()
        transitionJob = null
        nextCard?.let { rootView.removeView(it) }
        nextCard = null
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    private fun stopPlayer() {
        val exo = player ?: return
        progressJob?.cancel()
        progressJob = null
        record()
        reportJellyfin(JellyfinPlaybackEvent.STOPPED, exo.currentPosition)
        jellyfinPlaying = null
        startPositionMs = exo.currentPosition
        playWhenReady = exo.playWhenReady
        exo.removeListener(listener)
        programmaticTrackChanges.clear()
        playerView.player = null
        exo.release()
        player = null
    }

    private fun showInformation(movie: MovieEntity) {
        titleLabel.text = movie.title.ifBlank { movie.fileName }
        val episode = movie.episodeInfo?.let { "${movie.seriesTitle ?: it.seriesTitle} · Season ${movie.seasonNumber ?: it.season} · Episode ${movie.episodeNumber ?: it.episode}" }
        val facts = listOfNotNull(episode, movie.year?.toString(), movie.genres.takeIf { it.isNotEmpty() }?.joinToString(" · "),
            movie.runtimeMinutes?.let { "$it min" }).joinToString(" · ")
        detailLabel.text = listOf(facts, movie.overview.orEmpty()).filter { it.isNotBlank() }.joinToString("\n")
    }

    /** Persists the resume point, or marks the movie watched once playback passes the watched threshold. */
    private fun record() {
        val exo = player ?: return
        val movieId = target?.movie?.id ?: return
        if (finishedPlayback) return
        val position = exo.currentPosition
        if (position <= 0) return
        val duration = knownDuration(exo)
        if (WatchRules.reachedEnd(position, duration)) return markFinished()
        val now = System.currentTimeMillis()
        val movie = target?.movie?.takeIf { it.id == movieId } ?: return
        container.library.playbackCheckpoint(movie, householdSession, position, duration, now, finished = false)
            ?.let { checkpoint -> container.playbackProgress.enqueue(checkpoint) }
    }

    private fun markFinished() {
        val movieId = target?.movie?.id ?: return
        if (finishedPlayback) return
        finishedPlayback = true
        val duration = player?.let(::knownDuration) ?: 0L
        val now = System.currentTimeMillis()
        val movie = target?.movie?.takeIf { it.id == movieId } ?: return
        container.library.playbackCheckpoint(movie, householdSession, 0, duration, now, finished = true)
            ?.let { checkpoint -> container.playbackProgress.enqueue(checkpoint) }
    }

    private fun knownDuration(exo: ExoPlayer): Long = exo.duration.takeIf { it != C.TIME_UNSET && it > 0 } ?: 0L

    /** ExoPlayer silently skips tracks the TV can't decode (e.g. DTS audio without a receiver); say so. */
    private fun warnAboutUnsupportedTracks(tracks: Tracks) {
        if (warnedAboutTracks || tracks.isEmpty) return
        val unsupported = listOfNotNull(
            "video".takeIf { tracks.containsType(C.TRACK_TYPE_VIDEO) && !tracks.isTypeSupported(C.TRACK_TYPE_VIDEO) },
            "audio".takeIf { tracks.containsType(C.TRACK_TYPE_AUDIO) && !tracks.isTypeSupported(C.TRACK_TYPE_AUDIO) },
        )
        if (unsupported.isEmpty()) return
        warnedAboutTracks = true
        val message = "This TV can't decode the ${unsupported.joinToString(" or ")} format of this file."
        Toast.makeText(this, message, Toast.LENGTH_LONG).show()
    }

    private fun errorMessage(error: PlaybackException): String = when (error.errorCode / 1000) {
        // Media3 groups error codes by category in thousands: 2xxx I/O, 3xxx parsing, 4xxx decoding, 5xxx audio.
        2 -> if (target?.plex != null) "Could not read this Plex stream."
            else if (target?.connection != null) "Could not read this Jellyfin stream."
            else error.cause?.let { SmbService.describe(it) } ?: "Could not read the file from the NAS."
        3 -> "This file's format isn't supported, or the file is damaged."
        4, 5 -> "This TV can't play this file's video or audio format."
        else -> error.message ?: "Playback failed."
    }

    companion object {
        private val jellyfinFallbackErrors = setOf(
            PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED,
            PlaybackException.ERROR_CODE_DECODER_INIT_FAILED,
            PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES,
            PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,
            PlaybackException.ERROR_CODE_AUDIO_TRACK_INIT_FAILED,
        )
        private const val EXTRA_MOVIE_ID = "movie_id"
        private const val EXTRA_RESUME = "resume"
        private const val STATE_POSITION = "position"
        private const val STATE_PLAY_WHEN_READY = "play_when_ready"
        private const val PROGRESS_INTERVAL_MS = 10_000L
        private const val SEEK_BACK_MS = 10_000L
        private const val SEEK_FORWARD_MS = 30_000L

        fun start(context: Context, movieId: String, resume: Boolean) {
            context.startActivity(
                Intent(context, PlayerActivity::class.java)
                    .putExtra(EXTRA_MOVIE_ID, movieId)
                    .putExtra(EXTRA_RESUME, resume),
            )
        }

        /** Display URI (no credentials); its file extension helps ExoPlayer pick the right extractor first. */
        fun filePlaybackUri(config: SourceConfig, path: String): Uri {
            if (config.isWebDav) {
                return Uri.parse(DavAddress(config.host, config.allowInsecureHttp).url(path).toString())
            }
            return Uri.Builder()
                .scheme("smb")
                .authority(SmbService.normalizedHost(config.host))
                .apply { (config.share.split('/', '\\') + path.split('/')).filter { it.isNotEmpty() }.forEach(::appendPath) }
                .build()
        }
    }
}
