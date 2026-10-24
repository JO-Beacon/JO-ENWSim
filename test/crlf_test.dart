// 从网页 / 聊天窗口复制多行文字过来时，换行往往是 **CRLF**。
//
// 回车符进到输入框里会变成一个“豆腐块”（☒），存进库以后还会把
// Markdown 的切块搞乱（截图里那行 `]]]` 就是这么来的）。
// 所以两道防：
//   1. 输入框入口就清掉（`JoTextField._sanitize`）；
//   2. 渲染端再统一一遍（`JoMarkdown` 里），库里的旧数据也不怕。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/markdown/md_view.dart';
import 'package:joenws/theme/tokens.dart';
import 'package:joenws/ui/common.dart';

Widget host(Widget child) => MaterialApp(
  home: JoTheme(
    settings: const JoSettings(),
    palette: JoPalette.dark,
    child: child,
  ),
);

void main() {
  testWidgets('粘进来的 CRLF：输入框里不留回车符', (WidgetTester t) async {
    final TextEditingController c = TextEditingController();
    addTearDown(c.dispose);
    await t.pumpWidget(
      host(
        Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 320,
            child: JoTextField(
              controller: c,
              style: JoFonts.ui.copyWith(color: JoPalette.dark.text),
              maxLines: 6,
            ),
          ),
        ),
      ),
    );

    await t.enterText(find.byType(EditableText), '第一行\r\n第二行\r第三行');
    await t.pumpAndSettle();

    expect(c.text.contains('\r'), isFalse, reason: '不能把回车符留在输入框里');
    expect(c.text, '第一行\n第二行\n第三行');
  });

  testWidgets('渲染端也吃 CRLF：正文照常排版，不出现回车符', (WidgetTester t) async {
    await t.pumpWidget(
      host(
        Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 420,
            child: JoMarkdown(
              data: '# 标题\r\n\r\n- 甲\r\n- 乙\r\n',
              style: const JoSettings().bodyStyle(JoPalette.dark.text),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();

    expect(t.takeException(), isNull);
    expect(find.textContaining('标题'), findsOneWidget);
    expect(find.textContaining('甲'), findsOneWidget);
    expect(find.textContaining('乙'), findsOneWidget);

    // 渲染出来的纯文本里不能残留 \r（那就是豆腐块的来源）。
    for (final Element e in find.byType(RichText).evaluate()) {
      final RichText r = e.widget as RichText;
      expect(r.text.toPlainText().contains('\r'), isFalse);
    }
  });
}
