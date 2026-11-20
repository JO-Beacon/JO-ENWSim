import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/data/world_store.dart';
import 'package:joenws/engine/character_memory.dart';
import 'package:joenws/engine/engine_state.dart';
import 'package:joenws/engine/perception.dart';
import 'package:joenws/model/demo.dart';
import 'package:joenws/model/turn.dart';

void main() {
  test('每回合一份状态：追加、读最新、删最新回到上一份', () {
    final WorldStore store = WorldStore.memory();
    final World world = DemoData.worlds.first;
    store.saveWorld(world);

    expect(store.loadLatestState(world.id, 'l1'), isNull);

    final int n0 = store.appendTurnState(world.id, 'l1', '{"events":[0]}');
    final int n1 = store.appendTurnState(world.id, 'l1', '{"events":[1]}');
    expect(n0, 0);
    expect(n1, 1);
    expect(store.turnNumbers(world.id, 'l1'), <int>[0, 1]);
    expect(store.loadLatestState(world.id, 'l1'), '{"events":[1]}');

    expect(store.deleteLatestTurnState(world.id, 'l1'), isTrue);
    expect(store.loadLatestState(world.id, 'l1'), '{"events":[0]}');
    expect(store.turnNumbers(world.id, 'l1'), <int>[0]);

    expect(store.deleteLatestTurnState(world.id, 'l1'), isTrue);
    expect(store.loadLatestState(world.id, 'l1'), isNull);
    expect(store.deleteLatestTurnState(world.id, 'l1'), isFalse);
    store.close();
  });

  test('回退到上一份快照，记忆跟着回去', () {
    final WorldStore store = WorldStore.memory();
    final World world = DemoData.worlds.first;
    store.saveWorld(world);

    const CharacterMemory m0 = CharacterMemory(
      id: 'm0',
      characterId: 'char:人物1',
      text: '我记得一开始在楼梯口。',
    );
    const CharacterMemory m1 = CharacterMemory(
      id: 'm1',
      characterId: 'char:人物1',
      text: '后来有人从后门进来了。',
    );
    const TurnState turn0 = TurnState(
      events: <WorldEvent>[],
      memory: <CharacterMemory>[m0],
    );
    const TurnState turn1 = TurnState(
      events: <WorldEvent>[],
      memory: <CharacterMemory>[m0, m1],
    );

    store.appendTurnState(world.id, 'l1', turn0.encode());
    store.appendTurnState(world.id, 'l1', turn1.encode());
    expect(
      TurnState.decode(store.loadLatestState(world.id, 'l1')!).memory.length,
      2,
    );

    store.deleteLatestTurnState(world.id, 'l1');
    expect(
      TurnState.decode(store.loadLatestState(world.id, 'l1')!).memory.length,
      1,
    );
    store.close();
  });

  test('最后游玩时间取最近一条 turn', () {
    final WorldStore store = WorldStore.memory();
    final World world = DemoData.worlds.first;
    store.saveWorld(world);
    expect(store.lastPlayedAt(world.id), isNull);
    store.appendTurnState(world.id, 'l1', '{"events":[]}');
    expect(store.lastPlayedAt(world.id), isNotNull);
    expect(store.lastPlayedAt(world.id), isNotEmpty);
  });

  test('世界级单份状态：追加、读最新、删最新', () {
    final WorldStore store = WorldStore.memory();
    final World world = DemoData.worlds.first;
    store.saveWorld(world);

    expect(store.loadLatestWorldState(world.id), isNull);
    expect(store.appendWorldTurn(world.id, '{"v":1}'), 0);
    expect(store.appendWorldTurn(world.id, '{"v":2}'), 1);
    expect(store.loadLatestWorldState(world.id), '{"v":2}');

    expect(store.deleteLatestWorldTurn(world.id), isTrue);
    expect(store.loadLatestWorldState(world.id), '{"v":1}');
    expect(store.deleteLatestWorldTurn(world.id), isTrue);
    expect(store.loadLatestWorldState(world.id), isNull);
    expect(store.deleteLatestWorldTurn(world.id), isFalse);
    store.close();
  });

  test('序列状态 / 父子 / 合并目标能落盘读回', () {
    final WorldStore store = WorldStore.memory();
    final World world = DemoData.worlds.first;
    store.saveWorld(world);

    final ParallelPlace first = world.parallelPlaces.first;
    store.saveWorldMeta(
      world.copyWith(
        parallelPlaces: <ParallelPlace>[
          first.copyWith(
            status: 'merged',
            parentId: 'l0',
            mergeInto: 'l2',
          ),
          ...world.parallelPlaces.skip(1),
        ],
      ),
    );

    final ParallelPlace loaded = store.loadWorlds().worlds.first.parallelPlaces.first;
    expect(loaded.status, 'merged');
    expect(loaded.parentId, 'l0');
    expect(loaded.mergeInto, 'l2');
    expect(loaded.isActive, isFalse);
    store.close();
  });

  test('退回时按最近一条引擎步找到所属序列', () {
    final WorldStore store = WorldStore.memory();
    final World world = DemoData.worlds.first;
    store.saveWorld(world);

    store.appendStep(
      world.id,
      'l2',
      const TurnStep(
        kind: 'CH_ACT',
        who: '人物3',
        time: '现在',
        text: '测试',
        judgment: '引擎：测试步',
      ),
    );
    expect(store.deleteLatestEngineStep(world.id), 'l2');
    expect(store.deleteLatestEngineStep(world.id), isNull);
    store.close();
  });

  test('删世界会一起删 turn', () {
    final WorldStore store = WorldStore.memory();
    final World world = DemoData.worlds.first;
    store.saveWorld(world);
    store.appendTurnState(world.id, 'l1', '{"events":[]}');
    expect(store.turnNumbers(world.id, 'l1'), <int>[0]);
    store.deleteWorld(world.id);
    expect(store.turnNumbers(world.id, 'l1'), isEmpty);
    expect(store.loadLatestState(world.id, 'l1'), isNull);
    store.close();
  });

  test('数据统计按 UTF-8 字节算，只算世界级快照', () {
    final WorldStore store = WorldStore.memory();
    final World world = DemoData.worlds.first;
    store.saveWorld(world);

    const String a = '{"events":[]}';
    const String b = '{"events":[],"memory":[{"text":"记得"}]}';
    store.appendWorldTurn(world.id, a);
    // 旧的按地点分份的行不再算进“当前世界状态”。
    store.appendTurnState(world.id, 'l1', '{"old":true}');
    store.appendWorldTurn(world.id, b);

    final DatabaseStats s = store.databaseStats();
    expect(s.worldCount, 1);
    expect(s.turnRows, 2);
    expect(s.turnBytes, utf8.encode(a).length + utf8.encode(b).length);
    expect(s.maxTurnBytes, utf8.encode(b).length);
    expect(s.averageTurnBytes, closeTo(s.turnBytes / 2, 0.001));
    expect(s.worlds.single.turnRows, 2);
    expect(s.stepRows, greaterThan(0)); // 播种的 demo 世界自带画布步
    expect(s.isMemory, isTrue);
    expect(s.fileBytes, 0); // 内存库没有磁盘文件
    store.close();
  });
}
