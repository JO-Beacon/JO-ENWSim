import 'perception.dart';

/// 一条 GM_NARRATE 硬校验违规。程序只报事实，不改写正文。
class RenderViolation {
  const RenderViolation({
    required this.code,
    required this.message,
  });

  final String code;
  final String message;

  Map<String, Object?> toJson() => <String, Object?>{
        'code': code,
        'message': message,
      };

  factory RenderViolation.fromJson(Map<String, Object?> j) => RenderViolation(
        code: '${j['code'] ?? ''}',
        message: '${j['message'] ?? ''}',
      );
}

class RenderCheckResult {
  const RenderCheckResult(this.violations);

  final List<RenderViolation> violations;

  bool get ok => violations.isEmpty;
}

/// GM_NARRATE 的程序硬校验：
///   - public_text 不能为空；
///   - 引号里的台词必须能在事件里找到（逐字子串）；
///   - 有名字的角色必须是事件参与者、在场者，或事件里提到的人；
///   - 数字必须有事件依据。
///
/// 它不判断“动作有没有发生”“心理写得对不对”；那些交 GM_REVIEW_NARRATION AI 和人工。
/// 也不检查 god_note：god_note 是给读者/上帝的补充，不进记忆。
class RenderChecker {
  const RenderChecker();

  RenderCheckResult check({
    required String publicText,
    required String godNote,
    required List<WorldEvent> events,
    required NarrativeScene scene,
    List<String> entityNames = const <String>[],
  }) {
    final List<RenderViolation> violations = <RenderViolation>[];
    final String text = publicText.trim();
    if (text.isEmpty) {
      violations.add(const RenderViolation(
        code: 'empty_public_text',
        message: 'public_text 不能为空',
      ));
    }

    _checkQuotes(text, events, violations);
    _checkNames(text, events, scene, violations);
    _checkEntities(text, events, entityNames, violations);
    _checkNumbers(text, events, violations);
    return RenderCheckResult(violations);
  }

  void _checkQuotes(
    String text,
    List<WorldEvent> events,
    List<RenderViolation> violations,
  ) {
    final int open = '“'.allMatches(text).length;
    final int close = '”'.allMatches(text).length;
    if (open != close) {
      violations.add(RenderViolation(
        code: 'unmatched_quote',
        message: 'public_text 的引号没有配对：$open 个“，$close 个”',
      ));
    }
    for (final String raw in _quoteBodies(text)) {
      final String body = _normalizeQuoteText(raw);
      if (body.isEmpty) {
        violations.add(const RenderViolation(
          code: 'empty_quote',
          message: 'public_text 里有空引号',
        ));
        continue;
      }
      final bool found = events.any(
        (WorldEvent e) => _normalizeQuoteText(e.content).contains(body),
      );
      if (!found) {
        violations.add(RenderViolation(
          code: 'invented_quote',
          message: '台词在事件里找不到逐字依据：“$raw”',
        ));
      }
    }
  }

  /// 支持嵌套引号：外层的“ ...”里可以再有“...”，返回最外层的内容。
  List<String> _quoteBodies(String text) {
    final List<String> out = <String>[];
    int start = -1;
    int depth = 0;
    for (int i = 0; i < text.length; i++) {
      final String c = text[i];
      if (c == '“') {
        if (depth == 0) start = i;
        depth++;
      } else if (c == '”' && depth > 0) {
        depth--;
        if (depth == 0 && start >= 0) {
          out.add(text.substring(start + 1, i));
          start = -1;
        }
      }
    }
    return out;
  }

  /// GM_NARRATE 可能把嵌套引号从“”改成‘’，或者调整空白；比较时只留文字内容。
  String _normalizeQuoteText(String s) {
    return s
        .replaceAll(RegExp(r'[“”‘’「」]'), '')
        .replaceAll(RegExp(r'\s+'), '');
  }

