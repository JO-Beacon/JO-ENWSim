import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/engine/c_writer.dart';
import 'package:joenws/engine/perception.dart';

NarrativeScene scene() {
  return NarrativeScene(
    place: '东门内侧',
    names: <String, String>{'char:信标': '信标', 'char:艾琳': '艾琳'},
    cast: <CharacterSnapshot>[
      CharacterSnapshot(id: 'char:信标', name: '信标', nearby: true),
      CharacterSnapshot(id: 'char:艾琳', name: '艾琳', nearby: true),
    ],
  );
}

void main() {
  test('C 抽取 segments 和 state_delta', () {
    final CExtracted result = const CWriter().extract(<String, Object?>{
      'segments': <Object?>[
        <String, Object?>{
          'kind': 'speech',
          'text': '别动。',
          'target': 'char:艾琳',
        },
      ],
      'state_delta': <String, Object?>{
        'move': <String, Object?>{'艾琳': '仓房'},
      },
    });
    expect(result.segments.single['text'], '别动。');
    expect(result.delta.moves['艾琳'], '仓房');
  });

  test('C 校验拒绝未知 target / unknown audience', () {
    const WorldEvent bad = WorldEvent(
      id: 'E1',
      kind: WorldEventKind.speech,
      content: '别动。',
      actor: 'char:信标',
      target: 'char:不存在',
      delivery: Delivery(
        channel: DeliveryChannel.voice,
        form: 'spoken',
        audience: Audience.unknown,
      ),
    );
    final List<CValidationError> errors =
        const CWriter().validate(bad, scene());
    expect(errors.any((e) => e.code == 'unknown_target'), isTrue);
    expect(errors.any((e) => e.code == 'unknown_audience'), isTrue);
  });

  test('C 拒绝只有台词却带 effects 的事件', () {
    const WorldEvent bad = WorldEvent(
      id: 'E2',
      kind: WorldEventKind.speech,
      content: '我没事。',
      actor: 'char:信标',
      target: 'char:艾琳',
      delivery: Delivery(
        channel: DeliveryChannel.voice,
        form: 'spoken',
        audience: Audience.scene,
      ),
      effects: <Map<String, Object?>>[
        <String, Object?>{'kind': 'move', 'who': '信标', 'to': '仓房'},
      ],
    );
    final List<CValidationError> errors =
        const CWriter().validate(bad, scene());
    expect(errors.any((e) => e.code == 'effects_without_action'), isTrue);
  });
}
