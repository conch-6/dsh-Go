package io.github.ccch1mneyyy.dsh_app.runtime

import java.io.File
import java.nio.file.Files
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

class RuntimeUpgradeIntegrationTest {
    private val base = Files.createTempDirectory("runtime-update-route").toFile()
    private fun write(path: String, value: String) = File(base, path).apply { parentFile!!.mkdirs(); writeText(value) }
    private fun info(version: String, layered: Boolean = true, id: String = "a".repeat(64)) = JSONObject()
        .put("runtimeVersion", version).put("abi", "arm64-v8a").put("ubuntuVersion", "24.04.5")
        .apply {
            if (layered) put("upgrade", JSONObject().put("schema", 1).put("baseId", id)
                .put("ubuntuVersion", "24.04.5").put("paths", JSONArray(ENGINE_PATHS)))
        }
    private val next = info("new")

    @After fun cleanup() { base.deleteRecursively() }

    private fun stage() {
        for (path in ENGINE_PATHS) write("staging/$path" + if (path in setOf("opt/dsh", "opt/node", "opt/dsh-go",
            "etc/dsh-app", "usr/local/lib/node_modules/pnpm")) "/version" else "", "new engine")
        write("staging/etc/dsh-app/runtime.json", next.toString())
        write("staging/etc/os-release", "ID=ubuntu\nVERSION_ID=24.04\n")
        write("staging/opt/python/bin/python3", "python")
        write("staging/usr/bin/gh", "factory gh (must not replace the user copy)")
        write("staging/var/lib/dpkg/status", "factory package database")
    }

    private fun installed(layered: Boolean) {
        write("rootfs/etc/dsh-app/runtime.json", info("old", layered).toString())
        write("rootfs/etc/os-release", "ID=ubuntu\nVERSION_ID=24.04\n")
        write("rootfs/opt/python/bin/python3", "python")
        write("rootfs/opt/python/lib/site-packages/user.py", "user pip package")
        write("rootfs/usr/bin/gh", "user gh")
        write("rootfs/var/lib/dpkg/status", "user package database")
        write("rootfs/usr/local/lib/node_modules/user/index.js", "user npm package")
        write("rootfs/root/workspace/project", "user work")
        write("rootfs.version", "old")
    }

    private fun activate() = activateRuntimeUpdate(base, "new", "arm64-v8a", next, sync = {})

    @Test fun productionRouteKeepsTheEntireUserSystemForLegacyAndLayeredUpgrades() {
        for (layered in listOf(false, true)) {
            base.deleteRecursively(); base.mkdirs()
            installed(layered); stage(); activate()
            assertEquals("user gh", File(base, "rootfs/usr/bin/gh").readText())
            assertEquals("user package database", File(base, "rootfs/var/lib/dpkg/status").readText())
            assertEquals("user npm package", File(base, "rootfs/usr/local/lib/node_modules/user/index.js").readText())
            assertEquals("user pip package", File(base, "rootfs/opt/python/lib/site-packages/user.py").readText())
            assertEquals("user work", File(base, "rootfs/root/workspace/project").readText())
            assertEquals("new engine", File(base, "rootfs/opt/dsh/version").readText())
            assertEquals("new", File(base, "rootfs.version").readText())
            assertFalse(File(base, "staging").exists())
        }
    }

    @Test fun productionRouteDoesNotReinstallAnIncompatibleOrUnidentifiedExistingSystem() {
        installed(true); stage()
        write("rootfs/etc/dsh-app/runtime.json", info("old", id = "b".repeat(64)).toString())
        assertThrows(RuntimeUpgradeBlocked::class.java) { activate() }
        assertEquals("user gh", File(base, "rootfs/usr/bin/gh").readText())
        assertEquals("old", File(base, "rootfs.version").readText())
        File(base, "rootfs/etc/dsh-app/runtime.json").delete()
        assertThrows(RuntimeUpgradeBlocked::class.java) { activate() }
        assertEquals("user package database", File(base, "rootfs/var/lib/dpkg/status").readText())
    }

    @Test fun onlyFirstInstallActivatesTheBundledSystem() {
        stage(); activate()
        assertEquals("factory gh (must not replace the user copy)", File(base, "rootfs/usr/bin/gh").readText())
        assertEquals("factory package database", File(base, "rootfs/var/lib/dpkg/status").readText())
        assertEquals("new", File(base, "rootfs.version").readText())
    }
}
