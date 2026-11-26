package com.dineshdevkota.cinevault

import android.app.Application
import android.content.Context
import android.util.Log
import com.dineshdevkota.cinevault.cloud.AndroidOneDriveAccountStore
import com.dineshdevkota.cinevault.cloud.ONEDRIVE
import com.dineshdevkota.cinevault.cloud.OneDriveMedia
import com.dineshdevkota.cinevault.data.CineVaultDatabase
import com.dineshdevkota.cinevault.data.SecretBox
import com.dineshdevkota.cinevault.data.Settings
import com.dineshdevkota.cinevault.library.LibraryEditor
import com.dineshdevkota.cinevault.library.LibraryScanner
import com.dineshdevkota.cinevault.metadata.MetadataService
import com.dineshdevkota.cinevault.metadata.TmdbClient
import com.dineshdevkota.cinevault.playback.PlaybackProgressWriter
import com.dineshdevkota.cinevault.photos.NasPhotoLoader
import com.dineshdevkota.cinevault.smb.SmbService
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import okhttp3.OkHttpClient
import java.util.concurrent.TimeUnit

class CineVaultApp : Application() {
    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        container = AppContainer(this)
        registerActivityLifecycleCallbacks(com.dineshdevkota.cinevault.family.FamilyLifecycle(container.family, container.scope) { container.photos.clearMemory() })
    }
}

/** App-wide singletons. Work launched in [scope] outlives individual screens (scans, metadata). */
class AppContainer(context: Context) {
    val scope = CoroutineScope(
        SupervisorJob() + Dispatchers.Default +
            CoroutineExceptionHandler { _, error -> Log.e("CineVault", "Background task failed", error) },
    )
    internal val jellyfinSetupSessions = com.dineshdevkota.cinevault.jellyfin.JellyfinSetupSessions(scope)
    val secrets = SecretBox()
    val family = com.dineshdevkota.cinevault.family.FamilyStore(context, secrets, initiallyActive = false)
    val settings = Settings(context, secrets) { family.current.historyId }
    val database = CineVaultDatabase.create(context)
    val library = com.dineshdevkota.cinevault.family.FamilyLibrary(database, family)
    val collections = com.dineshdevkota.cinevault.library.MediaCollections(context, family, library)
    internal val oneDrive = OneDriveMedia(AndroidOneDriveAccountStore(context, secrets))
    private val fileSources = mapOf(ONEDRIVE to oneDrive)
    val smb = SmbService(fileSources = fileSources)
    val photos = NasPhotoLoader(context, database, secrets, NasPhotoLoader.photoService(fileSources), family = family)
    val playbackProgress = PlaybackProgressWriter(scope)
    private val http = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()
    val metadata = MetadataService(database, TmdbClient(http) { settings.tmdbApiKey })
    val localMetadata = com.dineshdevkota.cinevault.metadata.LocalMetadataImporter(database, secrets,
        list = smb::listEntries, open = smb::open)
    val scanner = LibraryScanner(database, secrets, smb::scanVideos,
        afterScan = { metadata.fetchMissing()?.failureMessage }, importLocalMetadata = localMetadata::importSource, scanWithProgress = smb::scanMedia)
    val editor = LibraryEditor(database, metadata, playbackProgress, library)
}

val Context.container: AppContainer get() = (applicationContext as CineVaultApp).container
