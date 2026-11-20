// 右栏的“回合流程”。同一步在不同角色、事件批次和重试中共用一个块。

import 'package:flutter/material.dart';

import '../engine/step_id.dart';
import '../theme/tokens.dart';

const Size turnFlowSize = Size(360, 676);
const double _left = 20;
const double _right = 205;
const double _blockWidth = 128;

enum _Kind { gm, perception, action, system }

enum FlowStep {
  schedule('SYS_SCHEDULE', _left, 8, _Kind.system, systemTitle: '时间线调度'),
  openPlace(StepId.gmOpenPlace, _left, 56, _Kind.gm),
  route(StepId.gmRoute, _left, 104, _Kind.gm),
  environment(StepId.gmEnvironment, _right, 104, _Kind.gm),
  observeScene(StepId.gmObserveScene, _left, 176, _Kind.gm),
  perceive(StepId.chPerceive, _left, 230, _Kind.perception),
  writeMemory(StepId.chMemoryWrite, _left, 284, _Kind.perception),
  cast(StepId.gmCast, _left, 340, _Kind.gm),
  eligibility(StepId.gmEligibility, _left, 396, _Kind.gm),
  selectActor(StepId.gmSelectActor, _left, 452, _Kind.gm),
  recall(StepId.chMemoryRecall, _left, 520, _Kind.perception),
  parseInput(StepId.gmParseInput, _right, 520, _Kind.gm),
  act(StepId.chAct, _left, 578, _Kind.action),
  resolve(StepId.gmResolveAction, _left, 636, _Kind.gm),
  record(StepId.sysRecord, _right, 176, _Kind.system, systemTitle: '记录事件与状态变化'),
  mergePlace(StepId.gmMergePlace, _right, 284, _Kind.gm),
  commit(StepId.sysCommit, _right, 340, _Kind.system, systemTitle: '提交世界版本'),
  narrate(StepId.gmNarrate, _right, 396, _Kind.gm),
  review(StepId.gmReviewNarration, _right, 452, _Kind.gm, hint: '通过后结束本回合'),
  recovery(StepId.sysRecovery, _right, 48, _Kind.system,
      systemTitle: '等待玩家处理', hint: '轮到玩家或步骤求助时');

  const FlowStep(this.id, this._x, this._y, this._kind, {this.systemTitle, this.hint});

  final String id;
  final double _x;
  final double _y;
  final _Kind _kind;
  final String? systemTitle;
  final String? hint;

  String get title => systemTitle ?? StepId.title(id);
  Rect get rect => Rect.fromLTWH(_x, _y, _blockWidth, hint == null ? 32 : 42);
}

final Map<String, FlowStep> _stepsById = <String, FlowStep>{
  for (final step in FlowStep.values) step.id: step,
};

FlowStep? flowStepOf(String? id) => id == null ? null : _stepsById[StepId.base(id)];

/// 展开 / 收起的高度动画时长。
const Duration kJoFlowMs = Duration(milliseconds: 240);

class TurnFlow extends StatelessWidget {
  const TurnFlow({
    super.key,
    required this.palette,
    this.active,
    this.done = const <String>{},
    this.expanded = false,
    this.liveText = '',
    required this.onToggle,
  });

  final JoPalette palette;

  /// 正在执行的步骤，可以带角色或批次后缀。
  final String? active;

  /// 跑过的步骤 id。
  final Set<String> done;

  /// 展开了没有。
  ///
  /// 收起时**只占一行**（标题 + 当前步）；展开时按图自己的比例占应有的高度，
  /// **不遮挡也不挤走**后面的内容 —— 后面的东西顺着往下排，由外层一起滚。
  final bool expanded;
  final VoidCallback onToggle;

  /// 正在流式写出来的正文（只留尾巴，出完就清空）。
  ///
  /// 它**只是给眼睛看的进展**：解析、落盘都用攒完整的回复，不读这里。
  final String liveText;

