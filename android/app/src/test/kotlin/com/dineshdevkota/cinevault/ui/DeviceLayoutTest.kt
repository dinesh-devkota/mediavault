package com.dineshdevkota.cinevault.ui

import android.content.res.Configuration
import org.junit.Assert.*
import org.junit.Test

class DeviceLayoutTest {
    @Test fun fireFeatureEnablesRemoteLayoutEvenWhenUiModeIsNormal() {
        assertTrue(usesTelevisionLayout(Configuration.UI_MODE_TYPE_NORMAL, true))
        assertTrue(usesTelevisionLayout(Configuration.UI_MODE_TYPE_UNDEFINED, true))
        assertTrue(usesTelevisionLayout(Configuration.UI_MODE_TYPE_TELEVISION or Configuration.UI_MODE_NIGHT_YES, false))
    }

    @Test fun phonesAndNonTvAmazonDevicesKeepTouchLayout() {
        assertFalse(usesTelevisionLayout(Configuration.UI_MODE_TYPE_NORMAL, false))
        assertFalse(usesTelevisionLayout(Configuration.UI_MODE_TYPE_NORMAL or Configuration.UI_MODE_NIGHT_YES, false))
    }
}
