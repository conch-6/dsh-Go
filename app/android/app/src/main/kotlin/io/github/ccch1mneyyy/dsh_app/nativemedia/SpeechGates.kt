package io.github.ccch1mneyyy.dsh_app.nativemedia

import android.content.res.AssetManager
import android.util.Log

/** The models ship in the APK; where ONNX Runtime cannot load them, the energy gate does the work. */
object SpeechGates {
    fun create(assets: AssetManager, echoCancelled: Boolean): TurnGate {
        var vad: OrtSilero? = null
        var turn: OrtSmartTurn? = null
        try {
            vad = OrtSilero(load(assets, "silero_vad.onnx"))
            turn = OrtSmartTurn(load(assets, "smart-turn-v3.2-cpu.onnx"))
            // Initialize the streaming VAD; smart-turn runs only on its worker.
            vad.probability(ShortArray(512))
            vad.reset()
            return NeuralGate(vad, turn, echoCancelled, onTurnFailed = {
                Log.w("SpeechGates", "Turn model failed; pauses end after the energy gate's hangover", it)
            })
        } catch (_: Exception) {
            Log.w("SpeechGates", "Neural models unavailable; using energy gate")
        } catch (_: LinkageError) {
            Log.w("SpeechGates", "ONNX Runtime unavailable; using energy gate")
        }
        turn?.close()
        vad?.close()
        return SpeechGate(echoCancelled)
    }

    private fun load(assets: AssetManager, name: String): ByteArray = assets.open("speech/$name").use { it.readBytes() }
}
