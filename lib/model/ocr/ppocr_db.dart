// DB（Differentiable Binarization）检测后处理。
//
// 输入是检测模型输出的 1×1×H×W 概率图，输出是原图坐标系下的四边形。
//
// 步骤：
//   1. 概率 > 阈值 的二值化；
//   2. 连通域（8 邻域），每个连通域算凸包；
//   3. 旋转卡壳求最小外接矩形；
//   4. 框内平均分过滤；
//   5. 外扩（矩形按面积/周长的一半放大）；
//   6. 缩放到原图坐标。
//
// 外扩不用多边形偏移库：矩形向外 offset d 之后的包围矩形正好是
// 各边 +2d，所以直接改宽高就等价，省掉一个依赖。

import 'dart:math' as math;
import 'dart:typed_data';

/// 检测到的一个框：四个角（左上 / 右上 / 右下 / 左下）+ 置信度。
class DetBox {
  const DetBox(this.corners, this.score);

  final List<({double x, double y})> corners;
  final double score;
}

class DbPostProcess {
  const DbPostProcess({
    this.thresh = 0.3,
    this.boxThresh = 0.6,
    this.unclipRatio = 1.5,
    this.minSize = 3,
  });

  final double thresh;
  final double boxThresh;
  final double unclipRatio;
  final double minSize;

  /// [prob] 是 H×W 的概率图（行优先）。
  List<DetBox> process(
    Float32List prob,
    int predH,
    int predW,
    int originalH,
    int originalW,
  ) {
    final Uint8List mask = Uint8List(predH * predW);
    for (int i = 0; i < mask.length; i++) {
      if (prob[i] >= thresh) mask[i] = 1;
    }

    final List<DetBox> boxes = <DetBox>[];
    final List<List<({double x, double y})>> regions = _components(
      mask,
      predH,
      predW,
    );

    for (final List<({double x, double y})> region in regions) {
      final _Rect rect = _miniBox(region);
      if (rect.shortSide < minSize) continue;

      final double score = _boxScore(prob, predH, predW, rect.corners);
      if (score < boxThresh) continue;

      // 外扩：d = 面积 * ratio / 周长，矩形四边各 +2d。
      final double perimeter = 2 * (rect.width + rect.height);
      if (perimeter <= 0) continue;
      final double d = rect.width * rect.height * unclipRatio / perimeter;
      final double newW = rect.width + 2 * d;
      final double newH = rect.height + 2 * d;
      if (math.min(newW, newH) < minSize + 2) continue;

      final _Rect grow = _Rect(
        center: rect.center,
        width: newW,
        height: newH,
        angle: rect.angle,
      );

      final List<({double x, double y})> scaled = <({double x, double y})>[];
      for (final ({double x, double y}) p in grow.corners) {
        scaled.add((
          x: (p.x / predW * originalW).clamp(0, originalW - 1).toDouble(),
          y: (p.y / predH * originalH).clamp(0, originalH - 1).toDouble(),
        ));
      }

      final double w = _dist(scaled[0], scaled[1]);
      final double h = _dist(scaled[0], scaled[3]);
      if (w <= 3 || h <= 3) continue;

      boxes.add(DetBox(scaled, score));
    }

    boxes.sort((DetBox a, DetBox b) {
      final double ay = a.corners[0].y;
      final double by = b.corners[0].y;
      if ((ay - by).abs() > 10) return ay.compareTo(by);
      return a.corners[0].x.compareTo(b.corners[0].x);
    });
    return boxes;
  }

