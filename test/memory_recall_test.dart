import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/engine/character_memory.dart';
import 'package:joenws/engine/memory_agent.dart';
import 'package:joenws/engine/memory_recall.dart';

CharacterMemory oldMemory(String id, {String owner = 'char:灵梦',
    String text = '雨夜，我把钥匙藏在门边。', bool allowed = true,
    String visibility = 'self'}) => CharacterMemory(
  id: id, characterId: owner, text: text, state: MemoryState.archived,
  archiveRecallable: allowed, visibility: visibility, version: 2,
  sourceEvents: const <String>['old-event'],
);

const CharacterMemory summary = CharacterMemory(
  id: 'summary', characterId: 'char:灵梦', text: '我藏过钥匙。',
  kind: MemoryKind.summary, state: MemoryState.compressed,
  sourceMemories: <String>['old', 'disabled', 'foreign', 'hidden'],
);

MemoryRecallService serviceFor(MemoryStore store, {
    MemoryRecallLimits limits = const MemoryRecallLimits(),
    Map<String, Object?>? checkpoint,
    void Function(Map<String, Object?> data)? onChanged}) => MemoryRecallService(
  worldId: 'world', characterId: 'char:灵梦', memory: store.allEntries(),
  currentMemory: store.allEntries, limits: limits,
  checkpoint: checkpoint, onChanged: onChanged,
);

Map<String, Object?> read(String id) => <String, Object?>{
  'action': 'read', 'memory_ids': <String>[id],
};

Map<String, Object?> finish({List<String> active = const <String>[],
    List<String> archived = const <String>[]}) => <String, Object?>{
  'action': 'finish', 'memory_ids': active, 'archived_ids': archived,
};

