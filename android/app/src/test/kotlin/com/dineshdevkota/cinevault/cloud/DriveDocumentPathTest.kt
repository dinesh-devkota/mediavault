package com.dineshdevkota.cinevault.cloud

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class DriveDocumentPathTest {
    @Test fun opaqueIdentifiersDistinguishDuplicateNamesAndPreserveCase() {
        val folder = DriveDocumentPath.child(DriveDocumentPath.ROOT, "opaque/folder", "My Shows")
        val first = DriveDocumentPath.child(folder, "account:one/id", "Series.S01E02.mp4")
        val second = DriveDocumentPath.child(folder, "account:two/id", "Series.S01E02.mp4")
        assertNotEquals(first, second)
        assertEquals("opaque/folder", DriveDocumentPath.parentID(first))
        assertEquals("account:one/id", DriveDocumentPath.fileID(first))
        assertEquals("My Shows/Series.S01E02.mp4", DriveDocumentPath.displayPath(first))
        assertEquals(DriveDocumentGrant(tree = "content://fixture/tree/abc"),
            DriveDocumentGrant.decode(DriveDocumentGrant(tree = "content://fixture/tree/abc").encode()))
    }

    @Test fun malformedPathsAndMixedGrantsFailClosed() {
        assertNull(DriveDocumentPath.fileID("other/SGVsbG8~Movie.mp4"))
        assertNull(DriveDocumentPath.fileID("gdrive/@not-valid~Movie.mp4"))
        assertNull(DriveDocumentPath.fileID("gdrive/SGVsbG8~.."))
        assertThrows(IllegalArgumentException::class.java) {
            DriveDocumentPath.child(DriveDocumentPath.ROOT, "safe", "../escape.mp4")
        }
        assertThrows(GoogleDriveDocumentsException::class.java) {
            DriveDocumentGrant.decode("""{"tree":"content://fixture/tree/abc","documents":["content://fixture/document/a"]}""")
        }
    }
}
