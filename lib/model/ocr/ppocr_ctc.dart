// CTC 解码。
//
// 识别模型输出 [T, C]：每个时间步在字符表上分布。
// 解码规则：取 argmax → 去掉 blank（索引 0）→ 合并相邻重复 → 查表。

import 'dart:typed_data';

/// 字符表 = ['blank', ...字典, ' ']。
List<String> buildCtcLabel(List<String> dict) => <String>['', ...dict, ' '];

/// 返回 (text, 置信度)。
(String, double) ctcDecode(
  Float32List preds,
  int timeSteps,
  int numClasses,
  List<String> labels,
) {
  final StringBuffer text = StringBuffer();
  double confSum = 0;
  int confCount = 0;
  int prev = -1;

  for (int t = 0; t < timeSteps; t++) {
    final int base = t * numClasses;
    int best = 0;
    double bestVal = preds[base];
    for (int c = 1; c < numClasses; c++) {
      final double v = preds[base + c];
      if (v > bestVal) {
        bestVal = v;
        best = c;
      }
    }

    if (best != 0 && best != prev) {
      if (best < labels.length) text.write(labels[best]);
      confSum += bestVal;
      confCount++;
    }
    prev = best;
  }

  return (text.toString(), confCount == 0 ? 0 : confSum / confCount);
}
