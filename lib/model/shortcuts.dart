// 快捷键。
//
// 一张表：动作 id → 键位字符串。用户可以改，改完存进设置。
// 键位字符串自己定格式，够用就行：
//   'Enter' / 'Escape' / 'Ctrl+E' / 'Ctrl+,'
// 解析成 Flutter 的 SingleActivator 在下面。

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 动作 id。
class JoKey {
  static const String send = 'send';
  static const String newline = 'newline';
  static const String newWorld = 'newWorld';
  static const String edit = 'edit';
  static const String settings = 'settings';
}

/// 一个动作：id、界面上叫什么、默认键位。
typedef JoKeyItem = ({String id, String label, String fallback});

/// 全部动作。**顺序就是界面上的顺序。**
///
/// **不含 Esc。** Esc 是多功能键（关弹窗、取消、退出），
/// 它只做“弹窗自己那件事”，不归快捷键系统管。
const List<JoKeyItem> kJoKeys = <JoKeyItem>[
  // 发言框是多行的，两个动作各占一个键，都能在设置里改。
  // 默认：回车换行（多行框的直觉）、Ctrl+回车发送（不会误发）。
  (id: JoKey.send, label: '发送', fallback: 'Ctrl+Enter'),
  (id: JoKey.newline, label: '换行', fallback: 'Enter'),
  (id: JoKey.newWorld, label: '新建世界', fallback: 'Ctrl+N'),
  (id: JoKey.edit, label: '编辑这个世界', fallback: 'Ctrl+E'),
  (id: JoKey.settings, label: '打开设置', fallback: 'Ctrl+,'),
];

/// 默认键位。
Map<String, String> joDefaultKeys() => <String, String>{
  for (final JoKeyItem k in kJoKeys) k.id: k.fallback,
};

/// 某个动作的默认键位。界面取值时用它，**不要再在别处写死字符串** ——
/// 否则默认值一改，这里忘了改，实际行为就不是表里看到的那个。
String joFallback(String id) =>
    kJoKeys.firstWhere((JoKeyItem k) => k.id == id).fallback;

/// 两个键位字符串是不是**同一个实际按键**。
///
/// 大小写、空格、修饰键顺序都不计较；`esc` / `escape`、`ctrl` / `control`
/// 这类同义词也归一。空串跟任何东西都不相等（= 没绑）。
bool joSameKey(String a, String b) {
  final String x = _joNormKey(a);
  return x.isNotEmpty && x == _joNormKey(b);
}

String _joNormKey(String s) {
  final List<String> parts = s
      .toLowerCase()
      .split('+')
      .map((String p) => p.trim())
      .where((String p) => p.isNotEmpty)
      .map(
        (String p) => switch (p) {
          'control' => 'ctrl',
          'esc' => 'escape',
          _ => p,
        },
      )
      .toList();
  if (parts.isEmpty) return '';
  final String key = parts.removeLast();
  parts.sort();
  return <String>[...parts, key].join('+');
}

/// 把 [id] 设成 [spec]，并且把**用着同一个键**的其它动作清空（变成未设置）。
///
/// 一个键只能给一个动作用：后设的赢，先设的让位。
Map<String, String> joSetKey(Map<String, String> keys, String id, String spec) {
  final Map<String, String> next = <String, String>{...keys};
  final String want = spec.trim();
  if (want.isNotEmpty) {
    for (final JoKeyItem k in kJoKeys) {
      if (k.id == id) continue;
      final String cur = next[k.id] ?? k.fallback;
      if (joSameKey(cur, want)) next[k.id] = '';
    }
  }
  next[id] = spec;
  return next;
}

/// 把键位字符串解析成 Flutter 的快捷键。
///
/// 认不出来就返回 null —— **不猜**，界面上会如实说这条用不了。
ShortcutActivator? joActivator(String spec) {
  final String s = spec.trim();
  if (s.isEmpty) return null;
  final List<String> parts = s.split('+');
  final String key = parts.removeLast().trim();
  if (key.isEmpty) return null;
  bool ctrl = false;
  bool shift = false;
  bool alt = false;
  for (final String p in parts) {
    switch (p.trim().toLowerCase()) {
      case 'ctrl':
      case 'control':
        ctrl = true;
      case 'shift':
        shift = true;
      case 'alt':
        alt = true;
      default:
        return null;
    }
  }
  final LogicalKeyboardKey? code = _keys[key.toLowerCase()];
  if (code == null) return null;
  return SingleActivator(code, control: ctrl, shift: shift, alt: alt);
}

/// 认得的键名。只列常用的一批；认不出的会在页面上标出来。
const Map<String, LogicalKeyboardKey> _keys = <String, LogicalKeyboardKey>{
  'enter': LogicalKeyboardKey.enter,
  'escape': LogicalKeyboardKey.escape,
  'esc': LogicalKeyboardKey.escape,
  'space': LogicalKeyboardKey.space,
  'tab': LogicalKeyboardKey.tab,
  ',': LogicalKeyboardKey.comma,
  '.': LogicalKeyboardKey.period,
  '/': LogicalKeyboardKey.slash,
  'a': LogicalKeyboardKey.keyA,
  'b': LogicalKeyboardKey.keyB,
  'c': LogicalKeyboardKey.keyC,
  'd': LogicalKeyboardKey.keyD,
  'e': LogicalKeyboardKey.keyE,
  'f': LogicalKeyboardKey.keyF,
  'g': LogicalKeyboardKey.keyG,
  'h': LogicalKeyboardKey.keyH,
  'i': LogicalKeyboardKey.keyI,
  'j': LogicalKeyboardKey.keyJ,
  'k': LogicalKeyboardKey.keyK,
  'l': LogicalKeyboardKey.keyL,
  'm': LogicalKeyboardKey.keyM,
  'n': LogicalKeyboardKey.keyN,
  'o': LogicalKeyboardKey.keyO,
  'p': LogicalKeyboardKey.keyP,
  'q': LogicalKeyboardKey.keyQ,
  'r': LogicalKeyboardKey.keyR,
  's': LogicalKeyboardKey.keyS,
  't': LogicalKeyboardKey.keyT,
  'u': LogicalKeyboardKey.keyU,
  'v': LogicalKeyboardKey.keyV,
  'w': LogicalKeyboardKey.keyW,
  'x': LogicalKeyboardKey.keyX,
  'y': LogicalKeyboardKey.keyY,
  'z': LogicalKeyboardKey.keyZ,
  '1': LogicalKeyboardKey.digit1,
  '2': LogicalKeyboardKey.digit2,
  '3': LogicalKeyboardKey.digit3,
  '4': LogicalKeyboardKey.digit4,
  '5': LogicalKeyboardKey.digit5,
  '6': LogicalKeyboardKey.digit6,
  '7': LogicalKeyboardKey.digit7,
  '8': LogicalKeyboardKey.digit8,
  '9': LogicalKeyboardKey.digit9,
  '0': LogicalKeyboardKey.digit0,
};
