package io.github.ccch1mneyyy.dsh_app.files

import java.io.File
import java.io.InputStream
import java.nio.file.FileAlreadyExistsException
import java.nio.file.Files
import java.nio.file.StandardOpenOption.CREATE_NEW
import java.nio.file.StandardOpenOption.WRITE

/** Legacy Downloads: reserve the name and write through the same exclusive open.
 * The caller owns [source]; [name] has already passed FilesPlugin.safeName.
 */
internal object LegacyDownloads {
    fun copy(source: InputStream, directory: File, name: String): File {
        val dot = name.lastIndexOf('.').takeIf { it > 0 } ?: name.length
        val stem = name.substring(0, dot)
        val extension = name.substring(dot)
        var number = 1
        while (true) {
            val target = File(directory, if (number == 1) name else "$stem ($number)$extension")
            val output = try {
                Files.newOutputStream(target.toPath(), CREATE_NEW, WRITE)
            } catch (_: FileAlreadyExistsException) {
                number++
                continue
            }
            // No delete/reopen after reservation; another save must choose a
            // different name. Only a successful exclusive open owns cleanup.
            try {
                output.use { source.copyTo(it) }
                return target
            } catch (error: Throwable) {
                try {
                    Files.deleteIfExists(target.toPath())
                } catch (cleanup: Throwable) {
                    if (cleanup !== error) error.addSuppressed(cleanup)
                }
                throw error
            }
        }
    }
}
