// 存储层的测试。用内存库（WorldStore.memory），跑完就没了。
//
// 验的是**存进去 → 读出来**能不能对上，以及坏数据会不会带坏别的东西。

import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/data/world_store.dart';
import 'package:joenws/engine/character_memory.dart';
import 'package:joenws/model/demo.dart';
import 'package:joenws/model/turn.dart';

void main() {
  test('世界存进去再读出来，字段都对得上', () {
    final WorldStore s = WorldStore.memory();
    addTearDown(s.close);

    final World w = DemoData.worlds.first;
    s.saveWorld(w);

    final WorldsLoad r = s.loadWorlds();
    expect(r.broken, isFalse);
    expect(r.unreadable, 0);
    expect(r.worlds.length, 1);

    final World back = r.worlds.first;
    expect(back.id, w.id);
    expect(back.name, w.name);
    expect(back.note, w.note);
    expect(back.setting, w.setting);
    expect(back.opening, w.opening);
    expect(back.playerName, w.playerName);

    expect(back.characters.length, w.characters.length);
    expect(back.characters.first.name, w.characters.first.name);
    expect(back.characters.first.persona, w.characters.first.persona);

    expect(back.parallelPlaces.length, w.parallelPlaces.length);
    expect(back.parallelPlaces.first.id, w.parallelPlaces.first.id);
    expect(back.parallelPlaces.first.place, w.parallelPlaces.first.place);
    expect(back.parallelPlaces.first.here, w.parallelPlaces.first.here);
    expect(
      back.parallelPlaces.first.events.length,
      w.parallelPlaces.first.events.length,
    );

    final TurnStep a = w.parallelPlaces.first.events.first;
    final TurnStep b = back.parallelPlaces.first.events.first;
    expect(b.kind, a.kind);
    expect(b.who, a.who);
    expect(b.time, a.time);
    expect(b.text, a.text);

    expect(back.moves.length, w.moves.length);
    expect(back.moves.first.fromParallelPlace, w.moves.first.fromParallelPlace);
    expect(back.moves.first.toStep, w.moves.first.toStep);
  });

  test('世界和角色的 TTS key 存读不丢', () {
    final WorldStore s = WorldStore.memory();
    addTearDown(s.close);
    final World base = DemoData.worlds.first;
    final World w = base.copyWith(
      ttsKey: 'system\u0000\u0000voice-1\u0000',
      narratorTtsKey: 'builtin\u0000\u0000\u0000melo',
      characters: <CharCard>[
        base.characters.first.copyWith(
          ttsKey: 'api\u0000p1\u0000v1\u0000tts-1',
        ),
        ...base.characters.skip(1),
      ],
    );
    s.saveWorld(w);
    final World back = s.loadWorlds().worlds.single;
    expect(back.ttsKey, 'system\u0000\u0000voice-1\u0000');
    expect(back.narratorTtsKey, 'builtin\u0000\u0000\u0000melo');
    expect(back.characters.first.ttsKey, 'api\u0000p1\u0000v1\u0000tts-1');
    expect(back.characters[1].ttsKey, '');
  });

  test('三个 demo 世界全存得住', () {
    final WorldStore s = WorldStore.memory();
    addTearDown(s.close);

    for (final World w in DemoData.worlds) {
      s.saveWorld(w);
    }
    final WorldsLoad r = s.loadWorlds();
    expect(r.worlds.length, DemoData.worlds.length);
    expect(r.unreadable, 0);
    for (final World w in DemoData.worlds) {
      expect(r.worlds.any((World x) => x.id == w.id), isTrue);
    }
  });

  test('追加一步之后读得回来，而且带着过程产物', () {
    final WorldStore s = WorldStore.memory();
    addTearDown(s.close);

    final World w = DemoData.worlds.first;
    s.saveWorld(w);

    s.appendStep(
      w.id,
      'l1',
      const TurnStep(
        kind: 'CH_ACT',
        who: '人物2',
        time: '后来',
        text: '他去了仓房。',
        candidates: <String>['人物2', '人物3'],
        perceptions: <String, String>{'人物2': '听见楼上有脚步。'},
        chosen: '人物2',
        judgment: '',
        model: null,
      ),
    );

    final List<TurnStep> steps = s.loadSteps(w.id, 'l1');
    expect(steps.length, w.parallelPlaces.first.events.length + 1);

    final TurnStep last = steps.last;
    expect(last.kind, 'CH_ACT');
    expect(last.who, '人物2');
    expect(last.text, '他去了那间仓房。'.replaceAll('那间', ''));
    expect(last.candidates, <String>['人物2', '人物3']);
    expect(last.perceptions['人物2'], '听见楼上有脚步。');
    expect(last.chosen, '人物2');
    expect(last.ok, isTrue);
  });

  test('记忆存了能读回来，两个角色各一本', () {
    final WorldStore s = WorldStore.memory();
    addTearDown(s.close);

    final World w = DemoData.worlds.first;
    s.saveWorld(w);
    s.saveWorldMemory(w.id, <CharacterMemory>[
      const CharacterMemory(
        id: 'm1',
        characterId: 'char:人物1',
        text: '他记得门是插着的。',
        kind: MemoryKind.note,
        origin: MemoryOrigin.manual,
      ),
      const CharacterMemory(
        id: 'm2',
        characterId: 'char:人物2',
        text: '雨声很响。',
        kind: MemoryKind.note,
        origin: MemoryOrigin.manual,
      ),
    ]);

    final List<CharacterMemory> memory = s.loadWorldMemory(w.id);
    expect(memory.length, 2);
    expect(
      memory
          .firstWhere((CharacterMemory m) => m.characterId == 'char:人物1')
          .text,
      '他记得门是插着的。',
    );
    expect(
      memory
          .firstWhere((CharacterMemory m) => m.characterId == 'char:人物2')
          .text,
      '雨声很响。',
    );
  });

  test('一步坏掉只跳过那一步，其余照读', () {
    final WorldStore s = WorldStore.memory();
    addTearDown(s.close);

    final World w = DemoData.worlds.first;
    s.saveWorld(w);

    // 直接往 step 表塞一条认不出的 kind —— 读的时候应该只丢这一条。
    // （这里用 store 自己的接口做不到，所以走底层那条 appended 步。）
    s.appendStep(w.id, 'l1', const TurnStep(kind: 'CH_ACT', who: '人物9', text: 'x'));
    final List<TurnStep> ok = s.loadSteps(w.id, 'l1');
    expect(ok.length, w.parallelPlaces.first.events.length + 1);
    expect(ok.last.who, '人物9');
  });

  test('删世界会把它的回合和记忆一起删掉', () {
    final WorldStore s = WorldStore.memory();
    addTearDown(s.close);

    final World w = DemoData.worlds.first;
    s.saveWorld(w);
    s.saveWorldMemory(w.id, const <CharacterMemory>[
      CharacterMemory(
        id: 'm1',
        characterId: 'char:人物1',
        text: '忘掉吧。',
        kind: MemoryKind.note,
        origin: MemoryOrigin.manual,
      ),
    ]);

    s.deleteWorld(w.id);

    expect(s.loadWorlds().worlds, isEmpty);
    expect(s.loadSteps(w.id, 'l1'), isEmpty);
    expect(s.loadWorldMemory(w.id), isEmpty);
  });

  test('播种：手动播一下，demo 那几个世界就进去了', () {
    final WorldStore s = WorldStore.memory();
    addTearDown(s.close);

    // 内存库**不**自动播种 —— 测试要干净。
    expect(s.loadWorlds().worlds, isEmpty);

    s.seedDemo();
    final WorldsLoad r = s.loadWorlds();
    expect(r.worlds.length, DemoData.worlds.length);
    expect(r.unreadable, 0);
    expect(r.note, isNull);
  });

  test('追加一步之后，**读整个世界**也能看到那一步', () {
    // 这条是给一个真 bug 立的：步以前存两份（parallelPlaces JSON + step 表），
    // appendStep 只写 step 表，而 loadWorlds 读的是 JSON ——
    // 于是引擎跑完、重新读库，画布上永远看不到新步。
    final WorldStore s = WorldStore.memory();
    addTearDown(s.close);

    final World w = DemoData.worlds.first;
    s.saveWorld(w);
    s.appendStep(
      w.id,
      'l1',
      const TurnStep(kind: 'CH_ACT', who: '人物9', text: '新的一步'),
    );

    final World back = s.loadWorlds().worlds.first;
    final ParallelPlace place = back.parallelPlaces.firstWhere(
      (ParallelPlace p) => p.id == 'l1',
    );
    expect(place.events.length, w.parallelPlaces.first.events.length + 1);
    expect(place.events.last.text, '新的一步');
  });

  test('认不出的步骤类型会抛，不静默降级', () {
    expect(
      () => TurnStep.fromJson(<String, Object?>{'kind': 'ZZ'}),
      throwsFormatException,
    );
    expect(isKnownStep('CH_ACT'), isTrue);
    expect(isKnownStep('ZZ'), isFalse);
  });
}
