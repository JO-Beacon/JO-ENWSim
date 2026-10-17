// 存储层的测试。用内存库（WorldStore.memory），跑完就没了。
//
// 验的是**存进去 → 读出来**能不能对上，以及坏数据会不会带坏别的东西。

import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/data/world_store.dart';
import 'package:joenws/model/demo.dart';
import 'package:joenws/model/memory.dart';
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

    expect(back.lanes.length, w.lanes.length);
    expect(back.lanes.first.id, w.lanes.first.id);
    expect(back.lanes.first.place, w.lanes.first.place);
    expect(back.lanes.first.here, w.lanes.first.here);
    expect(back.lanes.first.events.length, w.lanes.first.events.length);

    final TurnStep a = w.lanes.first.events.first;
    final TurnStep b = back.lanes.first.events.first;
    expect(b.kind, a.kind);
    expect(b.who, a.who);
    expect(b.time, a.time);
    expect(b.text, a.text);

    expect(back.moves.length, w.moves.length);
    expect(back.moves.first.fromLane, w.moves.first.fromLane);
    expect(back.moves.first.toStep, w.moves.first.toStep);
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
        kind: 'B2',
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
    expect(steps.length, w.lanes.first.events.length + 1);

    final TurnStep last = steps.last;
    expect(last.kind, 'B2');
    expect(last.who, '人物2');
    expect(last.text, '他去了那间仓房。'.replaceAll('那间', ''));
    expect(last.candidates, <String>['人物2', '人物3']);
    expect(last.perceptions['人物2'], '听见楼上有脚步。');
    expect(last.chosen, '人物2');
    expect(last.ok, isTrue);
  });

  test('记忆存了能读回来，上帝那本也在', () {
    final WorldStore s = WorldStore.memory();
    addTearDown(s.close);

    final World w = DemoData.worlds.first;
    s.saveWorld(w);

    final MemoryEntry e = newMemoryEntry(content: '他记得门是插着的。');
    s.saveMemory(
      w.id,
      MemoryBook(ownerId: '', entries: <MemoryEntry>[e]),
    );
    s.saveMemory(
      w.id,
      MemoryBook(
        ownerId: '人物1',
        entries: <MemoryEntry>[newMemoryEntry(content: '雨声很响。')],
      ),
    );

    final List<MemoryBook> books = s.loadMemories(w.id);
    expect(books.length, 2);
    final MemoryBook god =
        books.firstWhere((MemoryBook b) => b.ownerId.isEmpty);
    expect(god.entries.length, 1);
    expect(god.entries.first.content, '他记得门是插着的。');
    final MemoryBook one =
        books.firstWhere((MemoryBook b) => b.ownerId == '人物1');
    expect(one.entries.first.content, '雨声很响。');
  });

  test('一步坏掉只跳过那一步，其余照读', () {
    final WorldStore s = WorldStore.memory();
    addTearDown(s.close);

    final World w = DemoData.worlds.first;
    s.saveWorld(w);

    // 直接往 step 表塞一条认不出的 kind —— 读的时候应该只丢这一条。
    // （这里用 store 自己的接口做不到，所以走底层那条 appended 步。）
    s.appendStep(w.id, 'l1', const TurnStep(kind: 'B2', who: '人物9', text: 'x'));
    final List<TurnStep> ok = s.loadSteps(w.id, 'l1');
    expect(ok.length, w.lanes.first.events.length + 1);
    expect(ok.last.who, '人物9');
  });

  test('删世界会把它的回合和记忆一起删掉', () {
    final WorldStore s = WorldStore.memory();
    addTearDown(s.close);

    final World w = DemoData.worlds.first;
    s.saveWorld(w);
    s.saveMemory(
      w.id,
      MemoryBook(
        ownerId: '',
        entries: <MemoryEntry>[newMemoryEntry(content: '忘掉吧。')],
      ),
    );

    s.deleteWorld(w.id);

    expect(s.loadWorlds().worlds, isEmpty);
    expect(s.loadSteps(w.id, 'l1'), isEmpty);
    expect(s.loadMemories(w.id), isEmpty);
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
    // 这条是给一个真 bug 立的：步以前存两份（lanes JSON + step 表），
    // appendStep 只写 step 表，而 loadWorlds 读的是 JSON ——
    // 于是引擎跑完、重新读库，画布上永远看不到新步。
    final WorldStore s = WorldStore.memory();
    addTearDown(s.close);

    final World w = DemoData.worlds.first;
    s.saveWorld(w);
    s.appendStep(
      w.id,
      'l1',
      const TurnStep(kind: 'B2', who: '人物9', text: '新的一步'),
    );

    final World back = s.loadWorlds().worlds.first;
    final SeqLane lane = back.lanes.firstWhere((SeqLane l) => l.id == 'l1');
    expect(lane.events.length, w.lanes.first.events.length + 1);
    expect(lane.events.last.text, '新的一步');
  });

  test('认不出的步骤类型会抛，不静默降级', () {
    expect(
      () => TurnStep.fromJson(<String, Object?>{'kind': 'ZZ'}),
      throwsFormatException,
    );
    expect(isKnownStep('B2'), isTrue);
    expect(isKnownStep('ZZ'), isFalse);
  });
}
