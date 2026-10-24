// 全局那条“装饰下划线”。
//
// 它本来是 MaterialApp 的 `_errorTextStyle`：红字、等宽、**黄色双下划线**
// （它拿来逼你把字包进 Material）。`Text` 会把环境样式 merge 进来，
// 于是每条没写 decoration 的字都白赚一条刺眼的黄线。
//
// 现在自己定：单线、1px、淡灰，随明暗走（暗色比底色亮一点，亮色比底色深一点）。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/data/world_store.dart';
import 'package:joenws/main.dart';
import 'package:joenws/theme/settings_store.dart';
import 'package:joenws/theme/tokens.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> boot(WidgetTester t, {bool dark = true}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final SettingsStore store = await SettingsStore.open();
  final WorldStore worldStore = WorldStore.memory()..seedDemo();
  addTearDown(worldStore.close);
  await t.pumpWidget(
    JoEnwsApp(
      store: store,
      worldStore: worldStore,
      initialWorlds: worldStore.loadWorlds().worlds,
      initial: JoSettings(isDark: dark),
    ),
  );
  await t.pumpAndSettle();
}

TextStyle rootStyle(WidgetTester t) {
  final Element e = find.byType(Text).evaluate().first;
  return DefaultTextStyle.of(e).style;
}

/// 亮度：0 = 黑，1 = 白。
double lum(Color c) => (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b);

void main() {
  test('暗色：线比底色亮一点，是灰的，不是黄线', () {
    final Color c = JoFonts.decorationColor(JoPalette.dark);
    expect(lum(c), greaterThan(lum(JoPalette.dark.bg)), reason: '暗色下要“淡一点”');
    // 黄线的特征是 R≈G 远大于 B；这条要三条都差不多。
    expect((c.r - c.g).abs(), lessThan(0.05));
    expect((c.g - c.b).abs(), lessThan(0.08));
  });

  test('亮色：线比底色深一点，也是灰的', () {
    final Color c = JoFonts.decorationColor(JoPalette.light);
    expect(lum(c), lessThan(lum(JoPalette.light.bg)), reason: '亮色下要“深一点”');
    expect((c.r - c.g).abs(), lessThan(0.05));
    expect((c.g - c.b).abs(), lessThan(0.08));
  });

  testWidgets('根默认样式：单线、1px、用我们那个灰（不是黄色双线）', (WidgetTester t) async {
    await boot(t);
    final TextStyle s = rootStyle(t);
    expect(s.decoration, TextDecoration.underline);
    expect(s.decorationStyle, TextDecorationStyle.solid);
    expect(s.decorationThickness, 1);
    expect(s.decorationColor, JoFonts.decorationColor(JoPalette.dark));
    // 老样式是纯黄（1,1,0）
    final Color c = s.decorationColor!;
    expect((c.r - c.b).abs() > 0.5 && (c.g - c.b).abs() > 0.5, isFalse);
  });

  testWidgets('亮色主题下也换成“深一点的灰”', (WidgetTester t) async {
    await boot(t, dark: false);
    final TextStyle s = rootStyle(t);
    expect(s.decorationColor, JoFonts.decorationColor(JoPalette.light));
  });

  testWidgets('Material 子树（弹窗那侧）也吃同一套：textTheme 里带同一条线', (
    WidgetTester t,
  ) async {
    await boot(t);
    final BuildContext ctx = find.byType(Scaffold).evaluate().isEmpty
        ? find.byType(Text).evaluate().first
        : find.byType(Scaffold).evaluate().first;
    final TextStyle body = Theme.of(ctx).textTheme.bodyMedium!;
    expect(body.decoration, TextDecoration.underline);
    expect(body.decorationStyle, TextDecorationStyle.solid);
    expect(body.decorationColor, JoFonts.decorationColor(JoPalette.dark));
  });

  test('正文样式：显式关掉下划线（以后接 markdown 也不会被叠线）', () {
    expect(JoFonts.body.decoration, TextDecoration.none);
    final TextStyle s = const JoSettings().bodyStyle(const Color(0xFFE6E3DC));
    expect(s.decoration, TextDecoration.none);
  });

  testWidgets('画布上的正文没线，界面小标签才有线', (WidgetTester t) async {
    await boot(t);

    // 正文（卡片内容）自己带了 decoration: none，不会把环境那条线 merge 进来。
    final Text body = t.widget<Text>(find.text('正厅的灯亮着。人物1站在楼梯口，没有动。'));
    expect(body.style?.decoration, TextDecoration.none);

    // 界面标签（回合流程）没写 decoration：继承根上那条淡灰线。
    final Text label = t.widget<Text>(find.text('回合流程'));
    expect(label.style?.decoration, isNull);
    expect(
      DefaultTextStyle.of(find.text('回合流程').evaluate().first).style.decoration,
      TextDecoration.underline,
      reason: '环境那条线还在，只是正文不用它',
    );
  });
}
