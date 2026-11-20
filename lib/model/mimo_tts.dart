// 小米 MiMo 的 TTS 接口。
//
// 文档：`AGENTS/docs-mimo/tts-25.md`
//   POST https://api.xiaomimimo.com/v1/chat/completions
//   {"model":"mimo-v2.5-tts",
//    "messages":[{"role":"assistant","content":"要念的文本"}],
//    "audio":{"format":"wav","voice":"mimo_default"}}
//   回包在 choices[0].message.audio.data（base64）。
//
// 注意：**不是** `/audio/speech` 专用端点；目标文本必须放在 assistant 消息里。
// `mimo-v2.5-tts` 的 user 消息是可选的风格指令；`风格` 是增强功能，先不传。

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'network.dart';
import 'tts_http.dart';

import 'tts_types.dart';

/// MiMo 预置音色（来自官方文档的预置音色列表）。
const List<TtsVoice> kMimoTtsVoices = <TtsVoice>[
  TtsVoice(id: 'mimo_default', name: 'MiMo-默认', language: '随集群'),
  TtsVoice(id: '冰糖', name: '冰糖', language: '中文', gender: '女性'),
  TtsVoice(id: '茉莉', name: '茉莉', language: '中文', gender: '女性'),
  TtsVoice(id: '苏打', name: '苏打', language: '中文', gender: '男性'),
  TtsVoice(id: '白桦', name: '白桦', language: '中文', gender: '男性'),
  TtsVoice(id: 'Mia', name: 'Mia', language: '英文', gender: '女性'),
  TtsVoice(id: 'Chloe', name: 'Chloe', language: '英文', gender: '女性'),
  TtsVoice(id: 'Milo', name: 'Milo', language: '英文', gender: '男性'),
  TtsVoice(id: 'Dean', name: 'Dean', language: '英文', gender: '男性'),
];

class MimoTts {
  const MimoTts({this.base = 'https://api.xiaomimimo.com/v1'});

  final String base;

  static const Duration _timeout = Duration(seconds: 90);

  /// 合成一段文字。
  ///
  /// [format] 一般用 wav（非流式）；pcm16 是流式拼接用的，这里不做流式。
  Future<TtsResult> synthesize(
    String apiKey,
    String text, {
    required String model,
    required String voice,
    String format = 'wav',
    String? style,
    http.Client? client,
  }) async {
    final String t = text.trim();
    if (t.isEmpty) {
      return const TtsResult(ok: false, message: '要念的文本是空的');
    }
    final Map<String, Object?> body = <String, Object?>{
      'model': model,
      'messages': <Map<String, Object?>>[
        // 目标文本必须在 assistant 里；user 是可选的风格指令。
        if (style != null && style.trim().isNotEmpty)
          <String, Object?>{'role': 'user', 'content': style.trim()},
        <String, Object?>{'role': 'assistant', 'content': t},
      ],
      'audio': <String, Object?>{'format': format, 'voice': voice},
    };

    final http.Response r;
    try {
      r = await TtsHttp.postJson(
        client: client ?? NetworkRuntime.newClient(),
        uri: _uri('/chat/completions'),
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

    final Object? j = _decode(r.body);
    if (j is! Map) {
      return TtsResult(ok: false, message: '响应不是 JSON：${_short(r.body)}');
    }
    final Object? choices = j['choices'];
    if (choices is! List || choices.isEmpty) {
      return TtsResult(ok: false, message: '响应里没有 choices：${_short(r.body)}');
    }
    final Object? first = choices.first;
    final Object? message = first is Map ? first['message'] : null;
    final Object? audio = message is Map ? message['audio'] : null;
    final Object? data = audio is Map ? audio['data'] : null;
    final String raw = data == null ? '' : '$data';
    if (raw.trim().isEmpty) {
      return TtsResult(
        ok: false,
        message: '响应里没有音频数据（choices[0].message.audio.data 是空的）',
      );
    }

    Uint8List bytes;
    try {
      bytes = base64Decode(_stripDataUrl(raw));
    } catch (e) {
      return TtsResult(ok: false, message: '音频 base64 解不开：$e');
    }
    if (bytes.isEmpty) {
      return const TtsResult(ok: false, message: '解出来的音频是空的');
    }

    return TtsResult(
      ok: true,
      message: '合成好了（${bytes.length} 字节）',
      bytes: bytes,
      mimeType: _mimeOf(format),
      extension: format,
    );
  }

  // ————————————————————————————— 内部

  Uri _uri(String path) =>
      Uri.parse('${base.replaceAll(RegExp(r'/+$'), '')}$path');

  Map<String, String> _headers(String apiKey) => <String, String>{
    'Authorization': 'Bearer ${apiKey.trim()}',
    'Content-Type': 'application/json; charset=utf-8',
    'Accept': 'application/json',
  };

  /// 文档说 data 是纯 base64；有的代理会带 `data:audio/wav;base64,` 前缀。
  static String _stripDataUrl(String raw) {
    final String t = raw.trim();
    final int comma = t.indexOf(',');
    if (t.startsWith('data:') && comma >= 0) return t.substring(comma + 1);
    return t;
  }

  static String _mimeOf(String format) => switch (format) {
    'mp3' => 'audio/mpeg',
    'wav' => 'audio/wav',
    'pcm16' => 'audio/L16',
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
    if (detail.isEmpty && j is Map && j['message'] != null) {
      detail = '${j['message']}';
    }
    if (detail.isEmpty) detail = _short(body);
    final String hint =
        <int, String>{
          400: '请求格式不对',
          401: 'API Key 不对',
          403: '没权限用这个模型 / 音色',
          404: '地址或模型名不对',
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
