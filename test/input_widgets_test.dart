// 输入框的回归测试。
//
// 背景：这套界面是自绘的，树里**没有 Material**。以前用 Flutter 自带的
// `TextField`，它在 debug 下要求有 `Material` 祖先，于是设置页整页红屏
// （release 里那句检查被编译掉、看着没事，所以只有调试时才炸）。
//
// 现在的做法：输入框用 Cupertino 那一套（`CupertinoTextField`），
// 它不要求 Material 祖先，选中 / 双击选词 / 右键菜单 / 输入法都是官方现成的。
// 外观（底色、描边、圆角）仍由外面的 Container 给。
//
// 注意：右键菜单“选项点了不生效”的问题**已搁置**，见
// `AGENTS/右键菜单问题.md`。下面因此不再钉菜单项的行为。

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/model/model_plan.dart';
import 'package:joenws/model/provider.dart';
import 'package:joenws/theme/tokens.dart';
import 'package:joenws/ui/common.dart';
import 'package:joenws/ui/provider_panel.dart';
import 'package:joenws/ui/settings_page.dart';

Widget host(Widget child) {
  // 刻意**不包 Material**：跟 App 里真实的树一样（MaterialApp → JoTheme → 内容）。
  return MaterialApp(
    home: JoTheme(
      settings: const JoSettings(),
      palette: JoPalette.dark,
      child: child,
    ),
  );
}

void main() {
  testWidgets('没有 Material 祖先也能建输入框（提示文字也在）', (WidgetTester t) async {
    final TextEditingController c = TextEditingController();
    addTearDown(c.dispose);

    await t.pumpWidget(
      host(
        Center(
          child: SizedBox(
            width: 240,
            child: JoTextField(
              controller: c,
              style: const TextStyle(fontSize: 13),
              hint: '搜索服务商或分组',
            ),
          ),
        ),
      ),
    );

    expect(t.takeException(), isNull);
    expect(find.text('搜索服务商或分组'), findsOneWidget);
    // 用的是 Cupertino 那套，不是 Material 的 TextField。
    expect(find.byType(CupertinoTextField), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('服务商面板（搜索框 + 密钥框）能建出来', (WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => t.binding.setSurfaceSize(null));

    await t.pumpWidget(
      host(
        ProviderPanel(
          providers: <Provider>[
            const Provider(
              id: 'p1',
              protocol: Protocol.openai,
              name: 'DeepSeek',
              apiKey: 'sk-test',
            ),
          ],
          onChanged: (List<Provider> _) {},
        ),
      ),
    );

    expect(t.takeException(), isNull);
    expect(find.byType(JoTextField), findsWidgets);
  });

  testWidgets('搜索服务：DeepSeek 那页有“试搜一下”，并写明按次计费', (WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => t.binding.setSurfaceSize(null));

    await t.pumpWidget(
      host(
        ProviderPanel(
          providers: <Provider>[
            const Provider(
              id: 's1',
              protocol: Protocol.deepseek,
              name: 'DeepSeek',
              apiKey: 'sk-test',
              baseUrl: 'https://api.deepseek.com',
              kind: ServiceKind.search,
            ),
          ],
          presets: kSearchPresets,
          onChanged: (List<Provider> _) {},
        ),
      ),
    );
    await t.pumpAndSettle();

    expect(t.takeException(), isNull);
    expect(find.text('试搜一下'), findsOneWidget);
    expect(find.textContaining('按次计费'), findsOneWidget);
  });

  testWidgets('设置 → 引擎 那页能建出来，且不再写“还没接入”', (WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1100, 760));
    addTearDown(() => t.binding.setSurfaceSize(null));

    await t.pumpWidget(
      host(
        SettingsPage(
          settings: const JoSettings(),
          onChanged: (JoSettings _) {},
          providers: const <Provider>[],
          onProvidersChanged: (List<Provider> _) {},
          globalPlan: const ModelPlan(),
          onGlobalPlanChanged: (ModelPlan _) {},
          keys: const <String, String>{},
          onKeysChanged: (Map<String, String> _) {},
          onBack: () {},
        ),
      ),
    );
    expect(t.takeException(), isNull);

    await t.tap(find.text('引擎').first);
    await t.pumpAndSettle();

    expect(t.takeException(), isNull);
    expect(find.textContaining('引擎还没接入'), findsNothing);
  });

  testWidgets('右键菜单：自己那套外观，点“全选”真的能选中', (WidgetTester t) async {
    final TextEditingController c = TextEditingController(text: 'abc def');
    addTearDown(c.dispose);

    await t.pumpWidget(
      host(
        Center(
          child: SizedBox(
            width: 300,
            child: JoTextField(
              controller: c,
              style: const TextStyle(fontSize: 16),
            ),
          ),
        ),
      ),
    );

    await t.tapAt(
      t.getTopLeft(find.byType(EditableText)) + const Offset(20, 8),
      buttons: kSecondaryMouseButton,
    );
    await t.pumpAndSettle();

    // 菜单项是自己的中文文案。
    expect(find.text('全选'), findsOneWidget);
    expect(t.takeException(), isNull);

    await t.tap(find.text('全选'));
    await t.pumpAndSettle();

    expect(c.selection.start, 0);
    expect(c.selection.end, c.text.length);
  });

  testWidgets('能拖选文字（选字真的能用）', (WidgetTester t) async {
    final TextEditingController c = TextEditingController(text: '一二三四五六七八');
    addTearDown(c.dispose);

    await t.pumpWidget(
      host(
        Center(
          child: SizedBox(
            width: 300,
            child: JoTextField(
              controller: c,
              style: const TextStyle(fontSize: 16),
            ),
          ),
        ),
      ),
    );

    final Finder f = find.byType(EditableText);
    final Offset p = t.getTopLeft(f) + const Offset(120, 8);

    // 从右往左拖（**鼠标**拖，触摸下拖选得先长按）：
    // 选中的应该是中间一截，而不是一个光标。
    final TestGesture g = await t.startGesture(
      p,
      kind: PointerDeviceKind.mouse,
    );
    await t.pump(const Duration(milliseconds: 20));
    await g.moveBy(const Offset(-90, 0));
    await t.pump(const Duration(milliseconds: 20));
    await g.up();
    await t.pumpAndSettle();

    expect(c.selection.isCollapsed, isFalse);
    expect(c.selection.textInside(c.text).isNotEmpty, isTrue);
  });
}
