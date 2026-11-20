import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/engine/agents/llm_agent_runner.dart';
import 'package:joenws/engine/causal_context.dart';
import 'package:joenws/engine/character_memory.dart';
import 'package:joenws/engine/engine_state.dart';
import 'package:joenws/engine/memory_agent.dart';
import 'package:joenws/engine/perception.dart';
import 'package:joenws/engine/state_delta.dart';
import 'package:joenws/engine/turn_loop.dart';
import 'package:joenws/engine/turn_session.dart';
import 'package:joenws/model/llm_client.dart';
import 'package:joenws/model/provider.dart';

import 'engine_causality_test.dart' as causal;
import 'engine_turn_loop_test.dart' as turns;

class _EnvironmentAgents extends causal.CausalAgents {
  _EnvironmentAgents({this.keepMemory = true});
  final bool keepMemory;

  @override
  Future<List<String>> selectEligible({
    required List<String> baseEligible,
    required List<String> cast,
    String playerNotes = '',
    List<String> errors = const [],
    List<String>? previous,
  }) async => [];

  @override
  Future<List<MemoryOperation>?> manageMemory({
    required String characterId,
    required Map<String, Object?> percepts,
    required List<CharacterMemory> memory,
    required Set<String> allowedEventIds,
  }) async => keepMemory ? [MemoryOperation(
    op: 'encode', text: jsonEncode(percepts), sourceEvents: allowedEventIds.toList(),
  )] : [];
}

const _rain = WorldEvent(
  id: 'ENV-review', kind: WorldEventKind.action, content: '雨势加大',
  actor: '', source: 'environment', placeId: '东门内侧',
  delivery: Delivery(channel: DeliveryChannel.other, form: 'narration', audience: Audience.scene),
);

TurnSession _session() => TurnSession(
  worldId: 'review', parallelPlaceId: 'gate', rawInput: '', journal: TurnJournal(),
);

TurnSession _save(TurnSession session, String stage, Map<String, Object?> data) {
  if (data['invalidate'] is List) {
    session = session.withoutCheckpoints((data['invalidate'] as List).cast<String>());
  }
  return session.withCheckpoint(stage, data);
}

Future<TurnTrace> _run(TurnLoop loop, {TurnSession? resume}) => loop.run(
  newEvents: [], actorNames: ['慧音'], resume: resume,
);

