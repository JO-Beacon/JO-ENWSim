// PP-OCR 引擎：自己接 ONNX Runtime，不依赖只覆盖一半平台的包装包。
//
// 流程：
//   原图 → 检测预处理（CHW）→ det 模型 → DB 后处理 → 四边形框
//        → 每个框透视矫正 → 识别预处理（高 48）→ rec 模型 → CTC 解码 → 文本
//
// 全平台同一套模型文件，同一套算法。

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:image/image.dart' as img;
import 'package:onnxruntime_v2/onnxruntime_v2.dart';

import 'ppocr_ctc.dart';
import 'ppocr_db.dart';
import 'ppocr_image.dart';
import 'ppocr_types.dart';

class PpOcrEngine {
  PpOcrEngine({this.options = const PpOcrOptions()});

  final PpOcrOptions options;

  OrtSession? _det;
  OrtSession? _rec;
  OrtRunOptions? _runOptions;
  List<String>? _labels;
  String? _loadedKey;

  bool get isReady => _det != null && _rec != null;

  /// 加载模型。重复调用同一组路径时直接复用。
  Future<void> load({
    required String detModelPath,
    required String recModelPath,
    required String dictPath,
  }) async {
    final String key = '$detModelPath|$recModelPath|$dictPath';
    if (_loadedKey == key && isReady) return;

    final OrtSessionOptions sessionOptions = OrtSessionOptions();
    sessionOptions.setIntraOpNumThreads(1);
    sessionOptions.setInterOpNumThreads(1);
    try {
      final Uint8List detBytes = await File(detModelPath).readAsBytes();
      final Uint8List recBytes = await File(recModelPath).readAsBytes();
      final List<String> dict = (await File(dictPath).readAsLines())
          .map((String l) => l.trimRight())
          .toList();

      _disposeSessions();
      _det = OrtSession.fromBuffer(detBytes, sessionOptions);
      _rec = OrtSession.fromBuffer(recBytes, sessionOptions);
      _runOptions ??= OrtRunOptions();
      _labels = buildCtcLabel(dict);
      _loadedKey = key;
    } finally {
      sessionOptions.release();
    }
  }

  /// 识别一张图片。
  Future<PpOcrResult> recognizeImage(img.Image source) async {
    if (!isReady) {
      return const PpOcrResult(error: 'OCR 模型还没加载。');
    }

    final int stopwatchDetStart = DateTime.now().microsecondsSinceEpoch;
    final ChwTensor detInput = preprocessDetection(
      source,
      limitSide: options.detLimitSide,
      minSide: options.detMinSide,
      maxSide: options.detMaxSide,
    );

    final Float32List prob;
    final int predW;
    final int predH;
    try {
      final OrtValueTensor input = OrtValueTensor.createTensorWithDataList(
        <Object>[detInput.data],
        <int>[1, 3, detInput.height, detInput.width],
      );
      final List<OrtValue?> outputs = _det!.run(_runOptions!, <String, OrtValue>{
        'x': input,
      });
      input.release();

      final OrtValueTensor out = outputs.first! as OrtValueTensor;
      final List<dynamic> data = out.value as List<dynamic>;
      // [1, 1, H, W]
      final List<dynamic> plane = (data.first as List<dynamic>).first
          as List<dynamic>;
      predH = plane.length;
      predW = (plane.first as List<dynamic>).length;
      prob = Float32List(predH * predW);
      for (int y = 0; y < predH; y++) {
        final List<dynamic> row = plane[y] as List<dynamic>;
        for (int x = 0; x < predW; x++) {
          prob[y * predW + x] = (row[x] as num).toDouble();
        }
      }
      out.release();
    } catch (err) {
      return PpOcrResult(error: '检测失败：$err');
    }

    final int detMs =
        (DateTime.now().microsecondsSinceEpoch - stopwatchDetStart) ~/ 1000;

    final List<DetBox> boxes = const DbPostProcess(
      thresh: 0.3,
      boxThresh: 0.6,
      unclipRatio: 1.5,
    ).process(prob, predH, predW, source.height, source.width);

    if (boxes.isEmpty) {
      return PpOcrResult(detectionMs: detMs);
    }

    final int stopwatchRecStart = DateTime.now().microsecondsSinceEpoch;
    final List<PpOcrLine> lines = <PpOcrLine>[];
    final int limit = boxes.length > options.maxLines
        ? options.maxLines
        : boxes.length;

    for (int i = 0; i < limit; i++) {
      final DetBox box = boxes[i];
      try {
        final List<({double x, double y})> quad = box.corners;
        final ChwTensor recInput = preprocessRecognition(
          source,
          quad: <Offset>[
            for (final ({double x, double y}) p in quad)
              Offset(p.x, p.y),
          ],
          recHeight: options.recHeight,
          recMaxWidth: options.recMaxWidth,
        );

        final OrtValueTensor input = OrtValueTensor.createTensorWithDataList(
          <Object>[recInput.data],
          <int>[1, 3, recInput.height, recInput.width],
        );
        final List<OrtValue?> outputs = _rec!.run(
          _runOptions!,
          <String, OrtValue>{'x': input},
        );
        input.release();

        final OrtValueTensor out = outputs.first! as OrtValueTensor;
        final List<dynamic> data = out.value as List<dynamic>;
        final List<dynamic> steps = data.first as List<dynamic>;
        final int timeSteps = steps.length;
        final int classes = (steps.first as List<dynamic>).length;

        final Float32List preds = Float32List(timeSteps * classes);
        for (int t = 0; t < timeSteps; t++) {
          final List<dynamic> row = steps[t] as List<dynamic>;
          final int base = t * classes;
          for (int c = 0; c < classes; c++) {
            preds[base + c] = (row[c] as num).toDouble();
          }
        }
        out.release();

        final (String, double) decoded = ctcDecode(
          preds,
          timeSteps,
          classes,
          _labels!,
        );
        if (decoded.$1.trim().isEmpty) continue;
        if (decoded.$2 < options.recMinScore) continue;

        lines.add(
          PpOcrLine(
            text: decoded.$1,
            confidence: decoded.$2,
            box: <Offset>[
              for (final ({double x, double y}) p in quad)
                Offset(p.x, p.y),
            ],
          ),
        );
      } catch (_) {
        // 单行失败不影响其他行。
        continue;
      }
    }

    final int recMs =
        (DateTime.now().microsecondsSinceEpoch - stopwatchRecStart) ~/ 1000;
    return PpOcrResult(lines: lines, detectionMs: detMs, recognitionMs: recMs);
  }

  /// 从文件识别。
  Future<PpOcrResult> recognizeFile(String path) async {
    final Uint8List bytes = await File(path).readAsBytes();
    final img.Image? decoded = img.decodeImage(bytes);
    if (decoded == null) {
      return const PpOcrResult(error: '这张图片解不开（格式不支持或文件损坏）。');
    }
    return recognizeImage(decoded);
  }

  void _disposeSessions() {
    _det?.release();
    _rec?.release();
    _det = null;
    _rec = null;
  }

  void dispose() {
    _disposeSessions();
    _runOptions?.release();
    _runOptions = null;
    _labels = null;
    _loadedKey = null;
  }
}
