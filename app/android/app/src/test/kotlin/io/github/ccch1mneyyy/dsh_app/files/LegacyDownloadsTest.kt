package io.github.ccch1mneyyy.dsh_app.files

import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class LegacyDownloadsTest {
    @Test fun keepsExistingNamesAndUsesTheSameSuffixConvention() = withDirectory { dir ->
        File(dir, "report.zip").writeText("original")
        File(dir, "report (2).zip").mkdir()
        val saved = ByteArrayInputStream("new".toByteArray()).use {
            LegacyDownloads.copy(it, dir, "report.zip")
        }
        assertEquals("report (3).zip", saved.name)
        assertEquals("new", saved.readText())
        assertEquals("original", File(dir, "report.zip").readText())
        assertTrue(File(dir, "report (2).zip").isDirectory)
        File(dir, ".hidden").writeText("hidden")
        assertEquals(".hidden (2)", ByteArrayInputStream(byteArrayOf(1)).use {
            LegacyDownloads.copy(it, dir, ".hidden")
        }.name)
    }

    @Test fun aSecondCopyWhileTheFirstIsWritingOwnsAnotherTarget() = withDirectory { dir ->
        var peer: File? = null
        val first = object : ByteArrayInputStream("first".toByteArray()) {
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                if (peer == null) {
                    // The production copy has opened its target before reading.
                    assertTrue(File(dir, "same.zip").isFile)
                    peer = ByteArrayInputStream("second".toByteArray()).use {
                        LegacyDownloads.copy(it, dir, "same.zip")
                    }
                }
                return super.read(buffer, offset, length)
            }
        }.use { LegacyDownloads.copy(it, dir, "same.zip") }
        assertEquals("same.zip", first.name)
        assertEquals("same (2).zip", peer!!.name)
        assertEquals("first", first.readText())
        assertEquals("second", peer!!.readText())
    }

    @Test fun readFailureRemovesOnlyItsPartialAndKeepsTheCompletedPeer() = withDirectory { dir ->
        File(dir, "same.zip").writeText("existing")
        val failure = IOException("source interrupted")
        var reads = 0
        var peer: File? = null
        val source = object : InputStream() {
            override fun read(): Int = throw AssertionError("bulk copy expected")
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                if (reads++ == 0) {
                    buffer[offset] = 42
                    return 1
                }
                assertEquals(listOf<Byte>(42), File(dir, "same (2).zip").readBytes().toList())
                peer = ByteArrayInputStream("peer".toByteArray()).use {
                    LegacyDownloads.copy(it, dir, "same.zip")
                }
                throw failure
            }
        }
        try {
            source.use { LegacyDownloads.copy(it, dir, "same.zip") }
            fail("copy should propagate the source failure")
        } catch (error: IOException) {
            assertSame(failure, error)
        }
        assertFalse(File(dir, "same (2).zip").exists())
        assertEquals("existing", File(dir, "same.zip").readText())
        assertEquals("same (3).zip", peer!!.name)
        assertEquals("peer", peer!!.readText())
    }

    @Test fun failureBeforeExclusiveOpenDoesNotRemoveExistingObjects() = withDirectory { dir ->
        val notDirectory = File(dir, "occupied").apply { writeText("keep") }
        try {
            ByteArrayInputStream(byteArrayOf(1)).use {
                LegacyDownloads.copy(it, notDirectory, "out.zip")
            }
            fail("a regular file cannot contain a target")
        } catch (_: IOException) {
            assertEquals("keep", notDirectory.readText())
        }
    }

    private fun withDirectory(block: (File) -> Unit) {
        val dir = Files.createTempDirectory("legacy-downloads-").toFile()
        try { block(dir) } finally { dir.deleteRecursively() }
    }
}