  /// 8 邻域连通域，返回每个连通域的点集（限制面积，太小的直接丢）。
  List<List<({double x, double y})>> _components(
    Uint8List mask,
    int h,
    int w,
  ) {
    final Uint8List visited = Uint8List(mask.length);
    final List<List<({double x, double y})>> out =
        <List<({double x, double y})>>[];
    final List<int> stack = <int>[];

    for (int start = 0; start < mask.length; start++) {
      if (mask[start] == 0 || visited[start] == 1) continue;
      final List<({double x, double y})> region = <({double x, double y})>[];
      stack
        ..clear()
        ..add(start);
      visited[start] = 1;

      while (stack.isNotEmpty) {
        final int idx = stack.removeLast();
        final int y = idx ~/ w;
        final int x = idx % w;
        region.add((x: x.toDouble(), y: y.toDouble()));

        for (int dy = -1; dy <= 1; dy++) {
          final int ny = y + dy;
          if (ny < 0 || ny >= h) continue;
          for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            final int nx = x + dx;
            if (nx < 0 || nx >= w) continue;
            final int nidx = ny * w + nx;
            if (mask[nidx] == 0 || visited[nidx] == 1) continue;
            visited[nidx] = 1;
            stack.add(nidx);
          }
        }
      }

      if (region.length >= 4) out.add(region);
    }
    return out;
  }

  /// 点集的凸包 + 旋转卡壳，求最小面积外接矩形。
  _Rect _miniBox(List<({double x, double y})> points) {
    final List<({double x, double y})> hull = _convexHull(points);
    if (hull.length < 3) {
      double minX = points.first.x, maxX = points.first.x;
      double minY = points.first.y, maxY = points.first.y;
      for (final ({double x, double y}) p in points) {
        minX = math.min(minX, p.x);
        maxX = math.max(maxX, p.x);
        minY = math.min(minY, p.y);
        maxY = math.max(maxY, p.y);
      }
      return _Rect(
        center: (x: (minX + maxX) / 2, y: (minY + maxY) / 2),
        width: maxX - minX,
        height: maxY - minY,
        angle: 0,
      );
    }

    double bestArea = double.infinity;
    _Rect best = _Rect(
      center: (x: 0, y: 0),
      width: 0,
      height: 0,
      angle: 0,
    );

    final int n = hull.length;
    for (int i = 0; i < n; i++) {
      final ({double x, double y}) p1 = hull[i];
      final ({double x, double y}) p2 = hull[(i + 1) % n];
      final double edge = math.atan2(p2.y - p1.y, p2.x - p1.x);
      final double cosA = math.cos(-edge);
      final double sinA = math.sin(-edge);

      double minX = double.infinity, maxX = -double.infinity;
      double minY = double.infinity, maxY = -double.infinity;
      for (final ({double x, double y}) p in points) {
        final double rx = (p.x - p1.x) * cosA - (p.y - p1.y) * sinA;
        final double ry = (p.x - p1.x) * sinA + (p.y - p1.y) * cosA;
        minX = math.min(minX, rx);
        maxX = math.max(maxX, rx);
        minY = math.min(minY, ry);
        maxY = math.max(maxY, ry);
      }

      final double bw = maxX - minX;
      final double bh = maxY - minY;
      final double area = bw * bh;
      if (area < bestArea) {
        bestArea = area;
        final double cxLocal = (minX + maxX) / 2;
        final double cyLocal = (minY + maxY) / 2;
        best = _Rect(
          center: (
            x: p1.x + cxLocal * math.cos(edge) - cyLocal * math.sin(edge),
            y: p1.y + cxLocal * math.sin(edge) + cyLocal * math.cos(edge),
          ),
          width: bw,
          height: bh,
          angle: edge,
        );
      }
    }
    return best;
  }

  /// Andrew 单调链凸包。
  List<({double x, double y})> _convexHull(
    List<({double x, double y})> points,
  ) {
    if (points.length <= 3) return List<({double x, double y})>.of(points);
    final List<({double x, double y})> sorted =
        List<({double x, double y})>.of(points)
          ..sort((
            ({double x, double y}) a,
            ({double x, double y}) b,
          ) => a.x == b.x ? a.y.compareTo(b.y) : a.x.compareTo(b.x));

    List<({double x, double y})> half(
      List<({double x, double y})> pts,
    ) {
      final List<({double x, double y})> hull = <({double x, double y})>[];
      for (final ({double x, double y}) p in pts) {
        while (hull.length >= 2) {
          final ({double x, double y}) a = hull[hull.length - 2];
          final ({double x, double y}) b = hull[hull.length - 1];
          final double cross =
              (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x);
          if (cross > 0) break;
          hull.removeLast();
        }
        hull.add(p);
      }
      return hull;
    }

    final List<({double x, double y})> lower = half(sorted);
    final List<({double x, double y})> upper = half(
      List<({double x, double y})>.of(sorted.reversed),
    );
    upper.removeAt(0);
    upper.removeLast();
    return <({double x, double y})>[...lower, ...upper];
  }

  /// 框内概率均值（按矩形内外判定，不做栅格蒙版）。
  double _boxScore(
    Float32List prob,
    int predH,
    int predW,
    List<({double x, double y})> corners,
  ) {
    double minX = corners.first.x, maxX = corners.first.x;
    double minY = corners.first.y, maxY = corners.first.y;
    for (final ({double x, double y}) p in corners) {
      minX = math.min(minX, p.x);
      maxX = math.max(maxX, p.x);
      minY = math.min(minY, p.y);
      maxY = math.max(maxY, p.y);
    }
    final int x0 = minX.floor().clamp(0, predW - 1);
    final int x1 = maxX.ceil().clamp(0, predW - 1);
    final int y0 = minY.floor().clamp(0, predH - 1);
    final int y1 = maxY.ceil().clamp(0, predH - 1);

    double total = 0;
    int count = 0;
    for (int y = y0; y <= y1; y++) {
      for (int x = x0; x <= x1; x++) {
        if (!_inside(corners, x + 0.5, y + 0.5)) continue;
        total += prob[y * predW + x];
        count++;
      }
    }
    return count == 0 ? 0 : total / count;
  }

  /// 点在四边形内（凸的；用同侧判定）。
  bool _inside(List<({double x, double y})> quad, double px, double py) {
    bool hasNeg = false;
    bool hasPos = false;
    for (int i = 0; i < quad.length; i++) {
      final ({double x, double y}) a = quad[i];
      final ({double x, double y}) b = quad[(i + 1) % quad.length];
      final double cross =
          (b.x - a.x) * (py - a.y) - (b.y - a.y) * (px - a.x);
      if (cross < 0) hasNeg = true;
      if (cross > 0) hasPos = true;
      if (hasNeg && hasPos) return false;
    }
    return true;
  }

  double _dist(({double x, double y}) a, ({double x, double y}) b) {
    final double dx = a.x - b.x;
    final double dy = a.y - b.y;
    return math.sqrt(dx * dx + dy * dy);
  }
}

