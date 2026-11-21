import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/engine/character_memory.dart';
import 'package:joenws/engine/intent_beat.dart';
import 'package:joenws/engine/memory_agent.dart';
import 'package:joenws/engine/perception.dart';
import 'package:joenws/engine/sequence.dart';
import 'package:joenws/engine/turn_loop.dart';
import 'package:joenws/engine/turn_session.dart';

NarrativeScene buildScene() => NarrativeScene(
      place: '东门内侧',
      names: <String, String>{
        'char:灵梦': '灵梦',
        'char:魔理沙': '魔理沙',
      },
      cast: <CharacterSnapshot>[
        CharacterSnapshot(
          id: 'char:灵梦',
          name: '灵梦',
          nearby: true,
          aliases: <String, String>{'char:魔理沙': '那个黑白'},
        ),
        CharacterSnapshot(
          id: 'char:魔理沙',
          name: '魔理沙',
          nearby: true,
          aliases: <String, String>{'char:灵梦': '巫女'},
        ),
      ],
    );

WorldEvent speechFrom(String actor, String target, String text) => WorldEvent(
      id: 'E0',
      kind: WorldEventKind.speech,
      content: text,
      actor: actor,
      target: target,
      delivery: const Delivery(
        channel: DeliveryChannel.voice,
        form: 'spoken',
        audience: Audience.target,
      ),
    );

class FakeIntentAgents implements IntentBeatAgents {
  FakeIntentAgents({
    required this.intents,
    required this.claims,
    required this.settlements,
  });

  final Map<String, CharacterIntent> intents;
  final Map<String, PublicClaim> claims;
  final Map<String, IntentSettlement> settlements;

  int intendCalls = 0;
  int fileCalls = 0;
  int adjudicateCalls = 0;
  final Map<String, String> deliveredText = <String, String>{};
  final Map<String, String> recalledText = <String, String>{};

  @override
  Future<CharacterIntent> intend({
    required String actor,
    required String delivered,
    required String recalled,
    required List<String> present,
  }) async {
    intendCalls++;
    deliveredText[actor] = delivered;
    recalledText[actor] = recalled;
    return intents[actor]!;
  }

  @override
  Future<PublicClaim> fileClaim({
    required CharacterIntent intent,
    required String publicScene,
    required Map<String, String> aliases,
    required List<String> knownEntities,
  }) async {
    fileCalls++;
    return claims[intent.id]!;
  }

  @override
  Future<List<IntentSettlement>> adjudicateBeat({
    required List<PublicClaim> claims,
    required String objectiveWorld,
    required List<String> present,
  }) async {
    adjudicateCalls++;
    return <IntentSettlement>[
      for (final PublicClaim c in claims) settlements[c.intentId]!,
    ];
  }

  @override
  Future<Map<String, String>> observeOutcome({
    required IntentSettlement settlement,
    required String objectiveWorld,
    required String observerId,
  }) async =>
      <String, String>{observerId: '$observerId 看到了一点动静'};

  @override
  Future<List<MemoryOperation>?> rememberOutcome({
    required String actor,
    required CharacterIntent intent,
    required IntentSettlement settlement,
    required List<CharacterMemory> memory,
    required Set<String> allowedEventIds,
  }) async =>
      null;

  @override
  Future<List<MemoryOperation>?> rememberWitness({
    required String actor,
    required WorldEvent event,
    required String seenText,
    required List<CharacterMemory> memory,
    required Set<String> allowedEventIds,
  }) async =>
      null;
}

CharacterIntent intentOf(String actor, String text) => CharacterIntent(
      id: 'i-$actor',
      actor: 'char:$actor',
      text: text,
      desired: text,
    );

PublicClaim claimOf(String actor, String text, {String targetId = ''}) =>
    PublicClaim(
      intentId: 'i-$actor',
      actor: 'char:$actor',
      kind: 'action',
      text: text,
      targetId: targetId,
    );

class FakeTurnAgents extends TurnAgents {
  @override
  Future<Map<String, Object?>> perceive({
    required String name,
    required String context,
    required String events,
  }) async =>
      <String, Object?>{};

  @override
  void setPlayerHelp(Map<String, String> help) {}

  @override
  void recordPlayerAnswer(String journalKey, String answer) {}

