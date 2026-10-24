// 把 Markdown 画成界面。
//
// 渲染交给 `flutter_markdown_plus`（它自己用官方 `markdown` 解析），
// 我们只负责**把它调成我们这套界面**：
//   · 字体 / 字号 / 行高 / 颜色 全部从 `JoFonts` + `JoPalette` 派生；
//   · 不要 Material 的观感：引用是左边一道细线、代码块是方角深底、
//     表格是 1px 细边、任务列表的勾选框自己画（不用 Material 图标字体）；
//   · 正文**没有那条装饰下划线**（`bodyStyle` 里写死 `decoration: none`）。
//
// 不做的事：画布上的文字**不可选**（拖动 = 平移画布，免得两种手势打架）。

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../theme/tokens.dart';
import '../ui/icons.dart';

/// 块与块之间留多少（切出告警块后，要自己拼间距）。
const double _blockSpacing = JoSpace.s3;

/// `> [!NOTE]` 这种行（大小写不敏感，允许前后空格）。
///
/// `multiLine: true` 是必须的：它既要能逐行匹配（切块时），
/// 也要能拿去 `replaceAllMapped` 整段替换（小卡片摘要里）。
final RegExp _alertHead = RegExp(
  r'^\s{0,3}>\s{0,3}\[!(note|tip|important|caution|warning)\]\s*$',
  caseSensitive: false,
  multiLine: true,
);

/// 引用块每行开头的 `>`（连同后面那一个空格）。
final RegExp _quotePrefix = RegExp(r'^\s{0,3}>\s?');

/// 正文里的一块：普通 Markdown，或一个告警块。
class _MdPiece {
  const _MdPiece({required this.text, this.alert});

  /// Markdown 源码（告警块里已去掉每行的 `>`）。
  final String text;

  /// 告警类型（note / warning …）；null = 普通 Markdown。
  final String? alert;
}

/// 告警块的颜色。
///
/// 普通引用用**正文色**（深色下近白），这里只定义五种告警。
/// 两种主题是**同一个色相**、只是深浅不同（淡蓝→深蓝、黄→土黄…），
/// 不能一个主题蓝、另一个主题绿——那是两回事，不是“深一点”。
const Map<String, (Color dark, Color light)> _kAlertColors =
    <String, (Color, Color)>{
      // 蓝
      'note': (Color(0xFF6FA8DC), Color(0xFF2F6FA8)),
      // 绿
      'tip': (Color(0xFF7FB069), Color(0xFF3F7A3A)),
      // 紫
      'important': (Color(0xFFA98BD6), Color(0xFF6B4FA0)),
      // 红 —— **最重**：要立刻注意、不改就可能出事
      'warning': (Color(0xFFD96C6C), Color(0xFFA83232)),
      // 黄 —— 提醒“这么做有后果”，比 WARNING 轻一档
      'caution': (Color(0xFFD9C25C), Color(0xFF8A6A10)),
    };

Color joAlertColor(JoPalette p, String type) {
  final (Color dark, Color light) =
      _kAlertColors[type] ?? (p.secondary, p.secondary);
  return p.isDark ? dark : light;
}

/// 告警块的小标题。
///
/// **写中文**：界面全是中文，标题里冒一个 NOTE / WARNING 很跳。
/// （以后真做了多语言，这里是换成查表的地方，现在不先搭空架子。）
String joAlertTitle(String type) => switch (type) {
  'note' => '注意',
  'tip' => '提示',
  'important' => '重要',
  'warning' => '警告',
  'caution' => '小心',
  _ => type.toUpperCase(),
};

/// 行内代码的底色。
///
/// **不能直接用 `p.surface`**：卡片本身就是 surface，代码底色跟卡面一模一样，
/// 看上去就跟没样式一样（用户就是这么发现的）。
/// 用“正文色打一层很淡的透明度”去叠——不管背后是卡面还是页面底，都能看出来。
Color joInlineCodeBg(JoPalette p) =>
    p.text.withValues(alpha: p.isDark ? 0.12 : 0.07);

/// 删除线。
///
/// 默认是 **1 逻辑像素**，在 13~15px 的中文上真是看不见；
/// 没聚焦的小卡片字更小（正文 −3），细得更离谱。
/// 所以线宽跟着字号走，而且给一个下限。
TextStyle joDelStyle(TextStyle base, JoPalette p) {
  final double size = base.fontSize ?? 16;
  return base.copyWith(
    decoration: TextDecoration.lineThrough,
    decorationColor: p.text,
    decorationThickness: math.max(2.0, size * 0.12),
  );
}

