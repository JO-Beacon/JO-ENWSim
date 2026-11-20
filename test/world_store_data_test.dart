// 数据层：记忆落盘、世界元信息不改步、每个角色自己的配置、索引。
//
// 这几条对应三个真问题：
//   1. 记忆以前根本没进库（只有 load/save 方法，没人调）；
//   2. 改个世界名会把整张 step 表删了重插；
//   3. 角色自己的模型 / 选择只在内存里，重启归零。

import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/data/world_store.dart';
import 'package:joenws/engine/character_memory.dart';
import 'package:joenws/engine/turn_session.dart';
import 'package:joenws/model/char_choices.dart';
import 'package:joenws/model/demo.dart';
import 'package:joenws/model/model_plan.dart';
import 'package:joenws/model/turn.dart';
import 'package:joenws/model/world_search.dart';

CharacterMemory note(String id, String name, String text) => CharacterMemory(
  id: id,
  characterId: 'char:$name',
  text: text,
  kind: MemoryKind.note,
  origin: MemoryOrigin.manual,
);

TurnStep step(String text) => TurnStep(
  kind: 'CH_ACT',
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
  parallelPlaces: const <ParallelPlace>[
    ParallelPlace(id: 'l1', place: '正厅', here: true, events: <TurnStep>[]),
    ParallelPlace(id: 'l2', place: '仓房', here: false, events: <TurnStep>[]),
  ],
  moves: const <MoveLink>[],
);

void main() {
  test('搜索账本能存能读', () {
    final WorldStore store = WorldStore.memory();
    final World world = DemoData.worlds.first;
    store.saveWorld(world);
    store.saveSearchLog(
      worldId: world.id,
      source: 'tavily',
      query: '沈宅 落款',
      ok: true,
      message: '2 条结果',
      hits: <Map<String, Object?>>[
        <String, Object?>{'title': '沈宅档案', 'url': 'https://example.com'},
      ],
    );
    final List<Map<String, Object?>> logs = store.loadSearchLogs(world.id);
    expect(logs, hasLength(1));
    expect(logs.single['query'], '沈宅 落款');
    expect(logs.single['ok'], isTrue);
  });

  test('世界搜索源能落盘读回', () {
    final WorldStore store = WorldStore.memory();
    final World world = DemoData.worlds.first.copyWith(
      searchSource: WorldSearchSource.tavily,
    );
    store.saveWorld(world);
    final WorldsLoad loaded = store.loadWorlds();
    expect(loaded.worlds.single.searchSource, WorldSearchSource.tavily);
  });

  test('未完成回合的恢复日志能存读删', () {
    final WorldStore s = WorldStore.memory();
    final TurnSession session = TurnSession(
      worldId: 'w1',
      parallelPlaceId: 'l1',
      rawInput: '我推门进去。',
      stage: 'GM_ELIGIBILITY',
      checkpoints: <String, TurnCheckpoint>{
        'GM_ELIGIBILITY': TurnCheckpoint(
          stage: 'GM_ELIGIBILITY',
          data: <String, Object?>{
            'eligible': <String>['灵梦'],
          },
        ),
      },
      journal: TurnJournal(
        responses: <String, String>{'GM_OPEN_PLACE#1': '{"places":[]}'},
        answers: <String, String>{'GM_OPEN_PLACE#1': '不开'},
      ),
      createdAt: '2026-11-17T12:00:00+08:00',
    );
    s.saveTurnSession(session);
    final TurnSession? loaded = s.loadTurnSession('w1');
    expect(loaded, isNotNull);
    expect(loaded!.rawInput, '我推门进去。');
    expect(loaded.stage, 'GM_ELIGIBILITY');
    expect(loaded.checkpoints['GM_ELIGIBILITY']?.data['eligible'], <String>['灵梦']);
    expect(loaded.lastCheckpointStage, 'GM_ELIGIBILITY');
    expect(loaded.journal.responses['GM_OPEN_PLACE#1'], '{"places":[]}');
    expect(loaded.journal.answers['GM_OPEN_PLACE#1'], '不开');
    s.clearTurnSession('w1');
    expect(s.loadTurnSession('w1'), isNull);
  });

  test('一整份记忆：存了能读回来，覆盖后旧的消失', () {
    final WorldStore s = WorldStore.memory();
    addTearDown(s.close);
    final World w = worldWith('w1');
    s.saveWorld(w);

    s.saveWorldMemory(w.id, <CharacterMemory>[
      note('m1', '人物1', '门是插着的。'),
      note('m2', '人物2', '雨声很响。'),
    ]);
    List<CharacterMemory> back = s.loadWorldMemory(w.id);
    expect(back.length, 2);
    expect(
      back.firstWhere((CharacterMemory m) => m.characterId == 'char:人物1').text,
      '门是插着的。',
    );

    // 第二次交回来的是完整一份：只留人物1的两条，人物2那条不再存在。
    s.saveWorldMemory(w.id, <CharacterMemory>[
      note('m1', '人物1', '门是插着的。'),
      note('m3', '人物1', '楼梯上有脚步。'),
    ]);
    back = s.loadWorldMemory(w.id);
    expect(back.length, 2);
    expect(
      back.every((CharacterMemory m) => m.characterId == 'char:人物1'),
      isTrue,
    );
    expect(back.last.text, '楼梯上有脚步。');
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
    final ParallelPlace l1 = loaded.parallelPlaces.firstWhere((ParallelPlace l) => l.id == 'l1');
    final ParallelPlace l2 = loaded.parallelPlaces.firstWhere((ParallelPlace l) => l.id == 'l2');
    final World cut = World(
      id: loaded.id,
      name: loaded.name,
      note: loaded.note,
      setting: loaded.setting,
      opening: loaded.opening,
      playerName: loaded.playerName,
      characters: loaded.characters,
      parallelPlaces: <ParallelPlace>[
        ParallelPlace(
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
      const ModelPlan(byStep: <String, String>{'CH_ACT': 'p1\u0000deepseek-chat'}),
    );
    var cfg = s.loadCharCfg('w1');
    expect(cfg.plans['人物1']?.stepKey('CH_ACT'), 'p1\u0000deepseek-chat');

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
    s.saveWorldMemory('w1', <CharacterMemory>[
      note('m1', '人物1', '一'),
    ]);
    s.saveCharPlan('w1', '人物1', const ModelPlan(defaultRef: 'p1\u0000m'));

    s.deleteWorld('w1');
    expect(s.loadWorldMemory('w1'), isEmpty);
    expect(s.loadCharCfg('w1').plans, isEmpty);
  });

  test('查表用的索引在', () {
    final WorldStore s = WorldStore.memory();
    addTearDown(s.close);
    s.saveWorld(worldWith('w1'));

    final List<String> idx = s.indexNames();
    expect(idx, contains('idx_step_lane'));
  });
}
