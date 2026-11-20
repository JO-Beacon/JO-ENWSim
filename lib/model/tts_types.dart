// TTS（文本转语音）的共用类型。
//
// 各家的请求 / 响应形状不一样（OpenAI 的 `/audio/speech` 回的就是音频字节，
// MiMo 走 `chat/completions` 再从 JSON 里解 base64），但对上层只该有一副样子：
// `TtsVoice` / `TtsResult`。具体怎么发请求，各在各的文件里
// （`openai_tts.dart`、`mimo_tts.dart`），由 `tts_api.dart` 按服务商分发。

import 'dart:typed_data';

/// 念稿时用哪一类声音。
enum TtsSource {
  builtin('内置 TTS'),
  system('系统 TTS'),
  api('接口 TTS');

  const TtsSource(this.label);

  final String label;
}

/// 一个角色 / 世界 / 全局的 TTS 选择。
///
/// 空配置用 `null` 表示“继承下一层”，不要在这里造一个 inherit 枚举。
class TtsPick {
  const TtsPick({
    required this.source,
    this.providerId = '',
    this.voiceId = '',
    this.modelId = '',
  });

  final TtsSource source;

  /// 接口 TTS 的服务商 id；系统/内置为空。
  final String providerId;

  /// 具体音色 id；内置时可以是 sid，系统时是声音 id/名字。
  final String voiceId;

  /// 内置模型：melo / kokoro；接口时可选模型（如 tts-1）。
  final String modelId;

  String get key =>
      '${source.name}\u0000$providerId\u0000$voiceId\u0000$modelId';

  static TtsPick? of(String? raw) {
    final String key = (raw ?? '').trim();
    if (key.isEmpty) return null;
    final List<String> p = key.split('\u0000');
    if (p.length < 4) return null;
    TtsSource? source;
    for (final TtsSource s in TtsSource.values) {
      if (s.name == p[0]) source = s;
    }
    if (source == null) return null;
    return TtsPick(
      source: source,
      providerId: p[1],
      voiceId: p[2],
      modelId: p[3],
    );
  }

  bool get isEmpty =>
      providerId.trim().isEmpty &&
      voiceId.trim().isEmpty &&
      modelId.trim().isEmpty;
}

/// 内置模型的存活策略。
///
/// 用户明确要求：两个模型不能同时常驻；默认完全冷启动。
enum TtsLifecycle {
  coldStart('完全冷启动'),
  idleUnload('空闲卸载'),
  keepLoaded('常驻');

  const TtsLifecycle(this.label);

  final String label;
}

/// 一个音色。
///
/// **定义在服务里**（这家有哪些音色），角色那边只存“用哪个”（id）。
class TtsVoice {
  const TtsVoice({
    required this.id,
    required this.name,
    this.language = '',
    this.gender = '',
    this.networkRequired = false,
  });

  /// 调接口时传的 voice 值。
  final String id;

  /// 界面上显示的名字。
  final String name;

  /// 语言（中文 / 英文 / 多语种…）。不知道就空着。
  final String language;

  /// 性别。不知道就空着——**不猜**。
  final String gender;

  /// 是否必须联网（Android 的部分系统声音是这样）。
  /// 系统 TTS 试听优先挑不需要联网的。
  final bool networkRequired;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'language': language,
    'gender': gender,
    'networkRequired': networkRequired,
  };

  static TtsVoice? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final String id = '${raw['id'] ?? ''}'.trim();
    if (id.isEmpty) return null;
    final String name = '${raw['name'] ?? ''}'.trim();
    return TtsVoice(
      id: id,
      name: name.isEmpty ? id : name,
      language: '${raw['language'] ?? ''}'.trim(),
      gender: '${raw['gender'] ?? ''}'.trim(),
      networkRequired: raw['networkRequired'] == true,
    );
  }
}

/// 一次 TTS 合成。
class TtsResult {
  const TtsResult({
    required this.ok,
    required this.message,
    this.bytes,
    this.mimeType = '',
    this.extension = '',
  });

  final bool ok;

  /// 给人看的一句话（成功时是“合成好了”，失败时是原因）。
  final String message;

  /// 音频字节。失败时为 null。
  final Uint8List? bytes;

  /// 响应给的 MIME（如 `audio/mpeg`）。拿不到就按格式推。
  final String mimeType;

  /// 文件扩展名（如 `mp3` / `wav`），保存时用。
  final String extension;

  bool get hasAudio => ok && bytes != null && bytes!.isNotEmpty;
}
