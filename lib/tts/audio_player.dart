// 内置 TTS 的播放：只播 WAV 文件。
//
// 不引第三方播放插件：Windows 走 winmm 的 PlaySound，Android 走 MediaPlayer，
// 由 `joenws/audio` 这条原生通道接。系统 TTS 是系统自己出声，不走这里。

import 'package:flutter/services.dart';

class BuiltinAudioPlayer {
  const BuiltinAudioPlayer();

  static const MethodChannel _channel = MethodChannel('joenws/audio');

  Future<void> play(String path) async {
    await _channel.invokeMethod<void>('play', <String, String>{'path': path});
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {
      // 非 Windows / Android（比如单元测试）没有这条通道，忽略。
    }
  }

  Future<void> pause() async {
    await _channel.invokeMethod<void>('pause');
  }

  Future<void> resume() async {
    await _channel.invokeMethod<void>('resume');
  }

  /// 当前播放位置与总时长；拿不到就返回 null。
  Future<({int positionMs, int durationMs})?> position() async {
    try {
      final Map<Object?, Object?>? m =
          await _channel.invokeMethod<Map<Object?, Object?>>('position');
      if (m == null) return null;
      return (
        positionMs: (m['positionMs'] as num?)?.toInt() ?? 0,
        durationMs: (m['durationMs'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}
