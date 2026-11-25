@file:OptIn(ExperimentalTvMaterial3Api::class)

package com.dineshdevkota.cinevault.ui

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.OutlinedTextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.activity.ComponentActivity
import androidx.activity.compose.LocalActivity
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.tv.material3.Card
import androidx.tv.material3.CardDefaults
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import coil3.compose.AsyncImage
import com.dineshdevkota.cinevault.container
import com.dineshdevkota.cinevault.core.Tmdb
import com.dineshdevkota.cinevault.data.MovieEntity
import com.dineshdevkota.cinevault.jellyfin.JELLYFIN
import com.dineshdevkota.cinevault.jellyfin.JellyfinImage
import com.dineshdevkota.cinevault.jellyfin.jellyfinItemID
import kotlinx.coroutines.CancellationException
import java.text.DateFormat
import java.util.Date
import java.util.Locale
import androidx.compose.material3.Text as MobileText

val PosterWidth = 168.dp
private val CardShape = RoundedCornerShape(10.dp)

/** Remote artwork over a titled placeholder, so missing or failed images still read well. */
@Composable
fun Artwork(url: String?, title: String, modifier: Modifier = Modifier, image: Bitmap? = null) {
    Box(
        modifier.background(Brush.verticalGradient(listOf(Color(0xFF2A2D36), Color(0xFF15161B)))),
        contentAlignment = Alignment.Center,
    ) {
        if (title.isNotEmpty()) {
            Text(
                title,
                style = MaterialTheme.typography.titleSmall,
                color = SecondaryText,
                textAlign = TextAlign.Center,
                maxLines = 4,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(12.dp),
            )
        }
        if (image != null) {
            Image(image.asImageBitmap(), contentDescription = null,
                contentScale = ContentScale.Crop, modifier = Modifier.matchParentSize())
        } else if (url != null) {
            AsyncImage(
                model = url,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.matchParentSize(),
            )
        }
    }
}

@Composable
internal fun MediaArtwork(
    movie: MovieEntity,
    url: String?,
    title: String,
    modifier: Modifier,
    width: Int,
    kind: JellyfinImage = JellyfinImage.Primary,
) {
    if (jellyfinItemID(movie.filePath) == null || movie.isHidden || movie.isMissing) {
        Artwork(url, title, modifier)
        return
    }
    val container = LocalContext.current.container
    val source by remember(movie.sourceId) { container.database.sources().observe(movie.sourceId) }
        .collectAsStateWithLifecycle(null)
    val session by container.family.session.collectAsStateWithLifecycle()
    val activeSource = source
    if (activeSource?.sourceType != JELLYFIN) {
        Artwork(url, title, modifier)
        return
    }
    val bitmap by key(session, activeSource, movie.id, movie.filePath, movie.ageCertification, kind, width) {
        produceState<Bitmap?>(null) {
            if (!container.family.isCurrent(session) || !container.family.permits(movie)) return@produceState
            try {
                value = container.photos.loadArtwork(movie.id, width, kind)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                // The card retains its normal title or existing matched artwork on an image error.
            }
        }
    }
    Artwork(url, title, modifier, bitmap)
}

@Composable
fun ProgressLine(fraction: Float, modifier: Modifier = Modifier) {
    Box(modifier.height(4.dp).clip(RoundedCornerShape(2.dp)).background(Color.White.copy(alpha = 0.25f))) {
        Box(Modifier.fillMaxHeight().fillMaxWidth(fraction.coerceIn(0f, 1f)).background(Accent))
    }
}

@Composable
private fun WatchedBadge(modifier: Modifier = Modifier) {
    Box(modifier.size(28.dp).clip(CircleShape).background(Accent), contentAlignment = Alignment.Center) {
        Text("✓", color = Color.Black, style = MaterialTheme.typography.labelLarge)
    }
}

