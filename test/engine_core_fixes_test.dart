import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/engine/agents/llm_agent_runner.dart';
import 'package:joenws/engine/causal_context.dart';
import 'package:joenws/engine/engine_state.dart';
import 'package:joenws/engine/perception.dart';
import 'package:joenws/engine/player_input.dart';
import 'package:joenws/engine/render_view.dart';
import 'package:joenws/engine/state_delta.dart';
import 'package:joenws/engine/turn_loop.dart';
import 'package:joenws/engine/turn_session.dart';
import 'package:joenws/model/llm_client.dart';
import 'package:joenws/model/provider.dart';

import 'engine_causality_test.dart' as causal;
import 'engine_turn_loop_test.dart' as turns;

const _provider = Provider(id: 'regression', protocol: Protocol.deepseekAnthropic, name: 'test');
const _rain = WorldEvent(id: 'ENV-fixes', kind: WorldEventKind.action,
  content: '雨势加大', actor: '', source: 'environment', placeId: '东门内侧',
  delivery: Delivery(channel: DeliveryChannel.visual, form: 'narration', audience: Audience.scene));

TurnSession _save(TurnSession session, String stage, Map<String, Object?> data) {
  if (data['invalidate'] is List) {
    session = session.withoutCheckpoints((data['invalidate'] as List).cast<String>());
  }
  return session.withCheckpoint(stage, data);
}

