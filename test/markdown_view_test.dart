// Markdown 渲染层（lib/markdown/md_view.dart）。
//
// 渲染交给 flutter_markdown_plus，样式是我们自己给的（见 md_view.dart）。
// 这里只验“该出现的样式出现了、该出现的东西在”，不验像素级外观。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/markdown/md_view.dart';
import 'package:joenws/theme/tokens.dart';
import 'package:joenws/ui/icons.dart';

Widget host(Widget child) => MaterialApp(
  home: JoTheme(
    settings: const JoSettings(),
    palette: JoPalette.dark,
    child: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 420, child: child),
      ),
    ),
  ),
);

TextStyle bodyStyle() =>
    const JoSettings().bodyStyle(JoPalette.dark.text).copyWith(fontSize: 15);

/// 把一段 Text.rich 的所有 span 摊平（方便查样式）。
List<TextSpan> spansOf(WidgetTester t, String containing) {
  final Text w = t.widget<Text>(find.textContaining(containing));
  final List<TextSpan> out = <TextSpan>[];
  void walk(InlineSpan s) {
    if (s is TextSpan) {
      out.add(s);
      for (final InlineSpan c in s.children ?? const <InlineSpan>[]) {
        walk(c);
      }
    }
  }

  walk(w.textSpan ?? const TextSpan());
  return out;
}

