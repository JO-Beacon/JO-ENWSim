import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/data/world_store.dart';
import 'package:joenws/main.dart';
import 'package:joenws/theme/settings_store.dart';
import 'package:joenws/theme/tokens.dart';
import 'package:joenws/ui/common.dart';
import 'package:joenws/ui/icons.dart';
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

  // 画布的选中动画：点开一张卡，它会慢慢变高、下面几行跟着让位。
  // 这里验的是“过渡中不炸”（卡按完整高度排版、外面裁成动画高度）
  // 以及选中之后右栏确实切到了“这一步”。
  testWidgets('App 里：点开一张卡有过渡，且不溢出', (WidgetTester tester) async {
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

    final Finder card = find.text('正厅的灯亮着。人物1站在楼梯口，没有动。');
    await tester.tap(card);
    await tester.pump();
    // 动画跑到一半：既没抛溢出，卡也已经变高了。
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('这一步'), findsOneWidget);
  });

  // 左栏每张世界卡片上的铅笔：在**右边**、跟整张卡片**上下居中**。
  testWidgets('App 里：左栏卡片上的铅笔靠右且上下居中', (WidgetTester tester) async {
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

    final Rect icon = tester.getRect(find.byIcon(JoIcons.pencil).first);
    final Rect name = tester.getRect(find.text('旧宅 · 雨夜').first);
    final Rect note = tester.getRect(find.text('三个地点 · 一场雨').first);

    // 靠右：在名字那一块的右侧。
    expect(icon.left, greaterThan(name.right));
    // 上下居中：图标中心 ≈ 名字到副标题这一块的正中。
    expect(icon.center.dy, closeTo((name.top + note.bottom) / 2, 6));
  });

  // 右栏底部那个入口现在是铅笔图标（以前是“编辑”两个字）。
  // 这里验两件事：图标在、点得开弹窗。
  testWidgets('App 里：底部是铅笔图标，点了打开编辑弹窗', (WidgetTester tester) async {
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

    // 左栏每个世界卡片上有一支，右栏底部一支（都是铅笔）。
    expect(find.byIcon(JoIcons.pencil), findsWidgets);
    // 右栏底部那支在最后（左栏先画）。
    await tester.tap(find.byIcon(JoIcons.pencil).last);
    await tester.pumpAndSettle();
    // 弹窗开了：五个标签页里第一个是“常规”。
    expect(find.text('常规'), findsOneWidget);
    // 弹窗标题也叫“编辑”，左栏卡片上也有“编辑”—— 所以只要求能找到。
    expect(find.text('编辑'), findsWidgets);
  });

  // 图标一律有悬停提示：停上去停一会儿，就能看到它叫什么。
  testWidgets('App 里：铅笔图标悬停会浮出名字', (WidgetTester tester) async {
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

    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await tester.pump();

    await mouse.moveTo(tester.getCenter(find.byIcon(JoIcons.pencil).last));
    await tester.pump();
    expect(find.text('编辑这个世界'), findsNothing);
    await tester.pump(const Duration(milliseconds: 420));
    await tester.pump();
    expect(find.text('编辑这个世界'), findsOneWidget);

    await mouse.moveTo(const Offset(1, 1));
    await tester.pumpAndSettle();
    expect(find.text('编辑这个世界'), findsNothing);
  });

  // 换世界：内容要先淡下去、换完再淡回来（左栏的世界列表不动）。
  testWidgets('App 里：换世界有过渡（淡出 → 换 → 淡入）', (WidgetTester tester) async {
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

    Iterable<FadeTransition> fades() =>
        tester.widgetList<FadeTransition>(find.byType(FadeTransition));

    // 一开始是满的。
    expect(fades().every((FadeTransition f) => f.opacity.value > 0.99), isTrue);

    // 点左栏里另一个世界（第一个就是当前世界，所以点第二个）。
    await tester.tap(find.text('海边小镇').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(
      fades().any((FadeTransition f) => f.opacity.value < 0.99),
      isTrue,
      reason: '换世界应该先把内容淡下去，而不是一秒换一张',
    );

    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // 换完了：内容里能看到新世界（标题栏）的名字，淡入也回到满。
    expect(find.text('海边小镇'), findsWidgets);
    expect(fades().every((FadeTransition f) => f.opacity.value > 0.99), isTrue);
  });

  // App 里的流程图：默认收起一行；点开就在右栏里**顺下去**（不盖住详情），
  // 再点一下又能收起。这条验的是**接线**（状态与布局），不验画得漂不漂亮。
  testWidgets('App 里：右栏流程图能展开，且详情还在下面', (WidgetTester tester) async {
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

    final Finder diagram = find.byKey(const ValueKey<String>('flow-diagram'));

    // 默认收起：只有一行，没有图。
    expect(find.text('回合流程'), findsOneWidget);
    expect(diagram, findsNothing);

    await tester.tap(find.text('回合流程'));
    await tester.pumpAndSettle();
    expect(diagram, findsOneWidget);
    expect(find.text('收起'), findsOneWidget);
    // **详情没被盖住也没被挤走**：展开后它被顶到图下面，往下滚就能看到。
    await tester.dragUntilVisible(
      find.text('世界观'),
      find.byKey(const ValueKey<String>('side-scroll')),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(find.text('世界观'), findsOneWidget);

    // 滚回顶部再收起。
    await tester.drag(
      find.byKey(const ValueKey<String>('side-scroll')),
      const Offset(0, 3000),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('回合流程'));
    await tester.pumpAndSettle();
    expect(diagram, findsNothing);
    expect(find.text('展开'), findsOneWidget);
  });
}