/// 行内代码 / 代码块的字体样式。
///
/// 两个坑：
///   · 正文默认是**宋体**——代码用宋体会显得歪歪扭扭，代码一律用**等宽字体**
///     （Noto Sans Mono，中文落回思源黑体，同一家设计）；
///   · 以前底色直接用 `surface`，跟卡面撞色 —— 现在用 `joInlineCodeBg`。
TextStyle joCodeStyle(TextStyle base, JoPalette p) => base.copyWith(
  fontFamily: JoFonts.mono,
  fontFamilyFallback: const <String>[JoFonts.sans],
  fontSize: (base.fontSize ?? 16) * 0.96,
  fontFeatures: JoFonts.tabular,
  letterSpacing: 0,
  backgroundColor: joInlineCodeBg(p),
  color: p.text,
);

class JoMarkdown extends StatelessWidget {
  const JoMarkdown({
    super.key,
    required this.data,
    required this.style,
    this.compact = false,
  });

  final String data;

  /// 正文那套样式（思源、字号、颜色）；标题/粗体都在它上面派生。
  final TextStyle style;

  /// 小卡片用：只出两行纯文字摘要，不排版。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = JoTheme.of(context);

    // 从网页 / 聊天窗口粘过来的多行文字常常带 CRLF（`\r\n`）。
    // `\r` 在界面上就是一个**豆腐块**（☒），还会把 Markdown 的块切乱。
    // 输入框里已经拦了一道（`JoTextField._sanitize`），
    // 这里再统一一遍：库里已有的旧数据也照样能正常显示。
    final String src = data.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

    if (compact) {
      // 小卡片：**要格式，不要排版**。
      // 以前这里只把字抽出来（连 `**` 都没了）——于是没聚焦的卡片
      // 既不像 Markdown 也不像原文。现在按行内样式画（粗/斜/代码），
      // 但不排块（不排列表、不画表格），就两行。
      return Text.rich(
        TextSpan(children: _inlineSpans(p, src)),
        style: style,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    }

    // 先把 `> [!NOTE]` 这类**告警块**切出来：渲染包对它们只会给出一个
    // 认不出的 `div`（它没有处理 div，实测直接抛 “Too many elements”），
    // 而我们要的是**按类型上色**的竖线，所以自己画。
    final List<_MdPiece> pieces = _split(src);
    if (pieces.every((_MdPiece x) => x.alert == null)) {
      return _body(p, src);
    }

    final List<Widget> out = <Widget>[];
    for (final _MdPiece piece in pieces) {
      final Widget w = piece.alert == null
          ? _body(p, piece.text)
          : _alert(p, piece.alert!, piece.text);
      if (out.isNotEmpty) out.add(SizedBox(height: _blockSpacing));
      out.add(w);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: out,
    );
  }

  /// 一段普通 Markdown（不含告警块）。
  Widget _body(JoPalette p, String src) => MarkdownBody(
    data: src,
    // 不可选：画布的拖动是平移，别让选字抢手势。
    selectable: false,
    styleSheet: _sheet(p, style),
    onTapLink: (String text, String? href, String? title) {
      if (href == null) return;
      final Uri? u = Uri.tryParse(href);
      if (u != null) launchUrl(u, mode: LaunchMode.externalApplication);
    },
    // 任务列表整行按**顶对齐**排（默认是基线对齐，勾选框没有基线，
    // 就会被摆到歪的地方），勾选框再自己往下挪半个行距，跟第一行字居中。
    listItemCrossAxisAlignment: MarkdownListItemCrossAxisAlignment.start,
    checkboxBuilder: (bool checked) => _checkbox(p, checked),
    imageBuilder: (Uri uri, String? title, String? alt) => _image(p, uri, alt),
    // 代码块默认用正文那套（宋体）——代码要等宽，自己画。
    builders: <String, MarkdownElementBuilder>{
      'pre': _CodeBlockBuilder(style: joCodeBlockStyle(style, p), p: p),
    },
  );

