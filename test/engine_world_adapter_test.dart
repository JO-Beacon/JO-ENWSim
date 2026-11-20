import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/engine/character_memory.dart';
import 'package:joenws/engine/engine_state.dart';
import 'package:joenws/engine/perception.dart';
import 'package:joenws/engine/sequence.dart';
import 'package:joenws/engine/state_delta.dart';
import 'package:joenws/engine/world_adapter.dart';
import 'package:joenws/model/demo.dart';
import 'package:joenws/model/turn.dart';

World buildWorld() {
  return const World(
    id: 'w-test',
    name: '测试世界',
    note: '两步',
    setting: '东门内侧。',
    opening: '',
    playerName: '信标',
    characters: <CharCard>[
      CharCard(name: '信标', persona: '外来探险家。', location: '东门内侧'),
      CharCard(
        name: '灵梦',
        persona: '博丽神社的巫女。',
        location: '东门内侧',
        state: '右臂缠着白布条',
        aliases: <String, String>{
          '信标': '那个黑铁壳子',
          '艾琳': '那个受伤的姑娘',
        },
      ),
      CharCard(
        name: '艾琳',
        persona: '受伤的联邦队员。',
        location: '仓房',
        aliases: <String, String>{'灵梦': '巫女'},
      ),
    ],
    parallelPlaces: <ParallelPlace>[
      ParallelPlace(
        id: 'l1',
        place: '东门内侧',
        here: true,
        events: <TurnStep>[
          TurnStep(
            kind: 'CH_ACT',
            who: '灵梦',
            time: '午后',
            text: '灵梦看着门外。',
          ),
        ],
      ),
    ],
    moves: <MoveLink>[],
  );
}