void main() {
  test('缺省字段兼容旧 payload，归档访问必须显式开启', () {
    final CharacterMemory old = oldMemory('old', allowed: false);
    expect(old.toJson().containsKey('archiveRecallable'), isFalse);
    expect(CharacterMemory.fromJson(old.toJson()).archiveRecallable, isFalse);
    expect(CharacterMemory.fromJson(old.copyWith(archiveRecallable: true).toJson())
        .archiveRecallable, isTrue);
  });

  test('压缩保留可召回原文，显式归档停用', () {
    final List<CharacterMemory> entries = <CharacterMemory>[
      summary.copyWith(state: MemoryState.fresh),
      const CharacterMemory(id: 'other', characterId: 'char:灵梦', text: '另一件事。'),
    ];
    final List<CharacterMemory> compressed = applyMemoryOperations(
      characterId: 'char:灵梦', current: entries, allowedEventIds: <String>{},
      operations: const <MemoryOperation>[
        MemoryOperation(op: 'compress', memoryIds: <String>['summary', 'other'], text: '摘要。'),
      ],
    );
    expect(compressed.where((CharacterMemory m) => m.state == MemoryState.archived)
        .every((CharacterMemory m) => m.archiveRecallable), isTrue);
    final List<CharacterMemory> stopped = applyMemoryOperations(
      characterId: 'char:灵梦', current: entries, allowedEventIds: <String>{},
      operations: const <MemoryOperation>[MemoryOperation(op: 'archive', memoryId: 'other')],
    );
    expect(stopped.last.archiveRecallable, isFalse);
  });

  test('归档读取不扩大任何写入操作的权限', () {
    final List<CharacterMemory> entries = <CharacterMemory>[summary, oldMemory('old')];
    for (final MemoryOperation operation in <MemoryOperation>[
      const MemoryOperation(op: 'reinforce', memoryId: 'old'),
      const MemoryOperation(op: 'reinterpret', memoryId: 'old', text: '新说法。'),
      const MemoryOperation(op: 'compress', memoryIds: <String>['old', 'summary'], text: '合并。'),
      const MemoryOperation(op: 'encode', kind: MemoryKind.note, text: '复制。', sourceMemories: <String>['old']),
    ]) {
      expect(() => applyMemoryOperations(characterId: 'char:灵梦', current: entries,
        operations: <MemoryOperation>[operation], allowedEventIds: <String>{}),
        throwsA(isA<MemoryAgentException>()));
    }
    expect(entries.last.version, 2);
    expect(entries.last.state, MemoryState.archived);
  });

  test('按来源读取并签发结果，停用和他人条目都不能读取', () {
    final MemoryStore store = MemoryStore(<CharacterMemory>[
      summary, oldMemory('old'), oldMemory('disabled', allowed: false),
      oldMemory('foreign', owner: 'char:艾琳', text: '别人的秘密。'),
      oldMemory('hidden', visibility: 'god'),
    ]);
    final String before = jsonEncode(store.allEntries().map((CharacterMemory m) => m.toJson()).toList());
    final MemoryRecallService service = serviceFor(store);
    for (final String id in <String>['disabled', 'foreign', 'hidden', 'missing']) {
      expect(serviceFor(store).handle(read(id))['error'], '请求包含不可读取的记忆');
    }
    expect(service.handle(read('old'))['entries'], isNotEmpty);
    expect(service.handle(finish(active: <String>['summary'], archived: <String>['old']))['complete'], isTrue);
    expect(service.contextFor(service.result!), contains('本次查阅的旧记忆'));
    expect(service.contextFor(service.result!), contains('雨夜'));
    expect(service.contextFor(service.result!), contains('"version":2'));
    expect(jsonEncode(store.allEntries().map((CharacterMemory m) => m.toJson()).toList()), before);
  });

  test('搜索先隔离角色与可见性，候选片段不能代替读取', () {
    final MemoryStore store = MemoryStore(<CharacterMemory>[
      oldMemory('old'), oldMemory('foreign', owner: 'char:艾琳', text: '雨夜秘密'),
      oldMemory('disabled', allowed: false), oldMemory('hidden', visibility: 'unknown'),
    ]);
    final MemoryRecallService service = serviceFor(store);
    final Map<String, Object?> found = service.handle(<String, Object?>{
      'action': 'search', 'query': '雨夜 钥匙',
    });
    expect((found['candidates'] as List).length, 1);
    expect(jsonEncode(found), isNot(contains('foreign')));
    expect(service.handle(finish(archived: <String>['old']))['error'], isNotNull);
    expect(service.result, isNull);
    service.handle(read('old'));
    service.handle(finish(archived: <String>['old']));
    expect(service.result!.archived.single.id, 'old');
  });

  test('结束前必须整批校验，空集和旧回退保持不同语义', () {
    final MemoryStore store = MemoryStore(<CharacterMemory>[summary, oldMemory('old')]);
    final MemoryRecallService service = serviceFor(store);
    expect(service.handle(finish(active: <String>['summary', 'old']))['error'], isNotNull);
    expect(service.result, isNull);
    service.handle(finish());
    expect(service.result!.activeIds, isEmpty);
    expect(service.legacy(null).activeIds, isNull);
    expect(() => service.legacy(<String>['old']), throwsA(isA<MemoryRecallException>()));
    expect(() => serviceFor(store).validate(service.result!), throwsA(isA<MemoryRecallException>()));
  });

  test('有限分页顺序稳定，猜测的游标和覆盖范围被拒绝', () {
    final MemoryStore store = MemoryStore(<CharacterMemory>[
      oldMemory('c', text: 'KEY Ａ'), oldMemory('a', text: 'key A'), oldMemory('b', text: 'key a'),
    ]);
    final MemoryRecallService service = serviceFor(store,
      limits: const MemoryRecallLimits(candidates: 1));
    final Map<String, Object?> first = service.handle(<String, Object?>{'action': 'search', 'query': 'ＫＥＹ a'});
    expect(((first['candidates'] as List).single as Map)['id'], 'a');
    final Map<String, Object?> second = service.handle(<String, Object?>{
      'action': 'search', 'query': 'ＫＥＹ a', 'cursor': first['cursor'],
    });
    expect(((second['candidates'] as List).single as Map)['id'], 'b');
    expect(service.handle(<String, Object?>{'action': 'search', 'query': 'key', 'cursor': 'forged'})['error'], isNotNull);
    expect(service.handle(<String, Object?>{'action': 'search', 'query': 'key', 'character': 'char:艾琳'})['error'], isNotNull);
  });

  test('Unicode 截断、累计预算与重复读取均受限', () {
    final MemoryStore store = MemoryStore(<CharacterMemory>[
      summary, oldMemory('old', text: List<String>.filled(3000, '😀').join()),
    ]);
    final MemoryRecallService service = serviceFor(store,
      limits: const MemoryRecallLimits(entryRunes: 10, totalRunes: 600, requests: 2));
    final Map entries = (service.handle(read('old'))['entries'] as List).single as Map;
    expect((entries['text'] as String).runes.length, 10);
    expect(entries['truncated'], isTrue);
    service.handle(read('old'));
    expect(service.returnedRunes, lessThanOrEqualTo(600));
    expect(service.handle(read('old'))['error'], contains('预算'));
    service.handle(finish(archived: <String>['old']));
    expect(service.result, isNotNull);
  });

  test('中途 checkpoint 保留结果、预算和版本，篡改或撤销时拒绝恢复', () {
    final MemoryStore store = MemoryStore(<CharacterMemory>[summary, oldMemory('old')]);
    final MemoryRecallService service = serviceFor(store);
    service.beforeModelCall();
    service.handle(read('old'));
    final Map<String, Object?> saved = jsonDecode(jsonEncode(service.toCheckpoint())) as Map<String, dynamic>;
    final MemoryRecallService resumed = serviceFor(store, checkpoint: saved);
    expect(resumed.requests, 1);
    expect(resumed.modelCalls, 1);
    expect(resumed.history, service.history);
    resumed.handle(finish(archived: <String>['old']));
    final MemoryRecallService done = serviceFor(store, checkpoint: resumed.toCheckpoint());
    expect(done.result!.archived.single.version, 2);
    expect(done.contextFor(done.result!), resumed.contextFor(resumed.result!));
  });

  test('归档撤销、版本变化和 checkpoint 篡改不能复用读取凭据', () {
    final MemoryStore store = MemoryStore(<CharacterMemory>[summary, oldMemory('old')]);
    final MemoryRecallService service = serviceFor(store);
    service.handle(read('old'));
    service.handle(finish(archived: <String>['old']));
    final Map<String, Object?> saved = service.toCheckpoint();
    final Map<String, Object?> tampered = jsonDecode(jsonEncode(saved)) as Map<String, dynamic>;
    (((tampered['history'] as List).first as Map)['response'] as Map)['entries'] = <Object?>[];
    expect(() => serviceFor(store, checkpoint: tampered), throwsA(isA<MemoryRecallException>()));
    store.replace(store.byId('old')!.copyWith(archiveRecallable: false, version: 3));
    expect(() => service.contextFor(service.result!), throwsA(isA<MemoryRecallException>()));
    expect(() => serviceFor(store, checkpoint: saved), throwsA(isA<MemoryRecallException>()));
  });

  test('返回查询结果前先持久化，保存失败向上传播', () {
    final MemoryStore store = MemoryStore(<CharacterMemory>[summary, oldMemory('old')]);
    final MemoryRecallService service = serviceFor(store, onChanged: (_) => throw StateError('保存失败'));
    expect(() => service.handle(read('old')), throwsStateError);
    expect(() => service.legacy(null), throwsA(isA<MemoryRecallException>()));
  });

  test('默认候选数、单批读取和不同条目总数均由程序限制', () {
    final List<String> ids = List<String>.generate(12, (int i) => 'old-$i');
    final MemoryStore store = MemoryStore(<CharacterMemory>[
      summary.copyWith(sourceMemories: ids),
      for (final String id in ids) oldMemory(id),
    ]);
    final MemoryRecallService search = serviceFor(store);
    expect((search.handle(<String, Object?>{'action': 'search', 'query': '钥匙'})
        ['candidates'] as List).length, 8);
    final MemoryRecallService service = serviceFor(store);
    expect(service.handle(<String, Object?>{'action': 'read', 'memory_ids': ids.take(4).toList()})
        ['error'], contains('数量'));
    expect(service.handle(<String, Object?>{'action': 'read', 'memory_ids': ids.take(3).toList()})
        ['entries'], hasLength(3));
    expect(service.handle(<String, Object?>{'action': 'read', 'memory_ids': ids.skip(3).take(3).toList()})
        ['entries'], hasLength(3));
    expect(service.handle(read(ids[6]))['error'], contains('条目预算'));
    expect(service.handle(read(ids[0]))['error'], contains('预算'));
    service.handle(finish(archived: ids.take(6).toList()));
    expect(service.result!.archived, hasLength(6));
  });

  test('世界绑定或协议版本不符的 checkpoint 不获得访问权', () {
    final MemoryStore store = MemoryStore(<CharacterMemory>[summary, oldMemory('old')]);
    final Map<String, Object?> saved = serviceFor(store).toCheckpoint();
    expect(() => serviceFor(store, checkpoint: <String, Object?>{...saved, 'world': 'another'}),
      throwsA(isA<MemoryRecallException>()));
    expect(() => serviceFor(store, checkpoint: <String, Object?>{...saved, 'recall_protocol': 99}),
      throwsA(isA<MemoryRecallException>()));
  });
}
