import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/data/world_store.dart';
import 'package:joenws/main.dart';
import 'package:joenws/theme/settings_store.dart';
import 'package:joenws/theme/tokens.dart';
import 'package:joenws/ui/common.dart';
import 'package:joenws/ui/jo_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('选中菜单用的是中文文案', () async {
    final CupertinoLocalizations l =
        await const JoCupertinoLocalizationsDelegate().load(
          const Locale('en', 'US'),
        );
    expect(l.cutButtonLabel, '剪切');
    expect(l.copyButtonLabel, '复制');
    expect(l.pasteButtonLabel, '粘贴');
    expect(l.selectAllButtonLabel, '全选');
  });
  testWidgets('壳能启动', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SettingsStore store = await SettingsStore.open();
    // 世界从库里来（内存库 + 播种），不再是 DemoData 直接喂。
    final WorldStore worldStore = WorldStore.memory()..seedDemo();
    addTearDown(worldStore.close);
    await tester.pumpWidget(
      JoEnwsApp(
        store: store,
        worldStore: worldStore,
        initialWorlds: worldStore.loadWorlds().worlds,
        initial: const JoSettings(),
      ),
    );
    expect(find.text('＋ 新建世界'), findsOneWidget);
    expect(find.text('你要做什么……'), findsOneWidget);
  });

  // 这条是在**整个 App 的树**里验证发言框：能写字、能拖选。
  // （右键菜单选项的问题已搁置，见 `AGENTS/右键菜单问题.md`，这里不验它。）
  testWidgets('App 里：发言框能写字、能拖选', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SettingsStore store = await SettingsStore.open();
    final WorldStore worldStore = WorldStore.memory()..seedDemo();
    addTearDown(worldStore.close);

    await tester.pumpWidget(
      JoEnwsApp(
        store: store,
        worldStore: worldStore,
        initialWorlds: worldStore.loadWorlds().worlds,
        initial: const JoSettings(),
      ),
    );
    await tester.pumpAndSettle();

    // 发言框：整页只有这一个 EditableText。
    final Finder field = find.byType(EditableText);
    expect(field, findsOneWidget);
    await tester.enterText(field, 'abcdef');
    await tester.pumpAndSettle();

    final EditableText et = tester.widget<EditableText>(field);
    expect(et.controller.text, 'abcdef');

    // 鼠标从左拖到右，应该选中一段。
    final Offset p = tester.getTopLeft(field) + const Offset(10, 6);
    final TestGesture g = await tester.startGesture(
      p,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 20));
    await g.moveBy(const Offset(70, 0));
    await tester.pump(const Duration(milliseconds: 20));
    await g.up();
    await tester.pumpAndSettle();

    expect(et.controller.selection.isCollapsed, isFalse);
  });

  testWidgets('发言框是多行的：长句折行；换行键插换行且光标跟上；发送不插换行', (WidgetTester tester) async {
    // 这里把“换行”绑成 **Shift+Enter**：裸 Enter 我们故意不绑，交给输入框
    // 自己处理（光标/滚动/输入法同步都是它的事）—— 测试环境模拟不了输入法
    // 插字，所以只能拿组合键验“我们手动插入”的那条路。
    SharedPreferences.setMockInitialValues(<String, Object>{
      'input.keys': '{"newline":"Shift+Enter"}',
    });
    final SettingsStore store = await SettingsStore.open();
    final WorldStore worldStore = WorldStore.memory()..seedDemo();
    addTearDown(worldStore.close);

    await tester.pumpWidget(
      JoEnwsApp(
        store: store,
        worldStore: worldStore,
        initialWorlds: worldStore.loadWorlds().worlds,
        initial: const JoSettings(),
      ),
    );
    await tester.pumpAndSettle();

    // 一开始没选中任何步骤，页面上只有发言框这一个 JoTextField。
    final Finder box = find.byType(JoTextField);
    expect(box, findsOneWidget);
    expect(tester.widget<JoTextField>(box).maxLines, greaterThan(1));

    // 长句跟进也不该抛（以前 maxLines: 1 时横向挤、框不折行）。
    await tester.enterText(
      find.byType(EditableText),
      '这一句很长很长很长很长很长很长很长很长很长很长很长很长很长很长很长',
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 换行键（Shift+Enter）：插换行，且光标跟到新行上。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    EditableText et = tester.widget<EditableText>(find.byType(EditableText));
    expect(et.controller.text.contains('\n'), isTrue);
    // 光标停在插进去的那个换行后面，不是停在原地。
    expect(et.controller.selection.baseOffset, et.controller.text.length);

    // 发送键（默认 Ctrl+Enter）：不插换行。
    final String before = et.controller.text;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    et = tester.widget<EditableText>(find.byType(EditableText));
    expect(et.controller.text, before);
  });
}
