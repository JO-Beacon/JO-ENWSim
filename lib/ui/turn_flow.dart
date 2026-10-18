// 右栏那张“回合流程”图。收起时只占一行，展开时占满右栏、一眼看全。
//
// 画法：自己排版 + CustomPaint 画全部内容（菱形判断 / 方框动作 / 分组框 /
// 带标签的箭头）。整张图按固定逻辑尺寸画好，再整体缩放 ——
// 这样面板怎么拉，图都保持比例，不会错位。
//
// 不引任何依赖，也不用 mermaid。
//
// 配色照 `AGENTS/流程图.html`：浅蓝 = 上帝那一侧、绿 = 角色感知、
// 橙 = 角色行为、灰白 = 传统程序。分组框用界面自己的底色和描边。

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// 图标示的一步（右栏高亮用）。
enum FlowStep { a0, split, decide, a1, a2, b1, a3, b2, judge, a4, merge }

/// 步骤 id → 图上的节点。引擎报的是 `A0` / `AD` / `A1` / `A2` / `B1` /
/// `A3` / `B2` / `A4`；图里的 C 判断、分裂、合并由程序自己走。
FlowStep? flowStepOf(String? id) => switch (id) {
  'A0' => FlowStep.a0,
  'AD' => FlowStep.decide,
  'A1' => FlowStep.a1,
  'A2' => FlowStep.a2,
  'B1' => FlowStep.b1,
  'A3' => FlowStep.a3,
  'B2' => FlowStep.b2,
  'A4' => FlowStep.a4,
  _ => null,
};

/// 展开 / 收起的高度动画时长。
const Duration kJoFlowMs = Duration(milliseconds: 240);

class TurnFlow extends StatelessWidget {
  const TurnFlow({
    super.key,
    required this.palette,
    this.active,
    this.done = const <String>{},
    this.expanded = false,
    required this.onToggle,
  });

  final JoPalette palette;

  /// 正在跑的步骤 id（`A0` / `AD` / `A1` / `A2` / `B1` / `A3` / `B2` / `A4`）。
  final String? active;

  /// 跑过的步骤 id。
  final Set<String> done;

