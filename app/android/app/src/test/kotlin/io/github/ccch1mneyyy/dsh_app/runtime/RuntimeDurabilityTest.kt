package io.github.ccch1mneyyy.dsh_app.runtime

import java.io.File
import java.io.IOException
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

class RuntimeDurabilityTest {
    private val base = Files.createTempDirectory("rootfs-durable").toFile()
    private val version = File(base, "rootfs.version")
    private val keep = File(base.parentFile, "${base.name}-keep")

    @After fun cleanup() {
        base.deleteRecursively()
        keep.deleteRecursively()
    }

    private fun write(path: String, value: String) {
        File(base, path).apply { parentFile!!.mkdirs(); writeText(value) }
    }

    private fun stage() {
        write("staging/bin/new", "new runtime")
        write("staging/root/skeleton", "fresh home")
    }

    private fun installed() {
        write("rootfs/bin/old", "old runtime")
        write("rootfs/root/workspace/notes", "user notes")
        version.writeText("same-version")
        stage()
    }

    @Test fun theReadyMarkerFollowsRestoredDataAndTheDataBarrierEvenForTheSameVersion() {
        installed()
        File(keep, "root/.dsh/dsh-go/ui.json").apply {
            parentFile!!.mkdirs()
            writeText("kept settings")
        }
        val order = mutableListOf<String>()
        activateRootfs(base, "same-version", keep, sync = {
            assertFalse(version.exists())
            assertEquals("new runtime", File(base, "rootfs/bin/new").readText())
            assertEquals("user notes", File(base, "rootfs/root/workspace/notes").readText())
            assertEquals("kept settings", File(base, "rootfs/root/.dsh/dsh-go/ui.json").readText())
            assertTrue(File(base, "rootfs.old/bin/old").isFile)
            order.add("data")
        }, syncDirectory = { directory ->
            assertFalse(version.exists())
            assertTrue(File(base, "rootfs/bin/old").isFile)
            assertTrue(File(base, "staging/bin/new").isFile)
            order.add("retire")
            syncDirectory(directory)
        })
        assertEquals(listOf("retire", "data"), order)
        assertEquals("same-version", version.readText())
        assertFalse(File(base, "rootfs.old").exists())
    }

    @Test fun aFailedRetirementBarrierLeavesTheActiveTreeAndHomeUntouched() {
        installed()
        val failure = IOException("directory sync failed")
        val actual = assertThrows(IOException::class.java) {
            activateRootfs(base, "same-version", sync = { fail("data barrier reached") },
                syncDirectory = { throw failure })
        }
        assertSame(failure, actual)
        assertEquals("old runtime", File(base, "rootfs/bin/old").readText())
        assertEquals("user notes", File(base, "rootfs/root/workspace/notes").readText())
        assertTrue(File(base, "staging/bin/new").isFile)
        assertFalse(File(base, "home.carry").exists())
        assertFalse(version.exists())
    }

    @Test fun aFailedDataBarrierLeavesNoReadyMarkerAndARealRetryKeepsTheHome() {
        installed()
        val failure = IOException("sync process failed")
        val actual = assertThrows(IOException::class.java) {
            activateRootfs(base, "same-version", sync = { throw failure })
        }
        assertSame(failure, actual)
        assertFalse(version.exists())
        assertTrue(File(base, "rootfs.old/bin/old").isFile)
        assertEquals("user notes", File(base, "rootfs/root/workspace/notes").readText())
        stage()
        activateRootfs(base, "same-version", sync = {})
        assertEquals("same-version", version.readText())
        assertEquals("user notes", File(base, "rootfs/root/workspace/notes").readText())
    }
}