  @override
  Future<Map<String, Object?>> render({
    required List<WorldEvent> events,
    RenderPov pov = RenderPov.omniscient,
    String observerId = '',
    NarrativeScene? scene,
    List<String> errors = const <String>[],
    Map<String, Object?>? previous,
  }) async =>
      <String, Object?>{'public_text': '意图回合。', 'god_note': ''};
}

void main() {
  test('一拍只有一个行动者：意图、立案、裁决、事件、行动者与目击者记忆', () async {
    final NarrativeScene scene = buildScene();
    final MemoryStore memory = MemoryStore();
    final FakeIntentAgents agents = FakeIntentAgents(
      intents: <String, CharacterIntent>{
        '灵梦': intentOf('灵梦', '我想拦住那个黑白'),
      },
      claims: <String, PublicClaim>{
        'i-灵梦': claimOf('灵梦', '灵梦想要拦住魔理沙', targetId: 'char:魔理沙'),
      },
      settlements: <String, IntentSettlement>{
        'i-灵梦': IntentSettlement(
          intentId: 'i-灵梦',
          actor: 'char:灵梦',
          result: 'success',
          resultText: '灵梦挡在魔理沙前面',
          selfText: '你挡在她前面，她停住了',
          observers: <String, String>{'char:魔理沙': '你被灵梦挡住了'},
          stateDelta: <String, Object?>{
            'constraints': <Object?>[
              <String, Object?>{
                'who': 'char:魔理沙',
                'capability': 'run',
                'state': 'cannot',
                'reason': '被灵梦挡住',
              },
            ],
          },
        ),
      },
    );
    final IntentBeat beat = IntentBeat(
      scene: scene,
      agents: agents,
      memory: memory,
      startSeq: 1,
    );

    final IntentBeatResult result = await beat.run(
      actor: '灵梦',
      incoming: <WorldEvent>[
        speechFrom('char:魔理沙', 'char:灵梦', '让开。'),
      ],
      objectiveWorld: '{}',
    );

    expect(result.ok, isTrue);
    expect(agents.intendCalls, 1);
    expect(agents.fileCalls, 1);
    expect(agents.adjudicateCalls, 1);
    expect(result.event, isNotNull);
    expect(result.event!.outcome, 'success');
    expect(result.event!.result, '灵梦挡在魔理沙前面');
    expect(result.event!.stateChanges['constraints'], isA<List<Object?>>());

    final List<CharacterMemory> ling = memory.forCharacter('char:灵梦');
    final List<CharacterMemory> mari = memory.forCharacter('char:魔理沙');
    expect(ling, hasLength(1));
    expect(ling.single.text, contains('拦住那个黑白'));
    expect(ling.single.text, contains('你挡在她前面'));
    expect(ling.single.sourceEvents, contains(result.event!.id));
    expect(mari, hasLength(1));
    expect(mari.single.text, contains('你被灵梦挡住了'));
    expect(mari.single.sourceEvents, contains(result.event!.id));
  });

  test('立案的 intent_id 对不上，整拍不落账', () async {
    final FakeIntentAgents agents = FakeIntentAgents(
      intents: <String, CharacterIntent>{
        '灵梦': intentOf('灵梦', '我想拦住那个黑白'),
      },
      claims: <String, PublicClaim>{
        'i-灵梦': const PublicClaim(
          intentId: 'i-别人的',
          actor: 'char:灵梦',
          kind: 'action',
          text: '灵梦想要拦住魔理沙',
        ),
      },
      settlements: const <String, IntentSettlement>{},
    );
    final IntentBeat beat = IntentBeat(
      scene: buildScene(),
      agents: agents,
      memory: MemoryStore(),
    );

    final IntentBeatResult result = await beat.run(
      actor: '灵梦',
      incoming: const <WorldEvent>[],
      objectiveWorld: '{}',
      cast: <String>['灵梦'],
    );

    expect(result.ok, isFalse);
    expect(result.event, isNull);
    expect(result.memories, isEmpty);
    expect(result.errors.single, contains('intent_id'));
  });

  test('投递只给行动者自己能感知的事件', () async {
    final FakeIntentAgents agents = FakeIntentAgents(
      intents: <String, CharacterIntent>{
        '灵梦': intentOf('灵梦', '我想等她说完'),
      },
      claims: <String, PublicClaim>{
        'i-灵梦': claimOf('灵梦', '灵梦想要等她说完'),
      },
      settlements: <String, IntentSettlement>{
        'i-灵梦': const IntentSettlement(
          intentId: 'i-灵梦',
          actor: 'char:灵梦',
          result: 'success',
          resultText: '灵梦等着',
          selfText: '你等着',
        ),
      },
    );
    final WorldEvent whisper = WorldEvent(
      id: 'E9',
      kind: WorldEventKind.speech,
      content: '只对你说。',
      actor: 'char:魔理沙',
      target: 'char:灵梦',
      delivery: const Delivery(
        channel: DeliveryChannel.voice,
        form: 'whisper',
        audience: Audience.target,
      ),
    );
    final IntentBeat beat = IntentBeat(
      scene: buildScene(),
      agents: agents,
      memory: MemoryStore(),
    );

    await beat.run(
      actor: '灵梦',
      incoming: <WorldEvent>[whisper],
      objectiveWorld: '{}',
    );

    expect(agents.deliveredText['灵梦'], contains('只对你说。'));
  });

  test('玩家角色走自己的意图来源，不走 NPC 的 intend', () async {
    final FakeIntentAgents agents = FakeIntentAgents(
      intents: <String, CharacterIntent>{
        '灵梦': intentOf('灵梦', 'NPC 不该被调用'),
      },
      claims: <String, PublicClaim>{
        'i-灵梦': claimOf('灵梦', '灵梦想要拦住她'),
      },
      settlements: <String, IntentSettlement>{
        'i-灵梦': const IntentSettlement(
          intentId: 'i-灵梦',
          actor: 'char:灵梦',
          result: 'success',
          resultText: '灵梦拦住了',
          selfText: '你拦住了',
        ),
      },
    );
    bool playerCalled = false;
    final IntentBeat beat = IntentBeat(
      scene: buildScene(),
      agents: agents,
      memory: MemoryStore(),
      controlledCharacter: '灵梦',
      playerIntent: (String actor) async {
        playerCalled = true;
        return intentOf('灵梦', '我要拦她');
      },
    );

    final IntentBeatResult result = await beat.run(
      actor: '灵梦',
      incoming: const <WorldEvent>[],
      objectiveWorld: '{}',
    );

    expect(playerCalled, isTrue);
    expect(agents.intendCalls, 0, reason: '玩家不占 NPC 的 intend 调用');
    expect(result.ok, isTrue);
  });

  test('结算状态变化不合格整拍不落账', () async {
    final FakeIntentAgents agents = FakeIntentAgents(
      intents: <String, CharacterIntent>{
        '灵梦': intentOf('灵梦', '我想拦住她'),
      },
      claims: <String, PublicClaim>{
        'i-灵梦': claimOf('灵梦', '灵梦想要拦住她'),
      },
      settlements: <String, IntentSettlement>{
        'i-灵梦': const IntentSettlement(
          intentId: 'i-灵梦',
          actor: 'char:灵梦',
          result: 'success',
          resultText: '灵梦拦住了',
          selfText: '你拦住了',
          stateDelta: <String, Object?>{
            'constraints': <Object?>[
              <String, Object?>{
                'who': 'char:魔理沙',
                'capability': 'run',
                'state': 'not-a-state',
              },
            ],
          },
        ),
      },
    );
    final IntentBeatResult result = await IntentBeat(
      scene: buildScene(),
      agents: agents,
      memory: MemoryStore(),
    ).run(
      actor: '灵梦',
      incoming: const <WorldEvent>[],
      objectiveWorld: '{}',
    );

    expect(result.ok, isFalse);
    expect(result.event, isNull);
    expect(result.errors.join(), contains('结算状态变化不合格'));
  });

  test('从 checkpoint 恢复：不再调用模型，事件和记忆沿用', () async {
    final NarrativeScene scene = buildScene();
    final MemoryStore memory = MemoryStore();
    final FakeIntentAgents agents = FakeIntentAgents(
      intents: <String, CharacterIntent>{
        '灵梦': intentOf('灵梦', '我想拦住那个黑白'),
      },
      claims: <String, PublicClaim>{
        'i-灵梦': claimOf('灵梦', '灵梦想要拦住魔理沙', targetId: 'char:魔理沙'),
      },
      settlements: <String, IntentSettlement>{
        'i-灵梦': const IntentSettlement(
          intentId: 'i-灵梦',
          actor: 'char:灵梦',
          result: 'success',
          resultText: '灵梦挡在魔理沙前面',
          selfText: '你挡在她前面',
        ),
      },
    );
    final Map<String, Map<String, Object?>> saved =
        <String, Map<String, Object?>>{};
    final IntentBeat first = IntentBeat(
      scene: scene,
      agents: agents,
      memory: memory,
      onCheckpoint: (String stage, Map<String, Object?> data) =>
          saved[stage] = data,
    );
    final IntentBeatResult one = await first.run(
      actor: '灵梦',
      incoming: const <WorldEvent>[],
      objectiveWorld: '{}',
    );
    expect(one.ok, isTrue);
    final int intents = agents.intendCalls;
    final int files = agents.fileCalls;
    final int rulings = agents.adjudicateCalls;

    final IntentBeat second = IntentBeat(
      scene: scene,
      agents: agents,
      memory: memory,
      checkpoints: saved,
      onCheckpoint: (String stage, Map<String, Object?> data) =>
          saved[stage] = data,
    );
    final IntentBeatResult two = await second.run(
      actor: '灵梦',
      incoming: const <WorldEvent>[],
      objectiveWorld: '{}',
    );

    expect(two.ok, isTrue);
    expect(agents.intendCalls, intents);
    expect(agents.fileCalls, files);
    expect(agents.adjudicateCalls, rulings);
    expect(two.event!.id, one.event!.id);
    expect(two.memories['char:灵梦']!.single.text,
        contains('你挡在她前面'));
  });

  test('未决裁定也落事件，不丢结果', () async {
    final FakeIntentAgents agents = FakeIntentAgents(
      intents: <String, CharacterIntent>{
        '灵梦': intentOf('灵梦', '我想试着推门'),
      },
      claims: <String, PublicClaim>{
        'i-灵梦': claimOf('灵梦', '灵梦试着推门'),
      },
      settlements: <String, IntentSettlement>{
        'i-灵梦': const IntentSettlement(
          intentId: 'i-灵梦',
          actor: 'char:灵梦',
          result: 'unresolved',
          resultText: '门后传来什么，还看不清',
          selfText: '你还没看清门后',
        ),
      },
    );
    final IntentBeatResult result = await IntentBeat(
      scene: buildScene(),
      agents: agents,
      memory: MemoryStore(),
    ).run(
      actor: '灵梦',
      incoming: const <WorldEvent>[],
      objectiveWorld: '{}',
    );

    expect(result.ok, isTrue);
    expect(result.event!.outcome, 'unresolved');
    expect(result.event!.result, '门后传来什么，还看不清');
  });

  test('召回只把选中的记忆交给意图', () async {
    final MemoryStore memory = MemoryStore(<CharacterMemory>[
      const CharacterMemory(
        id: 'm1',
        characterId: 'char:灵梦',
        text: '记得钥匙在仓房',
        kind: MemoryKind.episodic,
      ),
      const CharacterMemory(
        id: 'm2',
        characterId: 'char:灵梦',
        text: '不相关的旧事',
        kind: MemoryKind.episodic,
      ),
    ]);
    final FakeIntentAgents agents = FakeIntentAgents(
      intents: <String, CharacterIntent>{
        '灵梦': intentOf('灵梦', '我去看看钥匙'),
      },
      claims: <String, PublicClaim>{
        'i-灵梦': claimOf('灵梦', '灵梦走向仓房'),
      },
      settlements: <String, IntentSettlement>{
        'i-灵梦': const IntentSettlement(
          intentId: 'i-灵梦',
          actor: 'char:灵梦',
          result: 'success',
          resultText: '灵梦走到仓房',
          selfText: '你走到仓房',
        ),
      },
    );
    final IntentBeat beat = IntentBeat(
      scene: buildScene(),
      agents: agents,
      memory: memory,
      recall: ({
        required String characterId,
        required String delivered,
        required List<CharacterMemory> active,
      }) async =>
          <String>['m1'],
    );
    final IntentBeatResult result = await beat.run(
      actor: '灵梦',
      incoming: const <WorldEvent>[],
      objectiveWorld: '{}',
    );

    expect(result.ok, isTrue);
    expect(agents.recalledText['灵梦'], contains('记得钥匙在仓房'));
    expect(agents.recalledText['灵梦'], isNot(contains('不相关的旧事')));
  });

  test('跨地点移动会给目的地角色问到达见闻', () async {
    final NarrativeScene scene = buildScene();
    final MemoryStore memory = MemoryStore();
    final FakeIntentAgents agents = FakeIntentAgents(
      intents: <String, CharacterIntent>{
        '灵梦': intentOf('灵梦', '我去仓房'),
      },
      claims: <String, PublicClaim>{
        'i-灵梦': claimOf('灵梦', '灵梦走向仓房'),
      },
      settlements: <String, IntentSettlement>{
        'i-灵梦': const IntentSettlement(
          intentId: 'i-灵梦',
          actor: 'char:灵梦',
          result: 'success',
          resultText: '灵梦走进仓房',
          selfText: '你走进仓房',
          stateDelta: <String, Object?>{
            'move': <String, Object?>{'灵梦': '仓房'},
          },
        ),
      },
    );
    final IntentBeat beat = IntentBeat(
      scene: scene,
      agents: agents,
      memory: memory,
      sceneAt: (String place, Map<String, Object?> delta) => NarrativeScene(
        place: place,
        names: const <String, String>{'char:艾琳': '艾琳'},
        cast: <CharacterSnapshot>[
          CharacterSnapshot(id: 'char:艾琳', name: '艾琳', nearby: true),
        ],
      ),
    );
    final IntentBeatResult result = await beat.run(
      actor: '灵梦',
      incoming: const <WorldEvent>[],
      objectiveWorld: '{}',
    );

    expect(result.ok, isTrue);
    expect(result.event!.observations['char:艾琳'], contains('看到了一点动静'));
    expect(result.memories['char:艾琳'], isNotEmpty);
  });

  test('TurnLoop 的意图分支走完整拍', () async {
    final NarrativeScene scene = buildScene();
    final FakeIntentAgents agents = FakeIntentAgents(
      intents: <String, CharacterIntent>{
        '灵梦': intentOf('灵梦', '我要等她说完'),
      },
      claims: <String, PublicClaim>{
        'i-灵梦': claimOf('灵梦', '灵梦想要等她说完'),
      },
      settlements: <String, IntentSettlement>{
        'i-灵梦': const IntentSettlement(
          intentId: 'i-灵梦',
          actor: 'char:灵梦',
          result: 'success',
          resultText: '灵梦等着',
          selfText: '你等着',
        ),
      },
    );
    final TurnLoop loop = TurnLoop(
      scene: scene,
      agents: FakeTurnAgents(),
      memoryStore: MemoryStore(),
      intentAgents: agents,
      openPlaceDecider: ({
        required NarrativeScene scene,
        required List<WorldEvent> events,
        List<String>? errors,
        OpenPlaceResult? previous,
      }) async =>
          const OpenPlaceResult(openParallelPlace: false, why: '测试'),
      routeDecider: ({
        required NarrativeScene scene,
        required List<WorldEvent> events,
        List<String>? errors,
        String? previous,
      }) async =>
          'turn',
    );
    final TurnTrace trace = await loop.run(
      newEvents: const <WorldEvent>[],
      actorNames: <String>['灵梦'],
    );
    expect(trace.events, hasLength(1));
    expect(trace.eligible, <String>['灵梦']);
    expect(trace.chosen, '灵梦');
    expect(trace.render?['public_text'], '意图回合。');
    expect(trace.stop, isNull);
  });

  test('TurnLoop 单步在 CH_INTENT 暂停，恢复不重复调意图', () async {
    final FakeIntentAgents agents = FakeIntentAgents(
      intents: <String, CharacterIntent>{
        '灵梦': intentOf('灵梦', '我要等她说完'),
      },
      claims: <String, PublicClaim>{
        'i-灵梦': claimOf('灵梦', '灵梦想要等她说完'),
      },
      settlements: <String, IntentSettlement>{
        'i-灵梦': const IntentSettlement(
          intentId: 'i-灵梦',
          actor: 'char:灵梦',
          result: 'success',
          resultText: '灵梦等着',
          selfText: '你等着',
        ),
      },
    );
    final Map<String, TurnCheckpoint> checkpoints = <String, TurnCheckpoint>{};
    final TurnLoop first = TurnLoop(
      scene: buildScene(),
      agents: FakeTurnAgents(),
      memoryStore: MemoryStore(),
      intentAgents: agents,
      openPlaceDecider: ({
        required NarrativeScene scene,
        required List<WorldEvent> events,
        List<String>? errors,
        OpenPlaceResult? previous,
      }) async =>
          const OpenPlaceResult(openParallelPlace: false, why: '测试'),
      routeDecider: ({
        required NarrativeScene scene,
        required List<WorldEvent> events,
        List<String>? errors,
        String? previous,
      }) async =>
          'turn',
      onCheckpoint: (String stage, Map<String, Object?> data) {
        checkpoints[stage] = TurnCheckpoint(stage: stage, data: data);
        if (stage == 'CH_INTENT:灵梦') throw StagePause(stage);
      },
    );
    await expectLater(
      first.run(newEvents: const <WorldEvent>[], actorNames: <String>['灵梦']),
      throwsA(isA<StagePause>()),
    );
    final int calls = agents.intendCalls;
    expect(calls, 1);

    final TurnLoop resumed = TurnLoop(
      scene: buildScene(),
      agents: FakeTurnAgents(),
      memoryStore: MemoryStore(),
      intentAgents: agents,
      openPlaceDecider: ({
        required NarrativeScene scene,
        required List<WorldEvent> events,
        List<String>? errors,
        OpenPlaceResult? previous,
      }) async =>
          const OpenPlaceResult(openParallelPlace: false, why: '测试'),
      routeDecider: ({
        required NarrativeScene scene,
        required List<WorldEvent> events,
        List<String>? errors,
        String? previous,
      }) async =>
          'turn',
    );
    final TurnTrace trace = await resumed.run(
      newEvents: const <WorldEvent>[],
      actorNames: <String>['灵梦'],
      resume: TurnSession(
        worldId: '',
        parallelPlaceId: '',
        rawInput: '',
        journal: TurnJournal(),
        checkpoints: checkpoints,
      ),
    );

    expect(trace.events, hasLength(1));
    expect(agents.intendCalls, calls);
  });

  test('角色走光后会询问并行地点合并', () async {
    final FakeIntentAgents agents = FakeIntentAgents(
      intents: <String, CharacterIntent>{
        '灵梦': intentOf('灵梦', '我去仓房'),
      },
      claims: <String, PublicClaim>{
        'i-灵梦': claimOf('灵梦', '灵梦走向仓房'),
      },
      settlements: <String, IntentSettlement>{
        'i-灵梦': const IntentSettlement(
          intentId: 'i-灵梦',
          actor: 'char:灵梦',
          result: 'success',
          resultText: '灵梦走进仓房',
          selfText: '你走进仓房',
          stateDelta: <String, Object?>{
            'move': <String, Object?>{'灵梦': '仓房', '魔理沙': '仓房'},
          },
        ),
      },
    );
    final TurnLoop loop = TurnLoop(
      scene: buildScene(),
      agents: FakeTurnAgents(),
      memoryStore: MemoryStore(),
      intentAgents: agents,
      otherParallelPlaces: const <ParallelPlaceInfo>[
        ParallelPlaceInfo(id: 'b', place: '仓房'),
      ],
      openPlaceDecider: ({
        required NarrativeScene scene,
        required List<WorldEvent> events,
        List<String>? errors,
        OpenPlaceResult? previous,
      }) async =>
          const OpenPlaceResult(openParallelPlace: false, why: '测试'),
      routeDecider: ({
        required NarrativeScene scene,
        required List<WorldEvent> events,
        List<String>? errors,
        String? previous,
      }) async =>
          'turn',
      mergePlaceDecider: ({
        required NarrativeScene scene,
        required List<WorldEvent> events,
      }) async =>
          const MergePlaceResult(merge: true, into: 'b', why: '本线走光了'),
    );
    final TurnTrace trace = await loop.run(
      newEvents: const <WorldEvent>[],
      actorNames: <String>['灵梦'],
    );

    expect(trace.mergePlace.merge, isTrue);
    expect(trace.mergePlace.into, 'b');
  });
}