@Composable
fun PosterCard(movie: MovieEntity, onClick: () -> Unit, modifier: Modifier = Modifier, selected: Boolean? = null,
    cardModifier: Modifier = Modifier) {
    Column(modifier) {
        Card(
            onClick = onClick,
            modifier = cardModifier.fillMaxWidth().aspectRatio(2f / 3f).pointerClick(onClick = onClick)
                .then(if (selected == null) Modifier else Modifier.testTag("bulk-item:${movie.id}").semantics { this.selected = selected }),
            shape = CardDefaults.shape(CardShape),
        ) {
            Box(Modifier.fillMaxSize()) {
                MediaArtwork(movie, Tmdb.imageUrl(movie.posterPath, "w342"), movie.title, Modifier.fillMaxSize(), width = 342)
                if (movie.isWatched) WatchedBadge(Modifier.align(Alignment.TopEnd).padding(8.dp))
                selected?.let { SelectionBadge(it, Modifier.align(Alignment.TopStart).padding(8.dp)) }
                if (movie.isInProgress) {
                    ProgressLine(movie.progress, Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(10.dp))
                }
            }
        }
        Text(
            movie.title,
            style = MaterialTheme.typography.titleSmall,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 10.dp),
        )
        Text(movie.year?.toString() ?: " ", style = MaterialTheme.typography.labelMedium, color = SecondaryText)
    }
}

@Composable
private fun ContinueCard(item: ContinueWatchingItem, onClick: () -> Unit) {
    val movie = item.movie
    val remaining = (movie.durationMs - movie.playbackPositionMs).coerceAtLeast(0)
    val time = if (movie.durationMs > 0) "${formatDuration(remaining)} left" else "at ${formatDuration(movie.playbackPositionMs)}"
    val caption = when {
        item.action != ContinueAction.RESUME -> item.label
        movie.episodeInfo != null -> "${item.label} · $time"
        else -> "${item.label} $time"
    }
    Column(Modifier.width(300.dp)) {
        Card(
            onClick = onClick,
            modifier = Modifier.fillMaxWidth().aspectRatio(16f / 9f).testTag("continue:${item.id}")
                .semantics { contentDescription = "${item.title}, $caption" }.pointerClick(onClick = onClick),
            shape = CardDefaults.shape(CardShape),
        ) {
            Box(Modifier.fillMaxSize()) {
                MediaArtwork(movie, Tmdb.imageUrl(movie.backdropPath ?: movie.posterPath, "w780"), movie.title,
                    Modifier.fillMaxSize().clearAndSetSemantics {}, width = 780, kind = JellyfinImage.Backdrop)
                if (movie.isInProgress && movie.durationMs > 0) {
                    ProgressLine(movie.progress, Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(12.dp))
                }
            }
        }
        Text(
            item.title,
            style = MaterialTheme.typography.titleSmall,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 10.dp),
        )
        Text(
            caption,
            style = MaterialTheme.typography.labelMedium,
            color = SecondaryText,
        )
    }
}

@Composable
fun MovieRow(title: String, movies: List<MovieEntity>, onOpen: (MovieEntity) -> Unit, onSeeAll: (() -> Unit)? = null) {
    MediaRow(title, onSeeAll) {
        items(movies, key = { it.id }) { movie ->
            PosterCard(movie, onClick = { onOpen(movie) }, modifier = Modifier.width(PosterWidth))
        }
    }
}

@Composable
internal fun ContinueWatchingRow(choices: List<ContinueWatchingItem>, onOpen: (MovieEntity) -> Unit, onSeeAll: (() -> Unit)? = null) {
    MediaRow("Continue Watching", onSeeAll) {
        items(choices, key = { it.id }) { choice -> ContinueCard(choice, onClick = { onOpen(choice.movie) }) }
    }
}

