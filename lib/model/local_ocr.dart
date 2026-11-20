// 内置 OCR 的门面：全平台同一套 PP-OCR + ONNX Runtime。
//
// 模型不随 app 打包，由 OcrModelManager 下载到应用数据目录的
// models/ocr/；这里只负责从那里加载。不联网、不读 provider / API Key、
// 不调用外部进程。

import 'dart:io';

import 'ocr/ocr_models.dart';
import 'ocr/ppocr_engine.dart';

class LocalOcrEngine {
  LocalOcrEngine._();

  static final LocalOcrEngine instance = LocalOcrEngine._();

  final PpOcrEngine _engine = PpOcrEngine();
  Future<void>? _loading;
  String? _dir;

  /// 模型根目录，允许测试注入；默认走 [defaultOcrModelRoot]。
  String? modelRootOverride;

  Future<String> _modelDir() async {
    final String? cached = _dir;
    if (cached != null) return cached;
    final String root = modelRootOverride ?? await defaultOcrModelRoot();
    final String dir = '$root${Platform.pathSeparator}ocr';
    _dir = dir;
    return dir;
  }

  /// 模型是否已装好（供 UI 查询）。
  Future<bool> isInstalled() async {
    final String root = modelRootOverride ?? await defaultOcrModelRoot();
    return OcrModelManager(modelsRoot: root).isInstalled();
  }

  Future<void> _ensureLoaded() async {
    if (_engine.isReady) return;
    _loading ??= () async {
      try {
        final String dir = await _modelDir();
        final String det = '$dir${Platform.pathSeparator}ch_PP-OCRv5_det_mobile.onnx';
        final String rec = '$dir${Platform.pathSeparator}ch_PP-OCRv5_rec_mobile.onnx';
        final String dict = '$dir${Platform.pathSeparator}ch_ppocrv5_dict.txt';
        for (final String path in <String>[det, rec, dict]) {
          if (!File(path).existsSync()) {
            throw StateError('OCR 模型未安装：$path（请在 设置 → 行为 下载）');
          }
        }
        await _engine.load(detModelPath: det, recModelPath: rec, dictPath: dict);
      } catch (_) {
        _loading = null;
        rethrow;
      }
    }();
    await _loading;
  }

  /// 识别一张本地图片，返回按行拼好的纯文本。
  Future<({String text, String? error})> recognizeText(String imagePath) async {
    try {
      await _ensureLoaded();
      final result = await _engine.recognizeFile(imagePath);
      if (!result.ok) return (text: '', error: result.error);
      return (text: result.text, error: null);
    } catch (err) {
      return (text: '', error: '$err');
    }
  }

  /// 只用于排查的完整结果。
  Future<({String text, int ms, int lines, String? error})> recognizeDebug(
    String imagePath,
  ) async {
    try {
      await _ensureLoaded();
      final result = await _engine.recognizeFile(imagePath);
      if (!result.ok) {
        return (text: '', ms: 0, lines: 0, error: result.error);
      }
      return (
        text: result.text,
        ms: result.totalMs,
        lines: result.lines.length,
        error: null,
      );
    } catch (err) {
      return (text: '', ms: 0, lines: 0, error: '$err');
    }
  }

  /// 给测试用：直接喂已解码的字节。
  Future<({String text, String? error})> recognizeBytes(List<int> bytes) async {
    final Directory dir = await Directory.systemTemp.createTemp('joenws_ocr_');
    try {
      final File file = File('${dir.path}${Platform.pathSeparator}in.png');
      await file.writeAsBytes(bytes, flush: true);
      return await recognizeText(file.path);
    } finally {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  }

  void dispose() {
    _engine.dispose();
    _loading = null;
    _dir = null;
  }
}
