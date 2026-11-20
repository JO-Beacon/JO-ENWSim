// 真机验证：内置 PP-OCR 在 Android 上的加载、推理、识别质量。
//
// 跑法：
//   flutter test integration_test/ocr_test.dart -d <device-id>
//
// 不点 UI，直接调引擎 —— 这样测的是 ONNX Runtime + 模型 + 自写管线本身。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:joenws/model/local_ocr.dart';
import 'package:joenws/model/ocr/ocr_models.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('内置 PP-OCR 在真机上能识别英文', (WidgetTester tester) async {
    // 模型改为运行时下载：没装就先装，跑这个测试前需联网。
    if (!await LocalOcrEngine.instance.isInstalled()) {
      final Directory support = await getApplicationSupportDirectory();
      await OcrModelManager(
        modelsRoot: '${support.path}/models',
      ).installAll();
    }
    final img.Image canvas = img.Image(width: 720, height: 200, numChannels: 3);
    img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
    img.drawString(
      canvas,
      'Hello OCR 123',
      font: img.arial48,
      x: 30,
      y: 70,
      color: img.ColorRgb8(0, 0, 0),
    );
    final Uint8List png = Uint8List.fromList(img.encodePng(canvas));

    final result = await LocalOcrEngine.instance.recognizeBytes(png);
    // ignore: avoid_print
    print('OCR_ANDROID text=${result.text} error=${result.error}');

    expect(result.error, isNull);
    expect(result.text.toUpperCase(), contains('HELLO'));
    expect(result.text, contains('123'));
  });
}
