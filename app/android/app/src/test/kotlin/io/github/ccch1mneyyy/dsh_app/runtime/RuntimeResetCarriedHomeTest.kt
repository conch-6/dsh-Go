package io.github.ccch1mneyyy.dsh_app.runtime

import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class RuntimeResetCarriedHomeTest {
    private val skill = "root/.dsh/skills/mine/SKILL.md"
    private val profile = "root/.dsh/profiles/web/package.json"
    private fun write(base: File, path: String, text: String) {
        File(base, path).apply { parentFile!!.mkdirs() }.writeText(text)
    }

    @Test fun resetKeepsAuthoritativeCarryAtEveryInterruptedUpgradeStage() {
        for (stage in 0..2) {
            val files = Files.createTempDirectory("reset-carried-home").toFile()
            try {
                val base = File(files, "runtime")
                write(base, "home.carry/${skill.removePrefix("root/")}", "user skill")
                write(base, "home.carry/${profile.removePrefix("root/")}", "user profile")
                write(base, "home.carry/workspace/private", "delete this")
                when (stage) {
                    0 -> write(base, "rootfs/bin/old", "old")
                    1 -> write(base, "rootfs.old/bin/old", "old")
                    2 -> {
                        write(base, "rootfs.old/bin/old", "old")
                        write(base, "rootfs/$skill", "fresh skill")
                        write(base, "rootfs/$profile", "fresh profile")
                    }
                }
                val retired = File(files, "runtime.reset")
                val keep = File(files, "runtime-keep")
                retireRuntime(base, retired, keep, ResetKeep.ALL)
                assertEquals("stage $stage", "user skill", File(keep, skill).readText())
                assertEquals("stage $stage", "user profile", File(keep, profile).readText())
                assertFalse(File(keep, "root/workspace/private").exists())
                assertFalse(retired.exists())
                assertFalse(base.exists())
            } finally { files.deleteRecursively() }
        }
    }

    @Test fun resumedResetContinuesMovingFromCarryAndPreservesAlreadyKeptCopy() {
        val files = Files.createTempDirectory("reset-carried-resume").toFile()
        try {
            val retired = File(files, "runtime.reset")
            val keep = File(files, "runtime-keep")
            write(retired, "reset.keep", ResetKeep.ALL.joinToString("\n"))
            write(keep, skill, "earlier kept skill")
            write(retired, "home.carry/${skill.removePrefix("root/")}", "do not replace kept")
            write(retired, "home.carry/${profile.removePrefix("root/")}", "user profile")
            write(retired, "rootfs/$profile", "fresh profile")
            settleReset(retired, keep)
            assertEquals("earlier kept skill", File(keep, skill).readText())
            assertEquals("user profile", File(keep, profile).readText())
            assertFalse(retired.exists())
        } finally { files.deleteRecursively() }
    }

    @Test fun emptyChoiceStillDeletesCarryAndPreviouslyKeptData() {
        val files = Files.createTempDirectory("reset-carried-empty").toFile()
        try {
            val base = File(files, "runtime")
            val retired = File(files, "runtime.reset")
            val keep = File(files, "runtime-keep")
            write(base, "home.carry/${skill.removePrefix("root/")}", "user skill")
            write(keep, profile, "previously kept")
            retireRuntime(base, retired, keep, emptyList())
            assertFalse(base.exists())
            assertFalse(retired.exists())
            assertFalse(keep.exists())
        } finally { files.deleteRecursively() }
    }

    @Test fun completedCarryUsesNormalRootfsHome() {
        val files = Files.createTempDirectory("reset-carried-complete").toFile()
        try {
            val base = File(files, "runtime")
            val keep = File(files, "runtime-keep")
            write(base, "rootfs/$skill", "restored user skill")
            retireRuntime(base, File(files, "runtime.reset"), keep, ResetKeep.UI_AND_SKILLS.paths)
            assertEquals("restored user skill", File(keep, skill).readText())
        } finally { files.deleteRecursively() }
    }
    @Test fun missingCarriedPathDoesNotFallBackToFreshSkeleton() {
        val files = Files.createTempDirectory("reset-carried-missing").toFile()
        try {
            val base = File(files, "runtime")
            val keep = File(files, "runtime-keep")
            write(base, "home.carry/workspace/private", "not selected")
            write(base, "rootfs/$skill", "fresh skeleton is not user data")
            retireRuntime(base, File(files, "runtime.reset"), keep, ResetKeep.UI_AND_SKILLS.paths)
            assertFalse(File(keep, skill).exists())
        } finally { files.deleteRecursively() }
    }

}