  void _checkNames(
    String text,
    List<WorldEvent> events,
    NarrativeScene scene,
    List<RenderViolation> violations,
  ) {
    final Set<String> allowed = <String>{
      for (final CharacterSnapshot c in scene.cast) c.name,
      for (final WorldEvent e in events)
        if (e.actor.replaceFirst('char:', '').isNotEmpty)
          e.actor.replaceFirst('char:', ''),
      for (final WorldEvent e in events)
        if ((e.target ?? '').replaceFirst('char:', '').isNotEmpty)
          (e.target ?? '').replaceFirst('char:', ''),
    };
    // 角色自己的 alias 也可能出现在正文里。
    for (final CharacterSnapshot c in scene.cast) {
      for (final String alias in c.aliases.values) {
        if (alias.trim().isNotEmpty) allowed.add(alias.trim());
      }
    }
    // 事件里提到的已知名字也算有依据（例如回忆里的妹红）。
    final String eventText = events.map(_evidenceText).join('\n');
    for (final String name in scene.names.values) {
      if (name.trim().isNotEmpty && eventText.contains(name)) {
        allowed.add(name);
      }
    }
    for (final String name in scene.names.values) {
      if (name.trim().isEmpty) continue;
      if (!text.contains(name)) continue;
      if (!allowed.contains(name)) {
        violations.add(RenderViolation(
          code: 'unknown_name',
          message: '正文提到“$name”，但该角色既不在场，也不在事件里',
        ));
      }
    }
  }

  void _checkEntities(
    String text,
    List<WorldEvent> events,
    List<String> entityNames,
    List<RenderViolation> violations,
  ) {
    if (entityNames.isEmpty) return;
    final String eventText = events
        .map(_evidenceText)
        .join('\n');
    for (final String name in entityNames) {
      final String n = name.trim();
      if (n.isEmpty || !text.contains(n)) continue;
      if (!eventText.contains(n)) {
        violations.add(RenderViolation(
          code: 'unknown_entity',
          message: '正文提到实体“$n”，但事件里没有它',
        ));
      }
    }
  }

  void _checkNumbers(
    String text,
    List<WorldEvent> events,
    List<RenderViolation> violations,
  ) {
    final String eventText = events.map(_evidenceText).join('\n');
    final Set<int> allowed = _numberMentions(eventText);
    final Set<int> used = _numberMentions(text);
    for (final int n in used) {
      if (!allowed.contains(n)) {
        violations.add(RenderViolation(
          code: 'invented_number',
          message: '正文出现数字 $n，但事件里没有这个数字',
        ));
      }
    }
  }

  static final RegExp _arabic = RegExp(r'\d+');

  String _evidenceText(WorldEvent e) => <String>[
    e.summary, e.result, e.deliveryNote, e.distanceNote, e.manner,
  ].join('\n');
  static final RegExp _chinese = RegExp(
    r'([零一二三四五六七八九十百千万两]+)'
    r'(个|名|人|位|只|匹|辆|艘|架|门|间|处|道|条|根|张|块|片|份|包|瓶|盒|箱|袋|本|页|层|排|列)',
  );

  Set<int> _numberMentions(String text) {
    final Set<int> out = <int>{};
    for (final RegExpMatch m in _arabic.allMatches(text)) {
      final int? n = int.tryParse(m.group(0)!);
      if (n != null) out.add(n);
    }
    for (final RegExpMatch m in _chinese.allMatches(text)) {
      final int? n = _chineseToInt(m.group(1)!);
      if (n != null) out.add(n);
    }
    return out;
  }

  static int? _chineseToInt(String s) {
    const Map<String, int> digits = <String, int>{
      '零': 0,
      '一': 1,
      '二': 2,
      '两': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
    };
    const Map<String, int> units = <String, int>{
      '十': 10,
      '百': 100,
      '千': 1000,
    };
    int total = 0;
    int section = 0;
    int number = 0;
    for (int i = 0; i < s.length; i++) {
      final String c = s[i];
      final int? d = digits[c];
      if (d != null) {
        number = d;
        continue;
      }
      final int? u = units[c];
      if (u != null) {
        section += (number == 0 ? 1 : number) * u;
        number = 0;
        continue;
      }
      if (c == '万') {
        total += (section + number) * 10000;
        section = 0;
        number = 0;
        continue;
      }
      return null;
    }
    final int value = total + section + number;
    return value == 0 && !s.contains('零') ? null : value;
  }
}
