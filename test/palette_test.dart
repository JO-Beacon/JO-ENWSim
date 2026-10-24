// 调色板：强调色在两个主题下必须是**同一色相**，只是深浅不同。
//
// 以前暗色是淡蓝灰（#8AA0B8），浅色却是金褐（#9A7B4F）——
// 切到浅色，“链接 / 卡片标题 / 选中的世界名 / `>` 提示符”全变成橄榄色，
// 看着像发绿。那就是用户说的“原本淡蓝的地方变绿了”。

import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/theme/tokens.dart';

/// sRGB 分量 → 线性光（WCAG 的算法）。
double _lin(double v) =>
    v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();

double luminance(Color c) =>
    0.2126 * _lin(c.r) + 0.7152 * _lin(c.g) + 0.0722 * _lin(c.b);

/// 前景 / 背景对比度（WCAG）。4.5 是正文的及格线。
double contrast(Color fg, Color bg) {
  final double a = luminance(fg);
  final double b = luminance(bg);
  final double hi = math.max(a, b);
  final double lo = math.min(a, b);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  test('强调色：两个主题同一色相（蓝），只是深浅不同', () {
    final double dh = HSVColor.fromColor(JoPalette.dark.accent).hue;
    final double lh = HSVColor.fromColor(JoPalette.light.accent).hue;
    double diff = (dh - lh).abs();
    if (diff > 180) diff = 360 - diff;

    expect(diff, lessThan(12), reason: '暗 $dh° vs 浅 $lh°，色相不一样');
    expect(dh, inInclusiveRange(195, 230), reason: '强调色是蓝族');
    expect(
      HSVColor.fromColor(JoPalette.light.accent).value,
      lessThan(HSVColor.fromColor(JoPalette.dark.accent).value),
      reason: '浅色主题上要压深一档',
    );
  });

  test('强调色在各自底色上够清楚（对比度 ≥ 4.5）', () {
    expect(
      contrast(JoPalette.dark.accent, JoPalette.dark.bg),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      contrast(JoPalette.light.accent, JoPalette.light.bg),
      greaterThanOrEqualTo(4.5),
    );
  });
}
