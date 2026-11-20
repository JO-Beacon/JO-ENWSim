// 接口 TTS：服务商的在线 TTS API。
//
//   · OpenAI（真 OpenAI，含 /v1/audio/speech 形状）：`openai_tts.dart`
//   · 小米 MiMo（chat/completions + audio 参数）：`mimo_tts.dart`
//
// 另外两条路不在这里：
//   · 系统 TTS —— 操作系统自带，见 `lib/tts/system_tts.dart`；
//   · 内置 TTS —— 客户端自己捆模型，见 `lib/tts/builtin_tts.dart`。
// 三个词各有明确所指，不要用“本地”混着说。
//
// 其余几家（ElevenLabs / MiniMax / 火山 / Azure / 讯飞）请求形状各不相同，
// 认不出来就**如实说没接**，别拿 OpenAI 的形状硬套。

import 'dart:async';

import 'package:http/http.dart' as http;

import 'mimo_tts.dart';
import 'openai_tts.dart';
import 'provider.dart';
import 'tts_types.dart';

export 'tts_types.dart';

/// 同一服务商的 TTS 请求串行化，避免预取和正文朗读同时打同一条接口。
class TtsRateLimiter {
  TtsRateLimiter._();

  static final Map<String, Future<void>> _tails = <String, Future<void>>{};

  static Future<T> run<T>(String key, Future<T> Function() task) async {
    final Future<void> previous = _tails[key] ?? Future<void>.value();
    final Completer<void> done = Completer<void>();
    _tails[key] = done.future;
    await previous;
    try {
      return await task();
    } finally {
      done.complete();
      if (identical(_tails[key], done.future)) _tails.remove(key);
    }
  }
}

enum TtsVendor { openai, mimo, unknown }

/// 按服务商挑实现。
class TtsService {
  const TtsService(this.provider);

  final Provider provider;

  TtsVendor get vendor {
    final String base = _base.toLowerCase();
    if (base.contains('xiaomimimo')) return TtsVendor.mimo;
    if (provider.protocol.isOpenAi || base.contains('api.openai.com')) {
      return TtsVendor.openai;
    }
    return TtsVendor.unknown;
  }

  /// 这家有哪些音色。用户编辑过就用用户清单，否则用内置预设；
  /// 没接的返回空清单（界面据此如实显示）。
  List<TtsVoice> get voices {
    if (provider.voices.isNotEmpty) return provider.voices;
    return switch (vendor) {
      TtsVendor.openai => kOpenAiTtsVoices,
      TtsVendor.mimo => kMimoTtsVoices,
      TtsVendor.unknown => const <TtsVoice>[],
    };
  }

  String get defaultModel => switch (vendor) {
    TtsVendor.openai => 'tts-1',
    TtsVendor.mimo => 'mimo-v2.5-tts',
    TtsVendor.unknown => '',
  };

  String get defaultVoice => switch (vendor) {
    TtsVendor.openai => 'alloy',
    TtsVendor.mimo => 'mimo_default',
    TtsVendor.unknown => '',
  };

  String get defaultFormat => switch (vendor) {
    TtsVendor.openai => 'mp3',
    TtsVendor.mimo => 'wav',
    TtsVendor.unknown => '',
  };

  /// 合成一段文字。
  ///
  /// [model] / [voice] / [format] 不传就用这家的默认值。返回的
  /// [TtsResult.bytes] 是音频本体；落文件由 `lib/tts/tts_file.dart` 负责。
  Future<TtsResult> synthesize(
    String text, {
    String? model,
    String? voice,
    String? format,
    double? speed,
    String? style,
    http.Client? client,
  }) {
    final String t = text.trim();
    if (t.isEmpty) {
      return Future<TtsResult>.value(
        const TtsResult(ok: false, message: '要念的文本是空的'),
      );
    }
    final String m = _pick(model, defaultModel);
    final String v = _pick(voice, defaultVoice);
    final String f = _pick(format, defaultFormat);
    final String base = _base;

    return TtsRateLimiter.run(provider.id, () {
      switch (vendor) {
        case TtsVendor.openai:
          return OpenAiTts(base: base).synthesize(
            provider.apiKey,
            t,
            model: m,
            voice: v,
            format: f,
            speed: speed,
            style: style,
            client: client,
          );
        case TtsVendor.mimo:
          return MimoTts(base: base).synthesize(
            provider.apiKey,
            t,
            model: m,
            voice: v,
            format: f,
            style: style,
            client: client,
          );
        case TtsVendor.unknown:
          return Future<TtsResult>.value(
            const TtsResult(ok: false, message: '这家 TTS 接口还没接：只知道地址，不知道请求形状。'),
          );
      }
    });
  }

  String get _base {
    final String b = provider.baseUrl.trim().isEmpty
        ? provider.protocol.baseUrl
        : provider.baseUrl.trim();
    return b.replaceAll(RegExp(r'/+$'), '');
  }

  static String _pick(String? value, String fallback) {
    final String t = (value ?? '').trim();
    return t.isEmpty ? fallback : t;
  }
}
