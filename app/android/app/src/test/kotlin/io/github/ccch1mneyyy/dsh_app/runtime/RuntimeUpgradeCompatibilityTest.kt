package io.github.ccch1mneyyy.dsh_app.runtime

import java.io.File
import java.nio.file.Files
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

class RuntimeUpgradeCompatibilityTest {
    private val base = Files.createTempDirectory("upgrade-compatibility").toFile()
    private val abi = "arm64-v8a"
    private fun descriptor(id: String = "a".repeat(64)) = JSONObject()
        .put("schema", 1).put("baseId", id).put("ubuntuVersion", "24.04.5").put("paths", JSONArray(ENGINE_PATHS))
    private fun info(version: String, layered: Boolean = true): JSONObject = JSONObject()
        .put("runtimeVersion", version).put("abi", abi).put("ubuntuVersion", "24.04.5")
        .apply { if (layered) put("upgrade", descriptor()) }
    private val next = info("new")

    @After fun cleanup() { base.deleteRecursively() }

    private fun write(path: String, text: String) = File(base, path).apply { parentFile!!.mkdirs(); writeText(text) }
    private fun installed(layered: Boolean = true) {
        write("rootfs/etc/dsh-app/runtime.json", info("old", layered).toString())
        write("staging/etc/dsh-app/runtime.json", next.toString())
        for (tree in listOf("rootfs", "staging")) {
            write("$tree/etc/os-release", "ID=ubuntu\nVERSION_ID=\"24.04\"\n")
            write("$tree/opt/python/bin/python3", "same python binary")
        }
        write("rootfs/usr/bin/gh", "user tool")
        write("rootfs/var/lib/dpkg/status", "user packages")
        write("rootfs.version", "old")
    }
    private fun check() = checkEngineCompatibility(base, next, "new", abi)
    private fun rejected(reason: String) {
        val error = assertThrows(RuntimeUpgradeBlocked::class.java) { check() }
        assertEquals("runtime_upgrade_blocked:$reason", error.message)
        assertEquals("old", File(base, "rootfs.version").readText())
        assertEquals("user tool", File(base, "rootfs/usr/bin/gh").readText())
        assertEquals("user packages", File(base, "rootfs/var/lib/dpkg/status").readText())
    }

    @Test fun sameSystemAllowsIndependentEngineVersions() {
        installed()
        assertEquals("a".repeat(64), check().baseId)
    }

    @Test fun legacyRuntimeIsAdoptedWithoutReplacingItsSystemOrPythonPackages() {
        installed(layered = false)
        write("rootfs/opt/python/lib/site-packages/custom.py", "user pip package")
        assertEquals(ENGINE_PATHS, check().paths)
        assertEquals("user pip package", File(base, "rootfs/opt/python/lib/site-packages/custom.py").readText())
    }

    @Test fun changedFactorySystemStopsWithoutResetting() {
        installed()
        write("rootfs/etc/dsh-app/runtime.json", info("old").put("upgrade", descriptor("b".repeat(64))).toString())
        rejected("base")
    }

    @Test fun wrongAbiOrUserDistributionUpgradeIsNotSilentlyAccepted() {
        installed()
        write("rootfs/etc/dsh-app/runtime.json", info("old").put("abi", "x86_64").toString())
        rejected("base")
        installed()
        write("rootfs/etc/os-release", "ID=ubuntu\nVERSION_ID=26.04\n")
        rejected("base")
    }

    @Test fun legacyPythonOrUbuntuMismatchRequiresBackupAndMigration() {
        installed(layered = false)
        write("rootfs/opt/python/bin/python3", "different binary")
        rejected("base")
        installed(layered = false)
        write("rootfs/etc/dsh-app/runtime.json", info("old", false).put("ubuntuVersion", "24.04.4").toString())
        rejected("base")
    }

    @Test fun unknownMissingOrInconsistentManifestsNeverFallBackToFullRootfsReplacement() {
        installed()
        write("rootfs/etc/dsh-app/runtime.json", "not JSON")
        rejected("manifest")
        installed()
        next.getJSONObject("upgrade").put("schema", 99)
        rejected("manifest")
        next.put("upgrade", descriptor())
        write("staging/etc/dsh-app/runtime.json", info("wrong-version").toString())
        rejected("manifest")
        File(base, "rootfs/etc/dsh-app/runtime.json").delete()
        rejected("manifest")
    }

    @Test fun interruptedOldRootfsSwapIsPreservedForRecoveryInsteadOfBeingWiped() {
        installed()
        write("home.carry/user", "carried home")
        rejected("legacy_interrupted")
        assertEquals("carried home", File(base, "home.carry/user").readText())
    }
}
