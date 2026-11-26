package com.dineshdevkota.cinevault.cloud

import androidx.compose.ui.input.key.Key
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasContentDescription
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
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.dineshdevkota.cinevault.ui.DropboxSetupActivity
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
@OptIn(ExperimentalTestApi::class)
class DropboxSetupNavigationTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test
    fun dropboxOwnerCanOpenAndCancelTheQrApproval() {
        ActivityScenario.launch(DropboxSetupActivity::class.java).use { scenario ->
            val appKey = hasText("Dropbox app key") and hasSetTextAction()
            visible(appKey).performTextReplacement("invalid app key")
            press("Get Dropbox approval")
            visible(hasText("Enter a valid registered Dropbox app key."))
            visible(appKey).performTextReplacement("fixture-app")
            press("Get Dropbox approval")
            visible(hasContentDescription("Open Dropbox approval on a phone"))
            visible(hasText("Dropbox one-time code") and hasSetTextAction())
            compose.onNode(hasText("Verify code and choose a folder") and isEnabled()).assertDoesNotExist()
            press("Cancel")
            compose.waitUntil(timeoutMillis = 5_000) { scenario.state == Lifecycle.State.DESTROYED }
        }
    }

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