/// 旋转矩形。
class _Rect {
  const _Rect({
    required this.center,
    required this.width,
    required this.height,
    required this.angle,
  });

  final ({double x, double y}) center;
  final double width;
  final double height;

  /// 弧度。
  final double angle;

  double get shortSide => math.min(width, height);

  /// 四个角，顺序：左上 / 右上 / 右下 / 左下。
  ///
  /// 用「按 x 分左右、各自按 y 排」固定顺序，和 PP-OCR 的 get_mini_boxes 一致。
  List<({double x, double y})> get corners {
    final double hw = width / 2;
    final double hh = height / 2;
    final double cosA = math.cos(angle);
    final double sinA = math.sin(angle);

    ({double x, double y}) at(double dx, double dy) => (
      x: center.x + dx * cosA - dy * sinA,
      y: center.y + dx * sinA + dy * cosA,
    );

    final List<({double x, double y})> pts = <({double x, double y})>[
      at(-hw, -hh),
      at(hw, -hh),
      at(hw, hh),
      at(-hw, hh),
    ];

    pts.sort((
      ({double x, double y}) a,
      ({double x, double y}) b,
    ) => a.x.compareTo(b.x));
    final List<({double x, double y})> left = pts.sublist(0, 2)
      ..sort((
        ({double x, double y}) a,
        ({double x, double y}) b,
      ) => a.y.compareTo(b.y));
    final List<({double x, double y})> right = pts.sublist(2, 4)
      ..sort((
        ({double x, double y}) a,
        ({double x, double y}) b,
      ) => a.y.compareTo(b.y));

    return <({double x, double y})>[
      left[0], // 左上
      right[0], // 右上
      right[1], // 右下
      left[1], // 左下
    ];
  }
}
