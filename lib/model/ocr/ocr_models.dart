// OCR 模型的运行时下载与管理。
//
// 三个模型不随安装包，首次启动时询问后下载到应用数据目录：
//   <modelsRoot>/ocr/ch_PP-OCRv5_det_mobile.onnx
//   <modelsRoot>/ocr/ch_PP-OCRv5_rec_mobile.onnx
//   <modelsRoot>/ocr/ch_ppocrv5_dict.txt
//
// 来源：RapidOCR v3.9.2 官方模型（魔搭社区托管，Apache-2.0）。
// 下载先落 .part，校验 SHA-256 后再落盘。det 有个特殊处理：官方原版
// 声明 ONNX IR 10，而本项目内置的 ONNX Runtime 1.22 只支持到 IR 9，
// 加载会被拒。所以校验官方原版哈希后，把第 2 个字节 10 改成 9，
// 并再校验一次改完的哈希，确保改的确实是那一个字节。

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../network.dart';

/// 一个可下载的 OCR 模型文件。
class OcrModelSpec {
  const OcrModelSpec({
    required this.id,
    required this.fileName,
    required this.url,
    required this.officialSha256,
    required this.installedSha256,
    required this.bytes,
    this.patchIrVersion = false,
  });

  final String id;
  final String fileName;

  /// 官方原版下载地址。
  final String url;

  /// 官方原版的 SHA-256（下载后先按这个校验）。
  final String officialSha256;

  /// 落到磁盘后的 SHA-256（det 修补后与官方不同）。
  final String installedSha256;

  final int bytes;

  /// 是否需要把 IR 版本字节 10 改成 9。
  final bool patchIrVersion;
}

const String _kModelBase =
    'https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.9.2';

const List<OcrModelSpec> kOcrModelFiles = <OcrModelSpec>[
  OcrModelSpec(
    id: 'det',
    fileName: 'ch_PP-OCRv5_det_mobile.onnx',
    url: '$_kModelBase/onnx/PP-OCRv5/det/ch_PP-OCRv5_det_mobile.onnx',
    officialSha256: '4d97c44a20d30a81aad087d6a396b08f786c4635742afc391f6621f5c6ae78ae',
    installedSha256: '34c3923180271102580a1287bad09f57536a6813b512b4b2d5de29bf8cd9d81a',
    bytes: 4819576,
    patchIrVersion: true,
  ),
  OcrModelSpec(
    id: 'rec',
    fileName: 'ch_PP-OCRv5_rec_mobile.onnx',
    url: '$_kModelBase/onnx/PP-OCRv5/rec/ch_PP-OCRv5_rec_mobile.onnx',
    officialSha256: '5825fc7ebf84ae7a412be049820b4d86d77620f204a041697b0494669b1742c5',
    installedSha256: '5825fc7ebf84ae7a412be049820b4d86d77620f204a041697b0494669b1742c5',
    bytes: 16631306,
  ),
  OcrModelSpec(
    id: 'dict',
    fileName: 'ch_ppocrv5_dict.txt',
    url: '$_kModelBase/paddle/PP-OCRv5/rec/ch_PP-OCRv5_rec_mobile/ppocrv5_dict.txt',
    officialSha256: 'd1979e9f794c464c0d2e0b70a7fe14dd978e9dc644c0e71f14158cdf8342af1b',
    installedSha256: 'd1979e9f794c464c0d2e0b70a7fe14dd978e9dc644c0e71f14158cdf8342af1b',
    bytes: 74012,
  ),
];

/// 三个模型的总大小，给询问弹窗显示。
int get kOcrTotalBytes =>
    kOcrModelFiles.fold<int>(0, (int sum, OcrModelSpec f) => sum + f.bytes);

/// 默认模型根目录（与 TTS 共用）：应用数据目录下的 models。
Future<String> defaultOcrModelRoot() async {
  final String? override = Platform.environment['JOENWS_TTS_MODEL_ROOT'];
  if (override != null && override.trim().isNotEmpty) return override.trim();
  final Directory support = await getApplicationSupportDirectory();
  return '${support.path}${Platform.pathSeparator}models';
}

class OcrModelManager {
  OcrModelManager({required this.modelsRoot, this.client});

  final String modelsRoot;

  /// 测试可注入；正常运行时走网络设置里的 Client。
  final http.Client? client;

  String get ocrDir => '$modelsRoot${Platform.pathSeparator}ocr';

  String pathOf(OcrModelSpec f) =>
      '$ocrDir${Platform.pathSeparator}${f.fileName}';

  /// 单个文件是否已正确安装（存在且哈希匹配）。
  Future<bool> isFileInstalled(OcrModelSpec f) async {
    final File file = File(pathOf(f));
    if (!await file.exists()) return false;
    if (await file.length() != f.bytes) return false;
    final String actual = (await sha256.bind(file.openRead()).first).toString();
    return actual == f.installedSha256;
  }

