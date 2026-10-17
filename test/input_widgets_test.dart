// 输入框的回归测试。
//
// 为什么值得钉：这套界面的树里**没有 Material**，以前用自带的 `TextField`
// 在 debug 下会直接抛红屏（`TextField` 要求有 `Material` 祖先），而 release
// 里那句检查被编译掉、看着没事 —— 于是只有调试时才炸。
// 现在输入框都走 `JoTextField`（`EditableText` 打底），这里确保：
// 没有 Material 祖先也能正常建出来。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/model/provider.dart';
import 'package:joenws/theme/tokens.dart';
import 'package:joenws/ui/common.dart';
import 'package:joenws/ui/provider_panel.dart';

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
  testWidgets('没有 Material 祖先也能建输入框（有提示文字时）', (WidgetTester t) async {
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

    // 打了个字，提示就该消失。
    await t.enterText(find.byType(EditableText), '深');
    await t.pump();
    expect(find.text('搜索服务商或分组'), findsNothing);
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
}
