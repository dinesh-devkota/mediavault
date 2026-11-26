package com.dineshdevkota.cinevault.ui

import android.content.Context
import android.content.res.Configuration

internal const val FIRE_TV_FEATURE = "amazon.hardware.fire_tv"

/** Feature detection also covers Fire OS devices that don't report Android's TV UI mode. */
internal fun Configuration.isTelevision(fireTv: Boolean = false): Boolean =
    usesTelevisionLayout(uiMode, fireTv)

internal fun usesTelevisionLayout(uiMode: Int, fireTv: Boolean): Boolean =
    fireTv || uiMode and Configuration.UI_MODE_TYPE_MASK == Configuration.UI_MODE_TYPE_TELEVISION

internal fun Context.isTelevision(configuration: Configuration = resources.configuration): Boolean =
    configuration.isTelevision(packageManager.hasSystemFeature(FIRE_TV_FEATURE))
