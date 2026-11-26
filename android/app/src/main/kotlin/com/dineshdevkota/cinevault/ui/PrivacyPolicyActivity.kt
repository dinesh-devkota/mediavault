package com.dineshdevkota.cinevault.ui

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Text
import com.dineshdevkota.cinevault.R
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class PrivacyPolicyActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            // The bundled public policy is also available while household access is locked.
            CineVaultTheme {
                val policy by produceState<Result<String>?>(null) {
                    value = withContext(Dispatchers.IO) {
                        runCatching { assets.open("PRIVACY.md").bufferedReader().use { it.readText() } }
                    }
                }
                PrivacyPolicyScreen(policy)
            }
        }
    }
}

@Composable
internal fun PrivacyPolicyButton() {
    val context = LocalContext.current
    OutlinedButton(onClick = { context.startActivity(Intent(context, PrivacyPolicyActivity::class.java)) }) {
        Text(stringResource(R.string.privacy_policy))
    }
}

private val policyLink = Regex("""\[([^\]]+)]\((https://[^)]+)\)""")

@Composable
private fun PrivacyPolicyScreen(policy: Result<String>?) {
    val document = policy?.getOrNull()
    val sections = remember(document) { document?.replace("\r\n", "\n")?.trim()?.split("\n## ").orEmpty() }
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = ScreenPadding, vertical = 24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item {
            val title = sections.firstOrNull()?.substringBefore('\n')?.removePrefix("# ")
            ScreenHeader(title ?: stringResource(R.string.privacy_policy))
        }
        if (sections.isEmpty()) {
            item { Text(if (policy == null) "Loading privacy policy…" else "The privacy policy could not be opened.") }
        }
        sections.firstOrNull()?.let { introduction ->
            val body = formatPolicyBody(introduction.substringAfter('\n', ""))
            if (body.isNotEmpty()) item { GuideSection(title = null, body = body) }
        }
        items(sections.drop(1)) { section ->
            GuideSection(section.substringBefore('\n'), formatPolicyBody(section.substringAfter('\n', "")))
        }
    }
}

private fun formatPolicyBody(body: String): String =
    body.trim().split("\n\n").joinToString("\n\n") { paragraph ->
        policyLink.replace(paragraph.lineSequence().joinToString(" ") { it.trim() }) { link ->
            "${link.groupValues[1]} (${link.groupValues[2]})"
        }
    }
