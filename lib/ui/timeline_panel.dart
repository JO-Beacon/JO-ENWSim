import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/world_store.dart';
import '../theme/tokens.dart';
import 'common.dart';

enum TimelineAction { openHead, readVersion, fork, replay }

typedef TimelineSelection = ({
  TimelineAction action,
  String branchId,
  int versionId,
});

class TimelinePanel extends StatelessWidget {
  const TimelinePanel({
    super.key,
    required this.branches,
    required this.histories,
    required this.currentBranchId,
    this.statuses = const <String, String>{},
    this.viewingVersionId,
  });

  final List<TimelineBranch> branches;
  final Map<String, List<TimelineVersion>> histories;
  final String currentBranchId;
  final Map<String, String> statuses;
  final int? viewingVersionId;

  @override
  Widget build(BuildContext context) {
    final JoPalette palette = JoTheme.of(context);
    final Map<int, TimelineVersion> versions = <int, TimelineVersion>{};
    final Map<int, Offset> points = <int, Offset>{};
    final Map<String, Offset> heads = <String, Offset>{};
    final Set<int> currentPath = <int>{
      for (final version in histories[currentBranchId] ?? <TimelineVersion>[])
        version.id,
    };
    double width = 290;
    for (final (int row, TimelineBranch branch) in branches.indexed) {
      final List<TimelineVersion> history = histories[branch.id]!;
      final double y = 40.0 + row * 60;
      for (final TimelineVersion version in history) {
        versions[version.id] = version;
        points.putIfAbsent(
          version.id,
          () => Offset(40.0 + 72 * (version.round ?? 0), y),
        );
      }
      final double endX = points[branch.headVersionId]!.dx + 58;
      heads[branch.id] = Offset(endX, y);
      width = math.max(width, endX + 178);
    }
    final double height = math.max(84, branches.length * 60.0 + 24);

    void select(TimelineAction action, String branchId, int versionId) {
      Navigator.of(context).pop<TimelineSelection>((
        action: action,
        branchId: branchId,
        versionId: versionId,
      ));
    }

    return Dialog(
      backgroundColor: palette.bg,
      child: SizedBox(
        width: 850,
        height: 475,
        child: Padding(
          padding: const EdgeInsets.all(JoSpace.s4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '时间线',
                      style: JoFonts.ui.copyWith(
                        fontSize: 17, color: palette.text, fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  JoButton(text: '关闭', onTap: () => Navigator.of(context).pop()),
                ],
              ),
              const SizedBox(height: JoSpace.s3),
              Expanded(
                child: InteractiveViewer(
                  constrained: false,
                  minScale: 0.5,
                  maxScale: 2.0,
                  child: SizedBox(
                    width: width,
                    height: height,
                    child: Stack(
                      children: <Widget>[
                        Positioned.fill(
                          child: CustomPaint(painter: _TimelineEdges(
                            versions: versions,
                            points: points,
                            branches: branches,
                            heads: heads,
                            line: palette.border,
                            accent: palette.accent,
                            currentPath: currentPath,
                          )),
                        ),
                        for (final TimelineVersion version in versions.values)
                          Positioned(
                            left: points[version.id]!.dx - 28,
                            top: points[version.id]!.dy - 19,
                            child: PopupMenuButton<TimelineAction>(
                              tooltip: '回合操作',
                              onSelected: (TimelineAction action) => select(
                                action,
                                currentPath.contains(version.id)
                                    ? currentBranchId
                                    : version.branchId,
                                version.id,
                              ),
                              itemBuilder: (BuildContext context) =>
                                  <PopupMenuEntry<TimelineAction>>[
                                    const PopupMenuItem(
                                      value: TimelineAction.readVersion,
                                      child: Text('查看历史'),
                                    ),
                                    if (version.round != null)
                                      const PopupMenuItem(
                                        value: TimelineAction.fork,
                                        child: Text('从此处创建分支'),
                                      ),
                                    if ((version.round ?? 0) > 1)
                                      const PopupMenuItem(
                                        value: TimelineAction.replay,
                                        child: Text('重新推演本回合'),
                                      ),
                                  ],
                              child: Container(
                                width: 56,
                                height: 38,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: palette.bg,
                                  border: Border.all(
                                    color: currentPath.contains(version.id)
                                        ? palette.accent
                                        : palette.border,
                                    width: viewingVersionId == version.id ? 2 : 1,
                                  ),
                                  borderRadius: JoShape.br,
                                ),
                                child: Text(
                                  version.round == null ? '开场' : '第 ${version.round} 回合',
                                  style: JoFonts.meta.copyWith(
                                    color: palette.text, fontSize: 10,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        for (final TimelineBranch branch in branches)
                          Positioned(
                            left: heads[branch.id]!.dx,
                            top: heads[branch.id]!.dy - 15,
                            child: Row(
                              children: <Widget>[
                                JoButton(
                                  text: branch.name,
                                  color: branch.id == currentBranchId ? palette.accent : null,
                                  onTap: () => select(
                                    TimelineAction.openHead, branch.id, branch.headVersionId,
                                  ),
                                ),
                                if (statuses[branch.id] case final String status)
                                  Padding(
                                    padding: const EdgeInsets.only(left: JoSpace.s2),
                                    child: Text(status, style: JoFonts.meta.copyWith(
                                      color: palette.secondary, fontSize: 10,
                                    )),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TimelineEdges extends CustomPainter {
  const _TimelineEdges({
    required this.versions,
    required this.points,
    required this.branches,
    required this.heads,
    required this.line,
    required this.accent,
    required this.currentPath,
  });

  final Map<int, TimelineVersion> versions;
  final Map<int, Offset> points;
  final List<TimelineBranch> branches;
  final Map<String, Offset> heads;
  final Color line;
  final Color accent;
  final Set<int> currentPath;

  @override
  void paint(Canvas canvas, Size size) {
    void connect(Offset from, Offset to, Color color) {
      final double mid = (from.dx + to.dx) / 2;
      canvas.drawPath(
        Path()
          ..moveTo(from.dx, from.dy)
          ..cubicTo(mid, from.dy, mid, to.dy, to.dx, to.dy),
        Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 1.5,
      );
    }

    for (final TimelineVersion version in versions.values) {
      final Offset? parent = points[version.parentId];
      if (parent == null) continue;
      connect(parent, points[version.id]!, currentPath.contains(version.id) ? accent : line);
    }
    for (final TimelineBranch branch in branches) {
      connect(points[branch.headVersionId]!, heads[branch.id]!, line);
    }
  }

  @override
  bool shouldRepaint(covariant _TimelineEdges oldDelegate) =>
      oldDelegate.points != points || oldDelegate.currentPath != currentPath ||
      oldDelegate.line != line || oldDelegate.accent != accent;
}
