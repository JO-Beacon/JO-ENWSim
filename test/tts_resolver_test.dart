import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/model/demo.dart';
import 'package:joenws/model/tts_types.dart';
import 'package:joenws/theme/tokens.dart';
import 'package:joenws/tts/tts_resolver.dart';

void main() {
  const TtsPick charPick = TtsPick(
    source: TtsSource.api,
    providerId: 'p-char',
    voiceId: 'v-char',
    modelId: 'tts-1',
  );
  const TtsPick worldPick = TtsPick(
    source: TtsSource.system,
    voiceId: 'world-voice',
  );
  const TtsPick globalPick = TtsPick(
    source: TtsSource.builtin,
    modelId: 'melo',
    voiceId: '0',
  );

  World world({String worldTts = ''}) => World(
    id: 'w',
    name: 'w',
    note: '',
    setting: '',
    opening: '',
    characters: <CharCard>[
      CharCard(name: '甲', persona: '', ttsKey: charPick.key),
      CharCard(name: '乙', persona: ''),
    ],
    parallelPlaces: const <ParallelPlace>[],
    moves: const <MoveLink>[],
    ttsKey: worldTts,
  );

  const JoSettings settings = JoSettings();

  test('角色 > 世界 > 全局', () {
    final TtsResolver r = const TtsResolver();
    expect(
      r
          .resolve(
            speaker: 'char:甲',
            world: world(worldTts: worldPick.key),
            settings: settings,
          )
          .key,
      charPick.key,
    );
    expect(
      r
          .resolve(
            speaker: '乙',
            world: world(worldTts: worldPick.key),
            settings: settings,
          )
          .key,
      worldPick.key,
    );
    expect(
      r.resolve(speaker: '乙', world: world(), settings: settings).key,
      globalPick.key,
    );
  });

  test('旁白跳过角色，直接走世界/全局', () {
    final TtsResolver r = const TtsResolver();
    expect(
      r
          .resolve(
            speaker: '',
            world: world(worldTts: worldPick.key),
            settings: settings,
          )
          .key,
      worldPick.key,
    );
    expect(
      r.resolve(speaker: '旁白', world: world(), settings: settings).key,
      globalPick.key,
    );
  });

  test('旁白专属 TTS 优先于世界默认', () {
    const TtsPick narratorPick = TtsPick(
      source: TtsSource.builtin,
      modelId: 'kokoro',
      voiceId: '1',
    );
    final World withNarrator = world(
      worldTts: worldPick.key,
    ).copyWith(narratorTtsKey: narratorPick.key);
    expect(
      const TtsResolver()
          .resolve(speaker: '', world: withNarrator, settings: settings)
          .key,
      narratorPick.key,
    );
    expect(
      const TtsResolver()
          .resolve(speaker: '甲', world: withNarrator, settings: settings)
          .key,
      charPick.key,
    );
  });

  test('TtsPick key 往返不丢字段', () {
    expect(TtsPick.of(charPick.key)?.key, charPick.key);
    expect(TtsPick.of(''), isNull);
    expect(TtsPick.of('bad'), isNull);
  });
}
