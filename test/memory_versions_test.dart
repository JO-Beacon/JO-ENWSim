import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/data/world_store.dart';
import 'package:joenws/engine/character_memory.dart';
import 'package:joenws/engine/engine_state.dart';
import 'package:joenws/engine/memory_recall.dart';
import 'package:joenws/engine/perception.dart';
import 'package:joenws/engine/turn_session.dart';
import 'package:joenws/model/demo.dart';
import 'package:joenws/model/turn.dart';

void main() {
  test('归档召回权限与 session 进度入库，停用追加版本且旧结果不能恢复', () {
    final WorldStore store = WorldStore.memory()..seedDemo();
    addTearDown(store.close);
    final World world = store.loadWorlds().worlds.first;
    const CharacterMemory old = CharacterMemory(
      id: 'archived', characterId: 'char:灵梦', text: '原文。',
      state: MemoryState.archived, archiveRecallable: true,
    );
    const CharacterMemory proxy = CharacterMemory(
      id: 'proxy', characterId: 'char:灵梦', text: '摘要。',
      sourceMemories: <String>['archived'], kind: MemoryKind.summary,
    );
    store.saveWorldMemory(world.id, <CharacterMemory>[old, proxy]);
    List<CharacterMemory> current = store.loadWorldMemory(world.id);
    final MemoryRecallService service = MemoryRecallService(
      worldId: world.id, characterId: 'char:灵梦', memory: current,
      currentMemory: () => store.loadWorldMemory(world.id),
      onChanged: (Map<String, Object?> data) => store.saveTurnSession(
        TurnSession(worldId: world.id, parallelPlaceId: world.parallelPlaces.first.id,
          rawInput: '', journal: TurnJournal())
          .withCheckpoint('CH_MEMORY_RECALL:灵梦', data)),
    );
    service.beforeModelCall();
    service.handle(<String, Object?>{'action': 'read', 'memory_ids': <String>['archived']});
    final Map<String, Object?> saved = store.loadTurnSession(world.id)!
        .checkpoints['CH_MEMORY_RECALL:灵梦']!.data;
    final MemoryRecallService restored = MemoryRecallService(
      worldId: world.id, characterId: 'char:灵梦', memory: current,
      currentMemory: () => store.loadWorldMemory(world.id), checkpoint: saved,
    );
    expect(restored.requests, 1);
    expect(restored.history, service.history);
    store.saveWorldMemory(world.id, <CharacterMemory>[
      for (final CharacterMemory m in current)
        m.id == old.id ? m.copyWith(archiveRecallable: false) : m,
    ]);
    final List<CharacterMemory> versions = store.loadMemoryVersions(world.id, old.id);
    expect(versions, hasLength(2));
    expect(versions.first.archiveRecallable, isFalse);
    expect(versions.last.archiveRecallable, isTrue);
    current = store.loadWorldMemory(world.id);
    expect(() => MemoryRecallService(worldId: world.id, characterId: 'char:灵梦',
      memory: current, currentMemory: () => current, checkpoint: saved),
      throwsA(isA<MemoryRecallException>()));
  });

  test('saveWorldMemory 追加版本，loadMemoryVersions 最新在前', () {
    final WorldStore store = WorldStore.memory()..seedDemo();
    addTearDown(store.close);
    final World world = store.loadWorlds().worlds.first;
    final String parallelPlaceId = world.parallelPlaces.first.id;
    const CharacterMemory m = CharacterMemory(
      id: 'cm-version',
      characterId: 'char:灵梦',
      text: '第一版。',
      sourceEvents: <String>['evt-1'],
    );
    final TurnState state = const TurnState(
      events: <WorldEvent>[
        WorldEvent(
          id: 'E1',
          uid: 'evt-1',
          kind: WorldEventKind.action,
          content: '推门。',
          actor: 'char:灵梦',
          delivery: Delivery(
            channel: DeliveryChannel.other,
            form: 'other',
            audience: Audience.scene,
          ),
        ),
      ],
      memory: <CharacterMemory>[m],
    );
    store.commitTurn(
      worldId: world.id,
      stateJson: state.encodeCheckpoint(),
      parallelPlaceId: parallelPlaceId,
      mainStep: const TurnStep(kind: 'CH_ACT', text: '门开了。'),
      events: state.events,
      memory: state.memory,
      sessionId: 's1',
      world: world,
    );

    store.saveWorldMemory(world.id, <CharacterMemory>[
      m.copyWith(text: '第二版。'),
    ]);
    final List<CharacterMemory> versions =
        store.loadMemoryVersions(world.id, 'cm-version');
    expect(versions, hasLength(2));
    expect(versions.first.text, '第二版。');
    expect(versions.last.text, '第一版。');
    expect(versions.first.version, greaterThan(versions.last.version));

    // 原样再保存一次，不应凭空多一个版本。
    store.saveWorldMemory(world.id, <CharacterMemory>[
      m.copyWith(text: '第二版。'),
    ]);
    expect(
      store.loadMemoryVersions(world.id, 'cm-version'),
      hasLength(2),
    );
  });
}
