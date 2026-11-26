package com.dineshdevkota.cinevault.cloud

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.dineshdevkota.cinevault.data.SecretBox
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class OneDriveAccountStoreInstrumentedTest {
    @Test
    fun refreshRecordIsEncryptedOnDiskAndRemovable() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val source = UUID.randomUUID()
        val refresh = "one-drive-fixture-refresh"
        val app = "12345678-abcd-1234-1234-123456789abc"
        val store = AndroidOneDriveAccountStore(context, SecretBox(context))
        try {
            store.save(source, SavedOneDriveAccount(source.toString(), app, "fixture-drive", refresh))
            val prefs = context.getSharedPreferences("onedrive-accounts", Context.MODE_PRIVATE)
            val encrypted = requireNotNull(prefs.getString(source.toString(), null))
            assertFalse(encrypted.contains(refresh))
            assertFalse(encrypted.contains("fixture-drive"))

            val reopened = AndroidOneDriveAccountStore(context, SecretBox(context))
            val restored = requireNotNull(reopened.load(source))
            assertEquals(refresh, restored.refreshToken)
            assertEquals("fixture-drive", restored.driveId)
            assertEquals(source.toString(), restored.sourceId)
            assertEquals(app, restored.applicationId)
            assertNull(reopened.load(UUID.randomUUID()))
            reopened.remove(source)
            assertNull(reopened.load(source))
            assertNull(prefs.getString(source.toString(), null))
        } finally {
            store.remove(source)
        }
    }
}
