import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/engine/character_memory.dart';
import 'package:joenws/engine/ledger.dart';
import 'package:joenws/engine/memory_agent.dart';
import 'package:joenws/engine/perception.dart';

import 'package:joenws/engine/sequence.dart';
import 'package:joenws/engine/state_delta.dart';
import 'package:joenws/engine/turn_loop.dart';
import 'package:joenws/engine/turn_session.dart';

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

WorldEvent playerEvent() {
  return const WorldEvent(
    id: 'E1',
    kind: WorldEventKind.speech,
    content: '别小瞧任何你不了解的文明。',
    actor: 'char:信标',
    target: 'char:艾琳',
    delivery: Delivery(
      channel: DeliveryChannel.voice,
      form: 'spoken',
      audience: Audience.scene,
    ),
  );
}

Map<String, Object?> speechAction(String text) {
  return <String, Object?>{
    'intent': 'test',
    'segments': <Object?>[
      <String, Object?>{
        'kind': 'speech',
        'text': text,
        'target': '信标',
        'delivery': <String, Object?>{
          'channel': 'voice',
          'form': 'spoken',
          'audience': 'scene',
        },
        'manner': null,
        'requires': <String>['speak'],
        'perceivable_by': <String>[],
      },
    ],
    'manner': 'test',
  };
}

Map<String, Object?> stealAction() {
  return <String, Object?>{
    'intent': 'test',
    'segments': <Object?>[
      <String, Object?>{
        'kind': 'action',
        'action_kind': 'steal',
        'text': '伸手去抢急救包',
        'target': '信标',
        'delivery': <String, Object?>{
          'channel': 'visual',
          'form': 'gesture',
          'audience': 'scene',
        },
        'manner': null,
        'requires': <String>['use_right_arm'],
        'perceivable_by': <String>[],
      },
    ],
    'manner': 'test',
  };
}

Map<String, Object?> actionWithText(String text) {
  return <String, Object?>{
    'intent': 'test',
    'segments': <Object?>[
      <String, Object?>{
        'kind': 'action',
        'action_kind': null,
        'text': text,
        'target': '信标',
        'delivery': <String, Object?>{
          'channel': 'visual',
          'form': 'gesture',
          'audience': 'scene',
        },
        'manner': null,
        'requires': <String>[],
        'perceivable_by': <String>[],
      },
    ],
    'manner': 'test',
  };
}

Map<String, Object?> actionWithDelta() {
  return <String, Object?>{
    'intent': 'test',
    'segments': <Object?>[
      <String, Object?>{
        'kind': 'action',
        'action_kind': null,
        'text': '走到仓房门口',
        'target': null,
        'delivery': <String, Object?>{
          'channel': 'visual',
          'form': 'gesture',
          'audience': 'scene',
        },
        'manner': null,
        'requires': <String>[],
        'perceivable_by': <String>[],
      },
    ],
    'state_delta': <String, Object?>{
      'move': <String, Object?>{'慧音': '仓房'},
    },
    'manner': 'test',
  };
}

Map<String, Object?> moveEveryoneAction() {
  return <String, Object?>{
    'intent': 'test',
    'segments': <Object?>[
      <String, Object?>{
        'kind': 'action',
        'text': '走出门',
        'target': null,
        'delivery': <String, Object?>{
          'channel': 'visual',
          'form': 'gesture',
          'audience': 'scene',
        },
        'manner': null,
        'requires': <String>[],
        'perceivable_by': <String>[],
      },
    ],
    'state_delta': <String, Object?>{
      'move': <String, String>{
        '信标': '仓房',
        '灵梦': '仓房',
        '艾琳': '仓房',
        '魔理沙': '仓房',
        '慧音': '仓房',
      },
    },
    'manner': 'test',
  };
}
Map<String, Object?> actionWithRequires(String capability) {
  final Map<String, Object?> a =
      Map<String, Object?>.from(actionWithText('左手抡剑'));
  final List<Object?> segs = a['segments']! as List<Object?>;
  final Map<String, Object?> seg =
      (segs.first! as Map).cast<String, Object?>();
  seg['requires'] = <String>[capability];
  return a;
}

Map<String, Object?> actionWithoutRequires() {
  final Map<String, Object?> a =
      Map<String, Object?>.from(actionWithText('偏过头'));
  final List<Object?> segs = a['segments']! as List<Object?>;
  final Map<String, Object?> seg =
      (segs.first! as Map).cast<String, Object?>();
  seg.remove('requires');
  return a;
}

Map<String, Object?> stopAction({
  String code = 'constraint_conflict',
  String reason = '左肩不能用',
}) {
  return <String, Object?>{
    'status': 'stop',
    'code': code,
    'reason': reason,
    'question': '要换右手，还是停下？',
    'options': <String>['换右手', '停下'],
  };
}

class FakeAgents implements TurnAgents {
  FakeAgents({
    required this.choices,
    Map<String, Object?>? action,
    List<Map<String, Object?>>? actions,
    Map<String, Object?>? arbitration,
    List<Map<String, Object?>>? arbitrationAttempts,
    this.renderText = '渲染结果',
    this.renderTexts,
    this.perceptEventId = 'auto',
    this.perceptEventIds,
  })  : actions = (actions == null || actions.isEmpty)
            ? <Map<String, Object?>>[
                action ?? speechAction('我听见了。'),
              ]
            : actions,
        arbitration = arbitration ??
            <String, Object?>{
              'outcome': 'failure',
              'deltas': <Object?>[
                <String, Object?>{'kind': 'none'},
              ],
              'reason': 'test',
            },
        arbitrationAttempts =
            arbitrationAttempts ?? const <Map<String, Object?>>[];

  final List<String?> choices;
  final List<Map<String, Object?>> actions;
  final Map<String, Object?> arbitration;
  final List<Map<String, Object?>> arbitrationAttempts;
  final String renderText;
  final List<String>? renderTexts;
  final String perceptEventId;
  final List<String>? perceptEventIds;
  final List<String> perceiveHistory = <String>[];
  final List<List<String>> resolveFeedback = <List<String>>[];
  final List<List<String>> rFeedback = <List<String>>[];
  int renderCalls = 0;
  RenderPov? lastPov;
  int _index = 0;
  int _actionIndex = 0;
  int _perceptIndex = 0;
  int _arIndex = 0;
  int _renderIndex = 0;

  @override
  Future<Map<String, Object?>> perceiveWithImages({
    required String name,
    required String context,
    required String events,
    List<String> imageAssetIds = const <String>[],
  }) =>
      perceive(name: name, context: context, events: events);

  @override
  Future<Map<String, Object?>> perceive({
    required String name,
    required String context,
    required String events,
  }) async {
    final String id;
    final List<String>? ids = perceptEventIds;
    if (ids != null && ids.isNotEmpty) {
      id = ids[_perceptIndex.clamp(0, ids.length - 1)];
      _perceptIndex++;
    } else {
      id = perceptEventId == 'auto'
          ? (RegExp(r'^E\d+').firstMatch(events.trim())?.group(0) ?? 'E1')
          : perceptEventId;
    }
    return <String, Object?>{
      'percepts': <Object?>[
        <String, Object?>{
          'event_id': id,
          'content': '$name 听见了那句话。',
        },
      ],
      'attention': '想回应。',
    };
  }

