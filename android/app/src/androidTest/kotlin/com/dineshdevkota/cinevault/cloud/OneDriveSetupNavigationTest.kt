package com.dineshdevkota.cinevault.cloud

import androidx.compose.ui.input.key.Key
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasScrollToIndexAction
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performImeAction
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.click
import androidx.compose.ui.test.pressKey
import androidx.compose.ui.test.printToString
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.dineshdevkota.cinevault.CineVaultApp
import com.dineshdevkota.cinevault.ui.OneDriveSetupActivity
import com.dineshdevkota.cinevault.ui.isTelevision
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
@OptIn(ExperimentalTestApi::class)
class OneDriveSetupNavigationTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test
    fun ownerCanOpenOneDriveSetupAndRecoverFromInvalidPublicApplicationId() {
        val app = ApplicationProvider.getApplicationContext<CineVaultApp>()
        ActivityScenario.launch(OneDriveSetupActivity::class.java).use {
            try {
                compose.onNode(hasText("Connect OneDrive")).assertExists()
                val field = compose.onNode(hasText("Microsoft Entra application ID") and hasSetTextAction())
                field.performTextReplacement("invalid-public-id")
                val signInMatcher = hasText("Sign in with Microsoft") and hasClickAction()
                val signIn = compose.onNode(signInMatcher)
                if (app.isTelevision()) {
                    signIn.performSemanticsAction(SemanticsActions.RequestFocus)
                    signIn.performKeyInput { pressKey(Key.DirectionCenter) }
                } else {
                    signIn.performTouchInput { click() }
                }
                compose.onNode(hasText("Enter the public application ID from your Microsoft Entra registration.")).assertExists()
                val validId = "12345678-abcd-1234-1234-123456789abc"
                field.performTextReplacement(validId)
                field.assertTextContains(validId, substring = false)
                // Finish editing before returning to the control. The error panel and older TV
                // keyboard can move this lazy-list item outside the composed viewport.
                field.performImeAction()
                compose.onAllNodes(hasScrollToIndexAction()).onFirst().performScrollToNode(signInMatcher)
                signIn.assertIsEnabled()
            } catch (failure: AssertionError) {
                val tree = runCatching { compose.onRoot(useUnmergedTree = true).printToString(maxDepth = 12) }
                    .getOrDefault("No single active OneDrive setup root").take(20_000)
                throw AssertionError("${failure.message}\nOneDrive setup state:\n$tree", failure)
            }
        }
    }
}
