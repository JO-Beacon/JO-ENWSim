/// 时间标签：**文本，不是时间戳**。
///
/// 由产出事件的那一步自己写（GM_ENV_UPDATE / GM_RESOLVE_ACTION / CH_ACT /
/// GM_PARSE_INPUT），挂在它产生的事件上；程序只校验格式，不改写内容。
/// 只显示，不参与排版，也不能拿来当坐标轴。
///
/// 约定：
/// - 缺 = 空。不伪造“现在”这类假时间，界面上没写就是没标。
/// - 写了但不合格（时间戳、纯数字、换行、太长）= 报错，回原步骤重写。
library;

/// 时间标签的字数上限（按 rune 算）。一句话的模糊时间，不是叙述。
const int kMaxTimeLabelRunes = 24;

/// 规范化：只去首尾空白，不做别的加工。
String normalizeTimeLabel(Object? raw) => '${raw ?? ''}'.trim();

final RegExp _clockLike = RegExp(r'\d{1,2}\s*[:：]\s*\d{2}');
final RegExp _dateLike = RegExp(r'\d{4}\s*[-/.年]\s*\d{1,2}\s*[-/.月]\s*\d{1,2}');
final RegExp _monthDayLike = RegExp(r'\d{1,2}\s*月\s*\d{1,2}\s*[日号]');
final RegExp _digitsOnly = RegExp(r'^\d+$');

/// 返回 null 表示合格；否则返回**给模型看**的错误文案。
///
/// 空字符串合格：缺省就是不标时间。
String? timeLabelError(String label) {
  if (label.isEmpty) return null;
  if (label.contains('\n') || label.contains('\r')) {
    return 'time_label 不能换行：$label';
  }
  if (label.runes.length > kMaxTimeLabelRunes) {
    return 'time_label 超过 $kMaxTimeLabelRunes 字，写一句短的时间标记：$label';
  }
  if (_digitsOnly.hasMatch(label)) {
    return 'time_label 不能是纯数字，用文本描述：$label';
  }
  if (_clockLike.hasMatch(label)) {
    return 'time_label 不能写具体时刻，用文本描述：$label';
  }
  if (_dateLike.hasMatch(label)) {
    return 'time_label 不能写日期，用文本描述：$label';
  }
  if (_monthDayLike.hasMatch(label)) {
    return 'time_label 不能写日期，用文本描述：$label';
  }
  return null;
}
