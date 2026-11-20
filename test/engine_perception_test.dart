import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/engine/perception.dart';

NarrativeScene buildScene() {
  return NarrativeScene(
    place: '东门内侧',
    names: <String, String>{
      'char:信标': '信标',
      'char:灵梦': '灵梦',
      'char:艾琳': '艾琳',
      'char:魔理沙': '魔理沙',
      'char:慧音': '慧音',
    },
    cast: <CharacterSnapshot>[
      CharacterSnapshot(
        id: 'char:信标',
        name: '信标',
        nearby: true,
        aliases: <String, String>{
          'char:灵梦': '巫女',
          'char:艾琳': '联邦女人',
          'char:魔理沙': '魔理沙',
          'char:慧音': '慧音',
        },
      ),
      CharacterSnapshot(
        id: 'char:灵梦',
        name: '灵梦',
        nearby: true,
        aliases: <String, String>{
          'char:信标': '那个黑铁壳子',
          'char:艾琳': '那个受伤的联邦女人',
          'char:魔理沙': '魔理沙',
          'char:慧音': '慧音',
        },
      ),
      CharacterSnapshot(
        id: 'char:艾琳',
        name: '艾琳',
        nearby: true,
        aliases: <String, String>{
          'char:信标': '探险家',
          'char:灵梦': '巫女',
          'char:魔理沙': '魔理沙',
          'char:慧音': '慧音老师',
        },
      ),
      CharacterSnapshot(
        id: 'char:魔理沙',
        name: '魔理沙',
        nearby: false,
        aliases: <String, String>{
          'char:信标': '黑铁甲',
          'char:灵梦': '灵梦',
          'char:艾琳': '那个联邦女人',
          'char:慧音': '慧音',
        },
      ),
      CharacterSnapshot(
        id: 'char:慧音',
        name: '慧音',
        nearby: false,
        aliases: <String, String>{
          'char:信标': '那个青年',
          'char:灵梦': '灵梦',
          'char:艾琳': '那位姑娘',
          'char:魔理沙': '魔理沙',
        },
      ),
    ],
  );
}

WorldEvent buildEvent({
  required Audience audience,
  DeliveryChannel channel = DeliveryChannel.voice,
  String? target = 'char:艾琳',
  List<String> linkMembers = const <String>[],
  String deliveryNote = '',
  String distanceNote = '',
}) {
  return WorldEvent(
    id: 'E1',
    kind: WorldEventKind.speech,
    content: '别小瞧任何你不了解的文明。',
    actor: 'char:信标',
    target: target,
    delivery: Delivery(
      channel: channel,
      form: 'spoken',
      audience: audience,
    ),
    linkMembers: linkMembers,
    deliveryNote: deliveryNote,
    distanceNote: distanceNote,
  );
}

void main() {
  group('PerceptionEngine', () {
    final NarrativeScene scene = buildScene();
    const PerceptionEngine engine = PerceptionEngine();

    test('scene 让同场所有人看见', () {
      final List<Witness> ws = engine.witnesses(
        buildEvent(audience: Audience.scene),
        scene,
      );
      expect(ws.length, 5);
      final Witness marisa =
          ws.firstWhere((Witness w) => w.characterId == 'char:魔理沙');
      expect(marisa.content, contains('黑铁甲'));
      expect(marisa.content, contains('那个联邦女人'));
      expect(marisa.content, isNot(contains('信标')));
      expect(marisa.content, isNot(contains('艾琳')));
    });

    test('nearby 只给 same/near', () {
      final List<Witness> ws = engine.witnesses(
        buildEvent(audience: Audience.nearby),
        scene,
      );
      expect(ws.map((Witness w) => w.characterId).toSet(),
          <String>{'char:信标', 'char:灵梦', 'char:艾琳'});
    });

    test('target 只给目标', () {
      final List<Witness> ws = engine.witnesses(
        buildEvent(audience: Audience.target, target: 'char:艾琳'),
        scene,
      );
      expect(ws.length, 1);
      expect(ws.single.characterId, 'char:艾琳');
    });

    test('link 只给 linkMembers', () {
      final List<Witness> ws = engine.witnesses(
        buildEvent(
          audience: Audience.link,
          channel: DeliveryChannel.mental,
          linkMembers: <String>['char:信标', 'char:灵梦'],
        ),
        scene,
      );
      expect(ws.map((Witness w) => w.characterId).toSet(),
          <String>{'char:信标', 'char:灵梦'});
    });

    test('hidden 和 unknown 都不产生感知', () {
      expect(
        engine.witnesses(buildEvent(audience: Audience.hidden), scene),
        isEmpty,
      );
      expect(
        engine.witnesses(buildEvent(audience: Audience.unknown), scene),
        isEmpty,
      );
    });

    test('localize 不泄漏系统名', () {
      final CharacterSnapshot keine = scene.byId('char:慧音')!;
      expect(
        engine.localize('信标看向艾琳', keine, scene),
        '那个青年看向那位姑娘',
      );
    });
  });

  group('canonicalize', () {
    final NarrativeScene scene = buildScene();

    test('把各种称呼换回规范名', () {
      expect(canonicalize('慧音站到灵梦和那个青年之间', scene),
          '慧音站到灵梦和信标之间');
      expect(canonicalize('慧音老师看向那位姑娘', scene), '慧音看向艾琳');
      expect(canonicalize('探险家把目光转向了巫女', scene), '信标把目光转向了灵梦');
      expect(canonicalize('黑铁甲对那个联邦女人说', scene), '信标对艾琳说');
      expect(canonicalize('那个受伤的联邦女人没有动', scene), '艾琳没有动');
    });
  });

}