  @override
  Future<List<String>> selectEligible({
    required List<String> baseEligible,
    required List<String> cast,
    String playerNotes = '',
    List<String> errors = const <String>[],
    List<String>? previous,
  }) async {
    return baseEligible;
  }

  @override
  Future<List<MemoryOperation>?> manageMemory({
    required String characterId,
    required Map<String, Object?> percepts,
    required List<CharacterMemory> memory,
    required Set<String> allowedEventIds,
  }) async =>
      null;

  @override
  Future<List<String>?> recallMemory({
    required String characterId,
    required NarrativeScene scene,
    required Map<String, Object?> percepts,
    required List<CharacterMemory> memory,
  }) async =>
      null;

  @override
  Future<String?> selectActor({
    required List<String> eligible,
    required Map<String, Map<String, Object?>> percepts,
    String playerNotes = '',
    List<String> errors = const <String>[],
    String? previous,
  }) async {
    if (_index >= choices.length) return null;
    return choices[_index++];
  }

  @override
  Future<Map<String, Object?>> act({
    required String name,
    required String context,
    required String perceive,
    required List<String> present,
  }) async {
    perceiveHistory.add(perceive);
    final int i = _actionIndex < actions.length
        ? _actionIndex
        : actions.length - 1;
    _actionIndex++;
    return actions[i];
  }

  @override
  void setPlayerHelp(Map<String, String> help) {}

  @override
  void recordPlayerAnswer(String journalKey, String answer) {}

  @override
  void prepareRetry(String stage) {}

  @override
  void recordIntervention(String key, PlayerQuestion question, String answer) {}

  @override
  Future<Map<String, Object?>> adjudicate({
    required Map<String, Object?> action,
    required String actor,
    required String? target,
    required String place,
    required List<String> present,
    List<String> errors = const <String>[],
    Map<String, Object?>? previous,
    String playerNotes = '',
  }) async {
    resolveFeedback.add(List<String>.of(errors));
    if (arbitrationAttempts.isEmpty) return arbitration;
    final int i = _arIndex < arbitrationAttempts.length
        ? _arIndex
        : arbitrationAttempts.length - 1;
    _arIndex++;
    return arbitrationAttempts[i];
  }

  @override
  Future<Map<String, Object?>> render({
    required List<WorldEvent> events,
    RenderPov pov = RenderPov.omniscient,
    String observerId = '',
    NarrativeScene? scene,
    List<String> errors = const <String>[],
    Map<String, Object?>? previous,
  }) async {
    renderCalls++;
    lastPov = pov;
    rFeedback.add(List<String>.of(errors));
    String text = renderText;
    final List<String>? texts = renderTexts;
    if (texts != null && texts.isNotEmpty) {
      final int i = _renderIndex < texts.length ? _renderIndex : texts.length - 1;
      text = texts[i];
    }
    _renderIndex++;
    return <String, Object?>{
      'public_text': text,
      'god_note': '',
    };
  }
}

class InvalidEligibleAgents extends FakeAgents {
  InvalidEligibleAgents() : super(choices: <String?>['慧音']);

  int calls = 0;

  @override
  Future<List<String>> selectEligible({
    required List<String> baseEligible,
    required List<String> cast,
    String playerNotes = '',
    List<String> errors = const <String>[],
    List<String>? previous,
  }) async {
    calls++;
    if (calls == 1) return <String>['乱写的人'];
    return baseEligible;
  }
}

class MemoryFakeAgents extends FakeAgents {
  MemoryFakeAgents({this.sourceEventId})
      : super(choices: <String?>['慧音']);

  final String? sourceEventId;

  @override
  Future<List<MemoryOperation>?> manageMemory({
    required String characterId,
    required Map<String, Object?> percepts,
    required List<CharacterMemory> memory,
    required Set<String> allowedEventIds,
  }) async => <MemoryOperation>[
        MemoryOperation(
          op: 'encode',
          text: '我记得这件事。',
          sourceEvents: <String>[
            if (sourceEventId != null)
              sourceEventId!
            else if (allowedEventIds.isNotEmpty)
              allowedEventIds.first,
          ],
        ),
      ];

  @override
  Future<List<String>?> recallMemory({
    required String characterId,
    required NarrativeScene scene,
    required Map<String, Object?> percepts,
    required List<CharacterMemory> memory,
  }) async =>
      <String>[if (memory.isNotEmpty) memory.first.id];
}