void main() {
  testWidgets('段落 + 粗体 + 行内代码：样式落到对应的 span 上', (WidgetTester t) async {
    await t.pumpWidget(
      host(JoMarkdown(data: '他说**别开门**，然后敲了 `三下`。', style: bodyStyle())),
    );

    final List<TextSpan> spans = spansOf(t, '别开门');
    expect(
      spans.any(
        (TextSpan s) =>
            s.text == '别开门' && s.style?.fontWeight == FontWeight.w700,
      ),
      isTrue,
      reason: '粗体要真的加粗',
    );
    expect(
      spans.any(
        (TextSpan s) => s.text == '三下' && s.style?.backgroundColor != null,
      ),
      isTrue,
      reason: '行内代码要有底色',
    );
    // 标记本身不该露出来
    expect(find.textContaining('**'), findsNothing);
  });

  testWidgets('列表：每一项前面有点/编号，标记不露出来', (WidgetTester t) async {
    await t.pumpWidget(
      host(JoMarkdown(data: '- 第一件\n- 第二件\n\n1. 甲\n2. 乙', style: bodyStyle())),
    );
    expect(find.text('•'), findsNWidgets(2));
    // 有序列表的序号渲染成 `1.` / `2.`（带点）
    expect(find.text('1.'), findsOneWidget);
    expect(find.text('2.'), findsOneWidget);
    expect(find.textContaining('第一件'), findsOneWidget);
    expect(find.textContaining('- '), findsNothing);
  });

  testWidgets('引用：有竖线，文字还在', (WidgetTester t) async {
    await t.pumpWidget(host(JoMarkdown(data: '> 外面在下雨。', style: bodyStyle())));
    expect(find.textContaining('外面在下雨'), findsOneWidget);
    // 引用块左边有一道 2px 的线（包把装饰画在 DecoratedBox 上）
    final Iterable<Widget> boxes = t
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .where((DecoratedBox d) {
          final Decoration dec = d.decoration;
          if (dec is! BoxDecoration) return false;
          final Border? b = dec.border is Border ? dec.border! as Border : null;
          return b != null && b.left.width == 2;
        });
    expect(boxes, isNotEmpty);
  });

  testWidgets('代码块：原样显示，不去解析里面的符号', (WidgetTester t) async {
    await t.pumpWidget(
      host(
        JoMarkdown(
          data: '```dart\nfinal a = **不是粗体**;\n```',
          style: bodyStyle(),
        ),
      ),
    );
    expect(find.textContaining('**不是粗体**'), findsOneWidget);
  });

  testWidgets('表格：画成 Table，表头加粗', (WidgetTester t) async {
    await t.pumpWidget(
      host(
        JoMarkdown(
          data: '| 谁 | 做了什么 |\n| --- | --- |\n| 人物1 | 站着 |',
          style: bodyStyle(),
        ),
      ),
    );
    final Table table = t.widget<Table>(find.byType(Table));
    expect(table.children.length, 2, reason: '表头 + 一行数据');
    expect(find.textContaining('人物1'), findsOneWidget);
    final List<TextSpan> head = spansOf(t, '谁');
    expect(
      head.any((TextSpan s) => s.style?.fontWeight == FontWeight.w700),
      isTrue,
      reason: '表头要加粗',
    );
  });

  testWidgets('图片：本地文件不存在时退化成 alt 文字，不炸', (WidgetTester t) async {
    await t.pumpWidget(
      host(JoMarkdown(data: '![门厅的照片](/不存在的/图.png)', style: bodyStyle())),
    );
    expect(t.takeException(), isNull);
    expect(find.textContaining('门厅的照片'), findsOneWidget);
  });

  testWidgets('小卡片摘要：两行、带行内格式、不露符号', (WidgetTester t) async {
    await t.pumpWidget(
      host(
        JoMarkdown(
          data: '**正厅**的灯亮着。\n\n第二段不该出现。',
          style: bodyStyle(),
          compact: true,
        ),
      ),
    );
    final Text w = t.widget<Text>(find.textContaining('正厅'));
    expect(w.maxLines, 2);
    // 现在是**富文本**了：粗体照样粗，只是不排块。
    final List<TextSpan> all = <TextSpan>[];
    void walk(InlineSpan s) {
      if (s is TextSpan) {
        all.add(s);
        for (final InlineSpan c in s.children ?? const <InlineSpan>[]) {
          walk(c);
        }
      }
    }

    walk(w.textSpan ?? const TextSpan());
    expect(
      all.any(
        (TextSpan s) =>
            s.text == '正厅' && s.style?.fontWeight == FontWeight.w700,
      ),
      isTrue,
      reason: '摘要里的粗体也要粗',
    );
    expect(find.textContaining('**'), findsNothing);
  });

  testWidgets('解析器认不出的东西不会把整段吞掉', (WidgetTester t) async {
    await t.pumpWidget(
      host(JoMarkdown(data: '<div>原样文字</div>\n\n后面还有一句。', style: bodyStyle())),
    );
    expect(t.takeException(), isNull);
    expect(find.textContaining('后面还有一句'), findsOneWidget);
  });

  testWidgets('行内代码：底色不能和卡面一样（否则看着像没样式）', (WidgetTester t) async {
    await t.pumpWidget(
      host(JoMarkdown(data: '敲了 `三下` 门', style: bodyStyle(), compact: true)),
    );
    final List<TextSpan> all = <TextSpan>[];
    void walk(InlineSpan s) {
      if (s is TextSpan) {
        all.add(s);
        for (final InlineSpan c in s.children ?? const <InlineSpan>[]) {
          walk(c);
        }
      }
    }

    walk(t.widget<Text>(find.textContaining('三下')).textSpan!);
    final TextSpan code = all.firstWhere((TextSpan s) => s.text == '三下');
    final Color? bg = code.style?.backgroundColor;
    expect(bg, isNotNull, reason: '行内代码要有底色');
    // 卡片本身就是 surface：底色要是 surface 就白做了。
    expect(bg, isNot(JoPalette.dark.surface));
    // 用半透明叠色，铺在卡面或页面底上都看得见。
    expect(bg!.a, lessThan(1.0));
  });

  testWidgets('任务列表：勾选框自己画（用我们的 check 图标，不用 Material 图标字体）', (
    WidgetTester t,
  ) async {
    await t.pumpWidget(
      host(JoMarkdown(data: '- [x] 已做\n- [ ] 未做', style: bodyStyle())),
    );
    // 已勾选那个才有一个 check 图标；未勾选是空框。
    expect(find.byIcon(JoIcons.check), findsOneWidget);
    expect(find.textContaining('已做'), findsOneWidget);
    expect(find.textContaining('未做'), findsOneWidget);
    // 没带 Material 图标字体：不能用 Icons.*
    expect(find.byIcon(Icons.check_box), findsNothing);
  });

  testWidgets('未勾选的框：轮廓不能淡到看不见', (WidgetTester t) async {
    await t.pumpWidget(host(JoMarkdown(data: '- [ ] 未做', style: bodyStyle())));
    final Iterable<DecoratedBox> boxes = t
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .where((DecoratedBox d) {
          final Decoration dec = d.decoration;
          if (dec is! BoxDecoration) return false;
          final Border? b = dec.border is Border ? dec.border! as Border : null;
          return b != null && b.top.width >= 1 && b.top.width <= 2;
        });
    expect(boxes, isNotEmpty, reason: '没勾的那一项也得有框');

    final BoxDecoration d = boxes.first.decoration as BoxDecoration;
    final Color line = (d.border! as Border).top.color;
    final Color bg = JoPalette.dark.surface;

    // 亮度差：线要比卡面明显，否则就是“看不见”。
    double lum(Color c) => 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
    expect(
      (lum(line) - lum(bg)).abs(),
      greaterThan(0.2),
      reason: '框线跟卡面亮度差太小，看上去就像没框',
    );
  });

  testWidgets('任务列表：勾选框跟第一行字垂直居中（不能歪）', (WidgetTester t) async {
    await t.pumpWidget(
      host(JoMarkdown(data: '- [x] 已做\n- [ ] 未做', style: bodyStyle())),
    );
    // 勾选框：包给我们的宽度是**紧的**（整个项目符号列 26px），
    // 不包 Align 的话框会被拉成 26×15 的扁条 —— 就是“歪且丑”的根源。
    final Finder box = find
        .ancestor(
          of: find.byIcon(JoIcons.check),
          matching: find.byType(DecoratedBox),
        )
        .first;
    final Rect boxRect = t.getRect(box);
    expect(
      (boxRect.width - boxRect.height).abs(),
      lessThan(0.5),
      reason: '勾选框得是方的，不能被父级宽度拉成扁条',
    );

    final Rect iconRect = t.getRect(find.byIcon(JoIcons.check));
    expect(iconRect.width, iconRect.height, reason: '里面的勾也不能被拉歪');

    final Rect line1 = t.getRect(find.textContaining('已做').first);
    expect(
      iconRect.center.dy,
      closeTo(line1.center.dy, 2),
      reason: '勾选框要和第一行字居中对齐，不是挂在字腰上或脚跟下',
    );
  });

  testWidgets('删除线：真的画了线，而且够粗看得见', (WidgetTester t) async {
    await t.pumpWidget(
      host(JoMarkdown(data: '前 ~~删掉~~ 后', style: bodyStyle())),
    );
    final List<TextSpan> spans = spansOf(t, '删掉');
    final TextSpan del = spans.firstWhere((TextSpan s) => s.text == '删掉');
    expect(del.style?.decoration, TextDecoration.lineThrough);
    expect(del.style?.decorationThickness, greaterThanOrEqualTo(2.0));
  });

  testWidgets('小卡片（字更小）的删除线也不许细', (WidgetTester t) async {
    await t.pumpWidget(
      host(
        JoMarkdown(
          // 小卡片的字号就是正文 −3
          data: '前 ~~删掉~~ 后',
          style: bodyStyle().copyWith(fontSize: 13),
          compact: true,
        ),
      ),
    );
    final List<TextSpan> spans = spansOf(t, '删掉');
    final TextSpan del = spans.firstWhere((TextSpan s) => s.text == '删掉');
    expect(del.style?.decoration, TextDecoration.lineThrough);
    // 字小了线不能跟着变细：有下限
    expect(
      del.style?.decorationThickness,
      greaterThanOrEqualTo(2.0),
      reason: '小的字上必须更明显，而不是更模糊',
    );
  });

  testWidgets('行内代码用等宽字体（正文是宋体，代码不能跟着变）', (WidgetTester t) async {
    await t.pumpWidget(host(JoMarkdown(data: '敲了 `三下` 门', style: bodyStyle())));
    final List<TextSpan> spans = spansOf(t, '三下');
    final TextSpan code = spans.firstWhere((TextSpan s) => s.text == '三下');
    expect(code.style?.fontFamily, JoFonts.mono);
    expect(code.style?.fontFamilyFallback, contains(JoFonts.sans));
    expect(
      code.style?.fontFeatures,
      contains(const FontFeature.tabularFigures()),
    );
  });

  // —— 引用与告警块的颜色 ——
  //
  // 用户定的：深色模式下普通引用是**白**，NOTE 浅蓝，WARNING 橙红。

  /// 找出所有“左边有 2px 竖线”的装饰，返回竖线颜色（按出现顺序）。
  List<Color> leftRules(WidgetTester t) {
    final List<Color> out = <Color>[];
    for (final DecoratedBox d in t.widgetList<DecoratedBox>(
      find.byType(DecoratedBox),
    )) {
      final Decoration dec = d.decoration;
      if (dec is! BoxDecoration) continue;
      final Border? b = dec.border is Border ? dec.border! as Border : null;
      if (b == null) continue;
      if (b.left.width == 2 && b.left.style != BorderStyle.none) {
        out.add(b.left.color);
      }
    }
    return out;
  }

  testWidgets('普通引用的竖线是正文色（深色下近白），不是分隔线的灰', (WidgetTester t) async {
    await t.pumpWidget(host(JoMarkdown(data: '> 外面在下雨。', style: bodyStyle())));
    final List<Color> rules = leftRules(t);
    expect(rules, isNotEmpty);
    expect(rules.first, JoPalette.dark.text);
    expect(
      rules.first,
      isNot(JoPalette.dark.border),
      reason: '以前用的就是分隔线那个灰，太弱',
    );
  });

  testWidgets('NOTE 是浅蓝，WARNING 是红（深色）', (WidgetTester t) async {
    await t.pumpWidget(
      host(
        JoMarkdown(
          data: '> [!NOTE]\n> 这是提示\n\n> [!WARNING]\n> 这是警告',
          style: bodyStyle(),
        ),
      ),
    );
    expect(t.takeException(), isNull);

    final List<Color> rules = leftRules(t);
    expect(rules.length, 2);

    final Color note = joAlertColor(JoPalette.dark, 'note');
    final Color warn = joAlertColor(JoPalette.dark, 'warning');
    expect(rules[0], note);
    expect(rules[1], warn);

    // 蓝：B 最大；红：R 最大（且比 G、B 都高）。
    expect(note.b, greaterThan(note.r), reason: 'NOTE 要偏蓝');
    expect(warn.r, greaterThan(warn.g), reason: 'WARNING 是红（最重）');
    expect(warn.r, greaterThan(warn.b), reason: 'WARNING 是红（最重）');
    // 三种颜色彼此不能撞。
    expect(<Color>{note, warn, JoPalette.dark.text}.length, 3);
  });

  testWidgets('告警块：标题出来、内容出来、`[!NOTE]` 这种原文不露出来', (WidgetTester t) async {
    await t.pumpWidget(
      host(JoMarkdown(data: '> [!NOTE]\n> 这是**提示**内容', style: bodyStyle())),
    );
    expect(find.text('注意'), findsOneWidget);
    expect(find.textContaining('这是'), findsOneWidget);
    expect(find.textContaining('[!NOTE]'), findsNothing);
    // 标题用中文，不再是英文 NOTE
    expect(find.text('NOTE'), findsNothing);
  });

  testWidgets('告警块和普通段落混排：顺序不乱、块之间留空', (WidgetTester t) async {
    await t.pumpWidget(
      host(
        JoMarkdown(
          data: '第一段。\n\n> [!WARNING]\n> 小心。\n\n最后一段。',
          style: bodyStyle(),
        ),
      ),
    );
    expect(t.takeException(), isNull);
    final double a = t.getRect(find.textContaining('第一段')).top;
    final double b = t.getRect(find.text('警告')).top;
    final double c = t.getRect(find.textContaining('最后一段')).top;
    expect(a, lessThan(b));
    expect(b, lessThan(c));
  });

  testWidgets('浅色主题下同一类告警换成深一点的颜色', (WidgetTester t) async {
    final Color darkNote = joAlertColor(JoPalette.dark, 'note');
    final Color lightNote = joAlertColor(JoPalette.light, 'note');
    expect(lightNote, isNot(darkNote));
    double lum(Color c) => 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
    expect(lum(lightNote), lessThan(lum(darkNote)), reason: '浅色底上要用深一点的那档');
  });

  // —— 颜色：两个主题必须**同一个色相**，只是深浅不同 ——

  test('每种告警在两个主题下色相一致（不能深色蓝、浅色绿）', () {
    for (final String type in <String>[
      'note',
      'tip',
      'important',
      'warning',
      'caution',
    ]) {
      final HSVColor d = HSVColor.fromColor(joAlertColor(JoPalette.dark, type));
      final HSVColor l = HSVColor.fromColor(
        joAlertColor(JoPalette.light, type),
      );
      double diff = (d.hue - l.hue).abs();
      if (diff > 180) diff = 360 - diff;
      expect(
        diff,
        lessThan(25),
        reason: '$type 深色 ${d.hue.round()}° vs 浅色 ${l.hue.round()}°：色相变了',
      );
      // 浅色主题的饱和度/亮度要往“深一点”走，不然米色底上看不清。
      expect(l.value, lessThan(d.value), reason: '$type 浅色应该更深');
    }
  });

  test('WARNING 是红（最重），CAUTION 是黄，NOTE 是蓝', () {
    double hue(Color c) => HSVColor.fromColor(c).hue;
    for (final JoPalette p in <JoPalette>[JoPalette.dark, JoPalette.light]) {
      // 红：色相靠 0°/360°，所以两头都算
      final double h = hue(joAlertColor(p, 'warning'));
      expect(h < 15 || h > 345, isTrue, reason: 'WARNING 应该是红，实际色相 $h°');
      expect(hue(joAlertColor(p, 'caution')), inInclusiveRange(40, 65));
      expect(hue(joAlertColor(p, 'note')), inInclusiveRange(200, 240));
    }
  });

  test('五种告警的中文小标题', () {
    expect(joAlertTitle('note'), '注意');
    expect(joAlertTitle('tip'), '提示');
    expect(joAlertTitle('important'), '重要');
    expect(joAlertTitle('warning'), '警告');
    expect(joAlertTitle('caution'), '小心');
  });

  testWidgets('小卡片摘要：告警标记换成中文，不再露 [!NOTE]', (WidgetTester t) async {
    await t.pumpWidget(
      host(
        JoMarkdown(
          data: '> [!WARNING]\n> 门后有东西。',
          style: bodyStyle(),
          compact: true,
        ),
      ),
    );
    expect(find.textContaining('[!WARNING]'), findsNothing);
    expect(find.textContaining('警告'), findsOneWidget);
    expect(find.textContaining('门后有东西'), findsOneWidget);
  });
}
