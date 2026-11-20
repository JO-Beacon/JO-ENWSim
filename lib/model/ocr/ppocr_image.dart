// PP-OCR 的图片预处理。
//
// 检测：等比缩放到「最长边 ≤ limit、最短边 ≥ min」，宽高对齐到 32 的倍数，
//       归一化成 CHW。
// 识别：把四边形透视矫正成矩形，缩放到高 48、宽按比例，再归一化成 CHW。
//
// 归一化用的是 PP-OCR 的 (x/255 - 0.5) / 0.5，也就是 (x - 127.5) / 127.5。

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:image/image.dart' as img;

/// 归一化后的 CHW 张量。
class ChwTensor {
  const ChwTensor({
    required this.data,
    required this.width,
    required this.height,
  });

  final Float32List data;
  final int width;
  final int height;
}

/// 检测预处理：返回对齐到 32 倍数的 CHW 张量。
ChwTensor preprocessDetection(
  img.Image src, {
  int limitSide = 960,
  int minSide = 64,
  int maxSide = 4000,
}) {
  final int h = math.max(1, src.height);
  final int w = math.max(1, src.width);

  double ratio = 1;
  final int longest = math.max(h, w);
  final int shortest = math.min(h, w);
  if (longest > limitSide) {
    ratio = limitSide / longest;
  } else if (shortest < minSide) {
    // 小图放大：放大到最短边够 minSide，但别超过 maxSide。
    ratio = math.min(minSide / shortest, maxSide / longest);
  }

  int resizeH = (h * ratio).round();
  int resizeW = (w * ratio).round();
  resizeH = math.max(32, (resizeH / 32).round() * 32);
  resizeW = math.max(32, (resizeW / 32).round() * 32);
  if (resizeH > maxSide) resizeH = (maxSide / 32).floor() * 32;
  if (resizeW > maxSide) resizeW = (maxSide / 32).floor() * 32;

  final img.Image resized = (resizeW == w && resizeH == h)
      ? src
      : img.copyResize(
          src,
          width: resizeW,
          height: resizeH,
          interpolation: img.Interpolation.linear,
        );

  return ChwTensor(
    data: normalizeChw(resized),
    width: resized.width,
    height: resized.height,
  );
}

/// 识别预处理：把四边形矫正成矩形，缩放到高 [recHeight]。
///
/// 返回的 [ChwTensor.width] 是实际缩放后的宽度（模型支持动态宽度）。
ChwTensor preprocessRecognition(
  img.Image src, {
  required List<Offset> quad,
  int recHeight = 48,
  int recMaxWidth = 2048,
}) {
  final img.Image rectified = rectify(src, quad);

  final double ratio = rectified.width / rectified.height;
  int resizeW = (recHeight * ratio).ceil();
  resizeW = resizeW.clamp(1, recMaxWidth);

  final img.Image resized = img.copyResize(
    rectified,
    width: resizeW,
    height: recHeight,
    interpolation: img.Interpolation.linear,
  );

  return ChwTensor(
    data: normalizeChw(resized),
    width: resized.width,
    height: resized.height,
  );
}

/// 按四边形把 [src] 透视矫正成矩形。
///
/// [quad] 顺序必须是 左上 / 右上 / 右下 / 左下。
img.Image rectify(img.Image src, List<Offset> quad) {
  if (quad.length != 4) {
    throw ArgumentError.value(quad, 'quad', '必须是四个点');
  }
  final double top = _dist(quad[0], quad[1]);
  final double bottom = _dist(quad[3], quad[2]);
  final double left = _dist(quad[0], quad[3]);
  final double right = _dist(quad[1], quad[2]);

  final int w = math.max(1, math.max(top, bottom).round());
  final int h = math.max(1, math.max(left, right).round());

  final img.Image dst = img.Image(width: w, height: h, numChannels: 3);
  final img.Point tl = img.Point(quad[0].dx, quad[0].dy);
  final img.Point tr = img.Point(quad[1].dx, quad[1].dy);
  final img.Point br = img.Point(quad[2].dx, quad[2].dy);
  final img.Point bl = img.Point(quad[3].dx, quad[3].dy);

  for (int y = 0; y < h; y++) {
    final double v = h == 1 ? 0 : y / (h - 1);
    for (int x = 0; x < w; x++) {
      final double u = w == 1 ? 0 : x / (w - 1);
      // 双线性插值：四条边按 u / v 混合。
      final double sx = tl.x * (1 - u) * (1 - v) +
          tr.x * u * (1 - v) +
          bl.x * (1 - u) * v +
          br.x * u * v;
      final double sy = tl.y * (1 - u) * (1 - v) +
          tr.y * u * (1 - v) +
          bl.y * (1 - u) * v +
          br.y * u * v;
      dst.setPixel(x, y, src.getPixelInterpolate(sx, sy));
    }
  }
  return dst;
}

/// 归一化并转成 CHW（RGB 平面顺序）。
Float32List normalizeChw(img.Image image) {
  final int w = image.width;
  final int h = image.height;
  final Float32List out = Float32List(3 * h * w);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final img.Pixel p = image.getPixel(x, y);
      final int idx = y * w + x;
      out[idx] = (p.r - 127.5) / 127.5;
      out[h * w + idx] = (p.g - 127.5) / 127.5;
      out[2 * h * w + idx] = (p.b - 127.5) / 127.5;
    }
  }
  return out;
}

double _dist(Offset a, Offset b) {
  final double dx = a.dx - b.dx;
  final double dy = a.dy - b.dy;
  return math.sqrt(dx * dx + dy * dy);
}
