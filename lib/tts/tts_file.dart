// 把合成好的音频落成文件。
//
// 先做 A 方案：只写文件，不引音频播放插件。
// 播放是另一层的事（要加插件，得单独决定）。

import 'dart:io';
import 'dart:typed_data';

import '../model/tts_types.dart';

/// 保存一段合成音频，返回文件路径。
///
/// [directory] 由调用方给（应用数据目录 / 临时目录 / 用户选的目录）。
/// [fileName] 不给就按时间戳起名，并自动补上 [TtsResult.extension]。
Future<String> saveTtsAudio(
  TtsResult result, {
  required Directory directory,
  String? fileName,
}) async {
  final Uint8List? bytes = result.bytes;
  if (!result.ok || bytes == null || bytes.isEmpty) {
    throw ArgumentError('没有可保存的音频：${result.message}');
  }
  await directory.create(recursive: true);

  final String ext = result.extension.trim();
  String name = (fileName ?? '').trim();
  if (name.isEmpty) {
    final DateTime now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final String stamp =
        '${now.year}${two(now.month)}${two(now.day)}'
        '_${two(now.hour)}${two(now.minute)}${two(now.second)}'
        '_${now.millisecond.toString().padLeft(3, '0')}';
    name = 'tts_$stamp';
  }
  if (ext.isNotEmpty && !name.toLowerCase().endsWith('.$ext')) {
    name = '$name.$ext';
  }

  final File file = File('${directory.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}
