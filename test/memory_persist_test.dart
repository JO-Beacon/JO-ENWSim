// 记忆接线：写进弹窗的东西要真进库，重开还在。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/data/world_store.dart';
import 'package:joenws/engine/character_memory.dart';
import 'package:joenws/main.dart';
import 'package:joenws/theme/settings_store.dart';
import 'package:joenws/theme/tokens.dart';
import 'package:joenws/ui/icons.dart';
import 'package:joenws/ui/memory_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> boot(WidgetTester t, WorldStore worldStore) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final SettingsStore store = await SettingsStore.open();
  await t.pumpWidget(
    JoEnwsApp(
      store: store,
      worldStore: worldStore,
      initialWorlds: worldStore.loadWorlds().worlds,
      initial: const JoSettings(),
    ),
  );
  await t.pumpAndSettle();
}

Future<void> openMemoryTab(WidgetTester t) async {
  await t.tap(find.byIcon(JoIcons.pencil).last);
  await t.pumpAndSettle();
  await t.tap(find.text('记忆'));
  await t.pumpAndSettle();
}

CharacterMemory note(String id, String name, String text) {
  return CharacterMemory(
    id: id,
    characterId: 'char:$name',
    text: text,
    kind: MemoryKind.note,
    origin: MemoryOrigin.manual,
    createdAt: '2026-11-17T01:00:00Z',
    updatedAt: '2026-11-17T01:00:00Z',
  );
}

void main() {
  testWidgets('用户停用记忆后可逐条开启召回，保存并重开仍保持权限', (WidgetTester t) async {
    final WorldStore worldStore = WorldStore.memory()..seedDemo();
    addTearDown(worldStore.close);
    final String id = worldStore.loadWorlds().worlds.first.id;
    worldStore.saveWorldMemory(id, <CharacterMemory>[
      note('archive-toggle', '人物1', '楼梯上有脚步。'),
    ]);
    await boot(t, worldStore);
    await openMemoryTab(t);
    await t.tap(find.descendant(of: find.byType(MemoryPanel), matching: find.text('停用')));
    await t.pumpAndSettle();
    expect(find.textContaining('已停用，不参与模型召回'), findsOneWidget);
    await t.tap(find.text('保存'));
    await t.pumpAndSettle();
    expect(worldStore.loadWorldMemory(id).single.state, MemoryState.archived);
    expect(worldStore.loadWorldMemory(id).single.archiveRecallable, isFalse);
    await openMemoryTab(t);
    await t.tap(find.text('允许召回'));
    await t.pumpAndSettle();
    await t.tap(find.text('保存'));
    await t.pumpAndSettle();
    expect(worldStore.loadWorldMemory(id).single.archiveRecallable, isTrue);
    await openMemoryTab(t);
    expect(find.textContaining('可按需召回'), findsOneWidget);
    await t.tap(find.descendant(of: find.byType(MemoryPanel), matching: find.text('停用')));
    await t.pumpAndSettle();
    await t.tap(find.text('保存'));
    await t.pumpAndSettle();
    expect(worldStore.loadWorldMemory(id).single.archiveRecallable, isFalse);
    expect(worldStore.loadMemoryVersions(id, 'archive-toggle'), hasLength(4));
  });

  test('库里的记忆能被读出来（每个角色各一本）', () {
    final WorldStore s = WorldStore.memory()..seedDemo();
    addTearDown(s.close);
    final String id = s.loadWorlds().worlds.first.id;

    s.saveWorldMemory(id, <CharacterMemory>[
      note('m1', '人物1', '门是插着的。'),
      note('m2', '人物2', '雨声很响。'),
    ]);

    final List<CharacterMemory> back = s.loadWorldMemory(id);
    expect(back.length, 2);
    expect(
      back.firstWhere((CharacterMemory m) => m.characterId == 'char:人物1').text,
      '门是插着的。',
    );
  });

  testWidgets('在记忆面板里加一条，保存后真进了库', (WidgetTester t) async {
    final WorldStore worldStore = WorldStore.memory()..seedDemo();
    addTearDown(worldStore.close);
    final String id = worldStore.loadWorlds().worlds.first.id;

    await boot(t, worldStore);
    await openMemoryTab(t);

    await t.tap(find.textContaining('添加一条'));
    await t.pumpAndSettle();
    // 弹窗里其它标签页的输入框也还挂着（IndexedStack），
    // 所以只能在“记忆”面板里面找，且第一条就是正文。
    final Finder field = find
        .descendant(
          of: find.byType(MemoryPanel),
          matching: find.byType(EditableText),
        )
        .first;
    await t.enterText(field, '我记得门是插着的。');
    await t.pumpAndSettle();

    await t.tap(find.text('保存'));
    await t.pumpAndSettle();

    // 关键：不是界面上记着，是**库里**有。
    final List<CharacterMemory> all = worldStore.loadWorldMemory(id);
    expect(
      all.where((CharacterMemory m) => m.text == '我记得门是插着的。').length,
      1,
    );
  });

  testWidgets('库里已有的记忆，打开面板就能看到（重开也在）', (WidgetTester t) async {
    final WorldStore worldStore = WorldStore.memory()..seedDemo();
    addTearDown(worldStore.close);
    final String id = worldStore.loadWorlds().worlds.first.id;
    worldStore.saveWorldMemory(id, <CharacterMemory>[
      note('m1', '人物1', '楼梯上有脚步。'),
    ]);

    await boot(t, worldStore);
    await openMemoryTab(t);

    expect(find.text('楼梯上有脚步。'), findsOneWidget);
  });
}
