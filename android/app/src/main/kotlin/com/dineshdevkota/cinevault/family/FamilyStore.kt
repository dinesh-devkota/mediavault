package com.dineshdevkota.cinevault.family

import android.content.Context
import com.dineshdevkota.cinevault.data.SecretBox
import com.dineshdevkota.cinevault.data.MovieEntity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.util.UUID

data class FamilySession(val enabled: Boolean = false, val damaged: Boolean = false,
    val profile: HouseholdProfile? = null, val generation: Long = 0) {
    val unlocked: Boolean get() = !enabled || (!damaged && profile != null)
    val admin: Boolean get() = !enabled || (!damaged && profile?.isAdmin == true)
    val historyId: String get() = profile?.id ?: HouseholdProfile.ADMIN
}

@Serializable
private data class PinAttempts(val failures: Int = 0, val retryAfter: Long = 0)
@Serializable
private data class FamilyRecord(val profiles: List<HouseholdProfile>, val attempts: Map<String, PinAttempts> = emptyMap(), val enabled: Boolean = true)

/** Configured-but-unreadable storage is locked, never silently treated as disabled. */
class FamilyStore(context: Context, private val secrets: SecretBox,
    preferenceName: String = "household_profiles") {
    private val prefs = context.getSharedPreferences(preferenceName, Context.MODE_PRIVATE)
    private val mutex = Mutex()
    private val transitionLock = Any()
    private var lockEpoch = 0L
    private val json = Json { ignoreUnknownKeys = false }
    private var record: FamilyRecord? = null
    private val mutable = MutableStateFlow(FamilySession())
    val session = mutable.asStateFlow()
    val current: FamilySession get() = mutable.value
    val profiles: List<HouseholdProfile> get() = record?.profiles.orEmpty()

    init {
        if (prefs.getBoolean("configured", false) || prefs.contains("record")) {
            try {
                val loaded = json.decodeFromString<FamilyRecord>(secrets.decrypt(requireNotNull(prefs.getString("record", null))))
                require(loaded.profiles.count { it.isAdmin && it.pin != null } == 1)
                require(loaded.profiles.map { it.id }.distinct().size == loaded.profiles.size)
                require(loaded.attempts.values.all { it.failures >= 0 && it.retryAfter >= 0 })
                loaded.profiles.forEach { profile ->
                    require(profile.name.isNotBlank())
                    require(profile.movieLimit == null || profile.movieLimit in FamilyPolicy.movieRatings)
                    require(profile.tvLimit == null || profile.tvLimit in FamilyPolicy.tvRatings)
                    require(profile.folders.all { it.sourceId.isNotBlank() && (it.path.isEmpty() || com.dineshdevkota.cinevault.core.ScanExclusions.normalizeFolder(it.path) == it.path) })
                    profile.pin?.let { require(it.rounds == PinVerifier.ROUNDS && java.util.Base64.getDecoder().decode(it.salt).size == 16 && java.util.Base64.getDecoder().decode(it.hash).size == 32) }
                }
                record = loaded
                mutable.value = FamilySession(enabled = loaded.enabled)
            } catch (_: Exception) { mutable.value = FamilySession(enabled = true, damaged = true) }
        }
    }

    fun lock() = synchronized(transitionLock) {
        lockEpoch++
        if (current.enabled) mutable.value = current.copy(profile = null, generation = current.generation + 1)
    }
    fun isCurrent(token: FamilySession): Boolean = token == current && current.unlocked
    fun permits(movie: MovieEntity): Boolean = current.unlocked && (!current.enabled || current.profile?.let { FamilyPolicy.allows(it, movie) } == true)
    fun requireAdmin() = check(current.admin) { "Switch to Admin to make this change." }

    suspend fun setup(pin: String, confirmation: String) = withContext(Dispatchers.Default) { mutex.withLock {
        val initial = current
        val epoch = synchronized(transitionLock) { lockEpoch }
        check(!current.enabled && record == null) { "Use the existing Admin PIN to turn household profiles back on." }
        require(pin == confirmation) { "The PINs do not match." }
        val admin = HouseholdProfile(HouseholdProfile.ADMIN, "Admin", PinVerifier.create(pin))
        synchronized(transitionLock) {
            check(initial == current && epoch == lockEpoch) { "Setup was interrupted. Try again." }
            persist(FamilyRecord(listOf(admin)))
            mutable.value = FamilySession(enabled = true, generation = current.generation + 1)
        }
    } }

    suspend fun unlock(id: String, pin: String): String? = withContext(Dispatchers.Default) { mutex.withLock {
        val initial = current
        val epoch = synchronized(transitionLock) { lockEpoch }
        if (initial.damaged) return@withLock "Household controls could not be read. Access remains locked."
        val stored = record ?: return@withLock "Household controls could not be read. Access remains locked."
        if (!stored.enabled && id != HouseholdProfile.ADMIN) return@withLock "An adult must turn household profiles on with the Admin PIN."
        val now = System.currentTimeMillis()
        val attempts = stored.attempts[id] ?: PinAttempts()
        if (attempts.retryAfter > now) return@withLock "Too many attempts. Try again in ${((attempts.retryAfter - now + 999) / 1000)} seconds."
        val profile = stored.profiles.firstOrNull { it.id == id } ?: return@withLock "Choose an available profile."
        val matches = profile.pin == null || profile.pin.matches(pin)
        synchronized(transitionLock) {
            if (current != initial || epoch != lockEpoch) return@withLock "The session changed. Enter your PIN again."
            if (!matches) {
                val failures = (attempts.failures + 1).coerceAtMost(100)
                val delay = if (failures < 5) 0 else (30_000L shl (failures - 5).coerceAtMost(6)).coerceAtMost(1_800_000L)
                persist(stored.copy(attempts = stored.attempts + (id to PinAttempts(failures, now + delay))))
                return@withLock if (delay > 0) "Too many attempts. Try again in ${delay / 1000} seconds." else "That PIN did not match. Try again."
            }
            persist(stored.copy(attempts = stored.attempts - id, enabled = true))
            mutable.value = current.copy(enabled = true, profile = profile, generation = current.generation + 1)
        }
        null
    } }

    suspend fun saveProfile(profile: HouseholdProfile, newPin: String?, removePin: Boolean = false) = withContext(Dispatchers.Default) { mutex.withLock {
        check(current.enabled) { "Turn household profiles on with the Admin PIN first." }
        requireAdmin()
        val initial = current
        val stored = checkNotNull(record)
        require(profile.name.isNotBlank() && profile.name.trim().length <= 30) { "Use a name with 1–30 characters." }
        require(stored.profiles.none { it.id != profile.id && it.name.equals(profile.name.trim(), ignoreCase = true) }) { "Choose a different name. A profile already uses this name." }
        require(profile.id.isNotBlank() && (profile.movieLimit == null || profile.movieLimit in FamilyPolicy.movieRatings) &&
            (profile.tvLimit == null || profile.tvLimit in FamilyPolicy.tvRatings)) { "Choose a supported US rating limit." }
        val folders = profile.folders.map { grant ->
            require(grant.sourceId.isNotBlank()) { "Choose a NAS folder." }
            grant.copy(path = if (grant.path.isEmpty()) "" else requireNotNull(com.dineshdevkota.cinevault.core.ScanExclusions.normalizeFolder(grant.path)) { "Choose a valid folder." })
        }.distinct()
        val existing = stored.profiles.firstOrNull { it.id == profile.id }
        val verifier = when { !newPin.isNullOrEmpty() -> PinVerifier.create(newPin); removePin && !profile.isAdmin -> null; else -> existing?.pin }
        require(!profile.isAdmin || verifier != null) { "Admin always needs a PIN." }
        val saved = profile.copy(name = profile.name.trim(), pin = verifier, folders = folders)
        synchronized(transitionLock) {
            check(isCurrent(initial) && current.admin) { "Your session locked. Unlock Admin again." }
            persist(stored.copy(profiles = stored.profiles.filterNot { it.id == saved.id } + saved,
                attempts = if (verifier != existing?.pin) stored.attempts - saved.id else stored.attempts))
            mutable.value = current.copy(profile = if (saved.isAdmin) saved else current.profile, generation = current.generation + 1)
        }
    } }

    suspend fun deleteProfile(id: String) = withContext(Dispatchers.Default) { mutex.withLock {
        synchronized(transitionLock) {
            check(current.enabled) { "Turn household profiles on with the Admin PIN first." }
            requireAdmin(); require(id != HouseholdProfile.ADMIN)
            persist(checkNotNull(record).let { it.copy(profiles = it.profiles.filterNot { p -> p.id == id }) })
            mutable.value = current.copy(generation = current.generation + 1)
        }
    } }

    /** Keeps every profile, permission and history row; only an authenticated Admin may turn protection off. */
    suspend fun turnOff() = withContext(Dispatchers.Default) { mutex.withLock {
        synchronized(transitionLock) {
            check(current.enabled) { "Household profiles are already off." }
            requireAdmin()
            persist(checkNotNull(record).copy(enabled = false))
            mutable.value = FamilySession(generation = current.generation + 1)
        }
    } }

    private fun persist(value: FamilyRecord) {
        try {
            val sealed = secrets.encrypt(json.encodeToString(value))
            check(prefs.edit().putBoolean("configured", true).putString("record", sealed).commit())
            record = value
        } catch (failure: Exception) {
            mutable.value = current.copy(enabled = true, damaged = true, profile = null, generation = current.generation + 1)
            throw IllegalStateException("Household settings could not be saved. Access remains locked.", failure)
        }
    }

    fun newProfile(): HouseholdProfile = HouseholdProfile(UUID.randomUUID().toString(), "")
}
