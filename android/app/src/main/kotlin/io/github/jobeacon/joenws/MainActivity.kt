package io.github.jobeacon.joenws

import android.media.MediaPlayer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var player: MediaPlayer? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "joenws/audio")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "play" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.error("bad_args", "path is missing", null)
                            return@setMethodCallHandler
                        }
                        try {
                            player?.release()
                            val p = MediaPlayer()
                            p.setDataSource(path)
                            p.setOnCompletionListener { done ->
                                done.release()
                                if (player === done) player = null
                            }
                            p.prepare()
                            p.start()
                            player = p
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("play_failed", e.message, null)
                        }
                    }
                    "pause" -> {
                        try {
                            player?.pause()
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("pause_failed", e.message, null)
                        }
                    }
                    "resume" -> {
                        try {
                            player?.start()
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("resume_failed", e.message, null)
                        }
                    }
                    "position" -> {
                        val p = player
                        if (p == null) {
                            result.success(null)
                        } else {
                            try {
                                result.success(
                                    mapOf(
                                        "positionMs" to p.currentPosition,
                                        "durationMs" to p.duration,
                                    ),
                                )
                            } catch (e: Exception) {
                                result.error("position_failed", e.message, null)
                            }
                        }
                    }
                    "stop" -> {
                        try {
                            player?.stop()
                        } catch (_: Exception) {
                        }
                        player?.release()
                        player = null
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        player?.release()
        player = null
        super.onDestroy()
    }
}
