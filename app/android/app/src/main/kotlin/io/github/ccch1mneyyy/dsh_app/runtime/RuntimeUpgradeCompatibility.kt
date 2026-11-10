package io.github.ccch1mneyyy.dsh_app.runtime

import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import org.json.JSONObject

internal fun checkEngineCompatibility(baseDir: File, raw: JSONObject, version: String, abi: String): EngineUpgradeSpec {
    val rootfs = File(baseDir, "rootfs")
    val staging = File(baseDir, "staging")
    if (Files.isSymbolicLink(rootfs.toPath()) || File(baseDir, "home.carry").exists() ||
        File(baseDir, "rootfs.old").exists()) throw RuntimeUpgradeBlocked("legacy_interrupted")
    val next = parseUpgrade(raw)
    val shipped = readRuntimeInfo(staging)
    if (parseUpgrade(shipped) != next || shipped.optString("runtimeVersion") != version) {
        throw RuntimeUpgradeBlocked("manifest")
    }
    val previous = readRuntimeInfo(rootfs)
    if (previous.optString("abi") != abi || shipped.optString("abi") != abi ||
        osIdentity(rootfs) != osIdentity(staging)) throw RuntimeUpgradeBlocked("base")
    if (previous.has("upgrade")) {
        if (parseUpgrade(previous).baseId != next.baseId) throw RuntimeUpgradeBlocked("base")
    } else {
        // One-time adoption of old bundles. Do not infer compatibility just
        // from rNN or Node versions. Keep Python and all user pip packages.
        if (previous.optString("ubuntuVersion") != next.ubuntuVersion ||
            !samePython(rootfs, staging)) throw RuntimeUpgradeBlocked("base")
    }
    return next
}

private fun readRuntimeInfo(tree: File): JSONObject = try {
    JSONObject(File(tree, "etc/dsh-app/runtime.json").readText())
} catch (_: Exception) {
    throw RuntimeUpgradeBlocked("manifest")
}

private fun parseUpgrade(json: JSONObject): EngineUpgradeSpec = try {
    val upgrade = json.getJSONObject("upgrade")
    if (upgrade.getInt("schema") != 1) throw RuntimeUpgradeBlocked("manifest")
    val paths = upgrade.getJSONArray("paths")
    EngineUpgradeSpec(upgrade.getString("baseId"), upgrade.getString("ubuntuVersion"),
        List(paths.length()) { paths.getString(it) }).also { it.validate() }
} catch (_: Exception) {
    throw RuntimeUpgradeBlocked("manifest")
}

private fun osIdentity(tree: File): List<String> = try {
    val rows = File(tree, "etc/os-release").readLines()
    listOf("ID", "VERSION_ID").map { key ->
        rows.single { it.startsWith("$key=") }.substringAfter('=').trim().trim('"', '\'')
    }
} catch (_: Exception) {
    throw RuntimeUpgradeBlocked("base")
}

private fun samePython(old: File, next: File): Boolean = try {
    fun digest(tree: File): List<Byte> {
        val hash = MessageDigest.getInstance("SHA-256")
        File(tree, "opt/python/bin/python3").inputStream().use { input ->
            val buffer = ByteArray(65536)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                hash.update(buffer, 0, count)
            }
        }
        return hash.digest().toList()
    }
    digest(old) == digest(next)
} catch (_: Exception) { false }

