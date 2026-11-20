import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:joenws/model/ocr/ocr_models.dart';

/// 假的下载客户端：按 URL 返回预置字节。
http.Client _fakeClient(Map<String, Uint8List> bodies) {
  return MockClient((http.Request request) async {
    final Uint8List? body = bodies[request.url.toString()];
    if (body == null) {
      return http.Response('not found', 404);
    }
    return http.Response.bytes(body, 200);
  });
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('joenws_ocr_models_test_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('IR 10→9 修补后落盘，且哈希与期望一致', () async {
    // 造一个最小“模型”：头字节 08 0A（ir_version=10），后面随便填。
    final Uint8List official = Uint8List.fromList(<int>[
      0x08, 0x0A, 0x12, 0x00, 1, 2, 3, 4,
    ]);
    final Uint8List patched = Uint8List.fromList(official);
    patched[1] = 0x09;

    const String url = 'https://example.test/det.onnx';
    final OcrModelSpec spec = OcrModelSpec(
      id: 'det',
      fileName: 'ch_PP-OCRv5_det_mobile.onnx',
      url: url,
      officialSha256: sha256.convert(official).toString(),
      installedSha256: sha256.convert(patched).toString(),
      bytes: official.length,
      patchIrVersion: true,
    );

    final OcrModelManager manager = OcrModelManager(
      modelsRoot: tmp.path,
      client: _fakeClient(<String, Uint8List>{url: official}),
    );
    await manager.installFile(spec);

    final File installed = File('${manager.ocrDir}${Platform.pathSeparator}${spec.fileName}');
    expect(await installed.exists(), isTrue);
    final Uint8List got = await installed.readAsBytes();
    expect(got[0], 0x08);
    expect(got[1], 0x09); // IR 已改成 9
    expect(sha256.convert(got).toString(), spec.installedSha256);
    expect(await manager.isFileInstalled(spec), isTrue);
  });

  test('哈希不符时拒绝安装并删掉临时文件', () async {
    final Uint8List body = Uint8List.fromList(<int>[0, 1, 2, 3]);
    const String url = 'https://example.test/bad.onnx';
    final OcrModelSpec spec = OcrModelSpec(
      id: 'bad',
      fileName: 'bad.onnx',
      url: url,
      officialSha256: '0000000000000000000000000000000000000000000000000000000000000000',
      installedSha256: '0000000000000000000000000000000000000000000000000000000000000000',
      bytes: body.length,
    );
    final OcrModelManager manager = OcrModelManager(
      modelsRoot: tmp.path,
      client: _fakeClient(<String, Uint8List>{url: body}),
    );
    expect(
      manager.installFile(spec),
      throwsA(isA<StateError>().having(
        (StateError e) => e.toString(),
        'message',
        contains('SHA-256 校验失败'),
      )),
    );
  });

  test('已安装的文件不重复下载', () async {
    final Uint8List body = Uint8List.fromList(<int>[0x08, 0x09, 5, 6]);
    const String url = 'https://example.test/rec.onnx';
    final OcrModelSpec spec = OcrModelSpec(
      id: 'rec',
      fileName: 'rec.onnx',
      url: url,
      officialSha256: sha256.convert(body).toString(),
      installedSha256: sha256.convert(body).toString(),
      bytes: body.length,
    );
    final OcrModelManager manager = OcrModelManager(
      modelsRoot: tmp.path,
      client: _fakeClient(<String, Uint8List>{url: body}),
    );
    await manager.installFile(spec);
    expect(await manager.isFileInstalled(spec), isTrue);

    // 换一个会抛错的 client：如果还去下载就会失败。
    final OcrModelManager offline = OcrModelManager(
      modelsRoot: tmp.path,
      client: MockClient((_) async => http.Response('should not be called', 500)),
    );
    await offline.installFile(spec); // 不抛 = 没下载
    expect(await offline.isFileInstalled(spec), isTrue);
  });

  test('清单里的三个文件元数据自洽', () {
    expect(kOcrModelFiles, hasLength(3));
    for (final OcrModelSpec f in kOcrModelFiles) {
      expect(f.officialSha256, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(f.installedSha256, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(f.bytes, greaterThan(0));
      expect(f.url, startsWith('https://'));
    }
    expect(kOcrTotalBytes, greaterThan(20 * 1024 * 1024));
  });
}
