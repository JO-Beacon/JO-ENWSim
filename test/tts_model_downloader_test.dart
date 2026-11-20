import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:joenws/tts/downloadable_models.dart';
import 'package:joenws/tts/model_downloader.dart';
import 'package:joenws/tts/model_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
DownloadableTtsModel modelWith({
  required String id,
  required String sha256,
  required int bytes,
  String url = 'https://example.invalid/model.tar.bz2',
}) {
  return DownloadableTtsModel(
    id: id,
    label: '测试模型',
    language: '中文',
    description: '测试',
    license: 'Apache-2.0',
    licenseUrl: 'https://example.invalid/license',
    url: url,
    sha256: sha256,
    archiveBytes: bytes,
    kind: DownloadableTtsKind.vits,
  );
}

void main() {
  test('清单里的归档都有完整的 SHA-256', () {
    for (final DownloadableTtsModel m in kDownloadableTtsModels) {
      expect(m.sha256, hasLength(64), reason: m.id);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(m.sha256), isTrue);
    }
  });

  test('校验归档并解包到 models/<id>', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'joenws_model_test',
    );
    addTearDown(() => root.delete(recursive: true));

    final Archive archive = Archive();
    archive.addFile(
      ArchiveFile('demo-model/model.onnx', 3, <int>[1, 2, 3]),
    );
    archive.addFile(ArchiveFile('demo-model/tokens.txt', 2, <int>[4, 5]));
    archive.addFile(ArchiveFile('demo-model/lexicon.txt', 2, <int>[6, 7]));
    final Uint8List compressed = BZip2Encoder().encodeBytes(
      TarEncoder().encodeBytes(archive),
    );

    final Directory downloads = Directory('${root.path}/models/.downloads');
    await downloads.create(recursive: true);
    await File(
      '${downloads.path}/demo-model.tar.bz2',
    ).writeAsBytes(compressed, flush: true);

    final DownloadableTtsModel model = modelWith(
      id: 'demo-model',
      sha256: sha256.convert(compressed).toString(),
      bytes: compressed.length,
    );
    final installed = await TtsModelDownloader(
      modelsRoot: '${root.path}/models',
    ).install(model);

    expect(installed.id, 'demo-model');
    expect(File('${installed.path}/model.onnx').readAsBytesSync(), <int>[
      1,
      2,
      3,
    ]);
    expect(File('${installed.path}/tokens.txt').existsSync(), isTrue);
    expect(File('${installed.path}/lexicon.txt').existsSync(), isTrue);
  });

  test('哈希不匹配时拒绝安装', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'joenws_model_test',
    );
    addTearDown(() => root.delete(recursive: true));

    final Archive archive = Archive();
    archive.addFile(
      ArchiveFile('bad-model/model.onnx', 3, <int>[1, 2, 3]),
    );
    final Uint8List compressed = BZip2Encoder().encodeBytes(
      TarEncoder().encodeBytes(archive),
    );
    final Directory downloads = Directory('${root.path}/models/.downloads');
    await downloads.create(recursive: true);
    await File(
      '${downloads.path}/bad-model.tar.bz2',
    ).writeAsBytes(compressed, flush: true);

    final DownloadableTtsModel model = modelWith(
      id: 'bad-model',
      sha256: List<String>.filled(64, '0').join(),
      bytes: compressed.length,
    );
    final MockClient client = MockClient(
      (http.Request req) async => http.Response.bytes(compressed, 200),
    );

    await expectLater(
      TtsModelDownloader(
        modelsRoot: '${root.path}/models',
        client: client,
      ).install(model),
      throwsA(isA<StateError>()),
    );
  });

  test('从 HTTP 下载并安装', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'joenws_model_http_test',
    );
    addTearDown(() => root.delete(recursive: true));

    final Archive archive = Archive();
    archive.addFile(
      ArchiveFile('http-model/model.onnx', 3, <int>[8, 9, 10]),
    );
    archive.addFile(ArchiveFile('http-model/tokens.txt', 1, <int>[1]));
    final Uint8List compressed = BZip2Encoder().encodeBytes(
      TarEncoder().encodeBytes(archive),
    );

    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => server.close(force: true));
    server.listen((HttpRequest req) async {
      req.response.statusCode = 200;
      req.response.headers.contentLength = compressed.length;
      req.response.add(compressed);
      await req.response.close();
    });

    final DownloadableTtsModel model = modelWith(
      id: 'http-model',
      sha256: sha256.convert(compressed).toString(),
      bytes: compressed.length,
      url: 'http://127.0.0.1:${server.port}/model.tar.bz2',
    );
    final installed = await TtsModelDownloader(
      modelsRoot: '${root.path}/models',
    ).install(model);

    expect(
      File('${installed.path}/model.onnx').readAsBytesSync(),
      <int>[8, 9, 10],
    );
  });

  test('安装记录能存能读', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final Directory root = await Directory.systemTemp.createTemp(
      'joenws_model_store_test',
    );
    addTearDown(() => root.delete(recursive: true));
    final InstalledTtsModel model = InstalledTtsModel(
      id: 'x',
      label: '测试',
      path: root.path,
      kind: DownloadableTtsKind.vits,
      speakerCount: 3,
      license: 'Apache-2.0',
    );
    await TtsModelStore.save(<InstalledTtsModel>[model]);
    final List<InstalledTtsModel> loaded = await TtsModelStore.load();
    expect(loaded.length, 1);
    expect(loaded.first.id, 'x');
    expect(loaded.first.speakerCount, 3);
  });
}
