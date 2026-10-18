// 栏与栏之间那条能拖的缝。
//
// 做法参照 JO-Composer（它用的是 docking + multi_split_view），关键是这四条：
//
//   1. **抓得到**：能点的区域比画出来的线宽得多。线平时 1px、hover 2px，
//      但手能抓的地方有 10px —— 以前只有 6px，还得对准了才行。
//   2. **不粘手**：按下那一刻记下“当时的宽度”和“鼠标当时的位置”，之后每次
//      都用 `当前鼠标 − 按下位置` 重算宽度，**不是一帧一帧加增量**。
//      增量法一旦被最小宽度卡住，鼠标往回拖时得先“补回”超出的那段，
//      手感就是拖不动／发飘；绝对值法没有这个毛病。
//   3. **有边界**：这一栏和旁边那一栏都有最小宽度，中间那块画布不许被挤没；
//      最大宽度按窗口现算（父级传进来），窗口拉小也不会撑破。
//   4. **有反馈**：hover 变粗变亮、按住时一直亮着；双击回到默认宽度。

import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'common.dart';

/// 拖动条能点的宽度（画出来的线仍然只有 1~2px）。
const double kJoSplitterHit = 10;

/// 两根拖动条一共占掉多少横向空间（算“画布还剩多少”时要用）。
const double kJoSplitterTotal = kJoSplitterHit * 2;

class JoSplitter extends StatefulWidget {
  const JoSplitter({
    super.key,
    required this.palette,
    required this.width,
    required this.minWidth,
    required this.maxWidth,
    required this.defaultWidth,
    required this.growsRight,
    required this.onResize,
    this.onResizeEnd,
  });

  final JoPalette palette;

  /// 拖动条负责的那一栏现在的宽度（按下时会被记下来当初值）。
  final double width;

  final double minWidth;

  /// 最大宽度。父级按窗口宽度算好传进来，窗口变小就不会撑破。
  final double maxWidth;

  /// 双击复位用的宽度。
  final double defaultWidth;

  /// 往右拖是变宽（左栏，true）还是变窄（右栏，false）。
  final bool growsRight;

  /// 拖的时候回报“这一栏应该是多宽”。
  final ValueChanged<double> onResize;

  /// 松手时喊一声（存盘用）。
  final VoidCallback? onResizeEnd;

  @override
  State<JoSplitter> createState() => _JoSplitterState();
}

class _JoSplitterState extends State<JoSplitter> {
  /// 按下那一刻：栏宽 + 鼠标 x。拖动全程都从这两个数算绝对值。
  double _startWidth = 0;
  double _startX = 0;

  bool _hover = false;
  bool _active = false;

  double get _clamped =>
      widget.width.clamp(widget.minWidth, _safeMax).toDouble();

  /// maxWidth 正常情况下不会小于 minWidth；真被压成这样也先按 min 算，
  /// 免得 clamp 里 lower > upper 直接抛。
  double get _safeMax =>
      widget.maxWidth < widget.minWidth ? widget.minWidth : widget.maxWidth;

  void _apply(double want) =>
      widget.onResize(want.clamp(widget.minWidth, _safeMax));

  void _start(DragStartDetails d) {
    _startWidth = _clamped;
    _startX = d.globalPosition.dx;
    setState(() => _active = true);
  }

  void _update(DragUpdateDetails d) {
    final double moved = d.globalPosition.dx - _startX;
    _apply(widget.growsRight ? _startWidth + moved : _startWidth - moved);
  }

  void _end() {
    setState(() => _active = false);
    widget.onResizeEnd?.call();
  }

  @override
  Widget build(BuildContext context) {
    final JoPalette p = widget.palette;
    final bool lit = _hover || _active;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: _start,
        onHorizontalDragUpdate: _update,
        onHorizontalDragEnd: (_) => _end(),
        onHorizontalDragCancel: _end,
        onDoubleTap: () => _apply(widget.defaultWidth),
        child: SizedBox(
          width: kJoSplitterHit,
          height: double.infinity,
          child: Center(
            // 平时就是一条分隔线；hover / 按住时变粗变亮，告诉人“这儿能拖”。
            child: AnimatedContainer(
              duration: kJoTapMs,
              curve: Curves.easeOut,
              width: lit ? 2 : 1,
              color: lit ? p.accent : p.border,
            ),
          ),
        ),
      ),
    );
  }
}
