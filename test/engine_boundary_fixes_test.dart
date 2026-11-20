import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/engine/agents/llm_agent_runner.dart';
import 'package:joenws/engine/causal_context.dart';
import 'package:joenws/engine/character_memory.dart';
import 'package:joenws/engine/engine_state.dart';
import 'package:joenws/engine/memory_agent.dart';
import 'package:joenws/engine/perception.dart';
import 'package:joenws/engine/state_delta.dart';
import 'package:joenws/engine/step_id.dart';
import 'package:joenws/engine/turn_loop.dart';
import 'package:joenws/engine/turn_session.dart';
import 'package:joenws/model/llm_client.dart';
import 'package:joenws/model/provider.dart';

import 'engine_causality_test.dart' as causal;
import 'engine_turn_loop_test.dart' as turns;

const _provider = Provider(id: 'boundary', protocol: Protocol.deepseek, name: 'test');

TurnSession _save(TurnSession session, String stage, Map<String, Object?> data) {
  if (data['invalidate'] is List) {
    session = session.withoutCheckpoints((data['invalidate'] as List).cast<String>());
  }
  return session.withCheckpoint(stage, data);
}

class _Agents extends turns.FakeAgents {
  _Agents({String chosen = '慧音', this.eligibility, this.rememberScene = false})
      : super(choices: [chosen]);

  final LlmAgentRunner? eligibility;
  final bool rememberScene;
  String actionContext = '';
  String actionPercepts = '';
  String perceptionContext = '';
  int perceptionCalls = 0;

  @override
  Future<Map<String, Object?>> perceive({required String name, required String context,
      required String events}) async {
    perceptionCalls++;
    perceptionContext = context;
    if (events.isEmpty) return {'percepts': [], 'attention': '观察现场'};
    return super.perceive(name: name, context: context, events: events);
  }

  @override
  Future<List<String>> selectEligible({required List<String> baseEligible,
      required List<String> cast, String playerNotes = '', List<String> errors = const [],
      List<String>? previous}) => eligibility == null ? Future.value(baseEligible)
          : eligibility!.selectEligible(baseEligible: baseEligible, cast: cast,
              playerNotes: playerNotes, errors: errors, previous: previous);

  @override
  Future<List<String>?> recallMemory({required String characterId, required NarrativeScene scene,
      required Map<String, Object?> percepts, required List<CharacterMemory> memory}) async => [];

  @override
  Future<List<MemoryOperation>?> manageMemory({required String characterId,
      required Map<String, Object?> percepts, required List<CharacterMemory> memory,
      required Set<String> allowedEventIds}) async => rememberScene
          ? [MemoryOperation(op: 'encode', kind: MemoryKind.impression,
              text: '${percepts['current_scene']}', attention: '记住路牌')]
          : null;

  @override
  Future<Map<String, Object?>> act({required String name, required String context,
      required String perceive, required List<String> present}) {
    actionContext = context;
    actionPercepts = perceive;
    return super.act(name: name, context: context, perceive: perceive, present: present);
  }
}

