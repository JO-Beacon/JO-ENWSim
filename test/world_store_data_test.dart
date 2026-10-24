// 数据层：记忆落盘、世界元信息不改步、每个角色自己的配置、索引。
//
// 这几条对应三个真问题：
//   1. 记忆以前根本没进库（只有 load/save 方法，没人调）；
//   2. 改个世界名会把整张 step 表删了重插；
//   3. 角色自己的模型 / 选择只在内存里，重启归零。

import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/data/world_store.dart';
import 'package:joenws/model/char_choices.dart';
import 'package:joenws/model/demo.dart';
import 'package:joenws/model/memory.dart';
import 'package:joenws/model/model_plan.dart';
import 'package:joenws/model/turn.dart';

MemoryBook book(String owner, List<String> contents) => MemoryBook(
  ownerId: owner,
  entries: <MemoryEntry>[
    for (final String c in contents) newMemoryEntry(content: c),
  ],
);

TurnStep step(String text) => TurnStep(
  kind: 'B2',
  who: '人物1',
  time: '雨夜',
  text: text,
  candidates: const <String>['人物1'],
  perceptions: const <String, String>{'人物1': '听见楼上有人'},
  chosen: '人物1',
);

World worldWith(String id, {String name = '旧宅'}) => World(
  id: id,
  name: name,
  note: '三个地点',
  setting: '民国，南方小城',
  opening: '雨落在瓦上。',
  playerName: '人物1',
  characters: const <CharCard>[
    CharCard(name: '人物1', persona: '守着楼梯口的人'),
    CharCard(name: '人物2', persona: '从后门进来'),
  ],
  lanes: const <SeqLane>[
    SeqLane(id: 'l1', place: '正厅', here: true, events: <TurnStep>[]),
    SeqLane(id: 'l2', place: '仓房', here: false, events: <TurnStep>[]),
  ],
  moves: const <MoveLink>[],
);

