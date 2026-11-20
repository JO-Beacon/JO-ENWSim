import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/engine/character_memory.dart';
import 'package:joenws/engine/engine_state.dart';
import 'package:joenws/engine/perception.dart';
import 'package:joenws/engine/state_delta.dart';

void main() {
  const CharacterMemory sample = CharacterMemory(
    id: 'm1',
    characterId: 'char:灵梦',
    text: '我看见艾琳摔在泥里，她的腿好像撑不住了。',
    kind: MemoryKind.impression,
    origin: MemoryOrigin.model,
    sourceEvents: <String>['E7'],
    sourceMemories: <String>['m0'],
    attention: '她的腿',
    salience: '很在意',
    state: MemoryState.reinforced,
    revisionOf: 'm0',
    visibility: 'self',
    createdAt: '2026-11-17T01:00:00Z',
    updatedAt: '2026-11-17T02:00:00Z',
  );

  test('CharacterMemory JSON 来回读保留全部字段', () {
    final CharacterMemory back = CharacterMemory.fromJson(sample.toJson());
    expect(back.id, sample.id);
    expect(back.characterId, sample.characterId);
    expect(back.text, sample.text);
    expect(back.kind, MemoryKind.impression);
    expect(back.origin, MemoryOrigin.model);
    expect(back.sourceEvents, <String>['E7']);
    expect(back.sourceMemories, <String>['m0']);
    expect(back.attention, '她的腿');
    expect(back.salience, '很在意');
    expect(back.state, MemoryState.reinforced);
    expect(back.revisionOf, 'm0');
    expect(back.visibility, 'self');
    expect(back.createdAt, '2026-11-17T01:00:00Z');
    expect(back.updatedAt, '2026-11-17T02:00:00Z');
  });

  test('MemoryStore 按角色分组，归档不进 active', () {
    final MemoryStore store = MemoryStore(<CharacterMemory>[
      sample,
      const CharacterMemory(
        id: 'm2',
        characterId: 'char:灵梦',
        text: '雨声很大。',
        kind: MemoryKind.episodic,
        origin: MemoryOrigin.program,
        state: MemoryState.archived,
      ),
      const CharacterMemory(
        id: 'm3',
        characterId: 'char:艾琳',
        text: '有人朝我走过来。',
        kind: MemoryKind.episodic,
        origin: MemoryOrigin.manual,
      ),
    ]);

    expect(store.count('char:灵梦'), 2);
    expect(store.activeForCharacter('char:灵梦').length, 1);
    expect(store.forCharacter('char:艾琳').single.id, 'm3');
    expect(store.byId('m2')!.state, MemoryState.archived);
  });

  test('MemoryStore 拒绝重复 id，replace 改状态', () {
    final MemoryStore store = MemoryStore(<CharacterMemory>[sample]);
    expect(() => store.add(sample), throwsA(isA<ArgumentError>()));

    store.replace(
      sample.copyWith(
        state: MemoryState.archived,
        updatedAt: '2026-11-17T03:00:00Z',
      ),
    );
    expect(store.byId('m1')!.state, MemoryState.archived);
    expect(store.byId('m1')!.updatedAt, '2026-11-17T03:00:00Z');
  });

  test('TurnState 记忆能随状态编解码', () {
    const TurnState state = TurnState(
      events: <WorldEvent>[],
      memory: <CharacterMemory>[sample],
    );
    final TurnState back = TurnState.decode(state.encode());
    expect(back.memory.length, 1);
    expect(back.memory.single.text, sample.text);
    expect(back.memory.single.sourceEvents, <String>['E7']);
  });

  test('旧快照没有 memory 字段时当空', () {
    final TurnState old = TurnState.decode('{"events":[],"knowledge":[]}');
    expect(old.memory, isEmpty);
  });

  test('contextFor 只给角色自己的记忆', () {
    final NarrativeScene scene = NarrativeScene(
      place: '东门内侧',
      names: <String, String>{'char:灵梦': '灵梦', 'char:艾琳': '艾琳'},
      cast: <CharacterSnapshot>[
        CharacterSnapshot(
          id: 'char:灵梦',
          name: '灵梦',
          nearby: true,
          distanceNote: '很近',
        ),
        CharacterSnapshot(id: 'char:艾琳', name: '艾琳', nearby: true),
      ],
    );
    final MemoryStore store = MemoryStore(<CharacterMemory>[
      sample,
      const CharacterMemory(
        id: 'm9',
        characterId: 'char:艾琳',
        text: '别人的秘密。',
      ),
    ]);
    final String ctx = store.contextFor('char:灵梦', scene);
    expect(ctx, contains('我看见艾琳摔在泥里'));
    expect(ctx, contains('当时在意：她的腿'));
    expect(ctx, contains('【距离】很近'));
    expect(ctx, isNot(contains('别人的秘密')));
  });

  test('applyDelta 不会丢记忆', () {
    const TurnState before = TurnState(
      events: <WorldEvent>[],
      memory: <CharacterMemory>[sample],
    );
    final TurnState after = before.applyDelta(const StateDelta());
    expect(after.memory.length, 1);
    expect(after.memory.single.id, 'm1');
  });
}
