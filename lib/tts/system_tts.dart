// 系统 TTS：调操作系统自带的语音引擎。
//
// 三个名字要分清，别再用“本地”含糊带过：
//   · 系统 TTS —— 操作系统自带（Windows 的 SAPI / OneCore、Android 的 TextToSpeech），
//     不用 Key、不联网；就是本文件。
//   · 接口 TTS —— 服务商的在线 TTS API（`tts_api.dart`）。
//   · 内置 TTS —— 客户端自己捆一个神经网络模型（`builtin_tts.dart`）。
//
// 这一层只负责“让系统说话”：列声音、选声音、朗读、停。
// 不产生音频文件，也不走念稿模块——文本由调用方先准备好。

import 'package:flutter_tts/flutter_tts.dart';

import '../model/tts_types.dart';

/// 一次系统朗读的结果。
class SystemSpeakResult {
  const SystemSpeakResult({required this.ok, required this.message});

  final bool ok;
  final String message;
}

class SystemTts {
  SystemTts({FlutterTts? tts}) : _tts = tts ?? FlutterTts();

  /// 默认共用一份：系统 TTS 是全局的，多个实例会抢同一个播放器。
  static final SystemTts instance = SystemTts();

  final FlutterTts _tts;

  /// 系统里装了哪些声音。
  ///
  /// 平台不同，形状略有差异（Windows 给 identifier，Android 给 name + locale），
  /// 统一收成 [TtsVoice]。读不出来就抛，由界面如实显示，不假装“没有声音”。
  Future<List<TtsVoice>> voices() async {
    final dynamic raw = await _tts.getVoices;
    return parseVoices(raw);
  }

  /// 念一段文字。
  ///
  /// [awaitCompletion] 为真时，等整段念完才返回（设置页“试听”用）；
  /// 为假时，开始朗读就返回。
  Future<SystemSpeakResult> speak(
    String text, {
    TtsVoice? voice,
    double rate = 0.5,
    double pitch = 1.0,
    double volume = 1.0,
    bool awaitCompletion = true,
  }) async {
    final String t = text.trim();
    if (t.isEmpty) {
      return const SystemSpeakResult(ok: false, message: '要念的文本是空的');
    }
    try {
      await _tts.setSpeechRate(rate.clamp(0.0, 1.0));
      await _tts.setPitch(pitch);
      await _tts.setVolume(volume.clamp(0.0, 1.0));
      if (voice != null) {
        final dynamic found = await _tts.setVoice(<String, String>{
          'name': voice.name,
          'locale': voice.language,
        });
        if (found == 0) {
          return SystemSpeakResult(
            ok: false,
            message: '系统里找不到这个声音：${voice.name}',
          );
        }
      }
      await _tts.awaitSpeakCompletion(awaitCompletion);
      final dynamic r = await _tts.speak(t);
      if (r == 0) {
        return const SystemSpeakResult(ok: false, message: '系统 TTS 没有开始朗读');
      }
      return SystemSpeakResult(
        ok: true,
        message: awaitCompletion ? '朗读完了' : '开始朗读',
      );
    } catch (e) {
      return SystemSpeakResult(ok: false, message: '系统 TTS 调用失败：$e');
    }
  }

  /// 停止当前朗读（没有在念就什么也不做）。
  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {
      // 平台没有这条通道时忽略；调用方不需要为此报错。
    }
  }

  /// 把 `flutter_tts.getVoices` 的原始结果收成 [TtsVoice]。
  ///
  /// 抽成静态方法是为了能单独测：平台返回的 Map 形状不稳定，
  /// 这里把能认出来的字段认掉，认不出的不猜。
  static List<TtsVoice> parseVoices(Object? raw) {
    if (raw is! List) return const <TtsVoice>[];
    final List<TtsVoice> out = <TtsVoice>[];
    final Set<String> seen = <String>{};
    for (final Object? item in raw) {
      if (item is! Map) continue;
      final String name = '${item['name'] ?? ''}'.trim();
      if (name.isEmpty) continue;
      final String locale = '${item['locale'] ?? item['language'] ?? ''}'
          .trim();
      final String identifier = '${item['identifier'] ?? ''}'.trim();
      final String id = identifier.isEmpty ? '$name|$locale' : identifier;
      // 同一平台有时给 identifier、有时不给；按“名字 + 语言”去重更稳。
      if (!seen.add('$name|$locale')) continue;
      // Android 会带 features；标了 notInstalled 的声音念不出来，别列。
      final String features = '${item['features'] ?? ''}';
      if (features.split('\t').contains('notInstalled')) continue;
      final String gender = switch ('${item['gender'] ?? ''}'.toLowerCase()) {
        'male' => '男性',
        'female' => '女性',
        _ => '',
      };
      out.add(
        TtsVoice(
          id: id,
          name: name,
          language: locale,
          gender: gender,
          networkRequired: '${item['network_required'] ?? ''}' == '1',
        ),
      );
    }
    return out;
  }
}