void main() {
  test('角色渲染只收到观察者见闻，不带秘密结果、状态、附件或其他人的观察', () async {
    final requests = <LlmRequest>[];
    final loaded = <String>[];
    final runner = LlmAgentRunner(provider: _provider, apiKey: 'unused', model: 'test',
      loadImage: (id) async { loaded.add(id); return null; },
      sender: (request) async { requests.add(request);
        return const LlmReply(text: '{"public_text":"有人低声交谈。","god_note":"秘密补充"}'); });
    runner.setPlayerHelp({'GM_RESOLVE_ACTION': '上帝层秘密回答', 'GM_NARRATE': '按可见内容写'});
    const secret = WorldEvent(id: 'E77', kind: WorldEventKind.speech, actor: 'char:慧音',
      content: '密钥是红月', result: '暗伤秘密', attachmentIds: ['secret-image'],
      effects: [{'kind': 'fact', 'object': '秘密状态'}],
      delivery: Delivery(channel: DeliveryChannel.mental, form: 'telepathic', audience: Audience.hidden),
      witnessesResolved: true, witnesses: [
        Witness(characterId: 'char:信标', modality: 'sight', content: '有人低声交谈。'),
        Witness(characterId: 'char:灵梦', modality: 'mental', content: '另一个秘密'),
      ]);
    // 看见外在交谈不代表能读取这条心灵事件携带的图片。
    final output = await runner.render(events: [secret.copyWith(
      witnesses: const [Witness(characterId: 'char:信标', modality: 'hearing', content: '有人低声交谈。')])],
      pov: RenderPov.player, observerId: 'char:信标', scene: turns.buildScene());
    final input = requests.single.messages.single.content;
    expect(input, contains('char:信标'));
    expect(input, contains('有人低声交谈'));
    for (final text in ['密钥是红月', '暗伤秘密', '秘密状态', '另一个秘密', '上帝层秘密回答']) {
      expect(input, isNot(contains(text)));
    }
    expect(loaded, isEmpty);
    expect(output['god_note'], isEmpty);
  });

  test('不可见事件不调用正文模型，全知模式保留完整事件', () async {
    var calls = 0;
    final runner = LlmAgentRunner(provider: _provider, apiKey: 'unused', model: 'test',
      sender: (request) async { calls++;
        expect(request.messages.single.content, contains('秘密'));
        return const LlmReply(text: '{"public_text":"秘密","god_note":"全知补充"}'); });
    const hidden = WorldEvent(id: 'E78', kind: WorldEventKind.speech, actor: 'char:慧音', content: '秘密',
      delivery: Delivery(channel: DeliveryChannel.mental, form: 'telepathic', audience: Audience.hidden),
      witnessesResolved: true);
    final player = await runner.render(events: [hidden], pov: RenderPov.player,
      observerId: 'char:信标', scene: turns.buildScene());
    expect(player['public_text'], '当前没有可感知的新变化。');
    expect(calls, 0);
    final god = await runner.render(events: [hidden]);
    expect(calls, 1);
    expect(god['god_note'], '全知补充');
  });

  test('角色视角必须绑定操控角色', () async {
    await expectLater(TurnLoop(scene: turns.buildScene(), pov: RenderPov.player,
      agents: turns.FakeAgents(choices: ['慧音'])).run(newEvents: [], actorNames: ['慧音']),
      throwsFormatException);
  });

  test('角色正文硬校验和复核共用已过滤内容，秘密不能作为台词依据', () async {
    final action = turns.speechAction('密钥是红月');
    (action['segments'] as List).single['delivery']['audience'] = 'target';
    (action['segments'] as List).single['target'] = '灵梦';
    final agents = turns.FakeAgents(choices: ['慧音'], action: action,
      renderTexts: ['“密钥是红月”', '她听见脚步声。']);
    final inputs = <String>[];
    final trace = await TurnLoop(scene: turns.buildScene(), agents: agents,
      pov: RenderPov.player, controlledCharacter: '信标',
      rCheck: ({required publicText, required godNote, required events}) async {
        inputs.add(events.map((e) => e.content).join()); return [];
      }).run(newEvents: [], actorNames: ['慧音']);
    expect(trace.render!['public_text'], '当前没有可感知的新变化。');
    expect(agents.renderCalls, 0);
    expect(inputs, isEmpty);
  });

  test('看见尝试但不知道结果时，角色投影不暴露成功结论', () {
    final event = _rain.copyWith(outcome: 'success', result: '秘密行动成功',
      effects: [{'kind': 'fact', 'object': '隐藏事实'}], witnessesResolved: true,
      witnesses: [const Witness(characterId: 'char:信标', modality: 'sight', content: '看见有人伸手')]);
    final view = renderView([event], turns.buildScene(), 'char:信标').single;
    expect(view.content, '看见有人伸手');
    expect(view.result, isEmpty);
    expect(view.effects, isEmpty);
    expect(view.observations, isEmpty);
  });

  test('角色正文不能用隐藏裁定为台词背书，重写与复核使用同一份可见内容', () async {
    final action = turns.actionWithText('摸向门把手');
    (action['segments'] as List).single['action_kind'] = 'interact';
    final agents = turns.FakeAgents(choices: ['慧音'], action: action,
      arbitration: causal.ruling(result: '密钥是红月', observations: const {'char:信标': '看见手碰到门，结果不明'}),
      renderTexts: ['“密钥是红月”', '看见手碰到门，结果不明']);
    final inputs = <String>[];
    final trace = await TurnLoop(scene: turns.buildScene(), agents: agents,
      causalContext: CausalContext(state: causal.worldState()),
      pov: RenderPov.player, controlledCharacter: '信标',
      rCheck: ({required publicText, required godNote, required events}) async {
        inputs.add(events.map((e) => e.content).join()); return [];
      }).run(newEvents: [], actorNames: ['慧音']);
    expect(agents.renderCalls, 2);
    expect(agents.rFeedback[1].join(), contains('invented_quote'));
    expect(inputs.single, isNot(contains('密钥是红月')));
    expect(inputs.single, contains('看见手碰到门'));
    expect(trace.renderViolations, isEmpty);
    expect(trace.events.single.result, '密钥是红月');
  });

  test('正文复核格式错误会带负反馈重试，不能当作没有违规', () async {
    var calls = 0;
    final runner = LlmAgentRunner(provider: _provider, apiKey: 'unused', model: 'test',
      sender: (request) async {
        calls++;
        if (calls > 1) expect(request.messages.single.content, contains('复核输出不合格'));
        return LlmReply(text: calls == 1 ? '{"violations":{}}' : '{"violations":[]}');
      });
    expect(await runner.checkRender(publicText: '雨势加大', godNote: '', events: [_rain]), isEmpty);
    expect(calls, 2);
  });

  test('同名别称只按行动者自己的映射还原，目标与正文一致', () async {
    final scene = NarrativeScene(place: '东门内侧', names: const {
      'char:甲': '甲', 'char:乙': '乙', 'char:丙': '丙',
    }, cast: [
      CharacterSnapshot(id: 'char:乙', name: '乙', nearby: true, aliases: {'char:丙': '女人'}),
      CharacterSnapshot(id: 'char:甲', name: '甲', nearby: true, aliases: {'char:乙': '女人'}),
      CharacterSnapshot(id: 'char:丙', name: '丙', nearby: true),
    ]);
    final action = turns.actionWithText('看向女人')..['resolution'] = 'direct';
    (action['segments'] as List).single['action_kind'] = 'observe';
    (action['segments'] as List).single['target'] = '女人';
    final trace = await TurnLoop(scene: scene, agents: turns.FakeAgents(choices: ['甲'], action: action))
      .run(newEvents: [], actorNames: ['甲']);
    expect(trace.events.single.target, 'char:乙');
    expect(trace.events.single.content, '看向乙');
    expect(() => canonicalize('女人', scene), throwsFormatException);
  });

  test('台词原话保留自我介绍中的名字，叙述标签仍按听者称呼显示', () {
    const event = WorldEvent(id: 'E80', kind: WorldEventKind.speech, actor: 'char:艾琳',
      content: '我叫艾琳', source: 'npc',
      delivery: Delivery(channel: DeliveryChannel.voice, form: 'spoken', audience: Audience.scene));
    final heard = const PerceptionEngine().witnesses(event, turns.buildScene())
      .singleWhere((w) => w.characterId == 'char:灵梦').content;
    expect(heard, '那个受伤的联邦女人说：我叫艾琳');
  });

  test('玩家的距离、传达和神态经过行动、事件、存档和见闻仍保留', () async {
    const parsed = PlayerParseResult(raw: '因为距离近，声音小了一些，严肃地说：等等。',
      segments: [PlayerSegment(id: 's1', kind: PlayerSegmentKind.speech, text: '等等。', target: '艾琳',
        delivery: Delivery(channel: DeliveryChannel.voice, form: 'spoken', audience: Audience.scene),
        deliveryNote: '声音小了一些', distanceNote: '因为距离近', manner: '严肃', mannerNote: '严肃地说')],
      unresolved: [], warnings: []);
    final scene = turns.buildScene();
    final trace = await TurnLoop(scene: scene, agents: turns.FakeAgents(choices: ['信标']),
      controlledCharacter: '信标', playerActionHandler: ({required actor, required scene}) async =>
        parsed.toActionRecord(actorName: actor, scene: scene)).run(newEvents: [], actorNames: ['信标']);
    final event = worldEventFromJson(jsonDecode(jsonEncode(worldEventToJson(trace.events.single))));
    expect(event.deliveryNote, '声音小了一些');
    expect(event.distanceNote, '因为距离近');
    expect(event.manner, '严肃地说');
    expect(event.witnesses.first.content, contains('严肃地说'));
  });

  for (final environment in [false, true]) {
    test('正文语义意见反馈重写并重审，环境分支=$environment', () async {
      var checks = 0;
      final agents = turns.FakeAgents(choices: ['慧音'], renderTexts: ['她已经进屋。', '她仍在门外。']);
      final trace = await TurnLoop(scene: turns.buildScene(), agents: agents,
        routeDecider: ({required scene, required events, errors, previous}) async => environment ? 'env' : 'turn',
        environmentSource: ({required scene, required events, feedback}) async => [_rain],
        rCheck: ({required publicText, required godNote, required events}) async =>
          ++checks == 1 ? ['裁定没有允许进屋'] : [],
      ).run(newEvents: [], actorNames: ['慧音'], perceptionNames: []);
      expect(agents.renderCalls, 2);
      expect(agents.rFeedback[1].single, contains('裁定没有允许进屋'));
      expect(checks, 2);
      expect(trace.needsReview, isFalse);
      expect(trace.render!['public_text'], '她仍在门外。');
    });
  }

  test('语义复核预算耗尽后交给玩家，暂停和继续不重做已接受的行动', () async {
    var session = TurnSession(worldId: 'w', parallelPlaceId: 'p', rawInput: '', journal: TurnJournal());
    var repaired = false;
    var asked = 0;
    TurnLoop build(turns.FakeAgents agents) => TurnLoop(scene: turns.buildScene(), agents: agents,
      rStepBudget: 2,
      rCheck: ({required publicText, required godNote, required events}) async => repaired ? [] : ['多写了反应'],
      onCheckpoint: (stage, data) => session = _save(session, stage, data),
      askPlayer: (question) async { asked++; expect(question.step, 'GM_NARRATE');
        return repaired ? '按既有事实重写' : null; });
    final first = turns.FakeAgents(choices: ['慧音']);
    await expectLater(build(first).run(newEvents: [], actorNames: ['慧音']),
      throwsA(isA<PlayerPausedException>()));
    expect(first.renderCalls, 2);
    expect(asked, 1);
    expect(session.checkpoints, contains('CH_ACT'));
    repaired = true;
    final resumed = turns.FakeAgents(choices: []);
    final trace = await build(resumed).run(newEvents: [], actorNames: ['慧音'], resume: session);
    expect(resumed.perceiveHistory, isEmpty);
    expect(resumed.renderCalls, 1);
    expect(trace.needsReview, isFalse);
    expect(asked, 2);
  });

  test('旧复核警告恢复后会携带意见重写，而非重复返回旧警告', () async {
    var session = TurnSession(worldId: 'w', parallelPlaceId: 'p', rawInput: '', journal: TurnJournal());
    final first = turns.FakeAgents(choices: ['慧音']);
    await TurnLoop(scene: turns.buildScene(), agents: first, rStepBudget: 1,
      rCheck: ({required publicText, required godNote, required events}) async => ['多写了动作'],
      onCheckpoint: (stage, data) => session = _save(session, stage, data),
    ).run(newEvents: [], actorNames: ['慧音']);
    final next = turns.FakeAgents(choices: []);
    final trace = await TurnLoop(scene: turns.buildScene(), agents: next,
      rCheck: ({required publicText, required godNote, required events}) async => [],
    ).run(newEvents: [], actorNames: ['慧音'], resume: session);
    expect(next.renderCalls, 1);
    expect(next.rFeedback.single.single, contains('多写了动作'));
    expect(trace.needsReview, isFalse);
  });

  test('原始环境增量错误不能被解码丢掉，修正后才落账', () async {
    var calls = 0;
    final runner = LlmAgentRunner(provider: _provider, apiKey: 'unused', model: 'test',
      sender: (request) async { calls++;
        return LlmReply(text: jsonEncode({'events': [{'content': '门已经打开', 'state_delta': {
          'facts': calls == 1 ? {'subject': 'place:东门内侧'} : [
            {'subject': 'place:东门内侧', 'predicate': 'door_open', 'object': 'true', 'evidence': '门闩打开'}],
        }}]})); });
    final trace = await TurnLoop(scene: turns.buildScene(), agents: turns.FakeAgents(choices: []),
      causalContext: CausalContext(state: causal.worldState()),
      routeDecider: ({required scene, required events, errors, previous}) async => 'env',
      environmentSource: runner.environmentEvents,
    ).run(newEvents: [], actorNames: []);
    expect(calls, 2);
    expect(trace.environmentErrors, isEmpty);
    expect(trace.stateDelta!.facts.single.object, 'true');
  });

  test('裁定中的无效事实和能力状态拒绝后重裁，不静默接受', () async {
    final invalid = causal.ruling()..['facts'] = [null];
    final agents = turns.FakeAgents(choices: ['慧音'], action: turns.stealAction(),
      arbitrationAttempts: [invalid, causal.ruling()]);
    final trace = await TurnLoop(scene: turns.buildScene(), agents: agents,
      causalContext: CausalContext(state: causal.worldState()))
      .run(newEvents: [], actorNames: ['慧音']);
    expect(agents.resolveFeedback, hasLength(2));
    expect(agents.resolveFeedback[1].join(), contains('必须是对象'));
    expect(trace.resolveErrors, isEmpty);
  });

  test('行动增量格式、未知字段、能力状态和空条目均不能静默归零', () {
    for (final raw in <Object?>[
      {'move': ['慧音', '仓房']}, {'moves': {'慧音': '仓房'}},
      {'facts': [{}]}, {'items': [null]},
      {'constraints': [{'who': '慧音', 'capability': 'run', 'state': 'maybe'}]},
    ]) { expect(StateDelta.proposalErrors(raw), isNotEmpty); }
    expect(StateDelta.proposalErrors(const StateDelta().toJson()), isEmpty);
  });

  test('无声书写不要求发声能力，失声玩家可以完成行动', () async {
    const parsed = PlayerParseResult(raw: '写下等等', segments: [
      PlayerSegment(id: 's1', kind: PlayerSegmentKind.speech, text: '等等',
        delivery: Delivery(channel: DeliveryChannel.visual, form: 'written', audience: Audience.scene))],
      unresolved: [], warnings: []);
    final trace = await TurnLoop(scene: turns.buildScene(), agents: turns.FakeAgents(choices: ['信标']),
      controlledCharacter: '信标', constraints: const [FunctionalConstraint(
        who: '信标', capability: 'speak', state: ConstraintState.cannot)],
      playerActionHandler: ({required actor, required scene}) async => parsed.toActionRecord(actorName: actor, scene: scene),
    ).run(newEvents: [], actorNames: ['信标']);
    expect(trace.stop, isNull);
    expect(trace.events.single.content, '等等');
  });

  test('拒绝互相包含的容器，合法嵌套不受影响', () {
    const cycle = StateDelta(discoveries: [
      EntityDiscovery(id: 'container:a', kind: 'container', name: '甲箱', location: 'container:b', evidence: '现场描述'),
      EntityDiscovery(id: 'container:b', kind: 'container', name: '乙箱', location: 'container:a', evidence: '现场描述'),
    ]);
    final state = causal.worldState();
    expect(state.transitionErrors(cycle), contains(contains('循环包含')));
    expect(() => state.applyDelta(cycle), throwsStateError);
    expect(state.transitionErrors(const StateDelta(discoveries: [
      EntityDiscovery(id: 'container:a', kind: 'container', name: '甲箱', location: '东门内侧', evidence: '现场描述'),
      EntityDiscovery(id: 'container:b', kind: 'container', name: '乙箱', location: 'container:a', evidence: '现场描述'),
    ])), isEmpty);
  });
}
