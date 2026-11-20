import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/tts/builtin_models.dart';
import 'package:joenws/tts/downloadable_models.dart';
import 'package:joenws/tts/installed_models.dart';

DownloadableTtsModel? catalogOf(BuiltinModel model) {
  for (final DownloadableTtsModel m in kDownloadableTtsModels) {
    if (m.id == model.folder) return m;
  }
  return null;
}

void main() {
  test('Melo / Kokoro 在可下载清单里，id 与模型目录一致', () {
    for (final BuiltinModel model in BuiltinModel.values) {
      final DownloadableTtsModel? entry = catalogOf(model);
      expect(entry, isNotNull, reason: model.label);
      expect(entry!.label, model.label);
      expect(entry.kind.name, model == BuiltinModel.kokoro ? 'kokoro' : 'vits');
    }
  });

  test('内置模型的官方归档哈希与大小固定', () {
    final DownloadableTtsModel melo = catalogOf(BuiltinModel.melo)!;
    expect(
      melo.sha256,
      'e58351ed7149f290a54534538badd4077cdbe6fddc964b24d0bee870415d1514',
    );
    expect(melo.archiveBytes, 167006755);
    expect(melo.license, 'MIT');

    final DownloadableTtsModel kokoro = catalogOf(BuiltinModel.kokoro)!;
    expect(
      kokoro.sha256,
      'b78e1ac42b852e839cceaafbe88f66806bf5860992d1d7b9a3f2ad1198427aed',
    );
    expect(kokoro.archiveBytes, 364855331);
    expect(kokoro.license, 'Apache-2.0');
    expect(kokoro.speakerCount, 103);
  });

  test('清单里的归档都有完整的 SHA-256', () {
    for (final DownloadableTtsModel m in kDownloadableTtsModels) {
      expect(m.sha256, hasLength(64), reason: m.id);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(m.sha256), isTrue);
    }
  });

  test('模型目录里有 model.onnx 才算装好', () async {
    final Directory root = await Directory.systemTemp.createTemp('joenws_tts_');
    addTearDown(() => root.delete(recursive: true));

    expect(isBuiltinModelInstalled(BuiltinModel.melo, root.path), isFalse);
    final Directory melo = Directory('${root.path}/melo')
      ..createSync(recursive: true);
    File('${melo.path}/model.onnx').writeAsBytesSync(<int>[1, 2, 3]);
    expect(isBuiltinModelInstalled(BuiltinModel.melo, root.path), isTrue);
    expect(isBuiltinModelInstalled(BuiltinModel.kokoro, root.path), isFalse);
    expect(
      builtinModelMissingMessage(BuiltinModel.kokoro),
      contains('可下载模型'),
    );
  });
}
