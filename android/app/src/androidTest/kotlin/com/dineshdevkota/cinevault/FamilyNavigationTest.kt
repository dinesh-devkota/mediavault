package com.dineshdevkota.cinevault

import android.content.Intent
import android.view.WindowManager
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleCallback
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import androidx.test.uiautomator.UiDevice
import com.dineshdevkota.cinevault.data.MovieEntity
import com.dineshdevkota.cinevault.data.SourceEntity
import com.dineshdevkota.cinevault.family.FolderAccess
import com.dineshdevkota.cinevault.family.HouseholdProfile
import com.dineshdevkota.cinevault.playback.PlayerActivity
import com.dineshdevkota.cinevault.ui.FamilyActivity
import com.dineshdevkota.cinevault.ui.MovieDetailActivity
import com.dineshdevkota.cinevault.ui.SourceEditorActivity
import kotlinx.coroutines.delay
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** Run separately, only on a fresh disposable CI app. Intentionally leaves the synthetic household configured. */
@RunWith(AndroidJUnit4::class)
@OptIn(ExperimentalTestApi::class)
class FamilyNavigationTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val app = ApplicationProvider.getApplicationContext<CineVaultApp>()
    private val container get() = app.container
    private val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())

    @Before fun requireDisposableFixture() = runBlocking {
        check(InstrumentationRegistry.getArguments().getString("familyUiFixture") == "true") {
            "Family UI tests require the explicit familyUiFixture=true disposable-emulator invocation."
        }
        check(container.database.sources().all().isEmpty() && !container.family.current.enabled && container.family.profiles.isEmpty()) {
            "Family UI tests require a fresh disposable app; never run against an owner's library."
        }
    }

    @Test fun householdSetupProfilePermissionsDirectRoutesAndBackgroundLock() = runBlocking {
        ActivityScenario.launch(FamilyActivity::class.java).use { settings ->
            visible("A library for your household")
            field("Create six-digit Admin PIN", "123456")
            field("Confirm Admin PIN", "123456")
            click("Create household")
            visible("Who's watching?")
            assertFalse(container.family.current.unlocked)
            screenshot(settings, "family-profile-picker.png")
            click("Privacy policy")
            visible("MediaVault privacy policy")
            visible("Your library and playback")
            device.pressBack()
            visible("Who's watching?")
            assertFalse(container.family.current.unlocked)
            click("Admin · PIN required")
            field("Six-digit PIN", "999999"); click("Unlock")
            visible("That PIN did not match. Try again.")
            assertFalse(container.family.current.admin)
            field("Six-digit PIN", "123456"); click("Unlock")
            visible("Your household")
            click("Manage profiles · Admin PIN")
            field("Six-digit PIN", "123456"); click("Unlock")
            click("Add a viewer")
            visible("Viewer permissions")
            field("Viewer name", "Kids")
            click("US movies: No rating limit ▾")
            click("Up to PG")
            click("US TV series rating: No rating limit ▾")
            click("Up to TV-G")
            screenshot(settings, "family-admin-permissions.png")
            field("Optional six-digit PIN", "654321")
            field("Confirm new PIN", "654321")
            click("Save profile")
            visible("Your household")
            val child = container.family.profiles.single { !it.isAdmin }
            assertEquals("PG", child.movieLimit)
            assertEquals("TV-G", child.tvLimit)
            assertTrue(child.folders.isEmpty())
            // Only synthetic rows are added; source is refused loopback so the journey cannot contact a real NAS.
            val source = SourceEntity(id = "family-ui-fixture", name = "Family fixture", host = "127.0.0.1", port = 1, share = "fixture")
            container.database.sources().upsert(source)
            fun movie(id: String, path: String, title: String, rating: String?) = MovieEntity(id = id, sourceId = source.id,
                filePath = path, fileName = path.substringAfterLast('/'), fileSize = 100, parsedTitle = title, parsedYear = null,
                title = title, year = null, ageCertification = rating, certificationFetched = true)
            container.database.movies().insert(movie("family-allowed", "Kids/Family.mp4", "Allowed family film", "PG"))
            container.database.movies().insert(movie("family-private", "Private/Secret.mp4", "PRIVATE CANARY", "R"))
            container.database.movies().insert(movie("family-unrated", "Kids/Unknown.mp4", "UNRATED CANARY", null))
            container.family.saveProfile(child.copy(folders = listOf(FolderAccess(source.id, "Kids"))), null)
            click("Switch profile")
            click("Kids · PIN required")
            field("Six-digit PIN", "654321"); click("Unlock")
            visible("Managed by Admin")
            assertFalse(container.family.current.admin)

            ActivityScenario.launch(MainActivity::class.java).use { home ->
                visible("Allowed family film")
                compose.onAllNodesWithText("PRIVATE CANARY", substring = true).assertCountEquals(0)
                compose.onAllNodesWithText("UNRATED CANARY", substring = true).assertCountEquals(0)
                click("Settings")
                click("Privacy policy")
                visible("MediaVault privacy policy")
                device.pressBack()
                visible("Shared settings are managed by Admin.")
                assertFalse(container.family.current.admin)
                assertTrue(container.family.current.unlocked)
                click("Home")
                visible("Allowed family film")
                // Normal activity navigation preserves Home below the protected route. Launching
                // nested ActivityScenarios creates fresh tasks and destroys the return destination.
                home.onActivity { SourceEditorActivity.start(it, null) }
                visible("Managed by Admin")
                compose.onAllNodesWithText("Save & Scan").assertCountEquals(0)
                device.pressBack()
                visible("Allowed family film")
                deniedRoute(home, MovieDetailActivity::class.java)
                compose.onAllNodesWithText("PRIVATE CANARY", substring = true).assertCountEquals(0)
                deniedRoute(home, PlayerActivity::class.java)
                visible("Allowed family film")
                home.moveToState(Lifecycle.State.CREATED)
                assertFalse(container.family.current.unlocked)
                home.moveToState(Lifecycle.State.RESUMED)
                visible("Who's watching?")
                compose.onAllNodesWithText("Allowed family film", substring = true).assertCountEquals(0)
                click("Admin · PIN required")
                field("Six-digit PIN", "123")
                home.moveToState(Lifecycle.State.CREATED)
                home.moveToState(Lifecycle.State.RESUMED)
                visible("Who's watching?")
                compose.onAllNodesWithText("Six-digit PIN").assertCountEquals(0)
                click("Admin · PIN required")
                // Back from a PIN prompt returns to the chooser and never restores prior media.
                device.pressBack()
                visible("Who's watching?")
                assertFalse(container.family.current.unlocked)
            }
        }
    }

    private fun visible(text: String) {
        fun exists() = runCatching { compose.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty() }.getOrDefault(false)
        if (!exists()) {
            runCatching { compose.onNode(hasScrollToIndexAction()).performScrollToNode(hasText(text)) }
        }
        compose.waitUntil(timeoutMillis = 15_000) { exists() }
    }

    private suspend fun deniedRoute(home: ActivityScenario<MainActivity>, activityClass: Class<out android.app.Activity>) {
        val destroyed = CompletableDeferred<Unit>()
        val monitor = ActivityLifecycleMonitorRegistry.getInstance()
        val callback = ActivityLifecycleCallback { activity, stage ->
            if (activityClass.isInstance(activity) && stage == Stage.DESTROYED) destroyed.complete(Unit)
        }
        home.onActivity {
            monitor.addLifecycleCallback(callback)
            it.startActivity(Intent(it, activityClass).putExtra("movie_id", "family-private"))
        }
        try {
            withTimeout(10_000) { destroyed.await() }
            visible("Allowed family film")
        } finally { InstrumentationRegistry.getInstrumentation().runOnMainSync { monitor.removeLifecycleCallback(callback) } }
    }
    private fun click(text: String) {
        visible(text)
        val node = compose.onNodeWithText(text)
        runCatching { node.performScrollTo() }
        node.performSemanticsAction(SemanticsActions.RequestFocus)
        compose.waitForIdle()
        node.assertIsFocused().performKeyInput { pressKey(Key.DirectionCenter) }
        compose.waitForIdle()
    }
    private fun field(label: String, value: String) {
        visible(label)
        val node = compose.onNode(hasText(label) and hasSetTextAction())
        runCatching { node.performScrollTo() }
        node.performTextClearance(); node.performTextInput(value)
    }
    private fun screenshot(scenario: ActivityScenario<FamilyActivity>, name: String) {
        val directory = File(app.getExternalFilesDir(null), "test-artifacts").apply { mkdirs() }
        // Production secure-window protection is asserted before this instrumentation-only capture.
        scenario.onActivity { activity ->
            assertTrue(activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0)
            activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
        device.waitForIdle()
        assertTrue(device.takeScreenshot(File(directory, name)))
        scenario.onActivity { it.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE) }
    }
}