  /// 告警块（GitHub Alerts）：`> [!NOTE]` / `[!WARNING]` 等。
  ///
  /// 左边一道**按类型上色**的竖线 + 一个小标题，内容当普通 Markdown 排。
  Widget _alert(JoPalette p, String type, String body) {
    final Color color = joAlertColor(p, type);
    return Container(
      padding: const EdgeInsets.only(left: JoSpace.s3),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: color, width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            joAlertTitle(type),
            style: JoFonts.meta.copyWith(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
          SizedBox(height: JoSpace.s1),
          _body(p, body),
        ],
      ),
    );
  }

  /// 把 `> [!NOTE]` 这类块从正文里切出来。
  ///
  /// 其余部分原样交给渲染包——**不自己解析 Markdown**，只认这一种形状。
  List<_MdPiece> _split(String src) {
    final List<String> lines = src.split('\n');
    final List<_MdPiece> out = <_MdPiece>[];
    final List<String> buf = <String>[];

    void flush() {
      if (buf.isEmpty) return;
      final String t = buf.join('\n');
      buf.clear();
      if (t.trim().isEmpty) return;
      out.add(_MdPiece(text: t));
    }

    int i = 0;
    while (i < lines.length) {
      final RegExpMatch? m = _alertHead.firstMatch(lines[i]);
      if (m == null) {
        buf.add(lines[i]);
        i++;
        continue;
      }
      flush();
      final String type = m.group(1)!.toLowerCase();
      i++;
      final List<String> body = <String>[];
      while (i < lines.length) {
        final String line = lines[i];
        if (!line.trimLeft().startsWith('>')) break;
        body.add(line.replaceFirst(_quotePrefix, ''));
        i++;
      }
      out.add(_MdPiece(text: body.join('\n'), alert: type));
    }
    flush();
    return out;
  }

  /// 摘要用：把整段拍平成“行内 span”（粗体/斜体/代码/链接/图 alt），
  /// 块与块之间用一个空格隔开。
  List<InlineSpan> _inlineSpans(JoPalette p, String data) {
    final List<InlineSpan> out = <InlineSpan>[];
    // 摘要里没有块结构，`> [!NOTE]` 会原样带着符号显示；
    // 先把标记换成中文小标题（“注意：”），跟展开后的样子一致。
    final String src = data.replaceAllMapped(
      _alertHead,
      (Match m) => '${joAlertTitle(m.group(1)!.toLowerCase())}：',
    );
    if (src.trim().isEmpty) return out;

    void walk(md.Node n, TextStyle s) {
      if (n is md.Text) {
        out.add(TextSpan(text: n.text, style: s));
        return;
      }
      if (n is! md.Element) return;
      switch (n.tag) {
        case 'strong':
          for (final md.Node c in n.children ?? const <md.Node>[]) {
            walk(c, s.copyWith(fontWeight: FontWeight.w700));
          }
        case 'em':
          for (final md.Node c in n.children ?? const <md.Node>[]) {
            walk(c, s.copyWith(fontStyle: FontStyle.italic));
          }
        case 'del':
          for (final md.Node c in n.children ?? const <md.Node>[]) {
            walk(c, joDelStyle(s, p));
          }
        case 'code':
          out.add(TextSpan(text: n.textContent, style: joCodeStyle(s, p)));
        case 'a':
          for (final md.Node c in n.children ?? const <md.Node>[]) {
            walk(c, s.copyWith(color: p.accent));
          }
        case 'img':
          final String alt = n.attributes['alt'] ?? '';
          out.add(TextSpan(text: alt.isEmpty ? '（图片）' : alt, style: s));
        case 'br':
          out.add(TextSpan(text: ' ', style: s));
        default:
          for (final md.Node c in n.children ?? const <md.Node>[]) {
            walk(c, s);
          }
      }
    }

    try {
      final List<md.Node> nodes = md.Document(
        extensionSet: md.ExtensionSet.gitHubFlavored,
      ).parseLines(src.split('\n'));
      for (final md.Node n in nodes) {
        if (out.isNotEmpty) out.add(TextSpan(text: ' ', style: style));
        walk(n, style);
      }
    } catch (_) {
      // 解析器出错：就显示原文，不做格式。
      out
        ..clear()
        ..add(TextSpan(text: data, style: style));
    }
    return out;
  }

  /// 把我们这套样式写成 flutter_markdown_plus 认的样式表。
  MarkdownStyleSheet _sheet(JoPalette p, TextStyle base) {
    final double size = base.fontSize ?? 16;
    TextStyle head(double k) => base.copyWith(
      fontSize: size * k,
      fontWeight: FontWeight.w700,
      height: 1.35,
    );
    final EdgeInsets headPad = EdgeInsets.only(
      top: JoSpace.s4,
      bottom: JoSpace.s2,
    );

    return MarkdownStyleSheet(
      p: base,
      pPadding: EdgeInsets.zero,
      a: base.copyWith(
        color: p.accent,
        decoration: TextDecoration.underline,
        decorationColor: p.accent,
      ),
      em: base.copyWith(fontStyle: FontStyle.italic),
      strong: base.copyWith(fontWeight: FontWeight.w700),
      del: joDelStyle(base, p),
      code: joCodeStyle(base, p),
      h1: head(1.55),
      h2: head(1.35),
      h3: head(1.2),
      h4: head(1.1),
      h5: head(1.05),
      h6: head(1.0),
      h1Padding: headPad,
      h2Padding: headPad,
      h3Padding: headPad,
      h4Padding: headPad,
      h5Padding: headPad,
      h6Padding: headPad,
      blockSpacing: JoSpace.s3,
      blockquote: base.copyWith(color: p.secondary),
      blockquotePadding: const EdgeInsets.only(left: JoSpace.s3),
      blockquoteDecoration: BoxDecoration(
        // 普通引用的竖线用**正文色**（深色下近白、浅色下近黑）。
        // 以前用 `p.border`，那是分隔线的灰，当“引用标记”太弱。
        // 告警块（NOTE / WARNING …）不走这里，它们在 `_alert` 里按类型上色。
        border: Border(left: BorderSide(color: p.text, width: 2)),
      ),
      codeblockPadding: const EdgeInsets.all(JoSpace.s3),
      codeblockDecoration: BoxDecoration(
        color: p.surface,
        border: JoShape.border(p.border),
        borderRadius: JoShape.br,
      ),
      listIndent: 18,
      listBullet: base.copyWith(color: p.secondary),
      listBulletPadding: const EdgeInsets.only(right: JoSpace.s2),
      tableHead: base.copyWith(fontWeight: FontWeight.w700),
      tableBody: base,
      tableBorder: TableBorder.all(color: p.border, width: 1),
      tableCellsPadding: const EdgeInsets.symmetric(
        horizontal: JoSpace.s2,
        vertical: JoSpace.s1,
      ),
      tableHeadCellsPadding: const EdgeInsets.symmetric(
        horizontal: JoSpace.s2,
        vertical: JoSpace.s1,
      ),
      tableVerticalAlignment: TableCellVerticalAlignment.top,
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.border)),
      ),
      checkbox: base.copyWith(color: p.accent),
    );
  }

  /// 任务列表的勾选框。
  ///
  /// 两个要求：
  ///   · 跟**第一行字**垂直居中（清单里常常是一行字，
  ///     按基线对齐会把它摆到字的腰上或脚跟下）；
  ///   · 选中时**实底 + 底色对钩**，一眼能分清勾没勾。
  Widget _checkbox(JoPalette p, bool checked) {
    final double line = (style.fontSize ?? 16) * (style.height ?? 1.5);
    const double side = 15;
    final double top = ((line - side) / 2).clamp(0.0, 12.0);
    return Padding(
      padding: EdgeInsets.only(top: top),
      // **必须包一层 Align**：包给我们的宽度是**紧的**（整个项目符号列 26px），
      // 直接放 SizedBox(15) 会被父级约束拉成 26×15 的扁框，
      // 里面的勾也跟着被拉成 24×13 —— 就是“又歪又丑”的样子。
      child: Align(
        alignment: Alignment.center,
        widthFactor: 1,
        heightFactor: 1,
        child: SizedBox(
          width: side,
          height: side,
          child: Container(
            decoration: BoxDecoration(
              color: checked ? p.accent : Colors.transparent,
              border: Border.all(
                // 未勾选时不能跟普通分隔线一个色（`p.border` 在深色下是 #262A31，
                // 跟卡面几乎一样，看上去就像没框）。用次要色，
                // 和正文拉开一档，一眼能看出“这里能勾”。
                color: checked ? p.accent : p.secondary,
                width: checked ? 1 : 1.2,
              ),
              borderRadius: JoShape.br,
            ),
            child: checked ? Icon(JoIcons.check, size: 11, color: p.bg) : null,
          ),
        ),
      ),
    );
  }

  Widget _image(JoPalette p, Uri uri, String? alt) {
    final Widget fail = Text(
      (alt == null || alt.trim().isEmpty) ? '（图片）' : alt,
      style: style.copyWith(color: p.secondary),
    );
    final String src = uri.toString();
    if (src.startsWith('http://') || src.startsWith('https://')) {
      return Image.network(
        src,
        errorBuilder: (_, _, _) => fail,
        fit: BoxFit.contain,
      );
    }
    final String path = uri.scheme == 'file' ? uri.toFilePath() : src;
    final File f = File(path);
    if (f.existsSync()) {
      return Image.file(
        f,
        errorBuilder: (_, _, _) => fail,
        fit: BoxFit.contain,
      );
    }
    return fail;
  }
}

/// 代码块的字体样式：黑体、不要行内代码那层底色（块自己有底）。
TextStyle joCodeBlockStyle(TextStyle base, JoPalette p) => base.copyWith(
  fontFamily: JoFonts.mono,
  fontFamilyFallback: const <String>[JoFonts.sans],
  fontSize: (base.fontSize ?? 16) * 0.95,
  fontFeatures: JoFonts.tabular,
  height: 1.5,
  color: p.text,
);

/// 代码块自己画，理由两个：
///   · 默认用 `p`（正文宋体）——代码看着歪；
///   · 默认还外套一个横向 Scrollbar，跟这套界面不合。
class _CodeBlockBuilder extends MarkdownElementBuilder {
  _CodeBlockBuilder({required this.style, required this.p});

  final TextStyle style;
  final JoPalette p;

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(JoSpace.s3),
      decoration: BoxDecoration(
        color: p.surface,
        border: JoShape.border(p.border),
        borderRadius: JoShape.br,
      ),
      child: Text(element.textContent.trimRight(), style: style),
    );
  }
}
