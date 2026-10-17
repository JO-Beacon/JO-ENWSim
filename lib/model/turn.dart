// 回合数据。字段按 `AGENTS/回合数据.md` 定。
//
// 一个类装全部：`kind` 区分是哪一步，用不到的字段留空。
// 步骤种类固定七种，不会长。
//
// **这不只是"跑完记一笔"**：过程产物（谁被框进来、每个角色感知到什么、
// 最后选中谁）都留着 —— 出了问题能回看"为什么这回合是人物3 而不是人物4"。

import 'char_choices.dart';
import 'llm_client.dart';
import 'model_plan.dart';

// 步骤 id 的**取值域只有一处**：model_plan.dart 的 `kSteps`
// （`A0` / `A1` / `A2` / `A3` / `A4` / `B1` / `B2`）。
//
// 这里存**字符串 id**，不另立一个 enum：
//   · 那个 StepKind 是 record（id + title + hint），不是 enum；
//   · const 列表的元素不能当常量表达式，demo 数据里用不了它。
// 所以两边共用的是**同一个 id 空间**，定义仍然只有一份。

/// 这个步骤 id 认不认得。
bool isKnownStep(String id) => kSteps.any((StepKind s) => s.id == id);

/// 一个回合。
class TurnStep {
  const TurnStep({
    required this.kind,
    this.who = '',
    this.time = '',
    this.text = '',
    this.candidates = const <String>[],
    this.perceptions = const <String, String>{},
    this.chosen = '',
    this.judgment = '',
    this.error,
    this.model,
    this.choices,
    this.usage,
  });

  final String kind;

  /// 谁：人物名（行为），或**旁白**（上帝那一侧各步）。
  final String who;

  /// 时间标签。**文本，不是时间戳** —— 由 A 决定怎么写，只显示，不参与排版。
  final String time;

  /// 正文。序列上真正显示的就是它。
  final String text;

  /// 这一步框选出的参与角色（A₂）。
  final List<String> candidates;

  /// 每个参与角色感知到了什么（B₁）：角色名 → 感知内容。
  final Map<String, String> perceptions;

  /// 最后框定的那一个（A₃）。
  final String chosen;

  /// A₀ 的分裂判断 / A₁ 推进了什么 / A₄ 是否合并。
  final String judgment;

  /// 失败或取消时的一句话。**失败也留痕**。
  final String? error;

  /// 这一步用的哪个模型（服务商 + 模型）。没跑就为 null。
  final ModelPick? model;

  /// 这一步用的**选择**。是当时的快照 —— 之后角色改了选择，
  /// 这一步当初用的是什么仍然看得见。
  final CharChoices? choices;

  /// 花了多少。缓存命中与未命中**分开**（价差 50 倍）。
  final LlmUsage? usage;

  bool get ok => error == null;

  /// 序列上这一步是不是旁白（上帝那一侧说的）。
  /// 画布靠它决定用什么颜色、什么字重。
  bool get isNarration => who == '旁白';

  /// 序列画布上会不会出现这一步。
  ///
  /// 一步 = **一次行为**。所以只有两种上画布：
  /// 环境更新（A1）与角色行为（B2）。
  /// 其余（A0 / AD / A2 / A3 / A4）是**判断**，正文在 `judgment` 里；
  /// B1 是过程。它们留在库里可追溯，但不占画布 ——
  /// 否则画布上会多出一排空白卡片。
  bool get showsOnCanvas => kind == 'A1' || kind == 'B2';

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'who': who,
    'time': time,
    'text': text,
    'candidates': candidates,
    'perceptions': perceptions,
    'chosen': chosen,
    'judgment': judgment,
    'error': error,
    'model': model?.key,
    'choices': choices?.toJson(),
    'usage': usage == null
        ? null
        : <String, Object?>{
            'input': usage!.input,
            'output': usage!.output,
            'cacheHit': usage!.cacheHit,
            'cacheMiss': usage!.cacheMiss,
          },
  };

  /// 缺 = 默认；有但认不出 = 抛（不静默降级）。
  static TurnStep fromJson(Map<String, Object?> j) {
    final String kind = '${j['kind'] ?? ''}';
    if (!isKnownStep(kind)) {
      throw FormatException('认不出的步骤类型：$kind');
    }
    final Object? u = j['usage'];
    final Object? c = j['choices'];
    final Object? m = j['model'];
    return TurnStep(
      kind: kind,
      who: '${j['who'] ?? ''}',
      time: '${j['time'] ?? ''}',
      text: '${j['text'] ?? ''}',
      candidates: j['candidates'] is List
          ? (j['candidates']! as List).whereType<String>().toList()
          : const <String>[],
      perceptions: j['perceptions'] is Map
          ? (j['perceptions']! as Map).map(
              (Object? a, Object? b) => MapEntry<String, String>('$a', '$b'),
            )
          : const <String, String>{},
      chosen: '${j['chosen'] ?? ''}',
      judgment: '${j['judgment'] ?? ''}',
      error: j['error'] is String ? j['error']! as String : null,
      model: m is String && m.isNotEmpty ? ModelPick.of(m) : null,
      choices: c is Map
          ? CharChoices.fromJson(c.cast<String, Object?>())
          : null,
      usage: u is Map
          ? LlmUsage(
              input: _int(u['input']),
              output: _int(u['output']),
              cacheHit: _int(u['cacheHit']),
              cacheMiss: _int(u['cacheMiss']),
            )
          : null,
    );
  }

  static int _int(Object? v) => v is num ? v.toInt() : 0;
}
