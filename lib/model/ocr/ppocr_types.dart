// PP-OCR 的数据类型与参数。
//
// 我们自己接中游：模型和推理都走 ONNX Runtime，
// 不依赖任何“只覆盖一半平台”的 Flutter 包装包。

import 'dart:ui' show Offset;

/// 一行识别结果。
class PpOcrLine {
  const PpOcrLine({
    required this.text,
    required this.confidence,
    required this.box,
  });

  final String text;
  final double confidence;

  /// 原图坐标系下的四个角，顺序固定为 左上 / 右上 / 右下 / 左下。
  final List<Offset> box;
}

/// 一页识别结果。
class PpOcrResult {
  const PpOcrResult({
    this.lines = const <PpOcrLine>[],
    this.detectionMs = 0,
    this.recognitionMs = 0,
    this.error,
  });

  final List<PpOcrLine> lines;
  final int detectionMs;
  final int recognitionMs;
  final String? error;

  bool get ok => error == null;

  int get totalMs => detectionMs + recognitionMs;

  /// 按检测框顺序拼成一段文本，一行一个。
  String get text => lines
      .map((PpOcrLine l) => l.text.trim())
      .where((String s) => s.isNotEmpty)
      .join('\n');
}

/// 检测 / 识别的可调参数。默认值照 PP-OCR 官方 mobile 配置。
class PpOcrOptions {
  const PpOcrOptions({
    this.detThresh = 0.3,
    this.detBoxThresh = 0.6,
    this.detUnclipRatio = 1.5,
    this.detLimitSide = 960,
    this.detMinSide = 64,
    this.detMaxSide = 4000,
    this.recHeight = 48,
    this.recMaxWidth = 2048,
    this.recMinScore = 0.0,
    this.maxLines = 300,
  });

  /// DB 概率图阈值。
  final double detThresh;

  /// 框内平均分的下限。
  final double detBoxThresh;

  /// 外扩比例。
  final double detUnclipRatio;

  /// 检测时最长边目标；超过就缩小。
  final int detLimitSide;

  /// 检测时最短边下限；低于就放大（小图不会缩成一片噪点）。
  final int detMinSide;

  /// 硬上限，防止超大图把内存打满。
  final int detMaxSide;

  /// 识别输入高度。
  final int recHeight;

  /// 识别输入最大宽度。
  final int recMaxWidth;

  /// 识别分下限；低于就丢掉这一行。
  final double recMinScore;

  /// 最多识别多少行，防止一页几千行卡死。
  final int maxLines;
}
