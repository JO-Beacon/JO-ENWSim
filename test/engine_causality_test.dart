import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/data/world_store.dart';
import 'package:joenws/engine/agents/llm_agent_runner.dart';
import 'package:joenws/engine/c_writer.dart';
import 'package:joenws/engine/causal_context.dart';
import 'package:joenws/engine/character_memory.dart';
import 'package:joenws/engine/engine_state.dart';
import 'package:joenws/engine/memory_agent.dart';
import 'package:joenws/engine/perception.dart';
import 'package:joenws/engine/state_delta.dart';
import 'package:joenws/engine/turn_loop.dart';
import 'package:joenws/engine/turn_session.dart';
import 'package:joenws/engine/world_adapter.dart';
import 'package:joenws/model/llm_client.dart';
import 'package:joenws/model/provider.dart';
import 'package:joenws/model/turn.dart';

import 'engine_turn_loop_test.dart' as turns;
import 'engine_world_adapter_test.dart' as worlds;

TurnState worldState({List<FactRecord> facts = const [], List<InnerEntry> inner = const [],
    List<WorldEvent> events = const []}) => TurnState(
  events: events,
  entities: <String, EntityRecord>{
    for (final String name in turns.buildScene().names.values)
      'char:$name': EntityRecord(id: 'char:$name', kind: 'character', name: name, location: '东门内侧'),
    for (final String place in <String>['东门内侧', '仓房'])
      'place:$place': EntityRecord(id: 'place:$place', kind: 'place', name: place),
    'item:包': const EntityRecord(id: 'item:包', kind: 'item', name: '包', location: '信标'),
    'cont:箱': const EntityRecord(id: 'cont:箱', kind: 'container', name: '箱', location: '东门内侧'),
  },
  locations: <String, String>{for (final String name in turns.buildScene().names.values) name: '东门内侧'},
  inventories: const {'信标': ['item:包']},
  facts: facts,
  inner: inner,
);

Map<String, Object?> ruling({String outcome = 'failure', String result = '没有拿到包',
    Map<String, String> observations = const {'char:慧音': '手被挡住，没拿到包'},
    List<Object?> deltas = const [], List<Object?> facts = const []}) => <String, Object?>{
  'outcome': outcome, 'result': result, 'observations': observations,
  'deltas': deltas, 'facts': facts, 'reason': '依据当前位置、归属和防备',
};

class CausalAgents extends turns.FakeAgents {
  CausalAgents({super.action, Map<String, Object?>? arbitration, this.forget = false})
      : super(choices: ['慧音'], arbitration: arbitration ?? ruling());
  final bool forget;
  final List<String> perceptionInputs = [];
  final List<String> roleContexts = [];
  Map<String, Map<String, Object?>> scheduling = {};
  String? targetSeen;

  @override
  Future<Map<String, Object?>> perceive({required String name, required String context, required String events}) async {
    perceptionInputs.add(events);
    roleContexts.add(context);
    return <String, Object?>{
      'percepts': <Object?>[for (final String line in events.split('\n'))
        if (line.isNotEmpty) <String, Object?>{'event_id': line.split(' ').first, 'content': line}],
      'attention': '继续原来的打算',
    };
  }

  @override
  Future<List<MemoryOperation>?> manageMemory({required String characterId,
      required Map<String, Object?> percepts, required List<CharacterMemory> memory,
      required Set<String> allowedEventIds}) async => forget ? <MemoryOperation>[] : null;

  @override
  Future<String?> selectActor({required List<String> eligible,
      required Map<String, Map<String, Object?>> percepts, String playerNotes = '',
      List<String> errors = const [], String? previous}) async {
    scheduling = percepts;
    return '慧音';
  }

  @override
  Future<Map<String, Object?>> act({required String name, required String context,
      required String perceive, required List<String> present}) {
    roleContexts.add(context);
    return super.act(name: name, context: context, perceive: perceive, present: present);
  }

