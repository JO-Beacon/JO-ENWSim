// 我们自己的 Remix Icon 常量。
//
// **不经过任何第三方包。**
//   · 字体：官方仓库 Remix-Design/remixicon 的 fonts/remixicon.ttf
//     → assets/fonts/remixicon.ttf
//   · 码点：同一个仓库 fonts/remixicon.css 里公布的
//     （形如 `.ri-add-line:before { content: "\ea13"; }`）
//
// 只收我们要用的这些。官方一共 3229 个，没必要整包引进来。
//
// 许可：Remix Icon License v1.0 — https://remixicon.com
// 用了这套图标的地方，发行时要把那条署名和许可正文一起附出去。

import 'package:flutter/widgets.dart';

/// 字体族名。**必须跟 pubspec.yaml 里 fonts: 那个 family 一模一样。**
const String _kFamily = 'RemixIcon';

/// Remix Icon 的图标（我们用到的那批）。
///
/// 用法：`Icon(JoIcons.add, size: 18, color: ...)`。
///
/// 要加图标：去官方 `fonts/remixicon.css` 搜 `.ri-名字-line:before`，
/// 抄它 `content: "\xxxx"` 里的那串十六进制，在这里加一行。
class JoIcons {
  JoIcons._();

  // —— 通用动作
  static const IconData add = IconData(0xea13, fontFamily: _kFamily);
  static const IconData close = IconData(0xeb99, fontFamily: _kFamily);
  static const IconData check = IconData(0xeb7b, fontFamily: _kFamily);
  static const IconData more = IconData(0xef79, fontFamily: _kFamily);
  static const IconData refresh = IconData(0xf064, fontFamily: _kFamily);
  static const IconData search = IconData(0xf0d1, fontFamily: _kFamily);
  // —— 界面
  static const IconData settings = IconData(0xf0ee, fontFamily: _kFamily);
  // 明暗切换：现在显示当前是哪一套
  static const IconData sun = IconData(0xf1bf, fontFamily: _kFamily);
  static const IconData moon = IconData(0xef75, fontFamily: _kFamily);

  // —— 编辑
  static const IconData edit = IconData(0xec86, fontFamily: _kFamily);
  static const IconData pencil = IconData(0xefe0, fontFamily: _kFamily);
  static const IconData delete = IconData(0xec2a, fontFamily: _kFamily);
  static const IconData save = IconData(0xf0b3, fontFamily: _kFamily);

  // —— 导航
  static const IconData arrowLeft = IconData(0xea60, fontFamily: _kFamily);
  static const IconData history = IconData(0xee17, fontFamily: _kFamily);
  static const IconData links = IconData(0xeeb8, fontFamily: _kFamily);

  // —— 推进
  static const IconData play = IconData(0xf00b, fontFamily: _kFamily);
  static const IconData pause = IconData(0xefd8, fontFamily: _kFamily);
  static const IconData skipBack = IconData(0xf140, fontFamily: _kFamily);
  static const IconData skipForward = IconData(0xf144, fontFamily: _kFamily);
  static const IconData loader = IconData(0xeeca, fontFamily: _kFamily);

  // —— 世界与角色
  static const IconData cpu = IconData(0xebf0, fontFamily: _kFamily);
  static const IconData brain = IconData(0xf2f7, fontFamily: _kFamily);
  static const IconData book = IconData(0xeadb, fontFamily: _kFamily);
  static const IconData user = IconData(0xf264, fontFamily: _kFamily);
  static const IconData global = IconData(0xedcf, fontFamily: _kFamily);
  static const IconData eye = IconData(0xecb5, fontFamily: _kFamily);
  static const IconData run = IconData(0xf0a5, fontFamily: _kFamily);
  static const IconData sparkling = IconData(0xf36d, fontFamily: _kFamily);

  // —— 输入
  // 发送用 send-plane（斜的那只）。
  static const IconData send = IconData(0xf0da, fontFamily: _kFamily);
  static const IconData camera = IconData(0xeb31, fontFamily: _kFamily);
  static const IconData file = IconData(0xeceb, fontFamily: _kFamily);
  static const IconData image = IconData(0xee4b, fontFamily: _kFamily);
  static const IconData mic = IconData(0xef50, fontFamily: _kFamily);
}
