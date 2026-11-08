package io.github.ccch1mneyyy.dsh_app.runtime

import io.github.ccch1mneyyy.dsh_app.phone.skills.PhoneSkillDraft
import java.io.File
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.FileAlreadyExistsException
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import java.nio.file.StandardOpenOption.CREATE_NEW
import java.nio.file.StandardOpenOption.WRITE

/** One explicit save of a rendered, immutable local draft. Never accepts Markdown from Flutter. */
internal class PhoneSkillWrite(val document: PhoneSkillDraft.Ready) {
    enum class Phase { STAGING, COMMITTING, FINISHED, CANCELLED }
    private var phase = Phase.STAGING
    private var outcome: PhoneSkillInstallResult? = null

    @Synchronized fun canStage(): Boolean = phase == Phase.STAGING
    @Synchronized fun phase(): Phase = phase

    /** Short permission boundary. File IO must run after this monitor is released. */
    @Synchronized fun beginCommit(): Boolean {
        if (phase != Phase.STAGING) return false
        phase = Phase.COMMITTING
        return true
    }

    /** Once committing, closing the editor is not a promise to undo a saved file. */
    @Synchronized fun cancel(): Boolean {
        if (phase != Phase.STAGING) return false
        phase = Phase.CANCELLED
        return true
    }

    @Synchronized fun finish(result: PhoneSkillInstallResult) {
        if (outcome != null) return
        outcome = result
        phase = Phase.FINISHED
    }

    @Synchronized fun result(): PhoneSkillInstallResult? = outcome
}

internal sealed interface PhoneSkillInstallResult {
    data class Saved(val name: String) : PhoneSkillInstallResult {
        val relativePath: String get() = "skills/$name/SKILL.md"
    }
    enum class Refused : PhoneSkillInstallResult { STALE, NO_HOME, CONFLICT, IO }
}

/**
 * A new user skill, on RuntimeController's rootfs worker. Never updates a managed/user directory.
 * The final directory is exclusively created; the finished SKILL.md is published with a hard
 * link, whose creation fails if that name already exists. ATOMIC_MOVE alone is not no-replace.
 * Root swaps share the worker; containment checks do not sandbox a hostile same-UID process
 * concurrently replacing parent directories (the same boundary as ManagedSkillInstaller).
 */
internal object PhoneSkillInstaller {
    fun install(
        root: File,
        document: PhoneSkillDraft.Ready,
        canStage: () -> Boolean,
        beginCommit: () -> Boolean,
    ): PhoneSkillInstallResult {
        var ownedDirectory: Path? = null
        var stagedFile: Path? = null
        var published = false
        try {
            if (!canStage()) return PhoneSkillInstallResult.Refused.STALE
            val rootPath = root.canonicalFile.toPath()
            val home = File(root, "root/.dsh").canonicalFile.toPath()
            if (!home.startsWith(rootPath) || !Files.isDirectory(home)) return PhoneSkillInstallResult.Refused.NO_HOME
            val skills = home.resolve("skills")
            try { Files.createDirectory(skills) } catch (_: FileAlreadyExistsException) {
                if (!Files.isDirectory(skills, NOFOLLOW_LINKS)) return PhoneSkillInstallResult.Refused.NO_HOME
            }
            val directory = skills.resolve(document.skillName)
            try { Files.createDirectory(directory) } catch (_: FileAlreadyExistsException) {
                return PhoneSkillInstallResult.Refused.CONFLICT
            }
            ownedDirectory = directory
            val stage = directory.resolve(".SKILL.tmp")
            FileChannel.open(stage, CREATE_NEW, WRITE).use { channel ->
                stagedFile = stage
                val bytes = ByteBuffer.wrap(document.markdown.toByteArray(Charsets.UTF_8))
                while (bytes.hasRemaining()) channel.write(bytes)
                channel.force(true)
            }
            // Runtime generation and the explicit draft permission are checked together here.
            if (!beginCommit()) return PhoneSkillInstallResult.Refused.STALE
            Files.createLink(directory.resolve("SKILL.md"), stage)
            published = true
            return PhoneSkillInstallResult.Saved(document.skillName)
        } catch (_: FileAlreadyExistsException) {
            return PhoneSkillInstallResult.Refused.CONFLICT
        } catch (_: Exception) {
            // No paths, content, tokens or filesystem exception text enter diagnostics.
            return PhoneSkillInstallResult.Refused.IO
        } finally {
            stagedFile?.let { runCatching { Files.deleteIfExists(it) } }
            // Delete only our empty directory. Never recursively remove another writer's files.
            if (!published) ownedDirectory?.let { runCatching { Files.delete(it) } }
        }
    }
}