void main() {
  group('needsAr', () {
    test('物理/对抗行动才进 GM_RESOLVE_ACTION', () {
      expect(needsAr('steal'), isTrue);
      expect(needsAr('attack'), isTrue);
      expect(needsAr('dodge'), isTrue);
      expect(needsAr('speech'), isFalse);
      expect(needsAr('move'), isFalse);
      expect(needsAr('take'), isFalse);
      expect(needsAr('persuade'), isFalse);
    });
  });

  group('TurnLoop', () {
    test('TurnLoop 按 stage 顺序回调，供单步暂停', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(choices: <String?>['慧音']);
      final List<String> stages = <String>[];
      final Map<String, Map<String, Object?>> checkpoints =
          <String, Map<String, Object?>>{};
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        onStage: stages.add,
        onCheckpoint: (String stage, Map<String, Object?> data) {
          checkpoints[stage] = data;
        },
      );
      await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: <String>['慧音'],
      );
      expect(
        stages,
        containsAll(<String>[
          'GM_OPEN_PLACE',
          'GM_ROUTE',
          'CH_PERCEIVE:慧音',
          'GM_CAST',
          'GM_ELIGIBILITY',
          'GM_SELECT_ACTOR',
          'CH_ACT',
          'SYS_RECORD',
          'GM_NARRATE',
          'GM_MERGE_PLACE',
        ]),
      );
      expect(checkpoints['GM_OPEN_PLACE']?['openParallelPlace'], isFalse);
      expect(checkpoints['GM_CAST']?['cast'], isA<List<Object?>>());
      expect(checkpoints['GM_SELECT_ACTOR']?['chosen'], '慧音');
      expect(checkpoints['CH_ACT']?['actor'], '慧音');
      expect(checkpoints['SYS_RECORD']?['events'], isA<List<Object?>>());
    });

    test('TurnLoop 会调用 CH_MEMORY_WRITE 写侧和召回，并产生 CH_MEMORY_WRITE checkpoint', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final MemoryStore memory = MemoryStore();
      final List<String> stages = <String>[];
      final MemoryFakeAgents agents = MemoryFakeAgents();
      final TurnLoop loop = TurnLoop(
        scene: scene,
        memoryStore: memory,
        agents: agents,
        onStage: stages.add,
      );
      await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: <String>['慧音'],
      );
      expect(stages, contains('CH_MEMORY_WRITE:慧音'));
      expect(stages, contains('CH_MEMORY_RECALL:慧音'));
      expect(memory.forCharacter('char:慧音'), hasLength(1));
    });

    test('StagePause 能从 stage 回调把单步停下来', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(choices: <String?>['慧音']);
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        onStage: (String stage) {
          if (stage == 'GM_OPEN_PLACE') throw const StagePause('GM_OPEN_PLACE');
        },
      );
      await expectLater(
        loop.run(
          newEvents: <WorldEvent>[e1],
          npcNames: <String>['慧音'],
        ),
        throwsA(isA<StagePause>()),
      );
    });

    test('任何一个被 GM_SELECT_ACTOR 选中的人都能走完 CH_ACT/SYS_RECORD/GM_NARRATE', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();

      final FakeAgents agents = FakeAgents(choices: <String?>['慧音']);
      final MemoryStore memory = MemoryStore();
      final TurnLoop loop = TurnLoop(
        scene: scene,
        memoryStore: memory,
        agents: agents,
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: <String>['灵梦', '艾琳', '魔理沙', '慧音'],
      );

      expect(trace.chosen, '慧音');
      expect(trace.eligible, contains('慧音'));
      expect(trace.events.length, 1);
      expect(trace.render?['public_text'], '渲染结果');
      expect(memory.count('char:慧音'), 1);
      expect(memory.count('char:灵梦'), 1);
    });

    test('人控角色轮到但没有输入时停在等待玩家行动', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(choices: <String?>['慧音']);
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        controlledCharacter: '慧音',
        playerActionHandler: ({
          required String actor,
          required NarrativeScene scene,
        }) async =>
            null,
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        actorNames: <String>['信标', '灵梦', '艾琳', '魔理沙', '慧音'],
      );
      expect(trace.route, 'player');
      expect(trace.stop?.code, 'player_action');
      expect(trace.events, isEmpty);
    });

    test('玩家 CH_ACT 的 requires 撞上功能限制会停在玩家行动', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(choices: <String?>['慧音']);
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        controlledCharacter: '慧音',
        constraints: const <FunctionalConstraint>[
          FunctionalConstraint(
            who: '慧音',
            capability: 'use_left_arm',
            state: ConstraintState.cannot,
            reason: '左臂受伤',
          ),
        ],
        playerActionHandler: ({
          required String actor,
          required NarrativeScene scene,
        }) async =>
            <String, Object?>{
          'intent': '玩家用左手推门',
          'segments': <Object?>[
            <String, Object?>{
              'kind': 'action',
              'text': '用左手推门。',
              'target': null,
              'delivery': <String, Object?>{
                'channel': 'visual',
                'form': 'gesture',
                'audience': 'scene',
              },
              'requires': <String>['use_left_arm'],
              'perceivable_by': <String>[],
            },
          ],
          'state_delta': const <String, Object?>{},
        },
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        actorNames: <String>['信标', '灵梦', '艾琳', '魔理沙', '慧音'],
      );
      expect(trace.stop?.code, 'player_action');
      expect(trace.events, isEmpty);
      expect(trace.actErrors.single.code, 'capability_blocked');
    });

    test('玩家 CH_ACT 的 action_kind 也会进入 GM_RESOLVE_ACTION 裁定', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(choices: <String?>['慧音']);
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        controlledCharacter: '慧音',
        playerActionHandler: ({
          required String actor,
          required NarrativeScene scene,
        }) async =>
            <String, Object?>{
          'intent': '玩家攻击',
          'segments': <Object?>[
            <String, Object?>{
              'kind': 'action',
              'text': '扑向对方。',
              'target': '信标',
              'action_kind': 'grapple',
              'delivery': <String, Object?>{
                'channel': 'visual',
                'form': 'gesture',
                'audience': 'scene',
              },
              'requires': <String>[],
              'perceivable_by': <String>[],
            },
          ],
          'state_delta': const <String, Object?>{},
        },
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        actorNames: <String>['信标', '灵梦', '艾琳', '魔理沙', '慧音'],
      );
      expect(trace.arbitration, isNotNull);
      expect(trace.arbitration?['outcome'], 'failure');
    });

    test('actor 列表包含玩家人控角色，GM_SELECT_ACTOR 可以选中他', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(choices: <String?>['信标']);
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        controlledCharacter: '信标',
        playerActionHandler: ({
          required String actor,
          required NarrativeScene scene,
        }) async =>
            <String, Object?>{
          'intent': '玩家行动',
          'segments': <Object?>[
            <String, Object?>{
              'kind': 'action',
              'text': '抬手。',
              'target': null,
              'delivery': <String, Object?>{
                'channel': 'other',
                'form': 'gesture',
                'audience': 'scene',
              },
              'requires': <String>[],
              'perceivable_by': <String>[],
            },
          ],
          'state_delta': const <String, Object?>{},
        },
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        actorNames: <String>['信标', '灵梦', '艾琳', '魔理沙', '慧音'],
      );
      expect(trace.chosen, '信标');
      expect(trace.events.single.actor, 'char:信标');
    });

    test('GM_SELECT_ACTOR 选中当前操控角色时走玩家 CH_ACT，不调用 AI CH_ACT', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(choices: <String?>['慧音']);
      bool playerB2Called = false;
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        controlledCharacter: '慧音',
        playerActionHandler: ({
          required String actor,
          required NarrativeScene scene,
        }) async {
          playerB2Called = true;
          expect(actor, '慧音');
          return <String, Object?>{
            'intent': '玩家自己决定行动',
            'segments': <Object?>[
              <String, Object?>{
                'kind': 'action',
                'text': '抬手示意。',
                'target': null,
                'delivery': <String, Object?>{
                  'channel': 'other',
                  'form': 'gesture',
                  'audience': 'scene',
                },
                'requires': <String>[],
                'perceivable_by': <String>[],
              },
            ],
            'state_delta': <String, Object?>{
              'move': <String, String>{'慧音': '仓房'},
            },
          };
        },
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        actorNames: <String>['信标', '灵梦', '艾琳', '魔理沙', '慧音'],
      );
      expect(playerB2Called, isTrue);
      expect(trace.chosen, '慧音');
      expect(trace.events, isNotEmpty);
      expect(trace.events.single.actor, 'char:慧音');
      expect(trace.stateDelta?.moves['慧音'], '仓房');
    });

    test('CH_PERCEIVE 的感知写成角色记忆，来源是看见的事件', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();

      final FakeAgents agents = FakeAgents(choices: <String?>['慧音']);
      final MemoryStore memory = MemoryStore();
      final TurnLoop loop = TurnLoop(
        scene: scene,
        memoryStore: memory,
        agents: agents,
      );
      await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: <String>['慧音'],
      );

      final List<CharacterMemory> entries = memory.forCharacter('char:慧音');
      expect(entries, hasLength(1));
      expect(entries.single.sourceEvents, <String>['E1']);
      expect(entries.single.text, contains('慧音 听见了那句话。'));
      expect(entries.single.attention, '想回应。');
    });

    test('第二回合不再排除上一回合 actor', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(choices: <String?>['慧音', '灵梦']);
      final MemoryStore memory = MemoryStore();
      final TurnLoop loop = TurnLoop(
        scene: scene,
        memoryStore: memory,
        agents: agents,
      );

      final TurnTrace first = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: <String>['灵梦', '艾琳', '魔理沙', '慧音'],
      );
      expect(first.chosen, '慧音');

      final TurnTrace second = await loop.run(
        newEvents: first.events,
        npcNames: <String>['灵梦', '艾琳', '魔理沙', '慧音'],
      );
      expect(second.chosen, '灵梦');
      expect(second.eligible, contains('慧音'));
      expect(second.eligible, contains('灵梦'));
      expect(memory.count('char:灵梦'), 2);
    });

    test('同一角色可以连续两个角色回合行动', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(choices: <String?>['慧音', '慧音']);
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
      );

      final TurnTrace first = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: <String>['灵梦', '艾琳', '魔理沙', '慧音'],
      );
      expect(first.chosen, '慧音');

      final TurnTrace second = await loop.run(
        newEvents: first.events,
        npcNames: <String>['灵梦', '艾琳', '魔理沙', '慧音'],
      );
      expect(second.eligible, contains('慧音'));
      expect(second.chosen, '慧音');
    });

    test('GM_ELIGIBILITY 返回 eligible 外的人名会带着错误重写', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final InvalidEligibleAgents agents = InvalidEligibleAgents();
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: <String>['灵梦', '艾琳', '魔理沙', '慧音'],
      );
      expect(agents.calls, 2);
      expect(trace.castErrors, isEmpty);
      expect(trace.route, 'turn');
      expect(trace.chosen, isNotNull);
    });

    test('GM_SELECT_ACTOR 返回 eligible 外的人名走出错，不静默回退环境', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(choices: <String?>['乱写的人']);
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        parallelPlaceCandidates: const <ParallelPlaceCandidate>[
          ParallelPlaceCandidate(place: '仓房', members: <String>['人物2']),
        ],
        openPlaceDecider: ({
          required NarrativeScene scene,
          required List<WorldEvent> events,
          List<String>? errors,
          OpenPlaceResult? previous,
        }) async =>
            const OpenPlaceResult(openParallelPlace: true, place: '仓房', why: 'test-openPlace'),
        environmentSource: ({
          required NarrativeScene scene,
          required List<WorldEvent> events,
          String? feedback,
        }) async =>
            <WorldEvent>[
          WorldEvent(
            id: 'E9',
            kind: WorldEventKind.action,
            content: '雨声更密了。',
            actor: '',
            delivery: const Delivery(
              channel: DeliveryChannel.other,
              form: 'narration',
              audience: Audience.scene,
            ),
            source: 'environment',
            placeId: '东门内侧',
          ),
        ],
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: <String>['灵梦', '艾琳', '魔理沙', '慧音'],
      );
      expect(trace.route, 'error');
      expect(trace.chosen, isNull);
      expect(trace.environmentEvents, isEmpty);
      expect(trace.selectActorErrors, isNotEmpty);
      expect(trace.openPlace.openParallelPlace, isTrue);
      expect(trace.openPlace.why, 'test-openPlace');
    });

    test('环境回合也会让在场角色感知并写记忆', () async {
    final NarrativeScene scene = buildScene();
    final WorldEvent e1 = playerEvent();
    final MemoryStore memory = MemoryStore();
    final MemoryFakeAgents agents = MemoryFakeAgents(sourceEventId: 'E9');
    final TurnLoop loop = TurnLoop(
      scene: scene,
      memoryStore: memory,
      agents: agents,
      routeDecider: ({
        required NarrativeScene scene,
        required List<WorldEvent> events,
        List<String>? errors,
        String? previous,
      }) async =>
          'env',
      environmentSource: ({
        required NarrativeScene scene,
        required List<WorldEvent> events,
        String? feedback,
      }) async =>
          <WorldEvent>[
            WorldEvent(
              id: 'E9',
              kind: WorldEventKind.action,
              content: '雨声更密了。',
              actor: '',
              delivery: const Delivery(
                channel: DeliveryChannel.other,
                form: 'other',
                audience: Audience.scene,
              ),
              witnesses: <Witness>[
                const Witness(
                  characterId: 'char:慧音',
                  modality: 'other',
                  content: '雨声更密了。',
                ),
              ],
              source: 'environment',
              placeId: '东门内侧',
            ),
          ],
    );
    final TurnTrace trace = await loop.run(
      newEvents: <WorldEvent>[e1],
      npcNames: const <String>[],
      perceptionNames: <String>['慧音'],
    );
    expect(trace.route, 'env');
    expect(trace.perceiveErrors, isEmpty);
    expect(memory.forCharacter('char:慧音'), hasLength(1));
    expect(
      memory.forCharacter('char:慧音').single.sourceEvents,
      contains('E9'),
    );

    // 下一回合仍会看到这批环境事件，但已经记过就不应再写一条。
    await loop.run(
      newEvents: trace.environmentEvents,
      npcNames: <String>['慧音'],
    );
    expect(memory.forCharacter('char:慧音'), hasLength(1));
  });

  test('TurnLoop 能从 GM_NARRATE checkpoint 直接续跑，不重跑前面阶段', () async {
    final NarrativeScene scene = buildScene();
    final WorldEvent e1 = playerEvent();
    final MemoryFakeAgents agents = MemoryFakeAgents();
    final Map<String, TurnCheckpoint> checkpoints =
        <String, TurnCheckpoint>{};
    final TurnLoop first = TurnLoop(
      scene: scene,
      agents: agents,
      onCheckpoint: (String stage, Map<String, Object?> data) {
        checkpoints[stage] = TurnCheckpoint(stage: stage, data: data);
      },
    );
    final TurnTrace original = await first.run(
      newEvents: <WorldEvent>[e1],
      npcNames: <String>['慧音'],
    );
    expect(original.events, isNotEmpty);
    expect(checkpoints.containsKey('CH_PERCEIVE:慧音'), isTrue);
    expect(checkpoints.containsKey('CH_MEMORY_WRITE:慧音'), isTrue);

    final List<String> resumedStages = <String>[];
    final MemoryFakeAgents resumedAgents = MemoryFakeAgents();
    final TurnLoop resumed = TurnLoop(
      scene: scene,
      memoryStore: MemoryStore(),
      agents: resumedAgents,
      onStage: resumedStages.add,
    );
    final TurnSession session = TurnSession(
      worldId: 'w1',
      parallelPlaceId: 'l1',
      rawInput: '测试',
      journal: TurnJournal(),
      checkpoints: checkpoints,
      stage: 'GM_NARRATE',
    );
    final TurnTrace trace = await resumed.run(
      newEvents: <WorldEvent>[e1],
      npcNames: <String>['慧音'],
      resume: session,
    );
    expect(trace.render?['public_text'], original.render?['public_text']);
    expect(trace.events, isNotEmpty);
    expect(resumedStages, isEmpty);
    expect(resumedAgents.renderCalls, 0);
  });

  test('TurnLoop 能从 GM_SELECT_ACTOR checkpoint 直接续跑，只补后面的 stage', () async {
    final NarrativeScene scene = buildScene();
    final WorldEvent e1 = playerEvent();
    final Map<String, TurnCheckpoint> checkpoints =
        <String, TurnCheckpoint>{};
    final TurnLoop first = TurnLoop(
      scene: scene,
      agents: MemoryFakeAgents(),
      onCheckpoint: (String stage, Map<String, Object?> data) {
        checkpoints[stage] = TurnCheckpoint(stage: stage, data: data);
      },
    );
    await first.run(
      newEvents: <WorldEvent>[e1],
      npcNames: <String>['慧音'],
    );

    final List<String> resumedStages = <String>[];
    final TurnLoop resumed = TurnLoop(
      scene: scene,
      memoryStore: MemoryStore(),
      agents: MemoryFakeAgents(),
      onStage: resumedStages.add,
    );
    final Map<String, TurnCheckpoint> partial =
        Map<String, TurnCheckpoint>.of(checkpoints)
          ..removeWhere((String stage, TurnCheckpoint _) =>
              stage == 'CH_ACT' ||
              stage == 'SYS_RECORD' ||
              stage == 'GM_NARRATE' ||
              stage == 'GM_MERGE_PLACE' ||
              stage.startsWith('CH_MEMORY_RECALL'));
    final TurnSession session = TurnSession(
      worldId: 'w1',
      parallelPlaceId: 'l1',
      rawInput: '测试',
      journal: TurnJournal(),
      checkpoints: partial,
      stage: 'GM_SELECT_ACTOR',
    );
    final TurnTrace trace = await resumed.run(
      newEvents: <WorldEvent>[e1],
      npcNames: <String>['慧音'],
      resume: session,
    );
    expect(trace.render?['public_text'], isNotNull);
    expect(resumedStages, isNot(contains('GM_SELECT_ACTOR')));
    expect(resumedStages, isNot(contains('GM_CAST')));
    expect(resumedStages, isNot(contains('CH_PERCEIVE:慧音')));
    expect(resumedStages, contains('CH_ACT'));
  });

  test('GM_RESOLVE_ACTION 不合格会回给 GM_RESOLVE_ACTION 重写', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(
        choices: <String?>['魔理沙'],
        action: stealAction(),
        arbitrationAttempts: <Map<String, Object?>>[
          <String, Object?>{
            'outcome': '乱写',
            'deltas': <Object?>[],
            'reason': '先错一次',
          },
          <String, Object?>{
            'outcome': 'success',
            'deltas': <Object?>[],
            'reason': '重写后成立',
          },
        ],
      );
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        resolveStepBudget: 2,
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: <String>['灵梦', '艾琳', '魔理沙', '慧音'],
      );
      expect(trace.resolveErrors, isEmpty);
      expect(agents.resolveFeedback.length, 2);
      expect(agents.resolveFeedback[1], isNotEmpty);
      expect(trace.events, isNotEmpty);
    });

    test('steal 行动进 GM_RESOLVE_ACTION，SYS_RECORD 按 delta 移动物品', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();

      final Ledger ledger = Ledger();
      ledger.add(LedgerEntity(
        id: 'place:gate',
        kind: EntityKind.place,
        name: '东门',
      ));
      ledger.add(LedgerEntity(
        id: 'char:信标',
        kind: EntityKind.character,
        name: '信标',
        location: 'place:gate',
      ));
      ledger.add(LedgerEntity(
        id: 'char:魔理沙',
        kind: EntityKind.character,
        name: '魔理沙',
        location: 'place:gate',
      ));
      ledger.add(LedgerEntity(
        id: 'item:kit',
        kind: EntityKind.item,
        name: '急救包',
        location: 'char:信标',
      ));
      ledger.byId('char:信标')!.inventory.add('item:kit');

      final FakeAgents agents = FakeAgents(
        choices: <String?>['魔理沙'],
        action: stealAction(),
        arbitration: <String, Object?>{
          'outcome': 'success',
          'deltas': <Object?>[
            <String, Object?>{
              'kind': 'steal',
              'item_id': 'item:kit',
              'from': 'char:信标',
              'to': 'char:魔理沙',
            },
          ],
          'reason': 'test',
        },
      );
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        ledger: ledger,
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: <String>['灵梦', '艾琳', '魔理沙', '慧音'],
      );

      expect(trace.chosen, '魔理沙');
      expect(trace.arbitration, isNotNull);
      expect(trace.stateDelta!.items.single.itemId, 'item:kit');
      expect(ledger.byId('item:kit')!.location, 'char:魔理沙');
      expect(ledger.byId('char:信标')!.inventory, isEmpty);
      expect(ledger.byId('char:魔理沙')!.inventory, contains('item:kit'));
    });

    test('startSeq 让新事件接着已有编号', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(choices: <String?>['慧音']);
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        startSeq: 5,
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: <String>['灵梦', '艾琳', '魔理沙', '慧音'],
      );
      expect(trace.events.single.id, 'E5');
    });

    test('newEvents 已占 E12 时 CH_ACT 从 E13 开始，不重号', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e12 = const WorldEvent(
        id: 'E12',
        kind: WorldEventKind.speech,
        content: '门没有锁。',
        actor: 'char:信标',
        target: 'char:艾琳',
        delivery: Delivery(
          channel: DeliveryChannel.voice,
          form: 'spoken',
          audience: Audience.scene,
        ),
      );
      final FakeAgents agents = FakeAgents(
        choices: <String?>['慧音'],
        perceptEventId: 'E12',
      );
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        startSeq: 12,
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e12],
        npcNames: <String>['灵梦', '艾琳', '魔理沙', '慧音'],
      );
      expect(trace.events.single.id, 'E13');
    });

    test('只有 speech 的 state_delta 被拒绝，修正后才落账', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final Map<String, Object?> bad = speechAction('我没事。');
      bad['state_delta'] = <String, Object?>{
        'move': <String, Object?>{'信标': '仓房'},
      };
      final FakeAgents agents = FakeAgents(
        choices: <String?>['慧音'],
        actions: <Map<String, Object?>>[
          bad,
          speechAction('我没事，先站着。'),
        ],
      );
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: <String>['灵梦', '艾琳', '魔理沙', '慧音'],
      );
      expect(trace.actErrors.first.code, 'state_delta_without_action');
      expect(trace.events.single.content, '我没事，先站着。');
    });

    test('动作摘要去掉重复 actor 和句首“她”', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(
        choices: <String?>['慧音'],
        action: actionWithText('她偏过头看向信标'),
      );
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: <String>['灵梦', '艾琳', '魔理沙', '慧音'],
      );
      expect(trace.events.single.summary, '慧音偏过头看向信标');
    });

    test('CH_ACT 的 state_delta 进 TurnTrace', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(
        choices: <String?>['慧音'],
        action: actionWithDelta(),
      );
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: <String>['灵梦', '艾琳', '魔理沙', '慧音'],
      );
      expect(trace.stateDelta, isNotNull);
      expect(trace.stateDelta!.moves['慧音'], '仓房');
    });

    test('CH_ACT requires 撞上 cannot 会回给 CH_ACT 重写', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(
        choices: <String?>['慧音'],
        actions: <Map<String, Object?>>[
          actionWithRequires('use_left_arm'),
          actionWithText('偏过头'),
        ],
      );
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        constraints: const <FunctionalConstraint>[
          FunctionalConstraint(
            who: '慧音',
            capability: 'use_left_arm',
            state: ConstraintState.cannot,
            reason: '左肩刀伤',
          ),
        ],
        parallelPlaceCandidates: const <ParallelPlaceCandidate>[
          ParallelPlaceCandidate(place: '仓房', members: <String>['人物2']),
        ],
        openPlaceDecider: ({
          required NarrativeScene scene,
          required List<WorldEvent> events,
          List<String>? errors,
          OpenPlaceResult? previous,
        }) async =>
            const OpenPlaceResult(openParallelPlace: true, place: '仓房', why: 'test-openPlace'),
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: <String>['灵梦', '艾琳', '魔理沙', '慧音'],
      );
      expect(trace.actErrors.single.code, 'capability_blocked');
      expect(trace.openPlace.why, 'test-openPlace');
      expect(trace.events.length, 1);
      expect(trace.blocked, isEmpty);
    });

    test('CH_ACT 缺 requires 变成 observation，同一回合修正', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(
        choices: <String?>['慧音'],
        actions: <Map<String, Object?>>[
          actionWithoutRequires(),
          actionWithText('偏过头'),
        ],
      );
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        actStepBudget: 3,
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: <String>['灵梦', '艾琳', '魔理沙', '慧音'],
      );
      expect(trace.events.length, 1);
      expect(trace.stop, isNull);
      expect(trace.actErrors.single.code, 'missing_requires');
      expect(agents.perceiveHistory.length, 2);
      expect(agents.perceiveHistory[1], contains('missing_requires'));
    });

    test('CH_ACT segment 的 kind 不合法时不能落账，修正后才算合格', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final Map<String, Object?> bad = speechAction('在心里盘算');
      final List<Object?> segs = bad['segments']! as List<Object?>;
      (segs.first! as Map<String, Object?>)['kind'] = 'inner';
      final FakeAgents agents = FakeAgents(
        choices: <String?>['慧音'],
        actions: <Map<String, Object?>>[
          bad,
          speechAction('我听见了。'),
        ],
      );
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        actStepBudget: 3,
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: <String>['灵梦', '艾琳', '魔理沙', '慧音'],
      );
      expect(trace.stop, isNull);
      expect(trace.actErrors.single.code, 'segment_kind');
      expect(trace.events.length, 1);
    });

    test('CH_ACT 连续不合格耗尽 step 预算就停，不落账', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(
        choices: <String?>['慧音'],
        actions: <Map<String, Object?>>[
          actionWithoutRequires(),
          actionWithoutRequires(),
        ],
      );
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        actStepBudget: 2,
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: <String>['灵梦', '艾琳', '魔理沙', '慧音'],
      );
      expect(trace.stop?.code, 'step_budget');
      expect(trace.actErrors.length, 2);
      expect(trace.events, isEmpty);
      expect(trace.render, isNull);
    });

    test('CH_ACT 返回 status=stop 算契约错误，重写后落账', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(
        choices: <String?>['慧音'],
        actions: <Map<String, Object?>>[
          stopAction(),
          speechAction('我听见了。'),
        ],
      );
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        actStepBudget: 2,
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: <String>['灵梦', '艾琳', '魔理沙', '慧音'],
      );
      expect(trace.actErrors.single.code, 'status_not_allowed');
      expect(trace.stop, isNull);
      expect(trace.events.length, 1);
      expect(trace.render, isNotNull);
    });

    test('GM_NARRATE 硬校验拦住瞎编台词', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(
        choices: <String?>['慧音'],
        action: speechAction('我听见了。'),
        renderText: '“我没听见。”',
      );
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        rStepBudget: 1,
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: <String>['灵梦', '艾琳', '魔理沙', '慧音'],
      );
      expect(trace.renderViolations.single.code, 'invented_quote');
      expect(trace.events.length, 1);
    });

    test('GM_NARRATE 硬校验失败会回给 GM_NARRATE 重写', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(
        choices: <String?>['慧音'],
        action: speechAction('我听见了。'),
        renderTexts: <String>['“我没听见。”', '我听见了。'],
      );
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        rStepBudget: 2,
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: <String>['灵梦', '艾琳', '魔理沙', '慧音'],
      );
      expect(trace.renderViolations, isEmpty);
      expect(agents.rFeedback.length, 2);
      expect(agents.rFeedback[1], isNotEmpty);
      expect(trace.events.length, 1);
    });

    test('没人有资格行动时回退到环境更新', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(choices: <String?>['慧音']);
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        routeDecider: ({
          required NarrativeScene scene,
          required List<WorldEvent> events,
          List<String>? errors,
          String? previous,
        }) async =>
            'turn',
        environmentSource: ({
          required NarrativeScene scene,
          required List<WorldEvent> events,
          String? feedback,
        }) async =>
            <WorldEvent>[
          WorldEvent(
            id: 'E9',
            kind: WorldEventKind.action,
            content: '雨声更密了。',
            actor: '',
            delivery: const Delivery(
              channel: DeliveryChannel.other,
              form: 'narration',
              audience: Audience.scene,
            ),
            source: 'environment',
            placeId: '东门内侧',
          ),
        ],
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: const <String>[],
      );
      expect(trace.route, 'env');
      expect(trace.chosen, isNull);
      expect(trace.environmentEvents.single.content, '雨声更密了。');
    });

    test('环境事件 SYS_RECORD 校验失败会回给 GM_ENV_UPDATE 重写', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(choices: <String?>['慧音']);
      int calls = 0;
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        environmentStepBudget: 2,
        routeDecider: ({
          required NarrativeScene scene,
          required List<WorldEvent> events,
          List<String>? errors,
          String? previous,
        }) async =>
            'env',
        environmentSource: ({
          required NarrativeScene scene,
          required List<WorldEvent> events,
          String? feedback,
        }) async {
          calls++;
          return <WorldEvent>[
            WorldEvent(
              id: 'E9',
              kind: WorldEventKind.action,
              content: '雨声更密了。',
              actor: '',
              delivery: Delivery(
                channel: DeliveryChannel.other,
                form: 'narration',
                audience: calls == 1 ? Audience.unknown : Audience.scene,
              ),
              source: 'environment',
              placeId: '东门内侧',
            ),
          ];
        },
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: const <String>[],
      );
      expect(calls, 2);
      expect(trace.environmentErrors, isEmpty);
      expect(trace.environmentEvents.single.content, '雨声更密了。');
    });

    test('CH_PERCEIVE 引用候选集外的事件会被拒绝', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(
        choices: <String?>['慧音'],
        perceptEventId: 'E999',
      );
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        perceiveStepBudget: 2,
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: <String>['慧音'],
      );
      expect(trace.perceiveErrors, isNotEmpty);
      expect(trace.perceiveErrors.every((String e) => e.contains('E999')), isTrue);
      expect(trace.events, isEmpty);
    });

    test('CH_PERCEIVE 引用候选集外的事件会回给 CH_PERCEIVE 重写', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(
        choices: <String?>['慧音'],
        perceptEventIds: <String>['E999', 'E1'],
      );
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        perceiveStepBudget: 2,
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: <String>['慧音'],
      );
      expect(trace.perceiveErrors, isEmpty);
      expect(trace.events.length, 1);
      expect(trace.chosen, '慧音');
    });

    test('GM_OPEN_PLACE/GM_ENV_UPDATE/GM_MERGE_PLACE 记录和全知 POV 参数走通', () async {
      final NarrativeScene scene = NarrativeScene(
        place: '东门内侧',
        cast: const <CharacterSnapshot>[],
        names: const <String, String>{},
      );
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(choices: <String?>['慧音']);
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        pov: RenderPov.omniscient,
        parallelPlaceCandidates: const <ParallelPlaceCandidate>[
          ParallelPlaceCandidate(place: '仓房', members: <String>['人物2']),
        ],
        otherParallelPlaces: const <ParallelPlaceInfo>[
          ParallelPlaceInfo(id: 'l2', place: '仓房'),
        ],
        openPlaceDecider: ({
          required NarrativeScene scene,
          required List<WorldEvent> events,
          List<String>? errors,
          OpenPlaceResult? previous,
        }) async =>
            const OpenPlaceResult(openParallelPlace: false, why: 'test-openPlace'),
        routeDecider: ({
          required NarrativeScene scene,
          required List<WorldEvent> events,
          List<String>? errors,
          String? previous,
        }) async =>
            'env',
        environmentSource: ({
          required NarrativeScene scene,
          required List<WorldEvent> events,
          String? feedback,
        }) async =>
            <WorldEvent>[
          WorldEvent(
            id: 'E9',
            kind: WorldEventKind.action,
            content: '下雨了。',
            actor: '',
            delivery: const Delivery(
              channel: DeliveryChannel.other,
              form: 'narration',
              audience: Audience.scene,
            ),
            source: 'environment',
            placeId: '东门内侧',
          ),
        ],
        mergePlaceDecider: ({
          required NarrativeScene scene,
          required List<WorldEvent> events,
        }) async =>
            const MergePlaceResult(merge: true, into: 'l2', why: 'test-mergePlace'),
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: <String>[],
      );
      expect(trace.openPlace.why, 'test-openPlace');
      expect(trace.environmentEvents.single.summary, '下雨了。');
      expect(trace.mergePlace.merge, isTrue);
      expect(agents.lastPov, RenderPov.omniscient);
    });

    test('GM_OPEN_PLACE 有候选地点时才问，并把候选成员带出来', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(choices: <String?>['慧音']);
      int calls = 0;
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        parallelPlaceCandidates: const <ParallelPlaceCandidate>[
          ParallelPlaceCandidate(place: '仓房', members: <String>['人物2', '人物3']),
        ],
        openPlaceDecider: ({
          required NarrativeScene scene,
          required List<WorldEvent> events,
          List<String>? errors,
          OpenPlaceResult? previous,
        }) async {
          calls++;
          return const OpenPlaceResult(openParallelPlace: true, place: '仓房', why: '切过去');
        },
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: <String>['灵梦', '艾琳', '魔理沙', '慧音'],
      );
      expect(calls, 1);
      expect(trace.openPlace.openParallelPlace, isTrue);
      expect(trace.openPlace.place, '仓房');
      expect(trace.openPlace.members, <String>['人物2', '人物3']);
    });

    test('GM_OPEN_PLACE 一次能开多个并行地点，空地点也允许', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(choices: <String?>['慧音']);
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        parallelPlaceCandidates: const <ParallelPlaceCandidate>[
          ParallelPlaceCandidate(place: '仓房', members: <String>['人物2']),
          ParallelPlaceCandidate(place: '后巷', members: <String>[]),
        ],
        openPlaceDecider: ({
          required NarrativeScene scene,
          required List<WorldEvent> events,
          List<String>? errors,
          OpenPlaceResult? previous,
        }) async =>
            const OpenPlaceResult(
          openParallelPlace: true,
          why: '火势蔓延，同时切两处',
          openings: <ParallelPlaceOpening>[
            ParallelPlaceOpening(place: '仓房', why: '火势蔓延'),
            ParallelPlaceOpening(place: '后巷', why: '烟从后巷冒出来'),
          ],
        ),
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: <String>['灵梦', '艾琳', '魔理沙', '慧音'],
      );
      expect(trace.openPlace.allOpenings.map((ParallelPlaceOpening e) => e.place),
          <String>['仓房', '后巷']);
      expect(trace.openPlace.allOpenings[0].members, <String>['人物2']);
      expect(trace.openPlace.allOpenings[1].members, isEmpty);
    });

    test('GM_OPEN_PLACE 选候选外的地点会回给 GM_OPEN_PLACE 重写', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(choices: <String?>['慧音']);
      int calls = 0;
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        parallelPlaceCandidates: const <ParallelPlaceCandidate>[
          ParallelPlaceCandidate(place: '仓房', members: <String>['人物2']),
        ],
        openPlaceDecider: ({
          required NarrativeScene scene,
          required List<WorldEvent> events,
          List<String>? errors,
          OpenPlaceResult? previous,
        }) async {
          calls++;
          return calls == 1
              ? const OpenPlaceResult(openParallelPlace: true, place: '后巷', why: '乱选')
              : const OpenPlaceResult(openParallelPlace: true, place: '仓房', why: '改对');
        },
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: <String>['灵梦', '艾琳', '魔理沙', '慧音'],
      );
      expect(calls, 2);
      expect(trace.openPlaceErrors, isEmpty);
      expect(trace.openPlace.openParallelPlace, isTrue);
      expect(trace.openPlace.place, '仓房');
    });

    test('GM_OPEN_PLACE 连续不合格才报错，不推进回合', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(choices: <String?>['慧音']);
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        openPlaceStepBudget: 2,
        parallelPlaceCandidates: const <ParallelPlaceCandidate>[
          ParallelPlaceCandidate(place: '仓房', members: <String>['人物2']),
        ],
        openPlaceDecider: ({
          required NarrativeScene scene,
          required List<WorldEvent> events,
          List<String>? errors,
          OpenPlaceResult? previous,
        }) async =>
            const OpenPlaceResult(openParallelPlace: true, place: '后巷', why: '乱选'),
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: <String>['灵梦', '艾琳', '魔理沙', '慧音'],
      );
      expect(trace.openPlaceErrors, isNotEmpty);
      expect(trace.events, isEmpty);
    });

    test('GM_ROUTE 返回无效值会回给 GM_ROUTE 重写', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(choices: <String?>['慧音']);
      int calls = 0;
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        routeStepBudget: 2,
        routeDecider: ({
          required NarrativeScene scene,
          required List<WorldEvent> events,
          List<String>? errors,
          String? previous,
        }) async {
          calls++;
          return calls == 1 ? 'ENV' : 'env';
        },
        environmentSource: ({
          required NarrativeScene scene,
          required List<WorldEvent> events,
          String? feedback,
        }) async =>
            <WorldEvent>[
          WorldEvent(
            id: 'E9',
            kind: WorldEventKind.action,
            content: '下雨了。',
            actor: '',
            delivery: const Delivery(
              channel: DeliveryChannel.other,
              form: 'narration',
              audience: Audience.scene,
            ),
            source: 'environment',
            placeId: '东门内侧',
          ),
        ],
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: const <String>[],
      );
      expect(calls, 2);
      expect(trace.routeErrors, isEmpty);
      expect(trace.route, 'env');
      expect(trace.environmentEvents, isNotEmpty);
    });

    test('GM_ROUTE 请求玩家帮助后带回答继续', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(choices: <String?>['慧音']);
      int calls = 0;
      String? asked;
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        askPlayer: (PlayerQuestion q) async {
          asked = q.question;
          return 'env';
        },
        routeDecider: ({
          required NarrativeScene scene,
          required List<WorldEvent> events,
          List<String>? errors,
          String? previous,
        }) async {
          calls++;
          if (calls == 1) {
            throw const AskPlayerException(
              PlayerQuestion(
                step: 'GM_ROUTE',
                code: 'need_route',
                reason: '测试',
                question: '走哪条？',
              ),
            );
          }
          return 'env';
        },
        environmentSource: ({
          required NarrativeScene scene,
          required List<WorldEvent> events,
          String? feedback,
        }) async =>
            <WorldEvent>[
          WorldEvent(
            id: 'E9',
            kind: WorldEventKind.action,
            content: '下雨了。',
            actor: '',
            delivery: const Delivery(
              channel: DeliveryChannel.other,
              form: 'narration',
              audience: Audience.scene,
            ),
            source: 'environment',
            placeId: '东门内侧',
          ),
        ],
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: const <String>[],
      );
      expect(calls, 2);
      expect(asked, '走哪条？');
      expect(trace.routeErrors, isEmpty);
      expect(trace.route, 'env');
    });

    test('玩家取消求助只暂停，不抛普通错误', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(choices: <String?>['慧音']);
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        askPlayer: (PlayerQuestion q) async => null,
        routeDecider: ({
          required NarrativeScene scene,
          required List<WorldEvent> events,
          List<String>? errors,
          String? previous,
        }) async =>
            throw const AskPlayerException(
              PlayerQuestion(
                step: 'GM_ROUTE',
                code: 'need_route',
                reason: '测试',
                question: '走哪条？',
              ),
            ),
      );
      await expectLater(
        loop.run(
          newEvents: <WorldEvent>[e1],
          npcNames: const <String>[],
        ),
        throwsA(isA<PlayerPausedException>()),
      );
    });

    test('GM_ROUTE 连续无效才报错，不推进回合', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(choices: <String?>['慧音']);
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        routeStepBudget: 2,
        routeDecider: ({
          required NarrativeScene scene,
          required List<WorldEvent> events,
          List<String>? errors,
          String? previous,
        }) async =>
            'ENV',
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: const <String>[],
      );
      expect(trace.routeErrors, isNotEmpty);
      expect(trace.events, isEmpty);
    });

    test('GM_MERGE_PLACE 只有一条线时不问', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(choices: <String?>['慧音']);
      int calls = 0;
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        mergePlaceDecider: ({
          required NarrativeScene scene,
          required List<WorldEvent> events,
        }) async {
          calls++;
          return const MergePlaceResult(merge: true, into: 'l2', why: '不该问');
        },
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: <String>['灵梦', '艾琳', '魔理沙', '慧音'],
      );
      expect(calls, 0);
      expect(trace.mergePlace.merge, isFalse);
      expect(trace.mergePlace.why, contains('没有其他未合并序列'));
    });

    test('GM_MERGE_PLACE 本线还有角色时不问', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(choices: <String?>['慧音']);
      int calls = 0;
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        otherParallelPlaces: const <ParallelPlaceInfo>[
          ParallelPlaceInfo(id: 'l2', place: '仓房'),
        ],
        mergePlaceDecider: ({
          required NarrativeScene scene,
          required List<WorldEvent> events,
        }) async {
          calls++;
          return const MergePlaceResult(merge: true, into: 'l2', why: '不该问');
        },
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: <String>['灵梦', '艾琳', '魔理沙', '慧音'],
      );
      expect(calls, 0);
      expect(trace.mergePlace.merge, isFalse);
      expect(trace.mergePlace.why, contains('还有角色'));
    });

    test('GM_MERGE_PLACE 目标不存在时不合并', () async {
      final NarrativeScene scene = NarrativeScene(
        place: '东门内侧',
        cast: const <CharacterSnapshot>[],
        names: const <String, String>{},
      );
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(choices: <String?>['慧音']);
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        otherParallelPlaces: const <ParallelPlaceInfo>[
          ParallelPlaceInfo(id: 'l2', place: '仓房'),
        ],
        routeDecider: ({
          required NarrativeScene scene,
          required List<WorldEvent> events,
          List<String>? errors,
          String? previous,
        }) async =>
            'env',
        environmentSource: ({
          required NarrativeScene scene,
          required List<WorldEvent> events,
          String? feedback,
        }) async =>
            <WorldEvent>[
          WorldEvent(
            id: 'E9',
            kind: WorldEventKind.action,
            content: '下雨了。',
            actor: '',
            delivery: const Delivery(
              channel: DeliveryChannel.other,
              form: 'narration',
              audience: Audience.scene,
            ),
            source: 'environment',
            placeId: '东门内侧',
          ),
        ],
        mergePlaceDecider: ({
          required NarrativeScene scene,
          required List<WorldEvent> events,
        }) async =>
            const MergePlaceResult(merge: true, into: 'l9', why: '乱并'),
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: <String>[],
      );
      expect(trace.mergePlace.merge, isFalse);
      expect(trace.mergePlace.why, contains('不存在'));
    });

    test('GM_MERGE_PLACE 在本线所有人都走光后才问，并能合并', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(
        choices: <String?>['慧音'],
        action: moveEveryoneAction(),
      );
      int calls = 0;
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
        otherParallelPlaces: const <ParallelPlaceInfo>[
          ParallelPlaceInfo(id: 'l2', place: '仓房'),
        ],
        mergePlaceDecider: ({
          required NarrativeScene scene,
          required List<WorldEvent> events,
        }) async {
          calls++;
          return const MergePlaceResult(merge: true, into: 'l2', why: '人走光了');
        },
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: <String>['灵梦', '艾琳', '魔理沙', '慧音'],
      );
      expect(calls, 1);
      expect(trace.mergePlace.merge, isTrue);
      expect(trace.mergePlace.into, 'l2');
    });

    test('GM_RESOLVE_ACTION outcome/deltas 不合法就不落账', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(
        choices: <String?>['慧音'],
        action: stealAction(),
        arbitration: <String, Object?>{
          'outcome': 'bad',
          'deltas': <Object?>[],
          'reason': '',
        },
      );
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: <String>['灵梦', '艾琳', '魔理沙', '慧音'],
      );
      expect(trace.resolveErrors, isNotEmpty);
      expect(trace.events, isEmpty);
    });

    test('事件带 effects / witnesses / accepted 状态', () async {
      final NarrativeScene scene = buildScene();
      final WorldEvent e1 = playerEvent();
      final FakeAgents agents = FakeAgents(
        choices: <String?>['慧音'],
        action: actionWithDelta(),
      );
      final TurnLoop loop = TurnLoop(
        scene: scene,
        agents: agents,
      );
      final TurnTrace trace = await loop.run(
        newEvents: <WorldEvent>[e1],
        npcNames: <String>['灵梦', '艾琳', '魔理沙', '慧音'],
      );
      final WorldEvent event = trace.events.single;
      expect(event.effects.single['kind'], 'move');
      expect(event.witnesses, isNotEmpty);
      expect(event.status, WorldEventStatus.accepted);
      expect(event.publicText, '渲染结果');
    });
  });
}
