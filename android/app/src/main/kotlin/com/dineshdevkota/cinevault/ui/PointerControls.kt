package com.dineshdevkota.cinevault.ui

import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.material3.Button as MobileButton
import androidx.compose.material3.LocalContentColor as MobileContentColor
import androidx.compose.material3.OutlinedButton as MobileOutlinedButton
import androidx.tv.material3.Button as TvButton
import androidx.tv.material3.LocalContentColor as TvContentColor
import androidx.tv.material3.OutlinedButton as TvOutlinedButton

/** TV Material 1.0.1 handles D-pad keys, but not pointer taps. Keep its focus/key semantics. */
@Composable
fun Modifier.pointerClick(enabled: Boolean = true, onClick: () -> Unit): Modifier {
    val isTv = LocalTvLayout.current
    val action = rememberUpdatedState(onClick)
    val focus = remember { FocusRequester() }
    return focusRequester(focus).pointerInput(enabled) {
        if (enabled) detectTapGestures {
            if (isTv) focus.requestFocus()
            action.value()
        }
    }
}

@Composable
fun Button(onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true,
           content: @Composable RowScope.() -> Unit) {
    if (LocalTvLayout.current) TvButton(onClick, modifier.pointerClick(enabled, onClick), enabled = enabled, content = content)
    else MobileButton(onClick, modifier, enabled = enabled) {
        CompositionLocalProvider(TvContentColor provides MobileContentColor.current) { content() }
    }
}

@Composable
fun OutlinedButton(onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true,
                   content: @Composable RowScope.() -> Unit) {
    if (LocalTvLayout.current) TvOutlinedButton(onClick, modifier.pointerClick(enabled, onClick), enabled = enabled, content = content)
    else MobileOutlinedButton(onClick, modifier, enabled = enabled) {
        CompositionLocalProvider(TvContentColor provides MobileContentColor.current) { content() }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun AdaptiveActions(gap: Dp = 16.dp, content: @Composable () -> Unit) {
    val spacing = Arrangement.spacedBy(gap)
    if (LocalTvLayout.current) Row(horizontalArrangement = spacing) { content() }
    else FlowRow(horizontalArrangement = spacing, verticalArrangement = Arrangement.spacedBy(4.dp)) { content() }
}