  @override
  Future<Map<String, Object?>> adjudicate({required Map<String, Object?> action,
      required String actor, required String? target, required String place,
      required List<String> present, List<String> errors = const [],
      Map<String, Object?>? previous, String playerNotes = ''}) {
    targetSeen = target;
    return super.adjudicate(action: action, actor: actor, target: target, place: place,
        present: present, errors: errors, previous: previous, playerNotes: playerNotes);
  }
}

TurnLoop loopFor(CausalAgents agents, {TurnState? state, NarrativeScene? scene, MemoryStore? memory,
    CheckpointCallback? onCheckpoint}) => TurnLoop(
  scene: scene ?? turns.buildScene(), agents: agents,
  causalContext: CausalContext(state: state ?? worldState(), rules: '能力必须遵守世界规则'),
  memoryStore: memory, onCheckpoint: onCheckpoint,
  startSeq: 50,
);

Future<TurnTrace> runLoop(TurnLoop loop, {List<WorldEvent> events = const [], TurnSession? resume}) => loop.run(
  newEvents: events, actorNames: ['慧音'], perceptionNames: ['慧音'], resume: resume,
);

void main() {
  test('世界规则和权威状态进入真实裁定请求', () async {
    final List<String> inputs = [];
    for (final String rules in ['魔法不能穿透铁门', '魔法可以穿透铁门']) {
      final LlmAgentRunner runner = LlmAgentRunner(
        provider: const Provider(id: 'p', protocol: Protocol.deepseekAnthropic, name: 'test'),
        apiKey: 'unused', model: 'test', causalContext: CausalContext(state: worldState(), rules: rules),
        sender: (LlmRequest request) async {
          inputs.add(request.messages.single.content);
          return LlmReply(text: jsonEncode(ruling()));
        },
      );
      await runner.adjudicate(action: turns.stealAction(), actor: '慧音', target: '信标',
          place: '东门内侧', present: ['慧音', '信标']);
    }
    expect(inputs[0], contains('魔法不能穿透铁门'));
    expect(inputs[1], contains('魔法可以穿透铁门'));
    expect(inputs[0], contains('item:包'));
    expect(inputs[0], contains('inventories'));
    expect(inputs[0], contains('ongoing_processes'));
  });

  test('裁定请求跨回合复用规则和未变化的世界现状前缀', () async {
    final List<LlmRequest> requests = <LlmRequest>[];
    for (final int turn in <int>[12, 13]) {
      final LlmAgentRunner runner = LlmAgentRunner(
        provider: const Provider(id: 'p', protocol: Protocol.deepseekAnthropic, name: 'test'),
        apiKey: 'unused',
        model: 'test',
        causalContext: CausalContext(
          state: worldState(events: <WorldEvent>[turns.playerEvent().copyWith(turnIndex: turn)]),
          rules: '魔法不能穿透铁门',
        ),
        sender: (LlmRequest request) async {
          requests.add(request);
          return LlmReply(text: jsonEncode(ruling()));
        },
      );
      await runner.adjudicate(
        action: <String, Object?>{'intent': '尝试 $turn'},
        actor: '慧音', target: '信标', place: '东门内侧', present: <String>['慧音', '信标'],
      );
    }
    expect(requests.last.system, requests.first.system);
    final String first = requests.first.messages.single.content;
    final String second = requests.last.messages.single.content;
    final String prefix = first.split('"world_step":12').first;
    expect(prefix, contains('魔法不能穿透铁门'));
    expect(prefix, contains('item:包'));
    expect(prefix, contains('ongoing_processes'));
    expect(second, startsWith('${prefix}"world_step":13'));
    expect(second, contains('尝试 13'));
  });

  test('普通拿取未知物品必须裁定，失败不能凭提案造物', () async {
    final Map<String, Object?> action = turns.actionWithText('伸手拿钥匙')
      ..['resolution'] = 'direct'
      ..['state_delta'] = {'items': [{'kind': 'take', 'item_id': 'item:未知', 'from': 'cont:箱', 'to': '慧音'}]};
    final CausalAgents agents = CausalAgents(action: action);
    final TurnTrace trace = await runLoop(loopFor(agents));
    expect(agents.resolveFeedback, hasLength(1));
    expect(trace.stateDelta, isNull);
    final WorldEvent attempt = trace.events.single;
    expect(attempt.content, '伸手拿钥匙');
    expect(attempt.outcome, 'failure');
    expect(worldState().applyDelta(trace.stateDelta ?? const StateDelta()).entities.containsKey('item:未知'), isFalse);
  });

  test('他人的移动提案交给裁定，不由普通行动直接写入', () async {
    final CausalAgents agents = CausalAgents(action: turns.actionWithText('示意灵梦去仓房')
      ..['resolution'] = 'direct' ..['state_delta'] = {'move': {'灵梦': '仓房'}});
    final TurnTrace trace = await runLoop(loopFor(agents));
    expect(agents.resolveFeedback, hasLength(1));
    expect(trace.stateDelta, isNull);
  });

  test('前置条件未知时，直接动作仍然进入裁定', () async {
    final CausalAgents agents = CausalAgents(action: turns.actionWithText('敲门')
      ..['resolution'] = 'direct'
      ..['preconditions'] = [{'subject': 'place:东门内侧', 'predicate': 'door_open', 'object': 'true'}]);
    await runLoop(loopFor(agents));
    expect(agents.resolveFeedback, hasLength(1));
  });

  test('短台词目标不会覆盖实际行动目标', () async {
    final Map<String, Object?> action = turns.stealAction();
    (action['segments'] as List).insert(0, (turns.speechAction('请等等')['segments'] as List).single
      ..['target'] = '艾琳');
    final CausalAgents agents = CausalAgents(action: action);
    await runLoop(loopFor(agents));
    expect(agents.targetSeen, '信标');
  });

  test('一回合不能塞入多个行动，拒绝整份记录', () async {
    final Map<String, Object?> action = turns.stealAction();
    (action['segments'] as List).add((turns.actionWithText('然后离开')['segments'] as List).single);
    final TurnTrace trace = await runLoop(loopFor(CausalAgents(action: action)));
    expect(trace.events, isEmpty);
    expect(trace.actErrors.first.code, 'action_boundary');
  });

  test('错误物品来源与重复转移会整体拒绝且不污染原状态', () {
    final TurnState state = worldState();
    expect(() => state.applyDelta(const StateDelta(items: [
      StateItemDelta(kind: 'take', itemId: 'item:包', from: '慧音', to: '灵梦'),
    ])), throwsStateError);
    expect(() => state.applyDelta(const StateDelta(items: [
      StateItemDelta(kind: 'give', itemId: 'item:包', from: '信标', to: '慧音'),
      StateItemDelta(kind: 'give', itemId: 'item:包', from: '信标', to: '灵梦'),
    ])), throwsStateError);
    expect(state.inventories['信标'], ['item:包']);
  });

  test('有依据的新物品和容器归属保持一致', () {
    final TurnState found = worldState().applyDelta(const StateDelta(discoveries: [
      EntityDiscovery(id: 'item:钥匙', kind: 'item', name: '钥匙', location: 'cont:箱', evidence: '打开箱子看见钥匙'),
    ]));
    expect(found.entities['cont:箱']!.contains, ['item:钥匙']);
    final TurnState taken = found.applyDelta(const StateDelta(items: [
      StateItemDelta(kind: 'take', itemId: 'item:钥匙', from: 'cont:箱', to: '慧音'),
    ]));
    expect(taken.entities['cont:箱']!.contains, isEmpty);
    expect(taken.inventories['慧音'], ['item:钥匙']);
    expect(taken.transitionErrors(const StateDelta()), isEmpty);
  });

  test('角色不能直接跨地点转移他人物品', () {
    final TurnState state = worldState().applyDelta(const StateDelta(moves: {'信标': '仓房'}));
    expect(state.transitionErrors(const StateDelta(items: [
      StateItemDelta(kind: 'take', itemId: 'item:包', from: '信标', to: '慧音'),
    ]), actor: '慧音', place: '东门内侧', adjudicated: false), isNotEmpty);
  });

  test('成功与失败分别持久化，并给下一回合不同结果见闻', () async {
    final List<String> nextInputs = [];
    for (final bool success in [false, true]) {
      final CausalAgents agents = CausalAgents(action: turns.stealAction(), arbitration: ruling(
        outcome: success ? 'success' : 'failure', result: success ? '包已到慧音手中' : '包仍由信标持有',
        observations: {'char:慧音': success ? '我已握住包' : '我的手被挡开'},
        deltas: success ? [{'kind': 'steal', 'item_id': 'item:包', 'from': '信标', 'to': '慧音'}] : [],
      ));
      final TurnTrace trace = await runLoop(loopFor(agents));
      expect(trace.resolveErrors, isEmpty);
      final TurnState next = worldState().withEvents(trace.events).applyDelta(trace.stateDelta ?? const StateDelta());
      expect(next.inventories[success ? '慧音' : '信标'], contains('item:包'));
      final TurnState restored = TurnState.decode(next.encode());
      final CausalAgents follower = CausalAgents();
      await runLoop(loopFor(follower, state: restored), events: restored.events);
      nextInputs.add(follower.perceptionInputs.single);
    }
    expect(nextInputs[0], contains('我的手被挡开'));
    expect(nextInputs[1], contains('我已握住包'));
    expect(nextInputs[0], isNot(nextInputs[1]));
  });

  test('客观秘密与裁定原因不混进任何角色观察', () async {
    final TurnTrace trace = await runLoop(loopFor(CausalAgents(action: turns.stealAction(), arbitration: ruling(
      result: '暗格里藏有追踪器', observations: {},
    ))));
    final WorldEvent event = trace.events.single;
    expect(event.result, contains('追踪器'));
    expect(event.witnesses, isNotEmpty);
    expect(event.witnesses.map((Witness w) => w.content).join(), isNot(contains('追踪器')));
    expect(event.witnesses.map((Witness w) => w.content).join(), isNot(contains('裁定依据')));
  });

  test('隐蔽行动者知道自己的尝试，结果观察者只知道看见的结果', () {
    final WorldEvent event = turns.playerEvent().copyWith(source: 'player', observationsResolved: true,
        observations: {'char:慧音': '门自行合上'});
    final WorldEvent hidden = WorldEvent(id: event.id, kind: event.kind, content: '秘密口令', actor: event.actor,
      source: 'player', delivery: const Delivery(channel: DeliveryChannel.voice, form: 'whisper', audience: Audience.hidden),
      result: '秘密机关启动', observationsResolved: true, observations: event.observations);
    final List<Witness> witnesses = const PerceptionEngine().witnesses(hidden, turns.buildScene());
    expect(witnesses.firstWhere((Witness w) => w.characterId == 'char:信标').content, contains('秘密口令'));
    final String resultOnly = witnesses.firstWhere((Witness w) => w.characterId == 'char:慧音').content;
    expect(resultOnly, contains('门自行合上'));
    expect(resultOnly, isNot(contains('秘密口令')));
    expect(resultOnly, isNot(contains('秘密机关')));
  });

  test('已交付但没形成记忆也不会下回合重播或自动补种', () async {
    final CausalAgents agents = CausalAgents(forget: true);
    final TurnLoop first = loopFor(agents);
    await runLoop(first, events: [turns.playerEvent()]);
    expect(first.memory.allEntries(), isEmpty);
    final List<WorldEvent> history = historyAfterDelivery(events: [turns.playerEvent()], receipts: first.deliveryReceipts);
    final WorldEvent restored = worldEventFromJson(worldEventToJson(history.single));
    expect(restored.receivedBy, contains('char:慧音'));
    final CausalAgents second = CausalAgents();
    await runLoop(loopFor(second), events: [restored]);
    expect(second.perceptionInputs, isEmpty);
    expect(WorldAdapter(world: worlds.buildWorld(), parallelPlaceId: 'l1', priorEvents: [restored]).memorySeed(), isEmpty);
  });

  test('切换地点仅消费当前接收者，其他接收者仍保留待交付事件', () {
    final WorldEvent event = turns.playerEvent().copyWith(witnessesResolved: true, witnesses: const [
      Witness(characterId: 'char:慧音', modality: 'hearing', content: '见闻甲'),
      Witness(characterId: 'char:灵梦', modality: 'hearing', content: '见闻乙'),
    ]);
    final List<WorldEvent> pending = pendingAfterDelivery(incoming: [event], generated: [], receipts: {'E1': {'char:慧音'}});
    expect(pending, hasLength(1));
    expect(pending.single.receivedBy, ['char:慧音']);
    expect(pendingAfterDelivery(incoming: pending, generated: [], receipts: {'E1': {'char:灵梦'}}), isEmpty);
  });

  test('uid 补齐前后的事件合并回执且不重复历史', () {
    final WorldEvent old = turns.playerEvent().copyWith(uid: 'uid-1', receivedBy: ['char:灵梦']);
    final List<WorldEvent> merged = historyAfterDelivery(events: [old, turns.playerEvent()], receipts: {'E1': {'char:慧音'}});
    expect(merged, hasLength(1));
    expect(merged.single.uid, 'uid-1');
    expect(merged.single.receivedBy, containsAll(['char:灵梦', 'char:慧音']));
  });

  test('已确定无人见证的旧事件不会让后来者补看', () async {
    final WorldEvent unseen = turns.playerEvent().copyWith(witnessesResolved: true, witnesses: []);
    final CausalAgents agents = CausalAgents();
    await runLoop(loopFor(agents), events: [unseen]);
    expect(agents.perceptionInputs, isEmpty);
    expect(pendingAfterDelivery(incoming: [unseen], generated: [], receipts: {}), isEmpty);
  });

  test('暂停恢复 CH_PERCEIVE 和空记忆写入仍恢复交付回执', () async {
    final Map<String, TurnCheckpoint> saved = {};
    final TurnLoop initial = loopFor(CausalAgents(forget: true), onCheckpoint: (String stage, Map<String, Object?> data) {
      saved[stage] = TurnCheckpoint(stage: stage, data: data);
    });
    await runLoop(initial, events: [turns.playerEvent()]);
    for (final bool withMemory in [false, true]) {
      final CausalAgents agents = CausalAgents(forget: true);
      final TurnLoop resumed = loopFor(agents);
      await runLoop(resumed, events: [turns.playerEvent()], resume: TurnSession(
        worldId: 'w', parallelPlaceId: 'l1', rawInput: '', journal: TurnJournal(),
        checkpoints: {for (final MapEntry<String, TurnCheckpoint> e in saved.entries)
          if (e.key == 'CH_PERCEIVE:慧音' || (withMemory && e.key == 'CH_MEMORY_WRITE:慧音')) e.key: e.value},
      ));
      expect(agents.perceptionInputs, isEmpty);
      expect(resumed.deliveryReceipts['E1'], contains('char:慧音'));
    }
  });

  test('没有新刺激仍将旧承诺和当前念头交给调度', () async {
    final MemoryStore memory = MemoryStore();
    memory.restoreCharacter('char:慧音', [const CharacterMemory(id: 'm', characterId: 'char:慧音',
      text: '我答应去取药', attention: '先履行承诺')]);
    final CausalAgents agents = CausalAgents();
    await runLoop(loopFor(agents, memory: memory, state: worldState(inner: [
      const InnerEntry(id: 'i', characterId: 'char:慧音', text: '还没把药取回来'),
    ])));
    expect(jsonEncode(agents.scheduling['慧音']), contains('我答应去取药'));
    expect(jsonEncode(agents.scheduling['慧音']), contains('还没把药取回来'));
    expect(jsonEncode(agents.scheduling['慧音']), contains('先履行承诺'));
  });

  test('秘密事实、他人内心与上帝补充按角色隔离', () async {
    final TurnState state = worldState(facts: const [
      FactRecord(id: 'secret', subject: 'place:东门内侧', predicate: '机关', object: '暗格追踪器'),
      FactRecord(id: 'public', subject: 'place:东门内侧', predicate: '门', object: '已锁', visibility: 'public'),
    ], inner: const [InnerEntry(id: 'i', characterId: 'char:灵梦', text: '我准备背叛慧音')]);
    final NarrativeScene base = turns.buildScene();
    final NarrativeScene scene = NarrativeScene(place: base.place, cast: base.cast, names: base.names,
      playerNotes: '上帝秘密', characterNotes: {'char:慧音': '我亲眼看见了门锁'});
    final CausalAgents agents = CausalAgents();
    await runLoop(loopFor(agents, state: state, scene: scene), events: [turns.playerEvent()]);
    final String contexts = agents.roleContexts.join('\n');
    expect(contexts, contains('已锁'));
    expect(contexts, contains('我亲眼看见了门锁'));
    expect(contexts, isNot(contains('追踪器')));
    expect(contexts, isNot(contains('背叛')));
    expect(contexts, isNot(contains('上帝秘密')));
  });

  test('其他阶段求助回答不会从请求注入角色', () async {
    final List<String> inputs = [];
    final LlmAgentRunner runner = LlmAgentRunner(
      provider: const Provider(id: 'p', protocol: Protocol.deepseekAnthropic, name: 'test'),
      apiKey: 'unused', model: 'test', sender: (LlmRequest request) async {
        inputs.add(request.messages.map((LlmMessage m) => m.content).join());
        return const LlmReply(text: '{"percepts":[],"attention":"观察"}');
      },
    );
    runner.setPlayerHelp({'GM_RESOLVE_ACTION': '秘密房间有追踪器'});
    await runner.perceive(name: '慧音', context: '', events: 'E1 门关上');
    expect(inputs.single, isNot(contains('秘密房间')));
  });

  test('环境持久事实进入下一轮裁定且隐藏事实不公开', () async {
    final StateDelta changes = StateDelta(facts: const [
      StateFactDelta(subject: 'place:东门内侧', predicate: 'door', object: 'locked', evidence: '门闩落下', visibility: 'public'),
      StateFactDelta(subject: 'place:东门内侧', predicate: 'trap', object: 'armed', evidence: '机关接通'),
    ]);
    final TurnLoop loop = TurnLoop(scene: turns.buildScene(), agents: CausalAgents(),
      causalContext: CausalContext(state: worldState()),
      routeDecider: ({required scene, required events, errors = const [], previous}) async => 'env',
      environmentSource: ({required scene, required events, feedback}) async => [WorldEvent(
        id: 'ENV-1', kind: WorldEventKind.action, content: '门闩落下', actor: '', source: 'environment',
        delivery: const Delivery(channel: DeliveryChannel.other, form: 'narration', audience: Audience.scene),
        stateChanges: changes.toJson(), effects: changes.effectRecords,
      )],
    );
    final TurnTrace trace = await runLoop(loop);
    expect(trace.environmentErrors, isEmpty);
    expect(trace.environmentEvents, hasLength(1));
    final TurnState after = TurnState.decode(worldState().withEvents(trace.environmentEvents)
        .applyDelta(trace.stateDelta!, atTurn: 1).encode());
    expect(CausalContext(state: after).godText('东门内侧'), contains('armed'));
    expect(CausalContext(state: after).characterView('char:慧音', turns.buildScene()), contains('locked'));
    expect(trace.environmentEvents.single.witnesses.map((Witness w) => w.content).join(), isNot(contains('armed')));
  });

  test('旅行跨存档和地点切换保持过程，必须先开始再完成到达', () {
    ProcessDelta travel(String status, {String destination = '仓房'}) => ProcessDelta(
      id: 'process:旅行', place: '东门内侧', owner: '慧音', kind: 'travel', status: status,
      description: '前往仓房途中', completionCondition: '走过庭院并到达门口', destination: destination,
    );
    final TurnState start = worldState().applyDelta(StateDelta(processes: [travel('ongoing')]), atTurn: 1);
    final TurnState saved = TurnState.decode(start.withEvents([
      turns.playerEvent().copyWith(turnIndex: 2, placeId: '仓房'),
    ]).encode());
    expect(saved.ongoingProcesses.single.state['started_turn'], 1);
    expect(saved.locations['慧音'], '东门内侧');
    expect(() => saved.applyDelta(const StateDelta(moves: {'慧音': '仓房'})), throwsStateError);
    expect(() => worldState().applyDelta(StateDelta(moves: const {'慧音': '仓房'}, processes: [travel('completed')])), throwsStateError);
    expect(() => saved.applyDelta(StateDelta(processes: [travel('ongoing', destination: '东门内侧')])), throwsStateError);
    final TurnState arrived = saved.applyDelta(StateDelta(moves: const {'慧音': '仓房'}, processes: [travel('completed')]), atTurn: 3);
    expect(arrived.locations['慧音'], '仓房');
    expect(arrived.ongoingProcesses, isEmpty);
    expect(arrived.entities['process:旅行']!.state['updated_turn'], 3);
    expect(() => arrived.applyDelta(StateDelta(processes: [travel('completed')])), throwsStateError);
  });

  test('上帝补充默认私有，指定角色与公开补充才进入相应输入', () {
    final WorldAdapter adapter = WorldAdapter(world: worlds.buildWorld(), parallelPlaceId: 'l1', priorAnswers: const [
      PlayerAnswer(step: 'GM_RESOLVE_ACTION', question: '秘密', answer: '上帝知道的真相'),
      PlayerAnswer(step: 'GM_ENV_UPDATE', question: '观察', answer: '大家看见烟雾', visibility: 'public'),
      PlayerAnswer(step: 'GM_SELECT_ACTOR', question: '回忆', answer: '灵梦自己的记忆', visibility: 'character', characterId: 'char:灵梦'),
    ]);
    final NarrativeScene scene = adapter.scene();
    expect(scene.playerNotes, contains('上帝知道的真相'));
    expect(scene.characterNotes['char:信标'], contains('大家看见烟雾'));
    expect(scene.characterNotes['char:信标'], isNot(contains('上帝知道的真相')));
    expect(scene.characterNotes['char:信标'], isNot(contains('灵梦自己的记忆')));
    expect(scene.characterNotes['char:灵梦'], contains('灵梦自己的记忆'));
  });

  test('默认陌生称呼不暴露身份，初始地点实体统一使用名称键', () {
    final WorldAdapter adapter = WorldAdapter(world: worlds.buildWorld(), parallelPlaceId: 'l1');
    expect(adapter.scene().byId('char:信标')!.aliases['char:灵梦'], startsWith('陌生人'));
    expect(adapter.seedEntities()['place:东门内侧']!.kind, 'place');
    expect(adapter.seedEntities()['place:仓房']!.kind, 'place');
    expect(adapter.memorySeed(), isEmpty);
  });

  test('已裁定无人见证的结果和共同顺序能持久化', () {
    final WorldEvent event = const CWriter().commit(event: turns.playerEvent().copyWith(
        turnIndex: 7, duration: 'extended', observationsResolved: true, observations: {},
        outcome: 'unresolved', result: '结果暂时不明'), scene: turns.buildScene(), engine: const PerceptionEngine());
    final TurnState restored = TurnState.decode(TurnState(events: [event,
      event.copyWith(turnIndex: 100, status: WorldEventStatus.rejected)]).encode());
    expect(restored.worldStep, 7);
    expect(restored.events.first.observationsResolved, isTrue);
    expect(restored.events.first.duration, 'extended');
  });

  test('数据库再次提交历史时保留回执、结果、事实和持续过程', () {
    final WorldStore store = WorldStore.memory()..seedDemo();
    addTearDown(store.close);
    final world = store.loadWorlds().worlds.first;
    final String placeId = world.parallelPlaces.first.id;
    final WorldEvent event = turns.playerEvent().copyWith(uid: 'uid-causal', turnIndex: 1,
      observationsResolved: true, observations: {'char:慧音': '门已经锁上'},
      outcome: 'success', result: '门闩落下', witnessesResolved: true,
      witnesses: const [Witness(characterId: 'char:慧音', modality: 'hearing', content: '听见门闩落下')]);
    void save(TurnState state) => store.commitTurn(worldId: world.id, parallelPlaceId: placeId,
      stateJson: state.encodeCheckpoint(), events: state.events, memory: state.memory,
      mainStep: const TurnStep(kind: 'CH_ACT', text: '门闩落下'), world: world);
    save(worldState().withEvents([event]).applyDelta(const StateDelta(
      facts: [StateFactDelta(subject: 'place:东门内侧', predicate: 'door', object: 'locked', evidence: '门闩落下')],
      processes: [ProcessDelta(id: 'process:火', place: '东门内侧', description: '火正在烧', completionCondition: '燃料耗尽')],
    ), atTurn: 1));
    final TurnState loaded = store.loadTurnState(world.id)!;
    save(loaded.withEvents(historyAfterDelivery(events: loaded.events, receipts: {'uid-causal': {'char:慧音'}})));
    final TurnState restored = store.loadTurnState(world.id)!;
    expect(restored.events, hasLength(1));
    expect(restored.events.single.receivedBy, ['char:慧音']);
    expect(restored.events.single.result, '门闩落下');
    expect(restored.events.single.observations['char:慧音'], '门已经锁上');
    expect(restored.facts.single.evidence, '门闩落下');
    expect(restored.ongoingProcesses.single.state['started_turn'], 1);
    expect(() => save(restored.withEvents([restored.events.single.copyWith(result: '改写既有历史')])), throwsStateError);
    expect(store.loadTurnState(world.id)!.events.single.result, '门闩落下');
    expect(store.deleteLatestWorldTurn(world.id), isTrue);
    expect(store.loadTurnState(world.id)!.events.single.receivedBy, isEmpty);
  });

  test('恢复的旧裁定也必须满足当前结果协议', () async {
    final TurnSession saved = TurnSession(worldId: 'w', parallelPlaceId: 'l1', rawInput: '', journal: TurnJournal(),
      checkpoints: {'GM_RESOLVE_ACTION': const TurnCheckpoint(stage: 'GM_RESOLVE_ACTION', data: {'arbitration': {
        'outcome': 'success', 'deltas': [], 'reason': '旧裁定缺失实际结果',
      }})});
    await expectLater(runLoop(loopFor(CausalAgents(action: turns.stealAction())), resume: saved), throwsFormatException);
  });

  test('恢复的环境事件仍会校验，不能夹带角色移动', () async {
    final WorldEvent invalid = turns.playerEvent().copyWith(source: 'environment',
        stateChanges: const {'move': {'慧音': '仓房'}});
    final TurnSession saved = TurnSession(worldId: 'w', parallelPlaceId: 'l1', rawInput: '', journal: TurnJournal(),
      checkpoints: {
        'GM_ROUTE': const TurnCheckpoint(stage: 'GM_ROUTE', data: {'route': 'env'}),
        'GM_ENV_UPDATE': TurnCheckpoint(stage: 'GM_ENV_UPDATE', data: {'events': [worldEventToJson(invalid)]}),
      });
    await expectLater(runLoop(loopFor(CausalAgents()), resume: saved), throwsFormatException);
  });

  test('同一世界顺序不能立刻结算刚开始的持续过程', () {
    final TurnState state = worldState().applyDelta(const StateDelta(processes: [ProcessDelta(
      id: 'process:火', place: '东门内侧', description: '燃烧开始', completionCondition: '燃料耗尽',
    )]), atTurn: 1);
    expect(() => state.applyDelta(const StateDelta(processes: [ProcessDelta(
      id: 'process:火', place: '东门内侧', description: '燃烧结束', completionCondition: '燃料耗尽', status: 'completed',
    )]), atTurn: 1), throwsStateError);
  });
}
