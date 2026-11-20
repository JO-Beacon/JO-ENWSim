import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/engine/agents/llm_agent_runner.dart';
import 'package:joenws/engine/character_memory.dart';
import 'package:joenws/engine/memory_agent.dart';
import 'package:joenws/engine/perception.dart';
import 'package:joenws/engine/sequence.dart';
import 'package:joenws/engine/turn_loop.dart';
import 'package:joenws/engine/turn_session.dart';
import 'package:joenws/model/llm_client.dart';
import 'package:joenws/model/provider.dart';

import 'engine_turn_loop_test.dart' as fixtures;

const String directive = 'OWNER-SYS_RECOVERY-INSTRUCTION';

class InterventionAgents extends fixtures.FakeAgents {
  InterventionAgents(this.failure, {this.model})
      : super(choices: ['慧音'], action: failure == 'GM_RESOLVE_ACTION'
            ? fixtures.stealAction() : fixtures.speechAction('我听见了。'));

  final String failure;
  final LlmAgentRunner? model;
  bool repaired = false;
  final Map<String, int> calls = {};
  final Map<String, String> help = {};
  final List<String> retried = [];
  void hit(String stage) => calls.update(stage, (int n) => n + 1, ifAbsent: () => 1);
  bool fails(String stage) => failure == stage && !repaired;

  @override
  void prepareRetry(String stage) {
    retried.add(stage);
    model?.prepareRetry(stage);
  }

  @override
  void setPlayerHelp(Map<String, String> value) {
    help..clear()..addAll(value);
    model?.setPlayerHelp(value);
  }

  @override
  void recordIntervention(String key, PlayerQuestion question, String answer) {
    model?.recordIntervention(key, question, answer);
  }

  @override
  Future<Map<String, Object?>> perceive({required String name, required String context,
      required String events}) async {
    hit('CH_PERCEIVE');
    if (fails('CH_PERCEIVE')) {
      return {'percepts': [{'event_id': 'E999', 'content': '错误引用'}]};
    }
    return super.perceive(name: name, context: context, events: events);
  }

  @override
  Future<List<String>> selectEligible({required List<String> baseEligible,
      required List<String> cast, String playerNotes = '',
      List<String> errors = const [], List<String>? previous}) async {
    hit('GM_ELIGIBILITY');
    return fails('GM_ELIGIBILITY') ? ['不存在的角色'] : baseEligible;
  }

  @override
  Future<String?> selectActor({required List<String> eligible,
      required Map<String, Map<String, Object?>> percepts, String playerNotes = '',
      List<String> errors = const [], String? previous}) async {
    hit('GM_SELECT_ACTOR');
    return fails('GM_SELECT_ACTOR') ? '不存在的角色' : '慧音';
  }

  @override
  Future<Map<String, Object?>> act({required String name, required String context,
      required String perceive, required List<String> present}) async {
    hit('CH_ACT');
    if (failure == 'transport') {
      return model!.act(name: name, context: context, perceive: perceive, present: present);
    }
    if (fails('CH_ACT')) return fixtures.actionWithoutRequires();
    return super.act(name: name, context: context, perceive: perceive, present: present);
  }

  @override
  Future<Map<String, Object?>> adjudicate({required Map<String, Object?> action,
      required String actor, required String? target, required String place,
      required List<String> present, List<String> errors = const [],
      Map<String, Object?>? previous, String playerNotes = ''}) async {
    hit('GM_RESOLVE_ACTION');
    if (fails('GM_RESOLVE_ACTION')) return {'outcome': 'invalid', 'deltas': [], 'reason': ''};
    return super.adjudicate(action: action, actor: actor, target: target,
        place: place, present: present, errors: errors, previous: previous);
  }

  @override
  Future<Map<String, Object?>> render({required List<WorldEvent> events,
      RenderPov pov = RenderPov.omniscient, List<String> errors = const [],
      String observerId = '', NarrativeScene? scene,
      Map<String, Object?>? previous}) async {
    hit('GM_NARRATE');
    if (fails('GM_NARRATE') || fails('ENV_R')) return {'public_text': '', 'god_note': ''};
    return super.render(events: events, pov: pov, errors: errors, previous: previous);
  }

  @override
  Future<List<MemoryOperation>?> manageMemory({required String characterId,
      required Map<String, Object?> percepts, required List<CharacterMemory> memory,
      required Set<String> allowedEventIds}) async {
    if (failure == 'CH_MEMORY_WRITE') {
      return model!.manageMemory(characterId: characterId, percepts: percepts,
          memory: memory, allowedEventIds: allowedEventIds);
    }
    return super.manageMemory(characterId: characterId, percepts: percepts,
        memory: memory, allowedEventIds: allowedEventIds);
  }