void main() {
  test('一整份记忆：存了能读回来，删掉的主人也会删掉', () {
    final WorldStore s = WorldStore.memory();
    addTearDown(s.close);
    final World w = worldWith('w1');
    s.saveWorld(w);

    s.saveMemories(w.id, <String, MemoryBook>{
      '': book('', <String>['门是插着的。']),
      '人物1': book('人物1', <String>['雨声很响。']),
    });
    List<MemoryBook> back = s.loadMemories(w.id);
    expect(back.length, 2);
    expect(
      back.firstWhere((MemoryBook b) => b.ownerId == '').entries.length,
      1,
    );

    // 第二次只交回来上帝那一本：人物1 那本应当被删掉。
    s.saveMemories(w.id, <String, MemoryBook>{
      '': book('', <String>['门是插着的。', '楼梯上有脚步。']),
    });
    back = s.loadMemories(w.id);
    expect(back.length, 1);
    expect(back.first.ownerId, '');
    expect(back.first.entries.length, 2, reason: '交回来的整本要原样写进去');
  });

  test('改世界名字（saveWorldMeta）不会动已有的步', () {
    final WorldStore s = WorldStore.memory();
    addTearDown(s.close);
    final World w = worldWith('w1');
    s.saveWorld(w);
    s.appendStep('w1', 'l1', step('第一步'));
    s.appendStep('w1', 'l1', step('第二步'));
    expect(s.loadSteps('w1', 'l1').length, 2);

    // 只改名字：拿一份**不含步**的世界（就像编辑弹窗交回来的那样）。
    s.saveWorldMeta(worldWith('w1', name: '旧宅 · 改名了'));

    final World back = s.loadWorlds().worlds.first;
    expect(back.name, '旧宅 · 改名了');
    expect(
      s.loadSteps('w1', 'l1').length,
      2,
      reason: 'saveWorldMeta 不该碰 step 表',
    );
  });

  test('saveWorld 是对账：内存里删掉的步，库里也会删；别的列不动', () {
    final WorldStore s = WorldStore.memory();
    addTearDown(s.close);
    final World w = worldWith('w1');
    s.saveWorld(w);
    s.appendStep('w1', 'l1', step('正厅一'));
    s.appendStep('w1', 'l1', step('正厅二'));
    s.appendStep('w1', 'l2', step('仓房一'));

    // 内存里把 l1 的最后一步删掉，再整体 saveWorld。
    final WorldsLoad cur = s.loadWorlds();
    final World loaded = cur.worlds.first;
    final SeqLane l1 = loaded.lanes.firstWhere((SeqLane l) => l.id == 'l1');
    final SeqLane l2 = loaded.lanes.firstWhere((SeqLane l) => l.id == 'l2');
    final World cut = World(
      id: loaded.id,
      name: loaded.name,
      note: loaded.note,
      setting: loaded.setting,
      opening: loaded.opening,
      playerName: loaded.playerName,
      characters: loaded.characters,
      lanes: <SeqLane>[
        SeqLane(
          id: l1.id,
          place: l1.place,
          here: l1.here,
          events: <TurnStep>[l1.events.first],
        ),
        l2,
      ],
      moves: loaded.moves,
    );
    s.saveWorld(cut);

    expect(s.loadSteps('w1', 'l1').length, 1);
    expect(s.loadSteps('w1', 'l1').first.text, '正厅一');
    expect(s.loadSteps('w1', 'l2').length, 1, reason: '别的列不该被动到');
  });

  test('每个角色自己的模型：存了能读回来，清空后不再读出来', () {
    final WorldStore s = WorldStore.memory();
    addTearDown(s.close);
    s.saveWorld(worldWith('w1'));

    s.saveCharPlan(
      'w1',
      '人物1',
      const ModelPlan(byStep: <String, String>{'B2': 'p1\u0000deepseek-chat'}),
    );
    var cfg = s.loadCharCfg('w1');
    expect(cfg.plans['人物1']?.stepKey('B2'), 'p1\u0000deepseek-chat');

    // 清空：不设就跟随世界默认。
    s.saveCharPlan('w1', '人物1', const ModelPlan());
    cfg = s.loadCharCfg('w1');
    expect(cfg.plans.containsKey('人物1'), isFalse);
  });

  test('每个角色自己的选择：整份写、没了就清空', () {
    final WorldStore s = WorldStore.memory();
    addTearDown(s.close);
    s.saveWorld(worldWith('w1'));

    s.saveCharChoices('w1', <String, CharChoices>{
      '人物1': const CharChoices(temperature: '0.7', stream: true),
      '人物2': const CharChoices(maxOutput: '512'),
    });
    var cfg = s.loadCharCfg('w1');
    expect(cfg.choices['人物1']?.temperature, '0.7');
    expect(cfg.choices['人物1']?.stream, isTrue);
    expect(cfg.choices['人物2']?.maxOutput, '512');

    // 第二份只剩人物2：人物1 的选择应当被清掉。
    s.saveCharChoices('w1', <String, CharChoices>{
      '人物2': const CharChoices(maxOutput: '512'),
    });
    cfg = s.loadCharCfg('w1');
    expect(cfg.choices.containsKey('人物1'), isFalse);
    expect(cfg.choices['人物2']?.maxOutput, '512');
  });

  test('角色配置和记忆跟着世界一起删', () {
    final WorldStore s = WorldStore.memory();
    addTearDown(s.close);
    s.saveWorld(worldWith('w1'));
    s.saveMemories('w1', <String, MemoryBook>{
      '': book('', <String>['一']),
    });
    s.saveCharPlan('w1', '人物1', const ModelPlan(defaultRef: 'p1\u0000m'));

    s.deleteWorld('w1');
    expect(s.loadMemories('w1'), isEmpty);
    expect(s.loadCharCfg('w1').plans, isEmpty);
  });

  test('查表用的索引在（v2 迁移建的）', () {
    final WorldStore s = WorldStore.memory();
    addTearDown(s.close);
    s.saveWorld(worldWith('w1'));

    final List<String> idx = s.indexNames();
    expect(idx, contains('idx_step_lane'));
    expect(idx, contains('idx_memory_owner'));
  });
}
