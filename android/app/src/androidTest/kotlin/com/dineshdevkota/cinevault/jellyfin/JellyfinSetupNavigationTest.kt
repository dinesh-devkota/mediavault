package com.dineshdevkota.cinevault.jellyfin

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
import androidx.compose.ui.test.isEnabled
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
import com.dineshdevkota.cinevault.ui.JellyfinSetupActivity
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
@OptIn(ExperimentalTestApi::class)
class JellyfinSetupNavigationTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test
    fun remoteCanCorrectInvalidAddressAndCancelTheSetup() {
        ActivityScenario.launch(JellyfinSetupActivity::class.java).use { scenario ->
            val endpoint = field("Jellyfin HTTPS address")
            endpoint.performTextReplacement("http://localhost")
            field("Jellyfin username").performTextReplacement("fixture")
            press("Sign in and choose a library")
            visible(hasText("Enter a complete Jellyfin HTTPS address without credentials, a query, or a fragment."))
            field("Jellyfin HTTPS address").performTextReplacement("https://localhost")
            // Correcting the form and cancelling never attempts network sign-in.
            press("Cancel")
            compose.waitUntil(timeoutMillis = 5_000) { scenario.state == Lifecycle.State.DESTROYED }
        }
    }

    @Test
    fun renamingAnExistingSourceKeepsTheServerAndSavedCredentials() = runBlocking<Unit> {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val container = context.container
        val sources = container.database.sources()
        val source = SourceEntity(
            id = UUID.randomUUID().toString(), name = "Fixture name",
            host = "https://fixture.invalid/", share = "fixtureLibrary", username = "fixtureUser",
            encryptedPassword = container.secrets.encrypt("fixture-token"), sourceType = JELLYFIN,
        )
        try {
            sources.upsert(source)
            val intent = Intent(context, JellyfinSetupActivity::class.java).putExtra("source_id", source.id)
            ActivityScenario.launch<JellyfinSetupActivity>(intent).use { scenario ->
                field("Source name (optional)").performTextReplacement("Updated fixture name")
                press("Save source name")
                compose.waitUntil(timeoutMillis = 5_000) { scenario.state == Lifecycle.State.DESTROYED }
            }
            assertEquals(source.copy(name = "Updated fixture name"), sources.get(source.id))
        } finally {
            sources.delete(source.id)
        }
    }

    private fun field(label: String) = visible(hasText(label) and hasSetTextAction())

    private fun visible(matcher: SemanticsMatcher): SemanticsNodeInteraction {
        compose.waitUntil(timeoutMillis = 5_000) {
            try {
                compose.onNode(hasScrollToIndexAction()).performScrollToNode(matcher)
                compose.onNode(matcher).assertIsDisplayed()
                true
            } catch (_: AssertionError) { false }
        }
        return compose.onNode(matcher).assertIsDisplayed()
    }

    private fun press(label: String) {
        val button = visible(hasText(label) and hasClickAction() and isEnabled())
        button.performSemanticsAction(SemanticsActions.RequestFocus)
        button.assertIsFocused().performKeyInput { pressKey(Key.DirectionCenter) }
    }
}