  @override
  Widget build(BuildContext context) {
    final JoPalette palette = this.palette;
    final FlowStep? here = flowStepOf(active);
    final completed = done.map(flowStepOf).whereType<FlowStep>().toSet();
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
          if (liveText.trim().isNotEmpty) _liveLine(palette),
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
                      aspectRatio: turnFlowSize.aspectRatio,
                      child: FittedBox(
                        fit: BoxFit.fill,
                        child: SizedBox(
                          width: turnFlowSize.width,
                          height: turnFlowSize.height,
                          child: CustomPaint(
                            key: const ValueKey<String>('flow-diagram'),
                            painter: _EdgePainter(palette),
                            child: Stack(
                              children: <Widget>[
                                for (final step in FlowStep.values)
                                  Positioned.fromRect(
                                    rect: step.rect,
                                    child: _StepBlock(
                                      step: step,
                                      active: step == here,
                                      completed: completed.contains(step),
                                      palette: palette,
                                    ),
                                  ),
                              ],
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

  /// 正在写出来的那一小段。收起时也留着——不然勾了流式什么都看不见。
  Widget _liveLine(JoPalette p) {
    return Padding(
      padding: const EdgeInsets.only(top: JoSpace.s1),
      child: Text(
        liveText,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: JoFonts.meta.copyWith(color: p.secondary, height: 1.6),
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
                  '当前：$active · ${here.title}',
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

/// 一类步骤的填充与描边。
///
/// 调色板里只有一档蓝灰（[JoPalette.accent]）和中性灰，没有绿、橙这些色相，
/// 所以四类**不靠换色相区分**，而是靠“蓝的浓度台阶 + 有没有填充”。
/// 以前这里是照 Material 的 info / success / warning 抄的四支粉彩常量，
/// 不进调色板、不跟明暗：暗色主题下块面比正文还亮，切换主题时也纹丝不动。
@immutable
class _StepLook {
  const _StepLook(this.fill, this.border);

  final Color fill;
  final Color border;
}

_StepLook _lookOf(JoPalette p, _Kind kind) {
  // 把颜色按透明度压到面上，结果仍是主题里真实存在的色，不是新色号。
  Color tint(Color color, double alpha) =>
      Color.alphaBlend(color.withValues(alpha: alpha), p.surface);
  // 描边取“边框 → 目标色”的插值，两套主题都落在同一段色阶上。
  Color edge(Color color, double t) => Color.lerp(p.border, color, t)!;
  // 四类排成一条明度台阶：角色行动最重、程序次之、感知最轻、系统只留框。
  // 调色板只有一档强调色，硬凑四种色相只会又跑出主题外的颜色；
  // 台阶本身就能让人一眼分出主次，类别名在块里写着。
  //
  // 两套主题的浓度不一样：亮色底本来就近白，同样的透明度在那边层次会直接
  // 化掉（实测 0.06 只比底暗不到 1 个 L*），所以亮色要压得更实一档。
  final (double action, double gm, double perception) = p.isDark
      ? (0.30, 0.16, 0.07)
      : (0.32, 0.20, 0.13);
  return switch (kind) {
    _Kind.action => _StepLook(tint(p.accent, action), edge(p.accent, 0.85)),
    _Kind.gm => _StepLook(tint(p.accent, gm), edge(p.accent, 0.50)),
    _Kind.perception => _StepLook(tint(p.accent, perception), edge(p.accent, 0.30)),
    // 系统步骤不填充，只留一个框 —— 它们是结构件，不是内容步骤。
    _Kind.system => _StepLook(p.bg, edge(p.secondary, 0.45)),
  };
}

class _StepBlock extends StatelessWidget {
  const _StepBlock({
    required this.step,
    required this.active,
    required this.completed,
    required this.palette,
  });

  final FlowStep step;
  final bool active;
  final bool completed;
  final JoPalette palette;

  @override
  Widget build(BuildContext context) {
    final _StepLook look = _lookOf(palette, step._kind);
    // 当前步在类别底色上再压一层强调色，免得高亮只靠一条细边。
    final Color fill = active
        ? Color.alphaBlend(palette.accent.withValues(alpha: 0.14), look.fill)
        : look.fill;
    final Color border = active || completed ? palette.accent : look.border;
    final TextStyle style = TextStyle(
      fontFamily: JoFonts.sans, fontSize: 12, color: palette.text, height: 1.3,
    );
    return Semantics(
      container: true,
      value: active ? '当前步骤' : completed ? '已走过' : null,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: fill,
          border: Border.all(color: border, width: active ? 2 : 1),
          borderRadius: BorderRadius.circular(step._kind == _Kind.system ? 10 : 3),
          boxShadow: active
              ? [BoxShadow(color: palette.accent.withValues(alpha: 0.28), spreadRadius: 2)]
              : null,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(step.title, style: style),
                if (step.hint case final String hint)
                  Text(hint, style: style.copyWith(fontSize: 10)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 起止点取自步骤块的边界，折点和标签使用同一套画布坐标。
class FlowEdge {
  const FlowEdge(this.from, this.to, {
    this.start = Alignment.bottomCenter,
    this.end = Alignment.topCenter,
    this.via = const [],
    this.caption,
  });

  final FlowStep from;
  final FlowStep to;
  final Alignment start;
  final Alignment end;
  final List<Offset> via;
  final (String, Offset)? caption;

  List<Offset> get points => [start.withinRect(from.rect), ...via, end.withinRect(to.rect)];
}

const turnFlowEdges = <FlowEdge>[
  FlowEdge(FlowStep.schedule, FlowStep.openPlace),
  FlowEdge(FlowStep.openPlace, FlowStep.route),
  FlowEdge(FlowStep.route, FlowStep.observeScene, caption: ('角色回合', Offset(58, 146))),
  FlowEdge(FlowStep.route, FlowStep.environment,
      start: Alignment.centerRight, end: Alignment.centerLeft, caption: ('环境回合', Offset(177, 111))),
  FlowEdge(FlowStep.environment, FlowStep.schedule,
      start: Alignment.centerRight, end: Alignment.centerRight,
      via: [Offset(353, 120), Offset(353, 24)], caption: ('无事件，返回调度', Offset(241, 15))),
  FlowEdge(FlowStep.environment, FlowStep.record, caption: ('有事件', Offset(290, 155))),
  FlowEdge(FlowStep.record, FlowStep.observeScene,
      start: Alignment.centerLeft, end: Alignment.centerRight, caption: ('环境回合', Offset(177, 183))),
  FlowEdge(FlowStep.observeScene, FlowStep.perceive),
  FlowEdge(FlowStep.perceive, FlowStep.writeMemory),
  FlowEdge(FlowStep.writeMemory, FlowStep.perceive,
      start: Alignment.topRight, end: Alignment.centerRight,
      via: [Offset(160, 284), Offset(160, 246)], caption: ('下一位角色', Offset(131, 272))),
  FlowEdge(FlowStep.writeMemory, FlowStep.cast, caption: ('角色回合', Offset(109, 328))),
  FlowEdge(FlowStep.writeMemory, FlowStep.mergePlace,
      start: Alignment.centerRight, end: Alignment.centerLeft, caption: ('环境回合', Offset(177, 291))),
  FlowEdge(FlowStep.cast, FlowStep.eligibility),
  FlowEdge(FlowStep.eligibility, FlowStep.environment,
      start: Alignment.centerLeft, end: Alignment(-0.5, 1),
      via: [Offset(7, 412), Offset(7, 158), Offset(237, 158)],
      caption: ('无人可行动', Offset(151, 149))),
  FlowEdge(FlowStep.eligibility, FlowStep.selectActor),
  FlowEdge(FlowStep.selectActor, FlowStep.recall),
  FlowEdge(FlowStep.recall, FlowStep.act, caption: ('AI 角色', Offset(61, 565))),
  FlowEdge(FlowStep.recall, FlowStep.parseInput,
      start: Alignment.centerRight, end: Alignment.centerLeft, caption: ('玩家角色', Offset(177, 527))),
  FlowEdge(FlowStep.parseInput, FlowStep.act, end: Alignment(0.5, -1),
      via: [Offset(269, 565), Offset(116, 565)]),
  FlowEdge(FlowStep.act, FlowStep.resolve, caption: ('需裁定', Offset(106, 623))),
  FlowEdge(FlowStep.act, FlowStep.record,
      start: Alignment.centerRight, end: Alignment.centerRight,
      via: [Offset(353, 594), Offset(353, 192)], caption: ('直接记录', Offset(237, 585))),
  FlowEdge(FlowStep.resolve, FlowStep.record,
      start: Alignment.centerRight, end: Alignment.centerRight,
      via: [Offset(353, 652), Offset(353, 192)]),
  FlowEdge(FlowStep.resolve, FlowStep.commit,
      start: Alignment.topRight, end: Alignment.centerRight,
      via: [Offset(341, 636), Offset(341, 356)], caption: ('争用结果已一并记录', Offset(237, 627))),
  FlowEdge(FlowStep.record, FlowStep.mergePlace, caption: ('角色回合', Offset(294, 245))),
  FlowEdge(FlowStep.mergePlace, FlowStep.commit),
  FlowEdge(FlowStep.commit, FlowStep.narrate),
  FlowEdge(FlowStep.narrate, FlowStep.review),
  FlowEdge(FlowStep.review, FlowStep.narrate,
      start: Alignment.centerLeft, end: Alignment.centerLeft,
      via: [Offset(193, 473), Offset(193, 412)], caption: ('重写', Offset(207, 440))),
];

class _EdgePainter extends CustomPainter {
  const _EdgePainter(this.palette);

  final JoPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()..color = palette.secondary;
    final crossingGap = Paint()..color = palette.bg..strokeWidth = 4;
    for (final edge in turnFlowEdges) {
      final points = edge.points;
      for (int i = 1; i < points.length; i++) {
        canvas.drawLine(points[i - 1], points[i], crossingGap);
        canvas.drawLine(points[i - 1], points[i], line);
      }
      final tip = points.last;
      final direction = tip - points[points.length - 2];
      final unit = direction / direction.distance;
      final normal = Offset(-unit.dy, unit.dx);
      final base = tip - unit * 5;
      canvas.drawPath(Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(base.dx + normal.dx * 3, base.dy + normal.dy * 3)
        ..lineTo(base.dx - normal.dx * 3, base.dy - normal.dy * 3)
        ..close(), line);
    }
    for (final edge in turnFlowEdges) {
      if (edge.caption case (final text, final center)) {
        final label = TextPainter(
          text: TextSpan(text: text, style: TextStyle(
            fontFamily: JoFonts.sans, fontSize: 10, height: 1.15, color: palette.secondary,
          )),
          textDirection: TextDirection.ltr,
        )..layout();
        label.paint(canvas, center - Offset(label.width / 2, label.height / 2));
        label.dispose();
      }
    }
  }

  @override
  bool shouldRepaint(_EdgePainter old) =>
      palette.secondary != old.palette.secondary || palette.bg != old.palette.bg;
}