void main() {
  test('F1 未决裁定在落账前移交玩家，重裁只重做裁定及下游', () async {
    final agents = turns.FakeAgents(choices: ['慧音'], action: turns.stealAction(),
      arbitrationAttempts: [causal.ruling(outcome: 'unresolved', result: '依据不足'), causal.ruling()]);
    var asked = 0;
    final trace = await TurnLoop(scene: turns.buildScene(), agents: agents,
      causalContext: CausalContext(state: causal.worldState()),
      askPlayer: (question) async {
        asked++;
        expect(question.code, 'unresolved_action');
        expect(question.step, StepId.gmResolveAction);
        expect(agents.renderCalls, 0);
        return '按现有归属和防备裁定';
      }).run(newEvents: [], actorNames: ['慧音'], perceptionNames: []);
    expect(asked, 1);
    expect(agents.resolveFeedback, hasLength(2));
    expect(agents.perceiveHistory, hasLength(1));
    expect(agents.renderCalls, 1);
    expect(trace.needsReview, isFalse);
  });

  test('F1 暂缓未决裁定可跨序列化恢复，已完成行动保留', () async {
    var session = TurnSession(worldId: 'w', parallelPlaceId: 'p', rawInput: '', journal: TurnJournal());
    TurnLoop build(turns.FakeAgents agents, PlayerAsker ask) => TurnLoop(
      scene: turns.buildScene(), agents: agents, causalContext: CausalContext(state: causal.worldState()),
      askPlayer: ask, onCheckpoint: (stage, data) => session = _save(session, stage, data));
    final first = turns.FakeAgents(choices: ['慧音'], action: turns.stealAction(),
      arbitration: causal.ruling(outcome: 'unresolved', result: '缺少依据'));
    await expectLater(build(first, (_) async => null).run(newEvents: [], actorNames: ['慧音'], perceptionNames: []),
      throwsA(isA<PlayerPausedException>()));
    expect(session.checkpoints, contains(StepId.chAct));
    expect(session.checkpoints, isNot(contains(StepId.gmResolveAction)));
    expect(session.checkpoints[StepId.sysRecovery]!.data['code'], 'unresolved_action');
    session = TurnSession.fromJson(jsonDecode(jsonEncode(session.toJson())));
    final second = turns.FakeAgents(choices: [], arbitration: causal.ruling());
    final trace = await build(second, (question) async {
      expect(question.code, 'unresolved_action'); return '依照当前状态重裁';
    }).run(newEvents: [], actorNames: ['慧音'], perceptionNames: [], resume: session);
    expect(second.perceiveHistory, isEmpty);
    expect(second.resolveFeedback, hasLength(1));
    expect(trace.needsReview, isFalse);
  });

  test('F1 没有交互宿主时也返回结构化未决请求和空落账结果', () async {
    final trace = await TurnLoop(scene: turns.buildScene(),
      agents: turns.FakeAgents(choices: ['慧音'], action: turns.stealAction(),
        arbitration: causal.ruling(outcome: 'unresolved', result: '仍不确定')),
      causalContext: CausalContext(state: causal.worldState()))
      .run(newEvents: [], actorNames: ['慧音'], perceptionNames: []);
    expect(trace.playerIntervention!.code, 'unresolved_action');
    expect(trace.events, isEmpty);
    expect(trace.stateDelta, isNull);
    expect(trace.render, isNull);
  });

  test('F2 移动裁定确实包含目的地的锁状态，锁状态变化改变请求', () async {
    final requests = <LlmRequest>[];
    for (final lock in ['locked', 'unlocked']) {
      final state = causal.worldState(facts: [FactRecord(id: 'destination-lock',
        subject: 'place:仓房', predicate: 'door', object: lock, evidence: '已确认的门锁')]);
      final runner = LlmAgentRunner(provider: _provider, apiKey: 'unused', model: 'test',
        causalContext: CausalContext(state: state), sender: (request) async {
          requests.add(request); return LlmReply(text: jsonEncode(causal.ruling()));
        });
      await runner.adjudicate(action: turns.actionWithDelta(), actor: '慧音', target: null,
        place: '东门内侧', present: ['慧音']);
      // 尚未提出到达增量时，裁定仍必须看到目的地的客观门锁状态。
      await runner.adjudicate(action: turns.actionWithText('尝试走进仓房'), actor: '慧音', target: null,
        place: '东门内侧', present: ['慧音']);
    }
    final List<String> inputs = requests.map((request) => request.messages.single.content).toList();
    expect(inputs[0], contains('destination-lock'));
    expect(inputs[0], contains('"object":"locked"'));
    expect(inputs[2], contains('"object":"unlocked"'));
    expect(inputs[0], isNot(inputs[2]));
    expect(inputs[1], contains('destination-lock'));
    expect(inputs[1], isNot(inputs[3]));
  });

  test('F2 物品来源和前提引用也会纳入裁定范围', () {
    final state = causal.worldState().applyDelta(const StateDelta(discoveries: [
      EntityDiscovery(id: 'container:外层箱', kind: 'container', name: '外层箱', location: '仓房', evidence: '已确认'),
      EntityDiscovery(id: 'container:远处箱', kind: 'container', name: '远处箱', location: 'container:外层箱', evidence: '已确认'),
      EntityDiscovery(id: 'item:远处物品', kind: 'item', name: '远处物品', location: 'container:远处箱', evidence: '已确认'),
    ], facts: [StateFactDelta(subject: 'container:外层箱', predicate: 'sealed', object: 'true', evidence: '已上锁')]));
    final context = CausalContext(state: state);
    final action = turns.actionWithText('隔空拿取物品')..['state_delta'] = {
      'items': [{'kind': 'take', 'item_id': 'item:远处物品', 'from': 'container:远处箱', 'to': '慧音'}],
    }..['preconditions'] = [{'subject': 'place:仓房', 'predicate': 'door', 'object': 'open'}];
    final ids = context.actionEntities(action);
    expect(ids, containsAll(['container:远处箱', 'item:远处物品', 'place:仓房']));
    expect(jsonEncode(context.forGod('东门内侧', involved: ids)), contains('sealed'));
  });

  for (final hidden in [false, true]) {
    test('F3 跨地点结算固定目的地逐人见闻，隐蔽到达=$hidden', () async {
      final base = turns.buildScene();
      final origin = NarrativeScene(place: '东门内侧', names: base.names, cast: [base.byId('char:慧音')!]);
      final destination = NarrativeScene(place: '仓房', names: base.names, cast: [base.byId('char:信标')!]);
      final initial = causal.worldState().applyDelta(const StateDelta(moves: {'信标': '仓房'}));
      final agents = turns.FakeAgents(choices: ['慧音'], action: turns.actionWithDelta(),
        arbitration: causal.ruling(outcome: 'success', result: '到达仓房；出发地秘密标记', observations: {
          'char:慧音': '我到仓房了', 'char:信标': hidden ? '' : '看见慧音走进仓房',
        }, deltas: const [{'kind': 'move', 'who': '慧音', 'to': '仓房'}]));
      final trace = await TurnLoop(scene: origin, agents: agents, causalContext: CausalContext(state: initial),
        sceneForPlace: (_) => destination).run(newEvents: [], actorNames: ['慧音'], perceptionNames: []);
      expect(trace.resolveErrors, isEmpty);
      final event = worldEventFromJson(jsonDecode(jsonEncode(worldEventToJson(trace.events.single))));
      final received = event.witnesses.where((w) => w.characterId == 'char:信标').toList();
      expect(received, hasLength(hidden ? 0 : 1));
      if (!hidden) {
        expect(received.single.content, contains('走进仓房'));
        expect(received.single.content, isNot(contains('出发地秘密标记')));
        final receiver = _Agents(chosen: '信标');
        final nextState = initial.withEvents(trace.events).applyDelta(trace.stateDelta!, atTurn: 1);
        await TurnLoop(scene: destination, agents: receiver, causalContext: CausalContext(state: nextState))
          .run(newEvents: [event], actorNames: ['信标'], perceptionNames: ['信标']);
        expect(receiver.perceptionCalls, 1);
      }
    });
  }

  test('F3 裁定遗漏目的地观察者时重裁，不能默认无人看见', () async {
    final base = turns.buildScene();
    final origin = NarrativeScene(place: '东门内侧', names: base.names, cast: [base.byId('char:慧音')!]);
    final state = causal.worldState().applyDelta(const StateDelta(moves: {'信标': '仓房'}));
    final agents = turns.FakeAgents(choices: ['慧音'], action: turns.actionWithDelta(), arbitrationAttempts: [
      causal.ruling(outcome: 'success', result: '已到达', deltas: const [{'kind': 'move', 'who': '慧音', 'to': '仓房'}]),
      causal.ruling(outcome: 'success', result: '已到达', observations: const {'char:信标': ''},
        deltas: const [{'kind': 'move', 'who': '慧音', 'to': '仓房'}]),
    ]);
    final trace = await TurnLoop(scene: origin, agents: agents, causalContext: CausalContext(state: state))
      .run(newEvents: [], actorNames: ['慧音'], perceptionNames: []);
    expect(trace.resolveErrors, isEmpty);
    expect(agents.resolveFeedback, hasLength(2));
    expect(agents.resolveFeedback[1].join(), contains('目的地角色 char:信标'));
  });

  test('F3 确定的直接移动也交付到达见闻，无需为移动额外调用裁定', () async {
    final base = turns.buildScene();
    final origin = NarrativeScene(place: '东门内侧', names: base.names, cast: [base.byId('char:慧音')!]);
    final state = causal.worldState(facts: const [
      FactRecord(id: 'path', subject: 'place:东门内侧', predicate: 'connected_to', object: '仓房'),
      FactRecord(id: 'access', subject: 'place:仓房', predicate: 'accessible', object: 'true'),
    ]).applyDelta(const StateDelta(moves: {'信标': '仓房'}));
    final action = turns.actionWithDelta()..['resolution'] = 'direct';
    final agents = turns.FakeAgents(choices: ['慧音'], action: action);
    final trace = await TurnLoop(scene: origin, agents: agents, causalContext: CausalContext(state: state))
      .run(newEvents: [], actorNames: ['慧音'], perceptionNames: []);
    expect(agents.resolveFeedback, isEmpty);
    expect(trace.events.single.witnesses.singleWhere((w) => w.characterId == 'char:信标').content, contains('到达仓房'));
  });

  test('F4 空召回不通过动机字段向行动回灌全量活动记忆', () async {
    final agents = _Agents();
    await TurnLoop(scene: turns.buildScene(), agents: agents,
      memoryStore: MemoryStore([const CharacterMemory(id: 'excluded', characterId: 'char:慧音', text: '完整往事排除标记')]),
      causalContext: CausalContext(state: causal.worldState()))
      .run(newEvents: [], actorNames: ['慧音'], perceptionNames: []);
    expect(agents.actionContext, isNot(contains('完整往事排除标记')));
    expect(agents.actionPercepts, isNot(contains('完整往事排除标记')));
  });

  test('F5 缺少 eligible 会反馈重试，修正后仍执行角色回合', () async {
    var calls = 0;
    final runner = LlmAgentRunner(provider: _provider, apiKey: 'unused', model: 'test', sender: (request) async {
      calls++;
      if (calls > 1) expect(request.messages.single.content, contains('eligible 必须是角色名数组'));
      return LlmReply(text: calls == 1 ? '{}' : '{"eligible":["慧音"]}');
    });
    var environmentCalls = 0;
    final trace = await TurnLoop(scene: turns.buildScene(), agents: _Agents(eligibility: runner),
      environmentSource: ({required scene, required events, feedback}) async { environmentCalls++; return []; })
      .run(newEvents: [], actorNames: ['慧音'], perceptionNames: []);
    expect(calls, 2);
    expect(environmentCalls, 0);
    expect(trace.chosen, '慧音');
    expect(trace.route, 'turn');
  });

  test('F5 格式错误耗尽也不能成为合法空名单，显式空数组仍合法', () async {
    final invalid = LlmAgentRunner(provider: _provider, apiKey: 'unused', model: 'test',
      sender: (_) async => const LlmReply(text: '{"eligible":{}}'));
    await expectLater(invalid.selectEligible(baseEligible: ['慧音'], cast: ['慧音']),
      throwsA(isA<RetryExhaustedException>()));
    final valid = LlmAgentRunner(provider: _provider, apiKey: 'unused', model: 'test',
      sender: (_) async => const LlmReply(text: '{"eligible":[]}'));
    expect(await valid.selectEligible(baseEligible: ['慧音'], cast: ['慧音']), isEmpty);
  });

  test('F6 静态现场独立于事件投影，角色只收到自己的过滤结果并可形成印象', () async {
    final state = causal.worldState(facts: const [FactRecord(id: 'secret', subject: 'place:东门内侧',
      predicate: 'trap', object: '隐藏机关秘密标记')]).applyDelta(const StateDelta(discoveries: [
      EntityDiscovery(id: 'item:路牌', kind: 'item', name: '红色路牌', location: '东门内侧', evidence: '位于路中央'),
    ]));
    final requests = <LlmRequest>[];
    final projector = LlmAgentRunner(provider: _provider, apiKey: 'unused', model: 'test',
      causalContext: CausalContext(state: state), sender: (request) async {
        requests.add(request);
        expect(request.messages.single.content, contains('隐藏机关秘密标记'));
        return const LlmReply(text: '{"observations":{"char:慧音":"眼前竖着红色路牌"}}');
      });
    final agents = _Agents(rememberScene: true);
    final memory = MemoryStore();
    await TurnLoop(scene: turns.buildScene(), agents: agents, memoryStore: memory,
      sceneObserver: projector.observeScene, causalContext: CausalContext(state: state))
      .run(newEvents: [], actorNames: ['慧音'], perceptionNames: ['慧音']);
    expect(requests, hasLength(1));
    expect(agents.perceptionCalls, 1);
    expect(agents.actionContext, contains('红色路牌'));
    expect(agents.actionPercepts, contains('红色路牌'));
    expect(agents.actionContext, isNot(contains('隐藏机关秘密标记')));
    expect(memory.allEntries().single.text, contains('红色路牌'));
    expect(memory.allEntries().single.sourceEvents, isEmpty);
  });

  test('F6 现场见闻检查点恢复不重做投影或感知，也不重复写记忆', () async {
    var session = TurnSession(worldId: 'w', parallelPlaceId: 'p', rawInput: '', journal: TurnJournal());
    var projections = 0;
    final memory = MemoryStore();
    TurnLoop build(_Agents agents, {bool pause = false}) => TurnLoop(scene: turns.buildScene(), agents: agents,
      memoryStore: memory, causalContext: CausalContext(state: causal.worldState()),
      sceneObserver: ({required scene, required state, required observers}) async {
        projections++; return {'char:慧音': '眼前有红色路牌'};
      }, onCheckpoint: (stage, data) {
        session = _save(session, stage, data);
        if (pause && stage == 'CH_MEMORY_WRITE:慧音') throw StagePause(stage);
      });
    final first = _Agents(rememberScene: true);
    await expectLater(build(first, pause: true).run(newEvents: [], actorNames: ['慧音'], perceptionNames: ['慧音']),
      throwsA(isA<StagePause>()));
    session = TurnSession.fromJson(jsonDecode(jsonEncode(session.toJson())));
    memory.restore([]);
    final resumed = _Agents(rememberScene: true);
    await build(resumed).run(newEvents: [], actorNames: ['慧音'], perceptionNames: ['慧音'], resume: session);
    expect(projections, 1);
    expect(resumed.perceptionCalls, 0);
    expect(resumed.actionContext, contains('红色路牌'));
    expect(memory.allEntries(), hasLength(1));
  });

  test('F6 逐人投影缺角色或值类型错误会重试，不能沿用其他人的见闻', () async {
    var calls = 0;
    final projector = LlmAgentRunner(provider: _provider, apiKey: 'unused', model: 'test', sender: (request) async {
      calls++;
      return LlmReply(text: calls == 1 ? '{"observations":{"char:灵梦":"别人的秘密"}}'
          : '{"observations":{"char:慧音":"自己的见闻"}}');
    });
    final views = await projector.observeScene(scene: turns.buildScene(), state: causal.worldState(), observers: ['慧音']);
    expect(calls, 2);
    expect(views, {'char:慧音': '自己的见闻'});
  });

  test('F6 环境回合投影读取更新后的状态，恢复不混用角色分支的旧现场', () async {
    var session = TurnSession(worldId: 'w', parallelPlaceId: 'p', rawInput: '', journal: TurnJournal());
    final state = causal.worldState(facts: const [FactRecord(id: 'door', subject: 'place:东门内侧',
      predicate: 'door', object: 'open', visibility: 'public')]);
    const changes = StateDelta(facts: [StateFactDelta(subject: 'place:东门内侧',
      predicate: 'door', object: 'locked', evidence: '门闩落下', visibility: 'public')]);
    final projected = <String>[];
    final memory = MemoryStore();
    TurnLoop build(_Agents agents, {bool pause = false}) => TurnLoop(scene: turns.buildScene(),
      agents: agents, causalContext: CausalContext(state: state), memoryStore: memory,
      sceneObserver: ({required scene, required state, required observers}) async {
        final door = state.facts.single.object;
        projected.add(door); return {'char:慧音': '门状态：$door'};
      }, environmentSource: ({required scene, required events, feedback}) async => [WorldEvent(
        id: 'E50', kind: WorldEventKind.action, content: '门闩落下', actor: '', source: 'environment',
        delivery: const Delivery(channel: DeliveryChannel.visual, form: 'narration', audience: Audience.scene),
        stateChanges: changes.toJson(), effects: changes.effectRecords)],
      onCheckpoint: (stage, data) {
        session = _save(session, stage, data);
        if (pause && stage == '${StepId.gmObserveScene}:env') throw StagePause(stage);
      });
    await expectLater(build(_Agents(rememberScene: true), pause: true).run(newEvents: [], actorNames: [], perceptionNames: ['慧音']),
      throwsA(isA<StagePause>()));
    memory.restore([]);
    session = TurnSession.fromJson(jsonDecode(jsonEncode(session.toJson())));
    final resumed = _Agents(rememberScene: true);
    final trace = await build(resumed).run(newEvents: [], actorNames: [], perceptionNames: ['慧音'], resume: session);
    expect(projected, ['open', 'locked']);
    expect(trace.percepts['慧音']!['current_scene'], '门状态：locked');
    expect(resumed.perceptionContext, contains('door=locked'));
    expect(resumed.perceptionContext, isNot(contains('door=open')));
    expect(memory.allEntries(), hasLength(2));
    expect(state.applyDelta(trace.stateDelta!, atTurn: 1).facts.single.object, 'locked');
  });

  test('F7 已交付事件仍进入上帝近期历史，正文派生内容不作为事实回流', () async {
    final event = turns.playerEvent().copyWith(turnIndex: 1, witnessesResolved: true,
      witnesses: const [Witness(characterId: 'char:慧音', modality: 'hearing', content: '历史见闻')],
      publicText: '正文派生秘密标记', godNote: '额外叙述标记');
    final receipts = {'E1': {'char:慧音'}};
    final pending = pendingAfterDelivery(incoming: [event], generated: [], receipts: receipts);
    expect(pending, isEmpty);
    final requests = <LlmRequest>[];
    final runner = LlmAgentRunner(provider: _provider, apiKey: 'unused', model: 'test',
      causalContext: CausalContext(state: causal.worldState().withEvents([event])),
      sender: (request) async { requests.add(request); return const LlmReply(text: '{"next":"turn"}'); });
    await runner.decideNext(scene: turns.buildScene(), events: pending);
    expect(requests.single.messages.single.content, contains(event.content));
    expect(requests.single.messages.single.content, isNot(contains('正文派生秘密标记')));
    expect(requests.single.messages.single.content, isNot(contains('额外叙述标记')));
  });

  test('F7 历史按回合限窗，同一回合的多段保留，待交付不改变窗口', () async {
    final events = <WorldEvent>[
      for (var turn = 1; turn <= 9; turn++)
        for (var segment = 0; segment < 2; segment++)
          WorldEvent(id: 'E$turn-$segment', kind: WorldEventKind.action, content: '第 $turn 回合', actor: '',
            delivery: const Delivery(channel: DeliveryChannel.visual, form: 'gesture', audience: Audience.scene), turnIndex: turn),
    ];
    final context = CausalContext(state: causal.worldState().withEvents(events));
    final recent = context.recentHistory(additional: [events.first]);
    expect(recent, hasLength(12));
    expect(recent.first.turnIndex, 4);
    expect(recent.last.turnIndex, 9);
    final runner = LlmAgentRunner(provider: _provider, apiKey: 'unused', model: 'test',
      causalContext: context, sender: (request) async {
        expect(request.messages.single.content, isNot(contains('第 1 回合')));
        expect(request.messages.single.content, contains('第 9 回合'));
        return const LlmReply(text: '{"next":"turn"}');
      });
    await runner.decideNext(scene: turns.buildScene(), events: events);
  });

  test('F8 多出口关系并存，删除一条不影响其他，单值属性仍替换', () {
    final initial = causal.worldState().applyDelta(const StateDelta(discoveries: [
      EntityDiscovery(id: 'place:广场', kind: 'place', name: '广场', location: '', evidence: '已有广场'),
    ], facts: [
      StateFactDelta(subject: 'place:东门内侧', predicate: 'connected_to', object: '仓房', evidence: '仓房小径'),
      StateFactDelta(subject: 'place:东门内侧', predicate: 'connected_to', object: '广场', evidence: '广场街道'),
      StateFactDelta(subject: 'place:东门内侧', predicate: 'door', object: 'open', evidence: '门已打开'),
    ]));
    final saved = TurnState.decode(initial.encode());
    expect(saved.facts.where((f) => f.predicate == 'connected_to').map((f) => f.object), containsAll(['仓房', '广场']));
    const changes = StateDelta(facts: [
      StateFactDelta(subject: 'place:东门内侧', predicate: 'connected_to', object: '仓房', evidence: '道路已断', op: 'remove'),
      StateFactDelta(subject: 'place:东门内侧', predicate: 'door', object: 'locked', evidence: '门闩落下'),
    ]);
    final parsed = StateDelta.fromAction(jsonDecode(jsonEncode(changes.toJson())));
    final next = saved.applyDelta(parsed);
    expect(next.facts.where((f) => f.predicate == 'connected_to').single.object, '广场');
    expect(next.facts.where((f) => f.predicate == 'door').single.object, 'locked');
    expect(initial.facts.where((f) => f.predicate == 'connected_to'), hasLength(2));
    expect(StateDelta.proposalErrors({'facts': [{'subject': 'place:东门内侧', 'predicate': 'x',
      'object': 'y', 'evidence': 'z', 'op': 'invalid'}]}), isNotEmpty);
  });
}