  /// 展开了没有。
  ///
  /// 收起时**只占一行**（标题 + 当前步）；展开时按图自己的比例占应有的高度，
  /// **不遮挡也不挤走**后面的内容 —— 后面的东西顺着往下排，由外层一起滚。
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final JoPalette palette = this.palette;
    final FlowStep? here = flowStepOf(active);
    return Container(
      padding: const EdgeInsets.fromLTRB(
        JoSpace.s4,
        JoSpace.s2,
        JoSpace.s3,
        JoSpace.s2,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: JoShape.side(palette.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _header(palette, here),
          // 展开 / 收起走一段高度动画：0 ↔ 整张图。
          // 图本身不拉伸，是“拉帘子”式裁出来的（上面的先出现），
          // 下面的内容跟着顺下去，不是一下子跳。
          AnimatedSize(
            duration: kJoFlowMs,
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            clipBehavior: Clip.hardEdge,
            child: expanded
                ? Padding(
                    padding: const EdgeInsets.only(top: JoSpace.s3),
                    // 展开时**不遮不盖**：图按自己的比例占应有的高度，
                    // 下面的内容顺着往下排，整个右栏一起滚。
                    child: AspectRatio(
                      aspectRatio: _w / _h,
                      child: FittedBox(
                        fit: BoxFit.fill,
                        child: SizedBox(
                          width: _w,
                          height: _h,
                          child: CustomPaint(
                            key: const ValueKey<String>('flow-diagram'),
                            painter: _FlowPainter(
                              active: here,
                              done: done
                                  .map(flowStepOf)
                                  .whereType<FlowStep>()
                                  .toSet(),
                              secondary: palette.secondary,
                              frame: palette.border,
                              frameFill: palette.surface,
                              accent: palette.accent,
                            ),
                          ),
                        ),
                      ),
                    ),
                  )
                : const SizedBox(width: double.infinity, height: 0),
          ),
        ],
      ),
    );
  }

  /// 标题那一行：左边“回合流程 · 当前：决策”，右边一个小三角。整行可点。
  Widget _header(JoPalette p, FlowStep? here) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onToggle,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Row(
          children: <Widget>[
            Text(
              '回合流程',
              style: JoFonts.meta.copyWith(
                color: p.secondary,
                letterSpacing: 2,
              ),
            ),
            if (here != null) ...<Widget>[
              const SizedBox(width: JoSpace.s3),
              Flexible(
                child: Text(
                  '当前：${labelOf(here)}',
                  overflow: TextOverflow.ellipsis,
                  style: JoFonts.meta.copyWith(color: p.accent),
                ),
              ),
            ],
            const Spacer(),
            Text(
              expanded ? '收起' : '展开',
              style: JoFonts.meta.copyWith(color: p.secondary, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }
}

/// 图上每一步的中文名（收起时那一行要用）。
String labelOf(FlowStep s) => switch (s) {
  FlowStep.a0 => '是否分裂序列',
  FlowStep.split => '分裂序列',
  FlowStep.decide => '决策',
  FlowStep.a1 => '环境更新',
  FlowStep.a2 => '理解事件 / 框选',
  FlowStep.b1 => '并行感知',
  FlowStep.a3 => '框选唯一',
  FlowStep.b2 => '执行行为',
  FlowStep.judge => '传统程序判断',
  FlowStep.a4 => '是否需要合并',
  FlowStep.merge => '和其他序列合并',
};

/// 某个步骤在图上的矩形（自动滚到它用）。
Rect? rectOfStep(FlowStep s) {
  for (final _Node n in _nodes) {
    if (n.step == s) return n.rect;
  }
  return null;
}

// ————————————————————————————— 排版（固定逻辑尺寸）

const double _w = 332;
const double _h = 700;

/// 一个节点：位置 + 类型 + 两行文字。
class _Node {
  const _Node({
    required this.step,
    required this.kind,
    required this.rect,
    required this.lines,
    this.title,
  });

  final FlowStep? step;
  final _Kind kind;
  final Rect rect;
  final List<String> lines;

  /// 分组框才有标题。
  final String? title;
}

enum _Kind { pill, diamond, box, group, green, orange }

const List<_Node> _nodes = <_Node>[
  _Node(
    step: null,
    kind: _Kind.pill,
    rect: Rect.fromLTWH(92, 4, 116, 24),
    lines: <String>['开始'],
  ),
  _Node(
    step: FlowStep.a0,
    kind: _Kind.diamond,
    rect: Rect.fromLTWH(46, 44, 158, 62),
    lines: <String>['是否分裂序列'],
  ),
  _Node(
    step: FlowStep.split,
    kind: _Kind.box,
    rect: Rect.fromLTWH(86, 126, 108, 24),
    lines: <String>['分裂序列'],
  ),
  _Node(
    step: FlowStep.decide,
    kind: _Kind.diamond,
    rect: Rect.fromLTWH(38, 166, 174, 68),
    lines: <String>['决策', '走环境更新，还是角色回合？'],
  ),

  // —— 左：角色回合（分组框）——
  _Node(
    step: null,
    kind: _Kind.group,
    rect: Rect.fromLTWH(4, 254, 186, 250),
    lines: <String>[],
    title: '回合模型（角色）',
  ),
  _Node(
    step: FlowStep.a2,
    kind: _Kind.box,
    rect: Rect.fromLTWH(12, 276, 170, 56),
    lines: <String>['理解事件 / 获取环境', '框选参与的 B'],
  ),
  _Node(
    step: FlowStep.b1,
    kind: _Kind.green,
    rect: Rect.fromLTWH(12, 340, 170, 46),
    lines: <String>['参与的 B 并行感知', '（全 AI）'],
  ),
  _Node(
    step: FlowStep.a3,
    kind: _Kind.box,
    rect: Rect.fromLTWH(12, 394, 170, 38),
    lines: <String>['据感知结果框选唯一一个 B'],
  ),
  _Node(
    step: FlowStep.b2,
    kind: _Kind.orange,
    rect: Rect.fromLTWH(12, 440, 170, 52),
    lines: <String>['该 B 执行行为', '（NPC=AI / 玩家=人）'],
  ),

  // —— 右：环境更新（分组框）——
  _Node(
    step: null,
    kind: _Kind.group,
    rect: Rect.fromLTWH(198, 300, 98, 118),
    lines: <String>[],
    title: '回合模型（环境）',
  ),
  _Node(
    step: FlowStep.a1,
    kind: _Kind.box,
    rect: Rect.fromLTWH(206, 326, 82, 76),
    lines: <String>['环境更新', '世界自身的事件推进'],
  ),

  // —— 汇合 ——
  _Node(
    step: FlowStep.judge,
    kind: _Kind.diamond,
    rect: Rect.fromLTWH(56, 530, 148, 62),
    lines: <String>['传统程序判断', '还有未合并的序列吗'],
  ),
  _Node(
    step: FlowStep.a4,
    kind: _Kind.diamond,
    rect: Rect.fromLTWH(64, 606, 132, 48),
    lines: <String>['是否需要合并'],
  ),
  _Node(
    step: FlowStep.merge,
    kind: _Kind.box,
    rect: Rect.fromLTWH(200, 660, 96, 28),
    lines: <String>['和其他序列合并'],
  ),
];

class _FlowPainter extends CustomPainter {
  _FlowPainter({
    required this.active,
    required this.done,
    required this.secondary,
    required this.frame,
    required this.frameFill,
    required this.accent,
  });

  final FlowStep? active;
  final Set<FlowStep> done;
  final Color secondary;
  final Color frame;
  final Color frameFill;
  final Color accent;

  static const Color _blueFill = Color(0xFFE8F0FE);
  static const Color _blueLine = Color(0xFF7C9BD6);
  static const Color _greenFill = Color(0xFFE6F4EA);
  static const Color _greenLine = Color(0xFF7CA98C);
  static const Color _orangeFill = Color(0xFFFFF4E5);
  static const Color _orangeLine = Color(0xFFD3A163);
  static const Color _programFill = Color(0xFFF2F2F4);
  static const Color _programLine = Color(0xFF9A9AA2);
  static const Color _ink = Color(0xFF1A1C22);

  @override
  void paint(Canvas canvas, Size size) {
    // 顺序：连线 → 分组框 → 节点。
    // 连线先画，靠右侧绕回去的那几根就会被分组框遮住一段，
    // 不会明着压在框里面（参考图里那几根是走在框外面的）。
    _drawEdges(canvas);
    for (final _Node n in _nodes) {
      if (n.kind == _Kind.group) _drawGroup(canvas, n);
    }
    for (final _Node n in _nodes) {
      if (n.kind != _Kind.group) _drawNode(canvas, n);
    }
  }

  // —— 节点 ——

  void _drawNode(Canvas canvas, _Node n) {
    final bool on = active != null && n.step == active;
    final (Color fill, Color line) = switch (n.kind) {
      _Kind.green => (_greenFill, _greenLine),
      _Kind.orange => (_orangeFill, _orangeLine),
      _Kind.pill => (_programFill, _programLine),
      _Kind.diamond => (_blueFill, _blueLine),
      _ => (_blueFill, _blueLine),
    };

    final Paint p = Paint()..color = fill;
    final Paint stroke = Paint()
      ..color = on ? accent : line
      ..style = PaintingStyle.stroke
      ..strokeWidth = on ? 2 : 1;

    final Path path = n.kind == _Kind.diamond
        ? _diamondPath(n.rect)
        : (Path()..addRRect(
            RRect.fromRectAndRadius(
              n.rect,
              Radius.circular(n.kind == _Kind.pill ? 12 : 2),
            ),
          ));

    canvas.drawPath(path, p);
    canvas.drawPath(path, stroke);
    if (on) {
      // 正在跑：外面再描一圈淡的，显眼但不刺眼。
      final Paint halo = Paint()
        ..color = accent.withValues(alpha: 0.28)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4;
      canvas.drawPath(path, halo);
    }

    _text(canvas, n.rect.deflate(n.kind == _Kind.diamond ? 26 : 6), n.lines);
  }

  void _drawGroup(Canvas canvas, _Node n) {
    final Paint fill = Paint()..color = frameFill;
    final Paint stroke = Paint()
      ..color = frame
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final RRect rr = RRect.fromRectAndRadius(n.rect, const Radius.circular(2));
    canvas.drawRRect(rr, fill);
    canvas.drawRRect(rr, stroke);
    _text(
      canvas,
      Rect.fromLTWH(n.rect.left + 6, n.rect.top + 6, n.rect.width - 12, 16),
      <String>[n.title ?? ''],
      align: TextAlign.center,
    );
  }

  Path _diamondPath(Rect r) {
    final double cx = r.center.dx;
    final double cy = r.center.dy;
    return Path()
      ..moveTo(cx, r.top)
      ..lineTo(r.right, cy)
      ..lineTo(cx, r.bottom)
      ..lineTo(r.left, cy)
      ..close();
  }

  void _text(
    Canvas canvas,
    Rect area,
    List<String> lines, {
    TextAlign align = TextAlign.center,
  }) {
    final TextSpan span = TextSpan(
      children: <InlineSpan>[
        for (int i = 0; i < lines.length; i++)
          TextSpan(
            text: i == 0 ? lines[i] : '\n${lines[i]}',
            style: TextStyle(
              fontFamily: JoFonts.sans,
              fontSize: i == 0 ? 9.5 : 9,
              height: 1.35,
              color: _ink,
            ),
          ),
      ],
    );
    final TextPainter tp = TextPainter(
      text: span,
      textAlign: align,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: area.width);
    tp.paint(
      canvas,
      Offset(
        area.left + (area.width - tp.width) / 2,
        area.center.dy - tp.height / 2,
      ),
    );
  }

  // —— 连线 ——

  void _drawEdges(Canvas canvas) {
    final Paint line = Paint()
      ..color = const Color(0xFF7A7A85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    const double cx = 125; // 主干的中心

    /// 一条折线 + 末端箭头。`pts` 至少两个点。
    void poly(List<Offset> pts, {String? label, Offset? labelAt}) {
      for (int i = 0; i + 1 < pts.length; i++) {
        canvas.drawLine(pts[i], pts[i + 1], line);
      }
      if (pts.length >= 2) {
        _head(canvas, pts[pts.length - 2], pts.last);
      }
      if (label != null && labelAt != null) _label(canvas, label, labelAt);
    }

    // 开始 → A₀
    poly(<Offset>[const Offset(cx, 28), const Offset(cx, 44)]);

    // A₀ → 分裂序列：否 / 是 两条先下再汇
    poly(<Offset>[
      const Offset(96, 106),
      const Offset(96, 126),
      const Offset(154, 126),
      const Offset(154, 126),
    ]);
    poly(<Offset>[const Offset(cx, 126), const Offset(cx, 138)]);
    _label(canvas, '否', const Offset(76, 110));
    _label(canvas, '是', const Offset(160, 110));

    // 分裂序列 → A 决策
    poly(<Offset>[const Offset(cx, 150), const Offset(cx, 166)]);

    // 决策 → 左（角色回合）/ 右（环境更新）。标注用大白话，不写代号。
    // 拐一下再进框：直接扎进分组框的边上会跟框重合。
    poly(
      <Offset>[
        const Offset(46, 200),
        const Offset(46, 242),
        const Offset(97, 242),
        const Offset(97, 276),
      ],
      label: '角色回合',
      labelAt: const Offset(8, 214),
    );
    poly(
      <Offset>[
        const Offset(204, 200),
        const Offset(204, 288),
        const Offset(247, 288),
        const Offset(247, 326),
      ],
      label: '环境更新',
      labelAt: const Offset(208, 264),
    );

    // 角色回合内部：A₂ → B₁ → A₃ → B₂
    poly(<Offset>[const Offset(97, 332), const Offset(97, 340)]);
    poly(<Offset>[const Offset(97, 386), const Offset(97, 394)]);
    poly(<Offset>[const Offset(97, 432), const Offset(97, 440)]);

    // 两条支路汇到 C 判断
    poly(<Offset>[
      const Offset(97, 492),
      const Offset(97, 516),
      const Offset(247, 516),
      const Offset(247, 488),
    ]);
    poly(<Offset>[
      const Offset(247, 418),
      const Offset(247, 516),
      const Offset(97, 516),
      const Offset(97, 530),
    ]);

    // C 判断 → 是否需要合并（是）。标注放在线的**右边**，不压在线上。
    poly(<Offset>[const Offset(cx, 592), const Offset(cx, 606)]);
    _label(canvas, '是', const Offset(134, 594));

    // 是否需要合并 → 和其他序列合并（是）：往下拐再向右，箭头落在框左侧。
    poly(<Offset>[
      const Offset(cx, 654),
      const Offset(cx, 674),
      const Offset(200, 674),
    ]);
    _label(canvas, '是', const Offset(134, 660));

    // 否 → 绕右侧回到顶部。三道回环走在**环境框外侧**的空地上（x ≥ 306），
    // 不穿过任何框。
    poly(
      <Offset>[
        const Offset(204, 561),
        const Offset(306, 561),
        const Offset(306, 75),
        const Offset(204, 75),
      ],
      label: '否',
      labelAt: const Offset(288, 500),
    );

    poly(
      <Offset>[
        const Offset(196, 630),
        const Offset(314, 630),
        const Offset(314, 88),
        const Offset(204, 88),
      ],
      label: '否',
      labelAt: const Offset(295, 560),
    );

    poly(<Offset>[
      const Offset(296, 674),
      const Offset(322, 674),
      const Offset(322, 102),
      const Offset(204, 102),
    ]);
  }

  /// 箭头（三角）。
  void _head(Canvas canvas, Offset from, Offset to) {
    final Offset d = to - from;
    final double len = d.distance;
    if (len < 1) return;
    final Offset u = d / len;
    final Offset n = Offset(-u.dy, u.dx);
    final Offset tip = to;
    final Offset base = tip - u * 5;
    final Path p = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(base.dx + n.dx * 3, base.dy + n.dy * 3)
      ..lineTo(base.dx - n.dx * 3, base.dy - n.dy * 3)
      ..close();
    canvas.drawPath(p, Paint()..color = const Color(0xFF7A7A85));
  }

  void _label(Canvas canvas, String text, Offset at) {
    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: JoFonts.sans,
          fontSize: 8.5,
          color: secondary,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(_FlowPainter old) =>
      old.active != active ||
      old.accent != accent ||
      old.frame != frame ||
      old.secondary != secondary;
}
