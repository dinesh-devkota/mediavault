package com.dineshdevkota.cinevault.plex

import android.content.Context
import android.content.Intent
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasScrollToIndexAction
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.pressKey
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.dineshdevkota.cinevault.container
import com.dineshdevkota.cinevault.data.SourceEntity
import com.dineshdevkota.cinevault.ui.PlexSetupActivity
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
@OptIn(ExperimentalTestApi::class)
class PlexSetupNavigationTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test
    fun remoteCanRenameAndSignOutWithoutChangingLinkedIdentity() = runBlocking<Unit> {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val container = context.container
        val sources = container.database.sources()
        val source = SourceEntity(
            name = "Fixture Plex", host = "https://fixture.invalid/", share = "10", username = "fixture-server",
            encryptedPassword = container.secrets.encrypt("fixture-only"), sourceType = PLEX,
        )
        fun intent() = Intent(context, PlexSetupActivity::class.java).putExtra("source_id", source.id)
        try {
            sources.upsert(source)
            ActivityScenario.launch<PlexSetupActivity>(intent()).use { scenario ->
                val field = hasText("Source name (optional)") and hasSetTextAction()
                visible(field).performTextReplacement("Renamed fixture")
                press("Save source name")
                compose.waitUntil(timeoutMillis = 8_000) { scenario.state == Lifecycle.State.DESTROYED }
            }
            assertEquals(source.copy(name = "Renamed fixture"), sources.get(source.id))
            ActivityScenario.launch<PlexSetupActivity>(intent()).use { scenario ->
                press("Sign out and remove source")
                press("Confirm remove Plex source")
                compose.waitUntil(timeoutMillis = 8_000) { scenario.state == Lifecycle.State.DESTROYED }
            }
            assertNull(sources.get(source.id))
        } finally {
            sources.delete(source.id)
        }
    }

    private fun press(label: String) {
        val matcher = hasText(label) and hasClickAction()
        val button = visible(matcher)
        button.performSemanticsAction(SemanticsActions.RequestFocus)
        button.assertIsFocused().performKeyInput { pressKey(Key.DirectionCenter) }
    }

    private fun visible(matcher: SemanticsMatcher): SemanticsNodeInteraction {
        compose.waitUntil(timeoutMillis = 8_000) {
            try {
                compose.onNode(hasScrollToIndexAction()).performScrollToNode(matcher)
                compose.onNode(matcher).assertIsDisplayed()
                true
            } catch (_: AssertionError) { false }
        }
        return compose.onNode(matcher).assertIsDisplayed()
    }
}
