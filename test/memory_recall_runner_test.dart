import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/engine/agents/llm_agent_runner.dart';
import 'package:joenws/engine/character_memory.dart';
import 'package:joenws/engine/memory_recall.dart';
import 'package:joenws/engine/perception.dart';
import 'package:joenws/engine/turn_session.dart';
import 'package:joenws/model/llm_client.dart';
import 'package:joenws/model/provider.dart';

import 'memory_recall_test.dart' as fixture;

LlmAgentRunner runnerFor(Future<LlmReply> Function(LlmRequest) send, {
    TurnJournal? journal, void Function()? onJournalChanged}) => LlmAgentRunner(
  provider: const Provider(id: 'p', protocol: Protocol.deepseekAnthropic, name: 'test'),
  apiKey: 'test-key', model: 'test-model', sender: send, journal: journal,
  onJournalChanged: onJournalChanged,
);

NarrativeScene recallScene() => NarrativeScene(place: '门边',
  names: const <String, String>{'char:灵梦': '灵梦'},
  cast: <CharacterSnapshot>[CharacterSnapshot(id: 'char:灵梦', name: '灵梦', nearby: true)]);

Future<MemoryRecallResult> runRecall(LlmAgentRunner runner, MemoryRecallService service) =>
  runner.recallWithArchive(scene: recallScene(),
    percepts: const <String, Object?>{'attention': '想找钥匙'}, service: service);

String promptOf(LlmRequest request) => request.messages.map((LlmMessage m) => m.content).join();