@Composable
private fun MediaRow(title: String, onSeeAll: (() -> Unit)? = null, content: LazyListScope.() -> Unit) {
    Column {
        HomeShelfHeader(title, onSeeAll)
        LazyRow(
            contentPadding = PaddingValues(horizontal = ScreenPadding, vertical = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(24.dp),
            content = content,
        )
    }
}

@Composable
internal fun HomeShelfHeader(title: String, onSeeAll: (() -> Unit)?) {
    Row(Modifier.fillMaxWidth().padding(horizontal = ScreenPadding), verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
        if (onSeeAll != null) OutlinedButton(onClick = onSeeAll,
            modifier = Modifier.testTag("see-all:$title").semantics { contentDescription = "See all $title" }) {
            Text("See all")
        }
    }
}

@Composable
fun ScreenHeader(title: String, modifier: Modifier = Modifier, kicker: String? = null, trailing: String? = null, showBack: Boolean = true) {
    val activity = LocalActivity.current as? ComponentActivity
    if (!LocalTvLayout.current) {
        Column(modifier.fillMaxWidth().padding(top = 12.dp, bottom = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            if (showBack && activity != null && activity !is com.dineshdevkota.cinevault.MainActivity) {
                OutlinedButton(onClick = { activity.onBackPressedDispatcher.onBackPressed() }) { Text("Back") }
            }
            kicker?.let { Text(it, style = MaterialTheme.typography.labelLarge, color = Accent) }
            Text(title, style = MaterialTheme.typography.headlineMedium)
            trailing?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = SecondaryText) }
        }
        return
    }
    Row(modifier.fillMaxWidth().padding(top = 12.dp, bottom = 8.dp), verticalAlignment = Alignment.Bottom) {
        if (showBack && activity != null && activity !is com.dineshdevkota.cinevault.MainActivity) {
            OutlinedButton(onClick = { activity.onBackPressedDispatcher.onBackPressed() }, modifier = Modifier.padding(end = 16.dp)) { Text("Back") }
        }
        Column(Modifier.weight(1f)) {
            if (kicker != null) {
                Text(kicker, style = MaterialTheme.typography.labelLarge.copy(letterSpacing = 3.sp), color = Accent)
            }
            Text(title, style = MaterialTheme.typography.displaySmall)
        }
        if (trailing != null) {
            Text(
                trailing,
                style = MaterialTheme.typography.bodyMedium,
                color = SecondaryText,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                textAlign = TextAlign.End,
                modifier = Modifier.widthIn(max = 460.dp),
            )
        }
    }
}

@Composable
fun EmptyState(title: String, message: String, modifier: Modifier = Modifier,
    actionLabel: String? = null, onAction: (() -> Unit)? = null, actionModifier: Modifier = Modifier) {
    Column(modifier.fillMaxWidth().padding(vertical = if (onAction != null) 24.dp else 64.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Text(title, style = MaterialTheme.typography.headlineSmall)
        Text(
            message,
            style = MaterialTheme.typography.bodyLarge,
            color = SecondaryText,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = 8.dp),
        )
        if (actionLabel != null && onAction != null) {
            Button(onClick = onAction, modifier = actionModifier.padding(top = 16.dp)) { Text(actionLabel) }
        }
    }
}

/** Arrow keys move focus off the field; the centre button opens the on-screen keyboard. */
@Composable
fun TvTextField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    modifier: Modifier = Modifier,
    isPassword: Boolean = false,
    keyboardType: KeyboardType = KeyboardType.Text,
    imeAction: ImeAction = ImeAction.Next,
    enabled: Boolean = true,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier,
        singleLine = true,
        enabled = enabled,
        label = { MobileText(label) },
        visualTransformation = if (isPassword) PasswordVisualTransformation() else VisualTransformation.None,
        keyboardOptions = KeyboardOptions(
            keyboardType = if (isPassword && keyboardType != KeyboardType.NumberPassword) KeyboardType.Password else keyboardType,
            imeAction = imeAction,
            autoCorrectEnabled = false,
            showKeyboardOnFocus = !LocalTvLayout.current,
        ),
        // Results update live, so the IME's Search key only needs to close the keyboard.
        keyboardActions = KeyboardActions(onSearch = { defaultKeyboardAction(ImeAction.Done) }),
    )
}

fun formatDuration(ms: Long): String {
    val total = (ms / 1000).coerceAtLeast(0)
    val hours = total / 3600
    val minutes = (total % 3600) / 60
    val seconds = total % 60
    return if (hours > 0) {
        String.format(Locale.US, "%d:%02d:%02d", hours, minutes, seconds)
    } else {
        String.format(Locale.US, "%d:%02d", minutes, seconds)
    }
}

fun formatDate(epochMs: Long): String =
    DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(epochMs))