  @override
  Future<List<String>?> recallMemory({required String characterId,
      required NarrativeScene scene, required Map<String, Object?> percepts,
      required List<CharacterMemory> memory}) async {
    if (failure == 'CH_MEMORY_RECALL') {
      return model!.recallMemory(characterId: characterId, scene: scene,
          percepts: percepts, memory: memory);
    }
    return null;
  }
}

TurnLoop loopFor(InterventionAgents agents, {PlayerAsker? askPlayer,
    CheckpointCallback? onCheckpoint, String recoveryContext = '', RCheck? rCheck,
    PlayerActionHandler? playerActionHandler}) => TurnLoop(
  scene: fixtures.buildScene(), agents: agents, askPlayer: askPlayer,
  onCheckpoint: onCheckpoint, recoveryContext: recoveryContext, rCheck: rCheck,
  controlledCharacter: playerActionHandler == null ? '' : '慧音', playerActionHandler: playerActionHandler,
  openPlaceStepBudget: 2, routeStepBudget: 2, castStepBudget: 2, selectActorStepBudget: 2,
  perceiveStepBudget: 2, actStepBudget: 2, resolveStepBudget: 2, environmentStepBudget: 2, rStepBudget: 2,
  parallelPlaceCandidates: agents.failure == 'GM_OPEN_PLACE'
      ? const [ParallelPlaceCandidate(place: '仓房', members: [])] : const [],
  openPlaceDecider: ({required scene, required events, errors, previous}) async {
    agents.hit('GM_OPEN_PLACE');
    return agents.fails('GM_OPEN_PLACE')
        ? const OpenPlaceResult(openParallelPlace: true, why: '错误地点', place: '未知地点')
        : const OpenPlaceResult(openParallelPlace: false, why: '保持当前地点');
  },
  routeDecider: ({required scene, required events, errors, previous}) async {
    agents.hit('GM_ROUTE');
    if (agents.fails('GM_ROUTE')) return 'invalid';
    return ['GM_ENV_UPDATE', 'ENV_R'].contains(agents.failure) ? 'env' : 'turn';
  },
  castDecider: agents.failure != 'GM_CAST' ? null
      : ({required scene, required knownCast, errors, previous}) async {
          agents.hit('GM_CAST');
          return agents.fails('GM_CAST') ? ['不存在的角色'] : knownCast;
        },
  environmentSource: ({required scene, required events, feedback}) async {
    agents.hit('GM_ENV_UPDATE');
    return [WorldEvent(id: 'E9', kind: WorldEventKind.action,
      content: agents.fails('GM_ENV_UPDATE') ? '' : '雨势加大', actor: '', source: 'environment',
      delivery: const Delivery(channel: DeliveryChannel.other,
          form: 'narration', audience: Audience.scene))];
  },
);

Future<TurnTrace> run(TurnLoop loop, {TurnSession? resume}) => loop.run(
  newEvents: [fixtures.playerEvent()], actorNames: ['慧音'],
  perceptionNames: ['慧音'], resume: resume,
);

LlmAgentRunner modelFor(LlmSender sender) => LlmAgentRunner(
  provider: const Provider(id: 'review', protocol: Protocol.deepseekAnthropic, name: 'review'),
  apiKey: 'unused', model: 'test', sender: sender,
);

