package com.dineshdevkota.cinevault.ui

import android.content.ActivityNotFoundException
import android.content.Context
import android.net.Uri
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Text
import java.net.URI

private fun openInBrave(context: Context, address: String): String? {
    val url = runCatching { URI(address.trim()) }.getOrNull()
    if (url == null || url.host.isNullOrBlank() || !url.scheme.equals("https", ignoreCase = true) || url.userInfo != null) {
        return "Enter a full HTTPS video or website address."
    }
    for (browser in listOf("com.dineshdevkota.coveshelf.browser", "com.brave.browser")) {
        val tab = CustomTabsIntent.Builder().setShowTitle(true).build()
        tab.intent.setPackage(browser)
        try {
            tab.launchUrl(context, Uri.parse(url.toASCIIString()))
            return null
        } catch (_: ActivityNotFoundException) {
            // Try the next supported installation.
        } catch (_: SecurityException) {
            return "This TV blocked the browser from opening."
        }
    }
    return "Install the CoveShelf browser companion or Brave on this TV, then try again."
}

@Composable
internal fun WebVideoTab() {
    val context = LocalContext.current
    var address by rememberSaveable { mutableStateOf("") }
    var error by rememberSaveable { mutableStateOf<String?>(null) }
    Column(
        Modifier.verticalScroll(rememberScrollState()).padding(horizontal = ScreenPadding).widthIn(max = 680.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        ScreenHeader("Web Video")
        Button(onClick = { error = openInBrave(context, "https://www.youtube.com/tv") }) { Text("Open YouTube") }
        TvTextField(address, { address = it; error = null }, "Video or website address",
            keyboardType = KeyboardType.Uri, imeAction = ImeAction.Done)
        OutlinedButton(onClick = { error = openInBrave(context, address) }, enabled = address.isNotBlank()) {
            Text("Open in Brave")
        }
        error?.let { Text(it) }
    }
}
