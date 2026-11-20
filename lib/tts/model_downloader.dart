// 运行时下载 / 校验 / 解包 TTS 模型。
//
// 下载先落 .part，SHA-256 不通过就删掉；解包只接受归档里的相对路径，
// 防止 ../ 之类的东西写到模型目录外面。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../model/network.dart';
import 'downloadable_models.dart';
import 'model_store.dart';

class TtsModelDownloader {
  TtsModelDownloader({required this.modelsRoot, this.client});

  final String modelsRoot;

  /// 测试可以注入；正常运行时用网络设置里的 Client。
  final http.Client? client;

  Future<InstalledTtsModel> install(
    DownloadableTtsModel model, {
    void Function(double progress)? onProgress,
  }) async {
    final Directory root = Directory(modelsRoot);
    final Directory downloads = Directory('${root.path}/.downloads');
    await downloads.create(recursive: true);
    final File archive = File('${downloads.path}/${model.id}.tar.bz2');

    if (!await _isValidArchive(archive, model)) {
      if (await archive.exists()) await archive.delete();
      await _download(model, archive, onProgress);
    }

    if (model.sha256.isNotEmpty) {
      final String actual =
          (await sha256.bind(archive.openRead()).first).toString();
      if (actual != model.sha256) {
        await archive.delete();
        throw StateError('SHA-256 校验失败：期望 ${model.sha256}，实际 $actual');
      }
    } else if (await archive.length() != model.archiveBytes) {
      await archive.delete();
      throw StateError('归档大小不对：期望 ${model.archiveBytes} 字节');
    }

    final Directory target = Directory('${root.path}/${model.id}');
    if (await target.exists()) await target.delete(recursive: true);
    await target.create(recursive: true);

    final Uint8List compressed = await archive.readAsBytes();
    final Uint8List tarBytes;
    try {
      tarBytes = BZip2Decoder().decodeBytes(compressed);
    } catch (e) {
      throw StateError('解压失败：$e');
    }
    final Archive decoded = TarDecoder().decodeBytes(tarBytes);

    String? rootPrefix;
    for (final ArchiveFile f in decoded.files) {
      final String name = _safeName(f.name);
      if (name.endsWith('/model.onnx')) {
        rootPrefix = name.substring(0, name.length - 'model.onnx'.length);
        break;
      }
    }
    if (rootPrefix == null) {
      throw StateError('归档里没有 model.onnx');
    }

    for (final ArchiveFile f in decoded.files) {
      if (!f.isFile) continue;
      final String name = _safeName(f.name);
      if (!name.startsWith(rootPrefix)) continue;
      final String relative = name.substring(rootPrefix.length);
      if (relative.isEmpty) continue;
      final String outPath =
          '${target.path}${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}';
      final File out = File(outPath);
      await out.parent.create(recursive: true);
      await out.writeAsBytes(f.content, flush: false);
    }

    if (!File('${target.path}/model.onnx').existsSync()) {
      throw StateError('安装后找不到 model.onnx');
    }
    if (!File('${target.path}/tokens.txt').existsSync()) {
      throw StateError('安装后找不到 tokens.txt');
    }

    final InstalledTtsModel installed = InstalledTtsModel(
      id: model.id,
      label: model.label,
      path: target.path,
      kind: model.kind,
      speakerCount: model.speakerCount,
      license: model.license,
    );
    onProgress?.call(1);
    return installed;
  }

  Future<void> _download(
    DownloadableTtsModel model,
    File target,
    void Function(double)? onProgress,
  ) async {
    final http.Client client = this.client ?? NetworkRuntime.newClient();
    final File part = File('${target.path}.part');
    IOSink? sink;
    try {
      final http.Request request = http.Request('GET', Uri.parse(model.url));
      final http.StreamedResponse response = await client.send(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('下载失败：HTTP ${response.statusCode}');
      }
      final int total = response.contentLength ?? model.archiveBytes;
      int received = 0;
      // 边下边算哈希：Kokoro 归档有 365 MB，整包塞内存会在 32 位设备上炸。
      final _DigestSink digestSink = _DigestSink();
      final ByteConversionSink hashSink = sha256.startChunkedConversion(
        digestSink,
      );
      sink = part.openWrite();
      await for (final List<int> chunk in response.stream) {
        sink.add(chunk);
        hashSink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
      hashSink.close();
      await sink.flush();
      await sink.close();
      sink = null;

      final String digest = digestSink.value.toString();
      if (model.sha256.isNotEmpty && digest != model.sha256) {
        await part.delete();
        throw StateError('SHA-256 校验失败：期望 ${model.sha256}，实际 $digest');
      }
      if (model.sha256.isEmpty && await part.length() != model.archiveBytes) {
        await part.delete();
        throw StateError('归档大小不对：期望 ${model.archiveBytes} 字节');
      }
      if (await target.exists()) await target.delete();
      await part.rename(target.path);
    } catch (e) {
      try {
        await sink?.close();
      } catch (_) {}
      if (await part.exists()) await part.delete();
      rethrow;
    } finally {
      client.close();
    }
  }

  Future<bool> _isValidArchive(
    File file,
    DownloadableTtsModel model,
  ) async {
    if (!await file.exists()) return false;
    if (model.sha256.isEmpty) {
      return await file.length() == model.archiveBytes;
    }
    final String actual = (await sha256.bind(file.openRead()).first).toString();
    return actual == model.sha256;
  }

  String _safeName(String raw) {
    final String name = raw.replaceAll('\\', '/');
    if (name.startsWith('/') || name.contains('../') || name == '..') {
      throw StateError('归档里有不安全的路径：$raw');
    }
    return name;
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