void main() {
  for (final String stage in ['GM_OPEN_PLACE', 'GM_ROUTE', 'GM_CAST', 'GM_ELIGIBILITY', 'GM_SELECT_ACTOR',
      'CH_PERCEIVE', 'CH_ACT', 'GM_RESOLVE_ACTION', 'GM_ENV_UPDATE', 'GM_NARRATE', 'ENV_R']) {
    test('$stage 耗尽后交给玩家本人，收到指令才继续', () async {
      final InterventionAgents agents = InterventionAgents(stage);
      int asked = 0;
      final TurnTrace trace = await run(loopFor(agents, askPlayer: (question) async {
        asked++;
        expect(agents.repaired, isFalse);
        expect(question.code, 'retry_exhausted');
        expect(question.kind, 'direction');
        expect(question.reason, isNotEmpty);
        expect(question.step, stage == 'ENV_R' ? 'GM_NARRATE' : stage);
        expect(agents.calls[stage == 'ENV_R' ? 'GM_NARRATE' : stage], 2);
        agents.repaired = true;
        return directive;
      }));
      expect(asked, 1);
      expect(trace.playerIntervention, isNull);
      expect([...trace.events, ...trace.environmentEvents], isNotEmpty);
      expect([...trace.events, ...trace.environmentEvents].map((e) => e.content).join(),
          isNot(contains(directive)));
      expect(agents.help.values, contains(directive));
      if (stage == 'GM_NARRATE') expect(agents.calls['CH_ACT'], 1);
    });
  }

  test('暂缓处理会持久保存问题，恢复时保留已完成行动', () async {
    TurnSession session = TurnSession(worldId: 'w', parallelPlaceId: 'p',
        rawInput: '', journal: TurnJournal());
    void checkpoint(String stage, Map<String, Object?> data) {
      if (data['invalidate'] is List) {
        session = session.withoutCheckpoints((data['invalidate'] as List).cast<String>());
      }
      session = session.withCheckpoint(stage, data);
    }
    final InterventionAgents first = InterventionAgents('GM_NARRATE');
    int asked = 0;
    await expectLater(run(loopFor(first, onCheckpoint: checkpoint, askPlayer: (_) async {
      asked++;
      return null;
    })), throwsA(isA<PlayerPausedException>()));
    expect(asked, 1);
    expect(session.checkpoints['SYS_RECOVERY']!.data['pending'], isTrue);
    expect(session.checkpoints.containsKey('SYS_RECORD'), isTrue);
    expect(session.checkpoints.containsKey('GM_NARRATE'), isFalse);
    session = TurnSession.fromJson(jsonDecode(jsonEncode(session.toJson())));
    final InterventionAgents next = InterventionAgents('GM_NARRATE')..repaired = true;
    final TurnTrace trace = await run(loopFor(next, onCheckpoint: checkpoint,
        askPlayer: (_) async => directive), resume: session);
    expect(trace.renderViolations, isEmpty);
    expect(next.calls['CH_ACT'], isNull);
    expect(next.calls['GM_NARRATE'], 1);
    expect(session.checkpoints['SYS_RECOVERY']!.data['pending'], isFalse);
  });

  test('玩家修改上下文后丢弃旧恢复点和回放', () async {
    TurnSession session = TurnSession(worldId: 'w', parallelPlaceId: 'p', rawInput: '', journal: TurnJournal());
    void checkpoint(String stage, Map<String, Object?> data) {
      if (data['invalidate'] is List) {
        session = session.withoutCheckpoints((data['invalidate'] as List).cast<String>());
      }
      session = session.withCheckpoint(stage, data);
    }
    await expectLater(run(loopFor(InterventionAgents('GM_NARRATE'), onCheckpoint: checkpoint,
        recoveryContext: 'old', askPlayer: (_) async => null)), throwsA(isA<PlayerPausedException>()));
    final InterventionAgents changed = InterventionAgents('GM_NARRATE')..repaired = true;
    await run(loopFor(changed, onCheckpoint: checkpoint, recoveryContext: 'edited',
        askPlayer: (_) async => directive), resume: session);
    expect(changed.retried, contains('*'));
    expect(changed.calls['CH_ACT'], 1);
    expect(changed.calls['CH_PERCEIVE'], 1);
  });

  test('网络和 JSON 耗尽可恢复，指令在 JSON 重试时继续保留', () async {
    int sent = 0;
    final List<String> prompts = [];
    final LlmAgentRunner model = modelFor((request) async {
      sent++;
      prompts.add(request.messages.last.content);
      if (sent <= 3) return const LlmReply(error: 'network unavailable');
      if (sent == 4) return const LlmReply(text: 'invalid json');
      return LlmReply(text: jsonEncode(fixtures.speechAction('我听见了。')));
    });
    final InterventionAgents agents = InterventionAgents('transport', model: model);
    final TurnTrace trace = await run(loopFor(agents, askPlayer: (question) async {
      expect(sent, 3);
      expect(question.step, 'CH_ACT:慧音');
      return directive;
    }));
    expect(trace.events, hasLength(1));
    expect(sent, 5);
    expect(prompts.skip(3).every((p) => p.contains(directive)), isTrue);
    expect(model.journal.answers.values, contains(directive));
  });

  for (final String stage in ['CH_MEMORY_WRITE', 'CH_MEMORY_RECALL']) {
    test('$stage 的语义重试耗尽也移交玩家', () async {
      int sent = 0;
      bool repaired = false;
      final LlmAgentRunner model = modelFor((request) async {
        sent++;
        if (!repaired) {
          return LlmReply(text: stage == 'CH_MEMORY_WRITE'
              ? '{"operations":[{"op":"invalid"}]}' : '{"memory_ids":["unknown"]}');
        }
        expect(request.messages.last.content, contains(directive));
        return LlmReply(text: stage == 'CH_MEMORY_WRITE' ? '{"operations":[]}' : '{"memory_ids":[]}');
      });
      final InterventionAgents agents = InterventionAgents(stage, model: model);
      final TurnTrace trace = await run(loopFor(agents, askPlayer: (question) async {
        expect(sent, 3);
        expect(question.step, stage == 'CH_MEMORY_WRITE' ? 'CH_MEMORY_WRITE:慧音' : 'CH_MEMORY_RECALL:慧音');
        repaired = true;
        return directive;
      }));
      expect(trace.events, hasLength(1));
      expect(sent, 4);
    });
  }

  test('GM_PARSE_INPUT 的解析预算耗尽由玩家处理，不转成玩家角色行动', () async {
    bool repaired = false;
    int sent = 0;
    final LlmAgentRunner model = modelFor((request) async {
      sent++;
      return LlmReply(text: jsonEncode({
        'segments': [{'id': 's1', 'kind': 'speech', 'text': repaired ? '好' : '原文没有的台词',
          'target': null, 'delivery': {'channel': 'voice', 'form': 'spoken', 'audience': 'scene'},
          'requires': ['speak'], 'evidence': {}}],
        'unresolved': [], 'warnings': [],
      }));
    });
    final InterventionAgents agents = InterventionAgents('GM_PARSE_INPUT', model: model);
    final TurnTrace trace = await run(loopFor(agents, askPlayer: (question) async {
      expect(sent, 3);
      expect(question.step, 'GM_PARSE_INPUT');
      repaired = true;
      return directive;
    }, playerActionHandler: ({required actor, required scene}) async {
      final parsed = await model.parsePlayer(raw: '好', scene: scene, playerName: actor);
      return parsed.toActionRecord(actorName: actor, scene: scene);
    }));
    expect(sent, 4);
    expect(trace.events.single.content, '好');
  });

  test('GM_REVIEW_NARRATION 调用耗尽后保留正文，只重试复核', () async {
    int checked = 0;
    final InterventionAgents agents = InterventionAgents('GM_REVIEW_NARRATION');
    final TurnTrace trace = await run(loopFor(agents, askPlayer: (_) async {
      agents.repaired = true;
      return directive;
    }, rCheck: ({required publicText, required godNote, required events}) async {
      checked++;
      if (!agents.repaired) throw RetryExhaustedException(step: 'GM_REVIEW_NARRATION', reason: '复核调用耗尽');
      return [];
    }));
    expect(trace.needsReview, isFalse);
    expect(agents.calls['GM_NARRATE'], 1);
    expect(checked, 2);
  });

  test('再次耗尽必须再次移交，不能自行无限重试', () async {
    final InterventionAgents agents = InterventionAgents('CH_ACT');
    int asked = 0;
    await expectLater(run(loopFor(agents, askPlayer: (_) async {
      asked++;
      return asked == 1 ? directive : null;
    })), throwsA(isA<PlayerPausedException>()));
    expect(asked, 2);
    expect(agents.calls['CH_ACT'], 4);
    expect(agents.calls['GM_NARRATE'], isNull);
  });

  test('旧的失败正文恢复点先自动重写，修好后无需移交玩家', () async {
    final InterventionAgents agents = InterventionAgents('none');
    final TurnSession session = TurnSession(worldId: 'w', parallelPlaceId: 'p',
      rawInput: '', journal: TurnJournal(), checkpoints: {
        'GM_NARRATE': const TurnCheckpoint(stage: 'GM_NARRATE', data: {
          'render': {'public_text': '', 'god_note': ''}, 'publicText': '', 'godNote': '',
          'violations': [{'code': 'empty_public_text', 'message': '正文不能为空'}],
        }),
      });
    int asked = 0;
    final TurnTrace trace = await run(loopFor(agents, askPlayer: (_) async {
      asked++;
      return directive;
    }), resume: session);
    expect(asked, 0);
    expect(trace.renderViolations, isEmpty);
    expect(agents.calls['GM_NARRATE'], 1);
    expect(agents.calls['CH_ACT'], 1);
  });

  test('GM_ENV_UPDATE 主动求助暂缓后立即暂停，只询问一次', () async {
    int asked = 0;
    final TurnLoop loop = TurnLoop(scene: fixtures.buildScene(),
      agents: InterventionAgents('none'),
      routeDecider: ({required scene, required events, errors, previous}) async => 'env',
      environmentSource: ({required scene, required events, feedback}) async => throw const AskPlayerException(
        PlayerQuestion(step: 'GM_ENV_UPDATE', code: 'missing_fact', reason: '缺少环境依据', question: '是否下雨？')),
      askPlayer: (_) async { asked++; return null; },
    );
    await expectLater(run(loop), throwsA(isA<PlayerPausedException>()));
    expect(asked, 1);
  });
}
