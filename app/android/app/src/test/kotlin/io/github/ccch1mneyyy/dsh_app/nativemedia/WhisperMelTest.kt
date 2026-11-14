package io.github.ccch1mneyyy.dsh_app.nativemedia

import org.junit.Assert.assertEquals
import org.junit.Test

class WhisperMelTest {
    @Test fun matchesNumpyForSilenceLeftPaddingAndVaryingSignal() {
        val frontend = WhisperMel()
        val rows = javaClass.getResourceAsStream("/speech/whisper_mel.csv")!!
            .bufferedReader().use { reader -> reader.readLines().filterNot { it.startsWith("#") } }
            .groupBy { it.substringBefore(',') }
        for ((name, references) in rows) {
            val audio = FloatArray(WhisperMel.SAMPLES) { i ->
                when (name) {
                    "padded" -> if (i < 96000) 0f else ((i * 7919L % 65536) - 32768).toFloat() / 32768f
                    "varying" -> ((i * 97L % 4096) - 2048).toFloat() * (i / 1600 % 7 + 1) / 32768f + 0.125f
                    else -> 0f
                }
            }
            if (name == "padded") audio[audio.lastIndex] = 0.75f
            val actual = frontend.compute(audio)
            assertEquals(80 * 800, actual.size)
            for (row in references) {
                val fields = row.split(',')
                val band = fields[1].toInt()
                val time = fields[2].toInt()
                assertEquals("$name mel=$band frame=$time", fields[3].toFloat(), actual[band * 800 + time], 2e-5f)
            }
        }
    }
}
