// 022 演示场景：给工作区的“引擎”入口用。
//
// 这是固定 fixture，不是正式世界适配。正式版应从 WorldStore 读地点/角色/别名；
// 这里先把 022 第一回合的场景、记忆和玩家事件摆好，让 UI 能跑通整条链路。

import 'character_memory.dart';
import 'perception.dart';

class Demo022 {
  const Demo022._();

  static const List<String> npcNames = <String>['灵梦', '艾琳', '魔理沙', '慧音'];
  static const String playerName = '信标';

  static NarrativeScene scene() {
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

  static List<CharacterMemory> seedMemory() {
    final String now = DateTime.now().toIso8601String();
    CharacterMemory note(String name, String text) => CharacterMemory(
          id: newCharacterMemoryId(),
          characterId: 'char:$name',
          text: text,
          kind: MemoryKind.note,
          origin: MemoryOrigin.manual,
          createdAt: now,
          updatedAt: now,
        );
    return <CharacterMemory>[
      note('灵梦', '妹红留在村外看守残骸和尸体。'),
      note('灵梦', '慧音是寺子屋的老师。'),
      note('灵梦', '那个黑铁壳子是今天掉进村子的外来人，救了艾琳，打碎了棘星体。'),
      note('艾琳', '我的三个队员死了；飞艇记录仪在残骸里。'),
      note('艾琳', '我的左腿受伤。'),
      note('魔理沙', '那个黑铁甲就是刚才在天上打碎棘星体的人。'),
      note('慧音', '妹红留在村外看守残骸和尸体。'),
      note('慧音', '我交代过“谁都不许靠近”。'),
      note('慧音', '我认出那个青年是之前抱着艾琳往村里跑的人。'),
    ];
  }

  static List<WorldEvent> playerEvents() {
    return const <WorldEvent>[
      WorldEvent(
        id: 'E1',
        kind: WorldEventKind.speech,
        content:
            '“联邦队员这尸体我可管不了。哦对了，有个人守着，说什么‘慧音让所有人都不要靠近’，那个人跟我没关系。”',
        actor: 'char:信标',
        target: 'char:灵梦',
        delivery: Delivery(
          channel: DeliveryChannel.voice,
          form: 'spoken',
          audience: Audience.scene,
        ),
      ),
      WorldEvent(
        id: 'E2',
        kind: WorldEventKind.action,
        content: '看向艾琳',
        actor: 'char:信标',
        target: 'char:艾琳',
        delivery: Delivery(
          channel: DeliveryChannel.visual,
          form: 'gesture',
          audience: Audience.scene,
        ),
      ),
      WorldEvent(
        id: 'E3',
        kind: WorldEventKind.speech,
        content: '“记录仪没看，尸体我也没管，死人永远没有活人重要。还有……”',
        actor: 'char:信标',
        target: 'char:艾琳',
        delivery: Delivery(
          channel: DeliveryChannel.voice,
          form: 'spoken',
          audience: Audience.scene,
        ),
      ),
      WorldEvent(
        id: 'E4',
        kind: WorldEventKind.speech,
        content:
            '“我不知道你和外星文明打过多少交道，也不知道联邦教了你什么样的善良价值观，但是，别小瞧任何你不了解的文明，好吗？用人类的思维揣测外星文明，是绝对的大忌。”',
        actor: 'char:信标',
        target: 'char:艾琳',
        delivery: Delivery(
          channel: DeliveryChannel.voice,
          form: 'spoken',
          audience: Audience.scene,
        ),
      ),
    ];
  }
}
