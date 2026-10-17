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
  (id: JoKey.send, label: '发送', fallback: 'Enter'),
  (id: JoKey.newWorld, label: '新建世界', fallback: 'Ctrl+N'),
  (id: JoKey.edit, label: '编辑这个世界', fallback: 'Ctrl+E'),
  (id: JoKey.settings, label: '打开设置', fallback: 'Ctrl+,'),
];

/// 默认键位。
Map<String, String> joDefaultKeys() => <String, String>{
  for (final JoKeyItem k in kJoKeys) k.id: k.fallback,
};

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
