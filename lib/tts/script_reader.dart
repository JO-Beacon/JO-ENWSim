// 念稿模块：把原始文本整理成“能念的单元”。
//
// 只做确定性的事：
//   · 从事件里挑出该念的段（旁白 / 出声的台词）；
//   · 把 Markdown 清洗成纯文字；
//   · 按说话人拆开，标好念完停多久。
//
// 不做的事：不调 TTS、不播放、不管音色——那些在 TTS 服务那层。
// 也**不改写措辞**：念出来的必须是原文，不能是模型重写过的版本。

import 'package:markdown/markdown.dart' as md;

import '../engine/perception.dart';

/// 念稿范围。
enum ReadScope {
  /// 旁白（动作与叙述）+ 对白。默认。
  narrationAndDialogue,

  /// 只念对白。
  dialogueOnly,
}

/// 一个念稿单元：谁说的、念什么、念完停多久。
class Utterance {
  const Utterance({
    required this.speaker,
    required this.text,
    required this.pauseAfterMs,
  });

  /// 说话人：角色 id（`char:灵梦`）；旁白为空串。
  final String speaker;

  /// 要念的文字（已清洗，不含 Markdown 记号）。
  final String text;

  /// 念完后停多久（毫秒）。
  final int pauseAfterMs;

  bool get isNarration => speaker.isEmpty;
}

/// 念稿模块本身。
class ScriptReader {
  const ScriptReader({this.scope = ReadScope.narrationAndDialogue});

  final ReadScope scope;

  static const int pauseSentence = 300;
  static const int pauseComma = 120;
  static const int pauseParagraph = 600;
  static const int pauseHeading = 550;
  static const int pauseListItem = 450;
  static const int pauseSpeakerChange = 400;
  static const int pauseDefault = 200;

  /// 事件流 → 念稿单元。
  ///
  /// 说话声只念**真的出声**的：`visual` / `mental` / `digital`，以及
  /// `mouthed` / `written` / `telepathic` / `transmitted` 这些形式都跳过——
  /// 把写在纸上的字念出声，是另一回事。
  /// 被拒绝的事件也跳过。
  List<Utterance> readEvents(Iterable<WorldEvent> events) {
    final List<Utterance> out = <Utterance>[];
    for (final WorldEvent e in events) {
      if (e.status == WorldEventStatus.rejected) continue;
      final bool speech = e.kind == WorldEventKind.speech;
      if (speech && !_isVoiced(e.delivery)) continue;
      if (!speech && scope == ReadScope.dialogueOnly) continue;

      final String text = _flatText(e.content);
      if (text.isEmpty) continue;
      out.add(
        Utterance(
          // 动作由旁白念；台词归说话的角色的声线。
          speaker: speech ? e.actor : '',
          text: text,
          pauseAfterMs: 0,
        ),
      );
    }
    return _finish(out);
  }

  /// Markdown 文档 → 念稿单元。
  ///
  /// 标题 / 段落 / 列表项各算一段；代码块、表格、图片、分隔线跳过。
  /// 文档全部按旁白念（没有说话人信息）。
  ///
  /// [scope] 只管事件流里“旁白 / 对白”的取舍；文档没有对白结构，不受它影响。
  List<Utterance> readMarkdown(String source) {
    final List<_Block> blocks = _blocksOf(source);
    final List<Utterance> out = <Utterance>[
      for (final _Block b in blocks)
        Utterance(speaker: '', text: b.text, pauseAfterMs: b.pause),
    ];
    return _finish(out);
  }

  /// 只念真的出声的台词。
  static bool _isVoiced(Delivery d) {
    if (d.channel == DeliveryChannel.visual ||
        d.channel == DeliveryChannel.mental ||
        d.channel == DeliveryChannel.digital) {
      return false;
    }
    const Set<String> silentForms = <String>{
      'mouthed',
      'written',
      'telepathic',
      'transmitted',
    };
    return !silentForms.contains(d.form);
  }

  /// 事件正文是单段文字，拍平成一行。
  String _flatText(String raw) =>
      _blocksOf(raw).map((_Block b) => b.text).join(' ').trim();

  /// 补上停顿：标点决定基础停顿，换说话人至少停 [pauseSpeakerChange]。
  List<Utterance> _finish(List<Utterance> list) {
    final List<Utterance> out = <Utterance>[];
    for (int i = 0; i < list.length; i++) {
      final Utterance u = list[i];
      int pause = u.pauseAfterMs > 0 ? u.pauseAfterMs : _pauseOf(u.text);
      if (i + 1 < list.length && list[i + 1].speaker != u.speaker) {
        if (pause < pauseSpeakerChange) pause = pauseSpeakerChange;
      }
      out.add(Utterance(speaker: u.speaker, text: u.text, pauseAfterMs: pause));
    }
    return out;
  }