void main() {
  test('WorldAdapter 把玩家之前的回答带进 scene.playerNotes', () {
    final WorldAdapter adapter = WorldAdapter(
      world: buildWorld(),
      parallelPlaceId: 'l1',
      priorAnswers: const <PlayerAnswer>[
        PlayerAnswer(
          step: 'GM_ENV_UPDATE',
          question: '门锁了吗？',
          answer: '锁了。',
          kind: 'fact',
        ),
      ],
    );
    final NarrativeScene scene = adapter.scene();
    expect(scene.playerNotes, contains('门锁了吗？'));
    expect(scene.playerNotes, contains('锁了。'));
  });

  group('WorldAdapter', () {
    test('从世界数据生成 scene，现场/远处分得开', () {
      final WorldAdapter a = WorldAdapter(world: buildWorld(), parallelPlaceId: 'l1');
      expect(a.presentNames, contains('信标'));
      expect(a.presentNames, contains('灵梦'));
      expect(a.presentNames, isNot(contains('艾琳')));
      expect(a.actorNames, containsAll(<String>['信标', '灵梦']));
      expect(a.npcNames, <String>['灵梦']);

      final NarrativeScene s = a.scene();
      expect(s.place, '东门内侧');
      expect(s.byId('char:灵梦')!.nearby, isTrue);
      expect(s.byId('char:艾琳'), isNull);
      expect(s.byId('char:信标')!.nearby, isTrue);
    });

    test('priorLocations 只有空字符串时不能把现场清空', () {
      const World world = World(
        id: 'w-empty-location',
        name: '空地点',
        note: '',
        setting: '',
        opening: '',
        playerName: '信标',
        characters: <CharCard>[
          CharCard(name: '信标', persona: '玩家。'),
          CharCard(name: '灵梦', persona: '巫女。'),
        ],
        parallelPlaces: <ParallelPlace>[
          ParallelPlace(id: 'l1', place: '东门内侧', here: true, events: <TurnStep>[]),
        ],
        moves: <MoveLink>[],
      );
      final WorldAdapter a = WorldAdapter(
        world: world,
        parallelPlaceId: 'l1',
        priorLocations: <String, String>{'信标': '', '灵梦': ''},
      );
      expect(a.presentNames, contains('信标'));
      expect(a.presentNames, contains('灵梦'));
      expect(a.npcNames, <String>['灵梦']);
      expect(a.scene().cast.length, 2);
      expect(
        a.scene().cast.map((CharacterSnapshot c) => c.name),
        containsAll(<String>['信标', '灵梦']),
      );
    });

    test('并行地点候选只含有角色、但还没有序列覆盖的地点', () {
      final WorldAdapter a = WorldAdapter(world: buildWorld(), parallelPlaceId: 'l1');
      final List<ParallelPlaceCandidate> c = a.parallelPlaceCandidates();
      expect(c.length, 1);
      expect(c.single.place, '仓房');
      expect(c.single.members, <String>['艾琳']);
    });

    test('并行地点候选也可以是没有角色的已出现地点', () {
      final World world = buildWorld().copyWith(
        parallelPlaces: <ParallelPlace>[
          ...buildWorld().parallelPlaces,
          const ParallelPlace(
            id: 'l2',
            place: '后巷',
            here: false,
            status: 'merged',
            mergeInto: 'l1',
            events: <TurnStep>[],
          ),
        ],
      );
      final WorldAdapter a = WorldAdapter(world: world, parallelPlaceId: 'l1');
      final List<ParallelPlaceCandidate> c = a.parallelPlaceCandidates();
      final ParallelPlaceCandidate alley =
          c.firstWhere((ParallelPlaceCandidate x) => x.place == '后巷');
      expect(alley.members, isEmpty);
    });

    test('priorLocations 只写了一部分人时，角色卡地点仍会补进现场', () {
      final WorldAdapter a = WorldAdapter(
        world: buildWorld(),
        parallelPlaceId: 'l1',
        priorLocations: const <String, String>{'信标': '东门内侧'},
      );
      expect(a.presentNames, contains('信标'));
      expect(a.presentNames, contains('灵梦'));
      expect(a.presentNames, isNot(contains('艾琳')));
    });

    test('每条序列只带自己地点的人，不串线', () {
      final WorldAdapter a = WorldAdapter(world: buildWorld(), parallelPlaceId: 'l1');
      final ParallelPlaceInfo l1 = a.parallelPlaceInfos().single;
      expect(l1.place, '东门内侧');
      expect(l1.members, containsAll(<String>['信标', '灵梦']));
      expect(l1.members, isNot(contains('艾琳')));
    });

    test('场景正文不能直接成为任何角色的初始记忆', () {
      final WorldAdapter a = WorldAdapter(world: buildWorld(), parallelPlaceId: 'l1');
      final List<CharacterMemory> seeds = a.memorySeed();
      final String ling = seeds
          .where((CharacterMemory m) => m.characterId == 'char:灵梦')
          .map((CharacterMemory m) => m.text)
          .join('\n');
      final String ai = seeds
          .where((CharacterMemory m) => m.characterId == 'char:艾琳')
          .map((CharacterMemory m) => m.text)
          .join('\n');
      expect(ling, isEmpty);
      expect(ai, isNot(contains('灵梦看着门外。')));
    });

    test('已合并的序列默认不进引擎列表', () {
      final World world = buildWorld();
      final World merged = world.copyWith(
        parallelPlaces: <ParallelPlace>[
          world.parallelPlaces.first,
          const ParallelPlace(
            id: 'l2',
            place: '仓房',
            here: false,
            events: <TurnStep>[],
            status: 'merged',
            mergeInto: 'l1',
          ),
        ],
      );
      final WorldAdapter a = WorldAdapter(world: merged, parallelPlaceId: 'l1');
      expect(a.parallelPlaceInfos().map((ParallelPlaceInfo l) => l.id), <String>['l1']);
      expect(
        a.parallelPlaceInfos(includeMerged: true).map((ParallelPlaceInfo l) => l.id),
        <String>['l1', 'l2'],
      );
    });

    test('玩家不在这一列时，不把他塞进 cast', () {
      final World world = buildWorld();
      final World withSecond = world.copyWith(
        parallelPlaces: <ParallelPlace>[
          ...world.parallelPlaces,
          const ParallelPlace(
            id: 'l2',
            place: '仓房',
            here: false,
            events: <TurnStep>[],
          ),
        ],
      );
      final WorldAdapter a = WorldAdapter(world: withSecond, parallelPlaceId: 'l2');
      expect(a.presentNames, contains('艾琳'));
      expect(a.presentNames, isNot(contains('信标')));
      expect(a.npcNames, <String>['艾琳']);
    });

    test('没有位置信息时按该列最近几步推断现场（demo 的仓房）', () {
      final WorldAdapter a = WorldAdapter(
        world: DemoData.worlds.first,
        parallelPlaceId: 'l2',
      );
      expect(a.presentNames, containsAll(<String>['人物3', '人物4']));
      expect(a.presentNames, isNot(contains('人物1')));
      expect(a.npcNames, containsAll(<String>['人物3', '人物4']));
    });

    test('没有玩家、没有位置的单线世界，第一回合仍能拿全部角色', () {
      const World world = World(
        id: 'w-ai',
        name: '纯 AI',
        note: '',
        setting: '',
        opening: '',
        characters: <CharCard>[
          CharCard(name: '灵梦', persona: '巫女。'),
          CharCard(name: '艾琳', persona: '队员。'),
        ],
        parallelPlaces: <ParallelPlace>[
          ParallelPlace(id: 'l1', place: '开场', here: false, events: <TurnStep>[]),
        ],
        moves: <MoveLink>[],
      );
      final WorldAdapter a = WorldAdapter(world: world, parallelPlaceId: 'l1');
      expect(a.presentNames, containsAll(<String>['灵梦', '艾琳']));
      expect(a.npcNames, containsAll(<String>['灵梦', '艾琳']));
    });

    test('人设和地点由 profile 提供', () {
      final WorldAdapter a = WorldAdapter(world: buildWorld(), parallelPlaceId: 'l1');
      final profiles = a.profiles;
      expect(profiles['灵梦']!.persona, '博丽神社的巫女。');
      expect(profiles['灵梦']!.state, contains('当前地点：东门内侧'));
      expect(profiles['艾琳']!.state, contains('当前地点：仓房'));
    });

    test('玩家输入不在适配层造 speech，必须走 GM_PARSE_INPUT', () {
      final WorldAdapter a = WorldAdapter(world: buildWorld(), parallelPlaceId: 'l1');
      expect(a.newEvents('你好'), isEmpty);
    });

    test('没有输入时取当前地点最后一步', () {
      final WorldAdapter a = WorldAdapter(world: buildWorld(), parallelPlaceId: 'l1');
      final List<WorldEvent> events = a.newEvents('');
      expect(events.length, 1);
      expect(events.single.summary, '灵梦看着门外。');
      expect(events.single.actor, 'char:灵梦');
    });

    test('起始编号', () {
      final WorldAdapter a = WorldAdapter(world: buildWorld(), parallelPlaceId: 'l1');
      expect(a.startSeq, 2);
    });

    test('角色卡进 profiles', () {
      final WorldAdapter a = WorldAdapter(world: buildWorld(), parallelPlaceId: 'l1');
      expect(a.profiles['灵梦']!.persona, '博丽神社的巫女。');
      expect(a.profiles['灵梦']!.state, contains('右臂缠着白布条'));
      expect(a.profiles['灵梦']!.state, contains('当前地点：东门内侧'));
      expect(a.profiles['艾琳']!.persona, '受伤的联邦队员。');
    });

    test('角色卡别名进 scene，localize 用自己的称呼', () {
      final WorldAdapter a = WorldAdapter(world: buildWorld(), parallelPlaceId: 'l1');
      final NarrativeScene s = a.scene();
      expect(s.byId('char:灵梦')!.aliases['char:信标'], '那个黑铁壳子');
      expect(s.byId('char:灵梦')!.aliases['char:艾琳'], '那个受伤的姑娘');
      expect(
        const PerceptionEngine().localize(
          '信标看向艾琳',
          s.byId('char:灵梦')!,
          s,
        ),
        '那个黑铁壳子看向那个受伤的姑娘',
      );
    });

    test('priorLocations 覆盖世界里的 location', () {
      final WorldAdapter a = WorldAdapter(
        world: buildWorld(),
        parallelPlaceId: 'l1',
        priorLocations: <String, String>{
          '信标': '东门内侧',
          '灵梦': '仓房',
          '艾琳': '东门内侧',
        },
      );
      expect(a.presentNames, contains('艾琳'));
      expect(a.presentNames, isNot(contains('灵梦')));
      expect(a.npcNames, <String>['艾琳']);
    });

    test('prior 伤势事实/功能限制进 profiles，act=cannot 排除 eligible', () {
      final WorldAdapter a = WorldAdapter(
        world: buildWorld(),
        parallelPlaceId: 'l1',
        priorLocations: <String, String>{
          '信标': '东门内侧',
          '灵梦': '东门内侧',
          '艾琳': '东门内侧',
        },
        priorInjuries: const <InjuryFact>[
          InjuryFact(
            who: '灵梦',
            part: 'left_shoulder',
            kind: 'cut',
            cause: '刀伤',
            treatment: '已包扎',
          ),
        ],
        priorConstraints: const <FunctionalConstraint>[
          FunctionalConstraint(
            who: '灵梦',
            capability: 'act',
            state: ConstraintState.cannot,
            reason: '左肩刀伤',
          ),
        ],
      );
      expect(a.profiles['灵梦']!.state, contains('left_shoulder'));
      expect(a.profiles['灵梦']!.state, contains('功能限制'));
      expect(a.npcNames, isNot(contains('灵梦')));
      expect(a.npcNames, contains('艾琳'));
    });

    test('填了 location 就按 location 算，不再看最近步骤', () {
      const World w = World(
        id: 'w-loc',
        name: '位置测试',
        note: '',
        setting: '',
        opening: '',
        playerName: '信标',
        characters: <CharCard>[
          CharCard(name: '信标', persona: '玩家。', location: '东门内侧'),
          CharCard(name: '灵梦', persona: '巫女。', location: '仓房'),
          CharCard(name: '艾琳', persona: '队员。', location: '东门内侧'),
        ],
        parallelPlaces: <ParallelPlace>[
          ParallelPlace(
            id: 'l1',
            place: '东门内侧',
            here: true,
            events: <TurnStep>[
              TurnStep(kind: 'CH_ACT', who: '灵梦', text: '灵梦刚才在这里。'),
            ],
          ),
        ],
        moves: <MoveLink>[],
      );
      final WorldAdapter a = WorldAdapter(world: w, parallelPlaceId: 'l1');
      expect(a.presentNames, contains('信标'));
      expect(a.presentNames, contains('艾琳'));
      expect(a.presentNames, isNot(contains('灵梦')));
      expect(a.npcNames, <String>['艾琳']);
    });
  });
}