void main() {
  test('不合格正文与传达字段先交回行动重试，不保存错误行动', () async {
    final List<Map<String, Object?>> invalid = [
      turns.speechAction(''),
      turns.actionWithText('慧音'),
      turns.speechAction('坏传达'),
      turns.speechAction('未知范围'),
      turns.speechAction('未知角色'),
    ];
    ((invalid[2]['segments'] as List).single as Map).remove('delivery');
    (((invalid[3]['segments'] as List).single as Map)['delivery'] as Map)['audience'] = 'unknown';
    ((invalid[4]['segments'] as List).single as Map)['target'] = 'char:不存在';
    for (final Map<String, Object?> action in invalid) {
      final turns.FakeAgents agents = turns.FakeAgents(
        choices: ['慧音'], actions: [action, turns.speechAction('已修正')],
      );
      final TurnTrace trace = await _run(TurnLoop(scene: turns.buildScene(), agents: agents));
      expect(trace.events.single.content, '已修正');
      expect(trace.actErrors, hasLength(1));
      expect(agents.perceiveHistory, hasLength(2));
    }
    TurnSession saved = _session();
    final TurnTrace stopped = await _run(TurnLoop(
      scene: turns.buildScene(), agents: turns.FakeAgents(choices: ['慧音'], action: invalid.first),
      onCheckpoint: (stage, data) => saved = _save(saved, stage, data),
    ));
    expect(stopped.stop?.code, 'step_budget');
    expect(saved.checkpoints.containsKey('CH_ACT'), isFalse);
  });

  test('旧错误行动及下游恢复点被丢弃，继续时能重新生成', () async {
    TurnSession saved = _session();
    final TurnTrace old = await _run(TurnLoop(
      scene: turns.buildScene(),
      agents: turns.FakeAgents(choices: ['慧音'], action: turns.speechAction('旧正文')),
      onCheckpoint: (stage, data) => saved = _save(saved, stage, data),
    ));
    expect(old.events.single.content, '旧正文');
    saved = saved.withCheckpoint('CH_ACT', {'actor': '慧音', 'action': turns.speechAction('')});
    final turns.FakeAgents fixed = turns.FakeAgents(
      choices: [], action: turns.speechAction('已修正'), renderText: '已修正',
    );
    final TurnTrace trace = await _run(TurnLoop(
      scene: turns.buildScene(), agents: fixed,
      onCheckpoint: (stage, data) => saved = _save(saved, stage, data),
    ), resume: saved);
    expect(trace.events.single.content, '已修正');
    expect(trace.render?['public_text'], '已修正');
    expect(fixed.perceiveHistory, hasLength(1));
    expect(saved.checkpoints['CH_ACT']!.data['action'], turns.speechAction('已修正'));
  });

  test('旧人控错误行动回到玩家输入，不在落账阶段抛异常', () async {
    int asked = 0;
    final TurnTrace trace = await _run(TurnLoop(
      scene: turns.buildScene(), controlledCharacter: '慧音',
      agents: turns.FakeAgents(choices: ['慧音']),
      playerActionHandler: ({required actor, required scene}) async => turns.speechAction(''),
      askPlayer: (_) async { asked++; return '重试'; },
    ), resume: _session().withCheckpoint('CH_ACT', {'action': turns.speechAction('')}));
    // 人控行动不合格时应回到玩家输入，不能在落账阶段抛异常。
    expect(trace.stop?.code, 'player_action');
    expect(trace.actErrors.last.code, 'empty_content');
    expect(asked, 0);
  });

  test('NPC 空正文耗尽预算后仍可移交玩家并重新生成', () async {
    final turns.FakeAgents agents = turns.FakeAgents(choices: ['慧音'], actions: [
      for (int i = 0; i < 8; i++) turns.speechAction(''), turns.speechAction('已修正'),
    ]);
    int asked = 0;
    final TurnTrace trace = await _run(TurnLoop(scene: turns.buildScene(), agents: agents,
      askPlayer: (question) async {
        expect(question.step, 'CH_ACT');
        expect(agents.perceiveHistory, hasLength(8));
        asked++;
        return '重新尝试';
      },
    ));
    expect(asked, 1);
    expect(trace.events.single.content, '已修正');
  });

  test('旧人控错误行动可以由新的玩家行动替换', () async {
    final TurnTrace trace = await _run(TurnLoop(
      scene: turns.buildScene(), controlledCharacter: '慧音',
      agents: turns.FakeAgents(choices: ['慧音']),
      playerActionHandler: ({required actor, required scene}) async => turns.speechAction('新的玩家行动'),
    ), resume: _session().withCheckpoint('CH_ACT', {'action': turns.speechAction('')}));
    expect(trace.stop, isNull);
    expect(trace.events.single.content, '新的玩家行动');
  });

  test('普通暂停会保存指纹，设定改变时丢弃旧决定', () async {
    TurnSession saved = _session();
    await expectLater(_run(TurnLoop(
      scene: turns.buildScene(), recoveryContext: 'old',
      agents: turns.FakeAgents(choices: ['慧音'], action: turns.speechAction('旧决定')),
      onCheckpoint: (stage, data) {
        saved = _save(saved, stage, data);
        if (stage == 'CH_ACT') throw StagePause(stage);
      },
    )), throwsA(isA<StagePause>()));
    expect(saved.checkpoints['SYS_RECOVERY']!.data['context'], isNotEmpty);
    saved = TurnSession.fromJson(jsonDecode(jsonEncode(saved.toJson())));
    final turns.FakeAgents changed = turns.FakeAgents(
      choices: ['慧音'], action: turns.speechAction('新决定'),
    );
    final TurnTrace trace = await _run(TurnLoop(
      scene: turns.buildScene(), agents: changed, recoveryContext: 'new',
      onCheckpoint: (stage, data) => saved = _save(saved, stage, data),
    ), resume: saved);
    expect(trace.events.single.content, '新决定');
    expect(changed.perceiveHistory, hasLength(1));
  });

  test('旅行使用实际提交序号，下一世界顺序可以完成', () async {
    final Map<String, Object?> startAction = turns.actionWithText('出发前往仓房');
    final Map<String, Object?> startRuling = causal.ruling(outcome: 'success', result: '旅行开始')
      ..['processes'] = [const ProcessDelta(
        id: 'process:travel', place: '东门内侧', owner: '慧音', kind: 'travel',
        description: '正在前往仓房', completionCondition: '到达仓房', destination: '仓房',
      ).toJson()];
    final TurnState initial = causal.worldState();
    final TurnTrace started = await _run(causal.loopFor(
      causal.CausalAgents(action: startAction, arbitration: startRuling), state: initial,
    ));
    final TurnState saved = TurnState.decode(initial.withEvents(started.events)
        .applyDelta(started.stateDelta!, atTurn: initial.worldStep + 1).encode());
    expect(saved.worldStep, 1);
    expect(saved.entities['process:travel']!.state['started_turn'], 1);
    final Map<String, Object?> finishRuling = causal.ruling(
      outcome: 'success', result: '到达仓房', deltas: [{'kind': 'move', 'who': '慧音', 'to': '仓房'}],
    )..['processes'] = [const ProcessDelta(
      id: 'process:travel', place: '东门内侧', owner: '慧音', kind: 'travel',
      description: '已到达仓房', completionCondition: '到达仓房', destination: '仓房', status: 'completed',
    ).toJson()];
    final TurnTrace finished = await _run(causal.loopFor(
      causal.CausalAgents(action: turns.actionWithText('继续赶路'), arbitration: finishRuling), state: saved,
    ));
    expect(finished.resolveErrors, isEmpty);
    final TurnState next = saved.withEvents([...saved.events, ...finished.events])
        .applyDelta(finished.stateDelta!, atTurn: saved.worldStep + 1);
    expect(next.locations['慧音'], '仓房');
    expect(next.entities['process:travel']!.state['updated_turn'], 2);
  });

  for (final String pauseAt in ['GM_ELIGIBILITY', 'SYS_RECORD',
    'CH_PERCEIVE:慧音:env', 'CH_MEMORY_WRITE:慧音:env', 'GM_NARRATE']) {
    test('转环境线在 $pauseAt 暂停后仍交付新事件且不重复写记忆', () async {
      TurnSession saved = _session();
      TurnLoop loop(_EnvironmentAgents agents, {bool pause = false}) => TurnLoop(
        scene: turns.buildScene(), agents: agents,
        causalContext: CausalContext(state: causal.worldState()),
        environmentSource: ({required scene, required events, feedback}) async => [_rain],
        onCheckpoint: (stage, data) {
          saved = _save(saved, stage, data);
          if (pause && stage == pauseAt) throw StagePause(stage);
        },
      );
      await expectLater(loop(_EnvironmentAgents(), pause: true).run(
        newEvents: [turns.playerEvent()], actorNames: ['慧音'], perceptionNames: ['慧音'],
      ), throwsA(isA<StagePause>()));
      saved = TurnSession.fromJson(jsonDecode(jsonEncode(saved.toJson())));
      final TurnLoop resumed = loop(_EnvironmentAgents());
      final TurnTrace trace = await resumed.run(newEvents: [turns.playerEvent()],
        actorNames: ['慧音'], perceptionNames: ['慧音'], resume: saved);
      expect(trace.environmentEvents, hasLength(1));
      expect(trace.perceiveErrors, isEmpty);
      expect(resumed.deliveryReceipts[_rain.id], contains('char:慧音'));
      final List<CharacterMemory> entries = resumed.memory.forCharacter('char:慧音');
      expect(entries.where((m) => m.sourceEvents.contains(_rain.id)), hasLength(1));
      expect(entries.where((m) => m.sourceEvents.contains('E1')), hasLength(1));
    });
  }

  test('不形成记忆时转环境线也不会再次交付同一个旧事件', () async {
    final _EnvironmentAgents agents = _EnvironmentAgents(keepMemory: false);
    final TurnLoop loop = TurnLoop(scene: turns.buildScene(), agents: agents,
      environmentSource: ({required scene, required events, feedback}) async => [_rain]);
    await loop.run(newEvents: [turns.playerEvent()], actorNames: ['慧音']);
    expect(agents.perceptionInputs, hasLength(2));
    expect(agents.perceptionInputs.last, isNot(contains('E1 ')));
    expect(loop.deliveryReceipts[_rain.id], contains('char:慧音'));
  });

  test('感知和记忆日志按事件批次回放，恢复时不串用角色线结果', () async {
    final TurnJournal journal = TurnJournal();
    int sent = 0;
    LlmAgentRunner runner() => LlmAgentRunner(
      provider: const Provider(id: 'review', name: 'review', protocol: Protocol.deepseekAnthropic),
      apiKey: 'unused', model: 'review', journal: journal,
      sender: (request) async {
        sent++;
        if ((request.system ?? '').contains('整理一个角色')) {
          return const LlmReply(text: '{"operations":[]}');
        }
        final bool rain = request.messages.single.content.contains(_rain.id);
        return LlmReply(text: jsonEncode({'percepts': [{'event_id': rain ? _rain.id : 'E1',
          'content': rain ? '雨势加大' : '听见台词'}]}));
      },
    );
    final LlmAgentRunner first = runner();
    await first.perceive(name: '慧音', context: '', events: 'E1 听见台词');
    await first.manageMemory(characterId: 'char:慧音', percepts: {}, memory: [], allowedEventIds: {'E1'});
    final Map<String, Object?> rain = await first.perceive(
      name: '慧音', context: '', events: '${_rain.id} 雨势加大');
    await first.manageMemory(characterId: 'char:慧音', percepts: rain, memory: [], allowedEventIds: {_rain.id});
    expect(sent, 4);
    final LlmAgentRunner resumed = runner();
    final Map<String, Object?> replayed = await resumed.perceive(
      name: '慧音', context: '', events: '${_rain.id} 雨势加大');
    await resumed.manageMemory(characterId: 'char:慧音', percepts: replayed,
      memory: [], allowedEventIds: {_rain.id});
    expect(jsonEncode(replayed), contains(_rain.id));
    expect(sent, 4);
    resumed.prepareRetry('CH_PERCEIVE:慧音');
    await resumed.perceive(name: '慧音', context: '', events: '${_rain.id} 雨势加大');
    expect(sent, 5);
  });

  test('空能力声明不能让失声角色说话，心灵传达不误用发声限制', () async {
    for (final String channel in ['voice', 'mental']) {
      final Map<String, Object?> action = turns.speechAction('传达消息');
      final Map segment = (action['segments'] as List).single as Map;
      segment['requires'] = <String>[];
      (segment['delivery'] as Map)['channel'] = channel;
      final TurnTrace trace = await _run(TurnLoop(
        scene: turns.buildScene(), agents: turns.FakeAgents(choices: ['慧音'], action: action),
        constraints: const [FunctionalConstraint(
          who: '慧音', capability: 'speak', state: ConstraintState.cannot, reason: '失声',
        )],
      ));
      if (channel == 'voice') {
        expect(trace.events, isEmpty);
        expect(trace.actErrors.first.code, 'capability_blocked');
      } else {
        expect(trace.events, hasLength(1));
        expect(trace.actErrors, isEmpty);
      }
    }
  });

  test('放入容器的物品归属一致且下一回合可以取出', () {
    for (final bool usePlace in [true, false]) {
      final TurnState initial = causal.worldState();
      final TurnState placed = initial.applyDelta(StateDelta(items: [StateItemDelta(
        kind: 'drop', itemId: 'item:包', by: 'char:信标',
        place: usePlace ? 'cont:箱' : null, to: usePlace ? null : 'cont:箱',
      )]));
      expect(placed.entities['item:包']!.location, 'cont:箱');
      expect(placed.inventories['信标'], isEmpty);
      expect(placed.entities['cont:箱']!.contains, ['item:包']);
      expect(placed.transitionErrors(const StateDelta()), isEmpty);
      final TurnState taken = TurnState.decode(placed.encode()).applyDelta(const StateDelta(items: [
        StateItemDelta(kind: 'take', itemId: 'item:包', from: 'cont:箱', to: '慧音'),
      ]));
      expect(taken.entities['cont:箱']!.contains, isEmpty);
      expect(taken.inventories['慧音'], ['item:包']);
      expect(taken.transitionErrors(const StateDelta()), isEmpty);
      expect(initial.inventories['信标'], ['item:包']);
    }
  });
}
