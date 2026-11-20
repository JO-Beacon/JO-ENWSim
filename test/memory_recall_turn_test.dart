import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/engine/agents/llm_agent_runner.dart';
import 'package:joenws/engine/character_memory.dart';
import 'package:joenws/engine/memory_agent.dart';
import 'package:joenws/engine/memory_recall.dart';
import 'package:joenws/engine/perception.dart';
import 'package:joenws/engine/turn_loop.dart';
import 'package:joenws/engine/turn_session.dart';
import 'package:joenws/model/llm_client.dart';

import 'engine_turn_loop_test.dart' as turn;
import 'memory_recall_runner_test.dart' as runner;
import 'memory_recall_test.dart' as fixture;

class ArchiveAgents extends turn.FakeAgents implements ArchiveRecallAgents {
  ArchiveAgents(this.delegate, {super.actions}) : super(choices: <String?>['慧音']);
  final LlmAgentRunner delegate;
  final List<String> contexts = <String>[];
  int recallCalls = 0;

  @override
  Future<List<MemoryOperation>?> manageMemory({required String characterId,
      required Map<String, Object?> percepts, required List<CharacterMemory> memory,
      required Set<String> allowedEventIds}) async => <MemoryOperation>[];

  @override
  Future<MemoryRecallResult> recallWithArchive({required NarrativeScene scene,
      required Map<String, Object?> percepts, required MemoryRecallService service}) {
    recallCalls++;
    return delegate.recallWithArchive(scene: scene, percepts: percepts, service: service);
  }

  @override
  Future<Map<String, Object?>> act({required String name, required String context,
      required String perceive, required List<String> present}) {
    contexts.add(context);
    return super.act(name: name, context: context, perceive: perceive, present: present);
  }
}

class ForeignResultAgents extends ArchiveAgents {
  ForeignResultAgents() : super(runner.runnerFor((_) async => throw StateError('不应调用')));
  @override
  Future<MemoryRecallResult> recallWithArchive({required NarrativeScene scene,
      required Map<String, Object?> percepts, required MemoryRecallService service}) async =>
    fixture.serviceFor(MemoryStore(<CharacterMemory>[fixture.summary])).legacy(<String>[]);
}

MemoryStore turnMemory() => MemoryStore(<CharacterMemory>[
  const CharacterMemory(id: 'summary', characterId: 'char:慧音', text: '藏过钥匙。',
    kind: MemoryKind.summary, state: MemoryState.compressed, sourceMemories: <String>['old']),
  fixture.oldMemory('old', owner: 'char:慧音'),
  fixture.oldMemory('foreign', owner: 'char:艾琳', text: '他人的秘密。'),
]);

LlmAgentRunner readThenFinish() => runner.runnerFor((LlmRequest request) async {
  final String prompt = runner.promptOf(request);
  expect(prompt, isNot(contains('他人的秘密')));
  return LlmReply(text: jsonEncode(prompt.contains('"entries"')
    ? fixture.finish(active: <String>['summary'], archived: <String>['old'])
    : fixture.read('old')));
});

