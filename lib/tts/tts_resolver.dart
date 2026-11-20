import '../model/demo.dart';
import '../model/tts_types.dart';
import '../theme/tokens.dart';

/// 角色 → 世界 → 全局的 TTS 解析。
///
/// 只处理“有没有配置”；不检查服务商/模型是否可用。可用性由调用方
/// 在真正发声时判断，失败直接报错，不换声线。
class TtsResolver {
  const TtsResolver();

  TtsPick resolve({
    required String speaker,
    required World world,
    required JoSettings settings,
  }) {
    final String name = _canonicalName(speaker);
    if (name.isEmpty || name == '旁白') {
      final TtsPick? narrator = TtsPick.of(world.narratorTtsKey);
      if (narrator != null) return narrator;
    }
    if (name.isNotEmpty) {
      for (final CharCard c in world.characters) {
        if (c.name.trim() != name) continue;
        final TtsPick? own = TtsPick.of(c.ttsKey);
        if (own != null) return own;
        break;
      }
    }
    final TtsPick? worldPick = TtsPick.of(world.ttsKey);
    if (worldPick != null) return worldPick;
    return settings.globalTts;
  }

  String _canonicalName(String speaker) {
    final String s = speaker.trim();
    if (s.startsWith('char:')) return s.substring(5).trim();
    return s;
  }
}
