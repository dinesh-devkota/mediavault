package com.dineshdevkota.cinevault.emby

import org.junit.Assert.assertThrows
import org.junit.Test

class EmbyClientTest {
    @Test fun endpointRejectsCleartextAndInlineCredentials() {
        assertThrows(IllegalArgumentException::class.java) { EmbyClient("http://fixture.example/emby", "device", "1.0") }
        assertThrows(IllegalArgumentException::class.java) { EmbyClient("https://user:secret@fixture.example/emby", "device", "1.0") }
    }

    @Test fun identityCannotInjectHeaders() {
        assertThrows(IllegalArgumentException::class.java) { EmbyClient("https://fixture.example/emby", "device\r\n", "1.0") }
        EmbyClient("https://fixture.example/emby", "device", "1.0")
    }
}
