// OpenAI 的 TTS 接口。
//
// 文档（OpenAI 官方）：
//   POST https://api.openai.com/v1/audio/speech
//   Authorization: Bearer <api key>
//   {"model":"tts-1","input":"...","voice":"alloy","response_format":"mp3"}
//   2xx 直接回音频字节（不是 JSON）。
//
// 只做这一种形状。ElevenLabs / MiniMax / 火山 / Azure / 讯飞 各有各的请求形状，
// 不在这里硬套——认不出来就如实说没接（`tts_api.dart` 里分发）。

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'network.dart';
import 'tts_http.dart';

import 'tts_types.dart';

/// OpenAI 预置音色（tts-1 系列）。
///
/// 官方只给名字，没给语言 / 性别，所以这两栏**空着**，不猜。
const List<TtsVoice> kOpenAiTtsVoices = <TtsVoice>[
  TtsVoice(id: 'alloy', name: 'Alloy'),
  TtsVoice(id: 'echo', name: 'Echo'),
  TtsVoice(id: 'fable', name: 'Fable'),
  TtsVoice(id: 'onyx', name: 'Onyx'),
  TtsVoice(id: 'nova', name: 'Nova'),
  TtsVoice(id: 'shimmer', name: 'Shimmer'),
];

class OpenAiTts {
  const OpenAiTts({this.base = 'https://api.openai.com/v1'});

  final String base;

  static const Duration _timeout = Duration(seconds: 60);

  /// 合成一段文字。
  ///
  /// [format] 用接口的原名：mp3 / opus / aac / flac / wav / pcm。
  Future<TtsResult> synthesize(
    String apiKey,
    String text, {
    required String model,
    required String voice,
    String format = 'mp3',
    double? speed,
    String? style,
    http.Client? client,
  }) async {
    final String t = text.trim();
    if (t.isEmpty) {
      return const TtsResult(ok: false, message: '要念的文本是空的');
    }
    final Map<String, Object?> body = <String, Object?>{
      'model': model,
      'input': t,
      'voice': voice,
      'response_format': format,
      if (speed != null) 'speed': speed.clamp(0.25, 4.0),
      if (style != null &&
          style.trim().isNotEmpty &&
          !model.startsWith('tts-1'))
        'instructions': style.trim(),
    };

    final http.Response r;
    try {
      r = await TtsHttp.postJson(
        client: client ?? NetworkRuntime.newClient(),
        uri: _uri('/audio/speech'),
        headers: _headers(apiKey),
        body: body,
        timeout: _timeout,
      );
    } catch (e) {
      return TtsResult(ok: false, message: '请求失败：$e');
    }

    if (r.statusCode < 200 || r.statusCode >= 300) {
      return TtsResult(ok: false, message: _httpMessage(r.statusCode, r.body));
    }

    // 正常是音频字节；个别代理出错时仍回 200 + JSON，这里认出来并说清楚。
    final String contentType = (r.headers['content-type'] ?? '').toLowerCase();
    if (contentType.contains('application/json')) {
      return TtsResult(ok: false, message: '接口回了 JSON 而不是音频：${_short(r.body)}');
    }

    final Uint8List bytes = r.bodyBytes;
    if (bytes.isEmpty) {
      return const TtsResult(ok: false, message: '响应是空的（没有音频字节）');
    }
    final String mime = contentType.split(';').first.trim();
    return TtsResult(
      ok: true,
      message: '合成好了（${bytes.length} 字节）',
      bytes: bytes,
      mimeType: mime.isEmpty ? _mimeOf(format) : mime,
      extension: format,
    );
  }

  // ————————————————————————————— 内部

  Uri _uri(String path) =>
      Uri.parse('${base.replaceAll(RegExp(r'/+$'), '')}$path');

  Map<String, String> _headers(String apiKey) => <String, String>{
    'Authorization': 'Bearer ${apiKey.trim()}',
    // 与搜索那边同一个坑：不写 charset 时 http 包按 latin1 编请求体，中文会炸。
    'Content-Type': 'application/json; charset=utf-8',
    'Accept': 'audio/*',
  };

  static String _mimeOf(String format) => switch (format) {
    'mp3' => 'audio/mpeg',
    'opus' => 'audio/ogg',
    'aac' => 'audio/aac',
    'flac' => 'audio/flac',
    'wav' => 'audio/wav',
    'pcm' => 'audio/L16',
    _ => 'application/octet-stream',
  };

  static Object? _decode(String body) {
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }

  static String _httpMessage(int code, String body) {
    final Object? j = _decode(body);
    String detail = '';
    if (j is Map && j['error'] is Map) {
      final Object? m = (j['error'] as Map)['message'];
      if (m != null) detail = '$m';
    }
    if (detail.isEmpty) detail = _short(body);
    final String hint =
        <int, String>{
          400: '请求格式不对',
          401: 'API Key 不对',
          403: '没权限用这个模型 / 音色',
          404: '地址或模型名不对',
          413: '输入太长',
          429: '请求太快或额度用完了，等一会儿再试',
          500: '服务端出错，可以重试',
          502: '网关出错，可以重试',
          503: '服务忙，等一会儿再试',
        }[code] ??
        '请求失败';
    return 'HTTP $code · $hint：$detail';
  }

  static String _short(String s) {
    final String t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isEmpty) return '（空的响应）';
    return t.length > 200 ? '${t.substring(0, 200)}…' : t;
  }
}