void main() {
  test('真实回合将合法旧记忆交给行动，行动重试不重复召回', () async {
    final MemoryStore memory = turnMemory();
    final List<Map<String, Object?>> before = memory.allEntries()
        .map((CharacterMemory m) => m.toJson()).toList();
    final ArchiveAgents agents = ArchiveAgents(readThenFinish(),
      actions: <Map<String, Object?>>[<String, Object?>{}, turn.speechAction('我想起钥匙了。')]);
    final Map<String, TurnCheckpoint> checkpoints = <String, TurnCheckpoint>{};
    final TurnTrace trace = await TurnLoop(scene: turn.buildScene(), agents: agents, memoryStore: memory,
      onCheckpoint: (String stage, Map<String, Object?> data) =>
        checkpoints[stage] = TurnCheckpoint(stage: stage, data: data),
    ).run(newEvents: <WorldEvent>[turn.playerEvent()], npcNames: <String>['慧音']);
    expect(trace.events, isNotEmpty);
    expect(trace.events.any((WorldEvent e) => e.id == 'old-event'), isFalse);
    expect(agents.contexts, hasLength(2));
    expect(agents.contexts.first, agents.contexts.last);
    expect(agents.contexts.first, contains('本次查阅的旧记忆'));
    expect(agents.contexts.first, contains('雨夜'));
    expect(agents.contexts.first, isNot(contains('他人的秘密')));
    expect(agents.recallCalls, 1);
    expect(checkpoints['CH_MEMORY_RECALL:慧音']!.data['complete'], isTrue);
    expect(memory.allEntries().map((CharacterMemory m) => m.toJson()), unorderedEquals(before));
  });

  test('读取后中断再从 JSON session 恢复，只补结束请求', () async {
    final MemoryStore memory = turnMemory();
    final Map<String, TurnCheckpoint> checkpoints = <String, TurnCheckpoint>{};
    final ArchiveAgents original = ArchiveAgents(readThenFinish());
    await expectLater(TurnLoop(scene: turn.buildScene(), agents: original, memoryStore: memory,
      onCheckpoint: (String stage, Map<String, Object?> data) {
        checkpoints[stage] = TurnCheckpoint(stage: stage, data: data);
        if (stage == 'CH_MEMORY_RECALL:慧音' &&
            (data['history'] as List).isNotEmpty && data['complete'] == false) {
          throw StagePause(stage);
        }
      },
    ).run(newEvents: <WorldEvent>[turn.playerEvent()], npcNames: <String>['慧音']),
      throwsA(isA<StagePause>()));
    int calls = 0;
    final LlmAgentRunner next = runner.runnerFor((LlmRequest request) async {
      calls++;
      expect(runner.promptOf(request), contains('雨夜'));
      return LlmReply(text: jsonEncode(fixture.finish(archived: <String>['old'])));
    }, journal: original.delegate.journal);
    final ArchiveAgents resumed = ArchiveAgents(next);
    final TurnSession session = TurnSession.fromJson(jsonDecode(jsonEncode(
      TurnSession(worldId: '', parallelPlaceId: '', rawInput: '',
        journal: next.journal, checkpoints: checkpoints).toJson())) as Map<String, dynamic>);
    await TurnLoop(scene: turn.buildScene(), agents: resumed, memoryStore: turnMemory())
      .run(newEvents: <WorldEvent>[turn.playerEvent()], npcNames: <String>['慧音'], resume: session);
    expect(calls, 1);
    expect(resumed.contexts.single, contains('雨夜'));
  });

  test('完整召回 checkpoint 恢复后不调用召回模型', () async {
    final MemoryStore memory = turnMemory();
    final Map<String, TurnCheckpoint> checkpoints = <String, TurnCheckpoint>{};
    await expectLater(TurnLoop(scene: turn.buildScene(), agents: ArchiveAgents(readThenFinish()),
      memoryStore: memory, onCheckpoint: (String stage, Map<String, Object?> data) {
        checkpoints[stage] = TurnCheckpoint(stage: stage, data: data);
        if (stage == 'CH_MEMORY_RECALL:慧音' && data['complete'] == true) throw StagePause(stage);
      }).run(newEvents: <WorldEvent>[turn.playerEvent()], npcNames: <String>['慧音']),
      throwsA(isA<StagePause>()));
    final ArchiveAgents resumed = ArchiveAgents(runner.runnerFor((_) async => throw StateError('不应请求模型')));
    await TurnLoop(scene: turn.buildScene(), agents: resumed, memoryStore: turnMemory()).run(
      newEvents: <WorldEvent>[turn.playerEvent()], npcNames: <String>['慧音'],
      resume: TurnSession(worldId: '', parallelPlaceId: '', rawInput: '',
        journal: TurnJournal(), checkpoints: checkpoints));
    expect(resumed.recallCalls, 0);
    expect(resumed.contexts.single, contains('雨夜'));
  });

  test('引擎拒绝来自其他服务的结果，即使 runner 自称已校验', () async {
    final ForeignResultAgents agents = ForeignResultAgents();
    await expectLater(TurnLoop(scene: turn.buildScene(), agents: agents, memoryStore: turnMemory())
      .run(newEvents: <WorldEvent>[turn.playerEvent()], npcNames: <String>['慧音']),
      throwsA(isA<RetryExhaustedException>()));
    expect(agents.contexts, isEmpty);
  });

  test('模型直接结束空召回时，行动不会收到默认工作集或归档原文', () async {
    final ArchiveAgents agents = ArchiveAgents(runner.runnerFor((LlmRequest request) async {
      expect(runner.promptOf(request), isNot(contains('雨夜')));
      return LlmReply(text: jsonEncode(fixture.finish()));
    }));
    await TurnLoop(scene: turn.buildScene(), agents: agents, memoryStore: turnMemory())
      .run(newEvents: <WorldEvent>[turn.playerEvent()], npcNames: <String>['慧音']);
    expect(agents.contexts.single, isNot(contains('藏过钥匙')));
    expect(agents.contexts.single, isNot(contains('雨夜')));
    expect(agents.contexts.single, isNot(contains('本次查阅的旧记忆')));
  });
}
