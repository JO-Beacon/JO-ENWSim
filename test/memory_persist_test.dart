// 记忆接线：写进弹窗的东西要真进库，重开还在。
//
// 以前记忆只有 load/save 方法，界面上没人调：写进去关掉就没了。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/data/world_store.dart';
import 'package:joenws/main.dart';
import 'package:joenws/model/memory.dart';
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

void main() {
  test('库里的记忆能被读出来（上帝那本与角色那本都在）', () {
    final WorldStore s = WorldStore.memory()..seedDemo();
    addTearDown(s.close);
    final String id = s.loadWorlds().worlds.first.id;

    s.saveMemories(id, <String, MemoryBook>{
      '': MemoryBook(
        ownerId: '',
        entries: <MemoryEntry>[newMemoryEntry(content: '门是插着的。')],
      ),
      '人物1': MemoryBook(
        ownerId: '人物1',
        entries: <MemoryEntry>[newMemoryEntry(content: '雨声很响。')],
      ),
    });

    final List<MemoryBook> books = s.loadMemories(id);
    expect(books.length, 2);
    expect(
      books.firstWhere((MemoryBook b) => b.ownerId == '').entries.first.content,
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
    final List<MemoryBook> books = worldStore.loadMemories(id);
    final Iterable<MemoryEntry> all = books.expand((MemoryBook b) => b.entries);
    expect(all.where((MemoryEntry e) => e.content == '我记得门是插着的。').length, 1);
  });

  testWidgets('库里已有的记忆，打开面板就能看到（重开也在）', (WidgetTester t) async {
    final WorldStore worldStore = WorldStore.memory()..seedDemo();
    addTearDown(worldStore.close);
    final String id = worldStore.loadWorlds().worlds.first.id;
    worldStore.saveMemories(id, <String, MemoryBook>{
      '': MemoryBook(
        ownerId: '',
        entries: <MemoryEntry>[newMemoryEntry(content: '楼梯上有脚步。')],
      ),
    });

    await boot(t, worldStore);
    await openMemoryTab(t);

    expect(find.text('楼梯上有脚步。'), findsOneWidget);
  });
}