  /// 三个模型是否都装好了。
  Future<bool> isInstalled() async {
    for (final OcrModelSpec f in kOcrModelFiles) {
      if (!await isFileInstalled(f)) return false;
    }
    return true;
  }

  /// 下载并安装全部模型。[onProgress] 收到 0..1 的总进度。
  Future<void> installAll({
    void Function(double progress, String label)? onProgress,
  }) async {
    int done = 0;
    for (final OcrModelSpec f in kOcrModelFiles) {
      await installFile(
        f,
        onProgress: (double p) {
          final double overall = (done + p) / kOcrModelFiles.length;
          onProgress?.call(overall, f.fileName);
        },
      );
      done++;
    }
    onProgress?.call(1, '');
    await cleanLegacy();
  }

  /// 下载并安装单个模型。
  Future<void> installFile(
    OcrModelSpec f, {
    void Function(double progress)? onProgress,
  }) async {
    final Directory dir = Directory(ocrDir);
    if (!await dir.exists()) await dir.create(recursive: true);
    final File target = File(pathOf(f));

    // 已经装好就跳过，不重复下载。
    if (await isFileInstalled(f)) {
      onProgress?.call(1);
      return;
    }

    final File partFile = File('${target.path}.part');
    if (await partFile.exists()) await partFile.delete();
    await _download(f, partFile, onProgress);

    try {
      // 先验官方原版哈希，确认下载内容可信。
      final String official =
          (await sha256.bind(partFile.openRead()).first).toString();
      if (official != f.officialSha256) {
        throw StateError('SHA-256 校验失败：期望 ${f.officialSha256}，实际 $official');
      }

      Uint8List bytes = await partFile.readAsBytes();
      if (f.patchIrVersion) {
        bytes = _patchIrTo9(bytes, f.fileName);
        final String patched = _sha256Of(bytes);
        if (patched != f.installedSha256) {
          throw StateError('IR 修补后哈希不符：期望 ${f.installedSha256}，实际 $patched');
        }
      }

      await target.writeAsBytes(bytes, flush: true);
      final String installed =
          (await sha256.bind(target.openRead()).first).toString();
      if (installed != f.installedSha256) {
        await target.delete();
        throw StateError('落盘校验失败：期望 ${f.installedSha256}，实际 $installed');
      }
    } finally {
      if (await partFile.exists()) await partFile.delete();
    }
  }

  /// 官方原版 IR 10 → 9：protobuf 模型头第 2 个字节（索引 1）。
  Uint8List _patchIrTo9(Uint8List bytes, String fileName) {
    if (bytes.length < 2) {
      throw StateError('$fileName 太短，无法修补 IR 版本');
    }
    if (bytes[0] != 0x08) {
      throw StateError('$fileName 模型头格式不对，未修补 IR 版本');
    }
    if (bytes[1] == 0x09) {
      // 已经是 IR 9（比如官方升级了），直接返回。
      return bytes;
    }
    if (bytes[1] != 0x0A) {
      throw StateError('$fileName 的 IR 版本不是 10（0x0A），未盲目修补');
    }
    final Uint8List patched = Uint8List.fromList(bytes);
    patched[1] = 0x09;
    return patched;
  }

  String _sha256Of(List<int> bytes) =>
      sha256.convert(bytes).toString();

  Future<void> _download(
    OcrModelSpec f,
    File target,
    void Function(double progress)? onProgress,
  ) async {
    final http.Client effective = client ?? NetworkRuntime.newClient();
    IOSink? sink;
    try {
      final http.Request request = http.Request('GET', Uri.parse(f.url));
      final http.StreamedResponse response = await effective.send(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('下载失败：HTTP ${response.statusCode}');
      }
      final int total = response.contentLength ?? f.bytes;
      int received = 0;
      sink = target.openWrite();
      await for (final List<int> chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call((received / total).clamp(0, 1));
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (await target.length() != f.bytes) {
        throw StateError('下载大小不对：期望 ${f.bytes} 字节，实际 ${await target.length()}');
      }
    } catch (e) {
      try {
        await sink?.close();
      } catch (_) {}
      if (await target.exists()) await target.delete();
      rethrow;
    } finally {
      // 只有自己新建的 client 才关；注入的交给调用方。
      if (client == null) effective.close();
    }
  }

  /// 清理旧版从 assets materialize 出来的 support/ocr 目录。
  /// 只在三个新模型都装好之后才有意义，避免删了旧的又没装新的。
  Future<void> cleanLegacy() async {
    if (!await isInstalled()) return;
    final Directory support = await getApplicationSupportDirectory();
    final Directory legacy =
        Directory('${support.path}${Platform.pathSeparator}ocr');
    if (await legacy.exists()) {
      await legacy.delete(recursive: true);
    }
  }
}