  /// 句末 / 逗号这类标点之后该停多久。
  static int _pauseOf(String text) {
    String t = text.trimRight();
    // 收尾的引号、括号不改变句子停没停，往前再看一个字。
    const String closers = '”’"）)】》';
    while (t.isNotEmpty && closers.contains(t[t.length - 1])) {
      t = t.substring(0, t.length - 1).trimRight();
    }
    if (t.isEmpty) return 0;
    final String last = t[t.length - 1];
    if ('。！？!?…'.contains(last)) return pauseSentence;
    if ('，,、；;：:'.contains(last)) return pauseComma;
    return pauseDefault;
  }

  // ── Markdown ────────────────────────────────────────────────────────────

  /// 文档拆成“段”：每段一句完整的念稿文字 + 段后停顿。
  List<_Block> _blocksOf(String source) {
    final String src = source.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (src.trim().isEmpty) return const <_Block>[];

    List<md.Node> nodes;
    try {
      nodes = md.Document(
        extensionSet: md.ExtensionSet.gitHubFlavored,
      ).parseLines(src.split('\n'));
    } catch (_) {
      // 解析器出错：按纯文字念，不装作有格式。
      final String t = _plain(src.replaceAll(RegExp(r'[#>*_`~\[\]()]'), ' '));
      return t.isEmpty ? const <_Block>[] : <_Block>[_Block(t, pauseParagraph)];
    }

    final List<_Block> out = <_Block>[];
    for (final md.Node n in nodes) {
      _collect(n, out);
    }
    return out;
  }

  void _collect(md.Node n, List<_Block> out) {
    if (n is md.Text) {
      _add(n.text, pauseParagraph, out);
      return;
    }
    if (n is! md.Element) return;

    switch (n.tag) {
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        _add(n.textContent, pauseHeading, out);
      case 'p':
        _add(n.textContent, pauseParagraph, out);
      case 'li':
        _add(n.textContent, pauseListItem, out);
      case 'blockquote':
      case 'ul':
      case 'ol':
        for (final md.Node c in n.children ?? const <md.Node>[]) {
          _collect(c, out);
        }
      // 代码、表格、图片、分隔线：不念。
      case 'pre':
      case 'table':
      case 'img':
      case 'hr':
        break;
      default:
        // 不认识的块：有文字就按段落念，没有就交给子节点。
        if (n.textContent.trim().isNotEmpty) {
          _add(n.textContent, pauseParagraph, out);
        } else {
          for (final md.Node c in n.children ?? const <md.Node>[]) {
            _collect(c, out);
          }
        }
    }
  }

  void _add(String raw, int pause, List<_Block> out) {
    final String t = _plain(raw);
    if (t.isEmpty) return;
    out.add(_Block(t, pause));
  }

  /// 告警块的行首 `[!NOTE]` 换成中文小标题，别让 TTS 念方括号。
  static final RegExp _alert = RegExp(
    r'\[!(note|tip|important|caution|warning)\]',
    caseSensitive: false,
  );

  static String _alertTitle(String type) => switch (type.toLowerCase()) {
    'note' => '注意',
    'tip' => '提示',
    'important' => '重要',
    'caution' => '小心',
    'warning' => '警告',
    _ => '',
  };

  /// 纯文字：去告警标记、并掉换行、压掉多余空白。
  static String _plain(String raw) {
    String s = raw.replaceAllMapped(_alert, (Match m) {
      final String title = _alertTitle(m.group(1) ?? '');
      return title.isEmpty ? '' : '$title：';
    });
    s = s.replaceAll(RegExp(r'<!--[\s\S]*?-->'), ' ');
    s = s.replaceAll('\u00a0', ' ');

    // 中文之间的换行直接接上；两边都是 ASCII 的才补一个空格。
    String out = '';
    for (final String line0 in s.split('\n')) {
      final String line = line0.trim();
      if (line.isEmpty) continue;
      if (out.isNotEmpty &&
          _isAscii(out.codeUnitAt(out.length - 1)) &&
          _isAscii(line.codeUnitAt(0))) {
        out += ' ';
      }
      out += line;
    }
    return out.replaceAll(RegExp(r'[ \t]+'), ' ').trim();
  }

  static bool _isAscii(int c) => c < 128;
}

/// 一块要念的文字 + 段后停顿。
class _Block {
  const _Block(this.text, this.pause);

  final String text;
  final int pause;
}
