// “添加服务商”弹窗里的厂商搜索框。
//
// 预设越来越多（OpenAI / Gemini / Claude / DeepSeek / MiMo / 硅基流动 …），
// 光靠滚动找不现实，所以加个过滤框：按**名字或地址**找，
// 下面“自定义”那一组不受影响（它跟厂商无关）。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/model/provider.dart';
import 'package:joenws/theme/tokens.dart';
import 'package:joenws/ui/add_provider_dialog.dart';
import 'package:joenws/ui/common.dart';

/// 弹窗里能找到的文字（限定在 Dialog 里，避免撞到页面别处的同名文字）。
Finder inDialog(String text) =>
    find.descendant(of: find.byType(Dialog), matching: find.text(text));

void main() {
  Future<void> open(WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => t.binding.setSurfaceSize(null));

    await t.pumpWidget(
      MaterialApp(
        // JoTheme 要在 **Navigator 之上**（跟 main.dart 一样），
        // 否则 showDialog 弹窗落在外面，里面拿不到主题。
        builder: (BuildContext c, Widget? child) => JoTheme(
          settings: const JoSettings(),
          palette: JoPalette.dark,
          child: child ?? const SizedBox.shrink(),
        ),
        home: Builder(
          builder: (BuildContext c) => Scaffold(
            body: Center(
              child: JoButton(
                text: '打开',
                onTap: () => showAddProviderDialog(c),
              ),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('打开'));
    await t.pumpAndSettle();
  }

  Future<void> type(WidgetTester t, String s) async {
    await t.enterText(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(EditableText),
      ),
      s,
    );
    await t.pumpAndSettle();
  }

  testWidgets('弹窗里有搜索框，默认列出全部厂商', (WidgetTester t) async {
    await open(t);
    expect(t.takeException(), isNull);
    expect(find.text('找厂商（名字或地址）'), findsOneWidget);
    expect(inDialog('OpenAI'), findsOneWidget);
    expect(inDialog('小米 MiMo'), findsOneWidget);
    expect(inDialog('DeepSeek'), findsOneWidget);
  });

  testWidgets('按名字过滤', (WidgetTester t) async {
    await open(t);
    await type(t, 'mimo');

    expect(inDialog('小米 MiMo'), findsOneWidget);
    expect(inDialog('OpenAI'), findsNothing);
    expect(inDialog('DeepSeek'), findsNothing);
    // 自定义那组不受影响，还留着。
    expect(inDialog('自定义 · OpenAI 兼容 · chat/completions'), findsOneWidget);
  });

  testWidgets('按地址过滤（记得域名、忘了名字时用得上）', (WidgetTester t) async {
    await open(t);
    await type(t, 'xiaomimimo.com');

    expect(inDialog('小米 MiMo'), findsOneWidget);
    expect(inDialog('OpenAI'), findsNothing);
  });

  testWidgets('什么都搜不到时如实说明，且仍能用自定义', (WidgetTester t) async {
    await open(t);
    await type(t, 'zzz-not-a-vendor');

    expect(find.textContaining('没找到匹配的厂商'), findsOneWidget);
    expect(inDialog('小米 MiMo'), findsNothing);
    // 自定义还能用，不至于把路堵死。
    expect(inDialog('自定义 · OpenAI 兼容 · chat/completions'), findsOneWidget);
  });

  testWidgets('清空过滤词，列表回来', (WidgetTester t) async {
    await open(t);
    await type(t, 'mimo');
    expect(inDialog('OpenAI'), findsNothing);

    await type(t, '');
    expect(inDialog('OpenAI'), findsOneWidget);
    expect(inDialog('小米 MiMo'), findsOneWidget);
  });

  testWidgets('预设清单里确实有 MiMo 的两个形状', (WidgetTester t) async {
    // 这条不看界面，钉的是数据：两种形状都得在预设里。
    final List<String> names = <String>[
      for (final ProviderPreset ps in kProviderPresets) ps.name,
    ];
    expect(names, contains('小米 MiMo'));
    expect(names, contains('小米 MiMo · Anthropic 格式'));
  });
}