void main() {
  test('不发起查询时初始提示没有归档正文，明确空集不会回退', () async {
    final MemoryStore store = MemoryStore(<CharacterMemory>[fixture.summary, fixture.oldMemory('old')]);
    final MemoryRecallService service = fixture.serviceFor(store);
    final LlmAgentRunner runner = runnerFor((LlmRequest req) async {
      expect(promptOf(req), isNot(contains('雨夜')));
      expect(promptOf(req), contains('source_memories'));
      return LlmReply(text: jsonEncode(fixture.finish()));
    });
    final MemoryRecallResult result = await runRecall(runner, service);
    expect(result.activeIds, isEmpty);
    expect(result.archived, isEmpty);
    expect(service.requests, 0);
  });

  test('模型先搜索再读取并采用，保存实际用量', () async {
    final MemoryStore store = MemoryStore(<CharacterMemory>[
      fixture.oldMemory('old'), fixture.oldMemory('foreign', owner: 'char:艾琳', text: '他人秘密。'),
    ]);
    final MemoryRecallService service = fixture.serviceFor(store);
    int calls = 0;
    final LlmAgentRunner runner = runnerFor((LlmRequest req) async {
      calls++;
      expect(promptOf(req), isNot(contains('他人秘密')));
      if (calls == 1) {
        expect(promptOf(req), isNot(contains('雨夜')));
        return const LlmReply(text: '{"action":"search","query":"钥匙"}', usage: LlmUsage(input: 10, output: 2));
      }
      if (calls == 2) {
        expect(promptOf(req), contains('candidates'));
        return LlmReply(text: jsonEncode(fixture.read('old')), usage: const LlmUsage(input: 20, output: 3));
      }
      expect(promptOf(req), contains('entries'));
      return LlmReply(text: jsonEncode(fixture.finish(archived: <String>['old'])),
        usage: const LlmUsage(input: 30, output: 4));
    });
    final MemoryRecallResult result = await runRecall(runner, service);
    expect(result.archived.single.id, 'old');
    expect(calls, 3);
    expect(service.toCheckpoint()['input_tokens'], 60);
    expect(service.toCheckpoint()['output_tokens'], 9);
    expect(service.returnedRunes, service.history.fold<int>(0,
      (int sum, Map<String, Object?> item) => sum + jsonEncode(item['response']).runes.length));
  });

  test('读取后暂停可续跑，JSON session 保留同一正文且不重复查询', () async {
    final MemoryStore store = MemoryStore(<CharacterMemory>[fixture.summary, fixture.oldMemory('old')]);
    Map<String, Object?>? saved;
    bool pause = true;
    final MemoryRecallService first = fixture.serviceFor(store, onChanged: (Map<String, Object?> data) {
      saved = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
      if ((data['history'] as List).isNotEmpty && pause) {
        pause = false;
        throw StateError('模拟进程中断');
      }
    });
    final LlmAgentRunner original = runnerFor((_) async => LlmReply(text: jsonEncode(fixture.read('old'))));
    await expectLater(runRecall(original, first), throwsStateError);
    final TurnSession session = TurnSession(worldId: 'world', parallelPlaceId: 'lane', rawInput: '',
      journal: original.journal).withCheckpoint('CH_MEMORY_RECALL:灵梦', saved!);
    final TurnSession reloaded = TurnSession.fromJson(
      jsonDecode(jsonEncode(session.toJson())) as Map<String, dynamic>);
    final MemoryRecallService resumed = fixture.serviceFor(store,
      checkpoint: reloaded.checkpoints['CH_MEMORY_RECALL:灵梦']!.data);
    int calls = 0;
    final LlmAgentRunner runner = runnerFor((LlmRequest req) async {
      calls++;
      expect(promptOf(req), contains('雨夜'));
      return LlmReply(text: jsonEncode(fixture.finish(archived: <String>['old'])));
    }, journal: reloaded.journal);
    final MemoryRecallResult result = await runRecall(runner, resumed);
    expect(calls, 1);
    expect(resumed.requests, 1);
    expect(resumed.modelCalls, 2);
    expect(result.archived.single.version, 2);
    final MemoryRecallService completed = fixture.serviceFor(store, checkpoint: resumed.toCheckpoint());
    final LlmAgentRunner noNetwork = runnerFor((_) async => throw StateError('不应再次调用'));
    expect((await runRecall(noNetwork, completed)).archived.single.text, result.archived.single.text);
  });

  test('模型响应保存后但服务处理前中断，恢复回放响应不重复扣费', () async {
    final MemoryStore store = MemoryStore(<CharacterMemory>[fixture.summary, fixture.oldMemory('old')]);
    Map<String, Object?>? saved;
    final MemoryRecallService service = fixture.serviceFor(store, onChanged: (data) => saved = data);
    final LlmAgentRunner original = runnerFor(
      (_) async => LlmReply(text: jsonEncode(fixture.read('old'))),
      onJournalChanged: () => throw StateError('响应已记录但后续中断'));
    await expectLater(runRecall(original, service), throwsA(isA<MemoryRecallPersistenceException>()));
    final MemoryRecallService resumed = fixture.serviceFor(store, checkpoint: saved);
    int calls = 0;
    final LlmAgentRunner runner = runnerFor((_) async {
      calls++;
      return LlmReply(text: jsonEncode(fixture.finish(archived: <String>['old'])));
    }, journal: original.journal);
    final MemoryRecallResult result = await runRecall(runner, resumed);
    expect(result.archived.single.id, 'old');
    expect(calls, 1);
    expect(resumed.modelCalls, 2);
  });

  test('格式错误的网络重试与动作错误共享硬预算', () async {
    final MemoryStore store = MemoryStore(<CharacterMemory>[fixture.summary]);
    final MemoryRecallService service = fixture.serviceFor(store,
      limits: const MemoryRecallLimits(modelCalls: 2));
    int calls = 0;
    final LlmAgentRunner runner = runnerFor((_) async {
      calls++;
      return LlmReply(text: calls == 1 ? '不是 JSON' : '{"action":"invalid"}');
    });
    await expectLater(runRecall(runner, service), throwsA(isA<MemoryRecallException>()));
    expect(calls, 2);
    expect(service.modelCalls, 2);
  });

  test('模型调用之前预算持久化失败时不发出请求', () async {
    final MemoryStore store = MemoryStore(<CharacterMemory>[fixture.summary]);
    final MemoryRecallService service = fixture.serviceFor(store,
      onChanged: (_) => throw StateError('无法写入'));
    int calls = 0;
    final LlmAgentRunner runner = runnerFor((_) async {
      calls++;
      return LlmReply(text: jsonEncode(fixture.finish()));
    });
    await expectLater(runRecall(runner, service), throwsStateError);
    expect(calls, 0);
  });

  test('搜索无结果后正常结束，供应商未返回用量时不编造 token', () async {
    final MemoryStore store = MemoryStore(<CharacterMemory>[fixture.oldMemory('old')]);
    final MemoryRecallService service = fixture.serviceFor(store);
    int calls = 0;
    final LlmAgentRunner runner = runnerFor((LlmRequest request) async {
      calls++;
      if (calls == 1) return const LlmReply(text: '{"action":"search","query":"没有的线索"}');
      expect(promptOf(request), contains('"candidates":[]'));
      return LlmReply(text: jsonEncode(fixture.finish()));
    });
    expect((await runRecall(runner, service)).archived, isEmpty);
    expect(service.toCheckpoint()['input_tokens'], isNull);
    expect(service.toCheckpoint()['output_tokens'], isNull);
  });
}
