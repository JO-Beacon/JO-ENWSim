import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:joenws/model/ocr/ppocr_ctc.dart';
import 'package:joenws/model/ocr/ppocr_db.dart';
import 'package:joenws/model/ocr/ppocr_image.dart';

void main() {
  test('CTC 解码去掉 blank 与重复', () {
    // 4 个时间步、5 类；blank 是 0。
    final Float32List preds = Float32List.fromList(<double>[
      0.9, 0.05, 0.03, 0.01, 0.01, // blank
      0.1, 0.8, 0.05, 0.03, 0.02, // 字 1
      0.1, 0.7, 0.1, 0.05, 0.05, // 又是字 1（应合并）
      0.05, 0.05, 0.8, 0.05, 0.05, // 字 2
    ]);
    final List<String> labels = <String>['', '甲', '乙', '丙', ' '];
    final (String, double) decoded = ctcDecode(preds, 4, 5, labels);
    expect(decoded.$1, '甲乙');
    expect(decoded.$2, greaterThan(0.7));
  });

  test('CTC 空输出得到空串', () {
    final Float32List preds = Float32List.fromList(<double>[0.9, 0.1, 0.9, 0.1]);
    final (String, double) decoded = ctcDecode(
      preds,
      2,
      2,
      <String>['', '甲'],
    );
    expect(decoded.$1, '');
    expect(decoded.$2, 0);
  });

  test('DB 后处理能从一块白色区域里取到一个框', () {
    const int h = 40;
    const int w = 100;
    final Float32List prob = Float32List(h * w);
    // 中间 10..90 x 10..30 置高概率。
    for (int y = 10; y < 30; y++) {
      for (int x = 10; x < 90; x++) {
        prob[y * w + x] = 0.95;
      }
    }

    final List<DetBox> boxes = const DbPostProcess().process(prob, h, w, h, w);
    expect(boxes, hasLength(1));
    final List<({double x, double y})> corners = boxes.first.corners;
    expect(corners, hasLength(4));
    for (final ({double x, double y}) p in corners) {
      expect(p.x, inInclusiveRange(0, w - 1));
      expect(p.y, inInclusiveRange(0, h - 1));
    }
  });

  test('DB 后处理在全零概率图上不产出框', () {
    final List<DetBox> boxes = const DbPostProcess().process(
      Float32List(20 * 20),
      20,
      20,
      20,
      20,
    );
    expect(boxes, isEmpty);
  });

  test('检测预处理输出宽度是 32 的倍数，height*width*3 对齐', () {
    final img.Image source = img.Image(width: 300, height: 100);
    img.fill(source, color: img.ColorRgb8(255, 255, 255));
    final ChwTensor tensor = preprocessDetection(
      source,
      limitSide: 960,
      minSide: 64,
    );
    expect(tensor.width % 32, 0);
    expect(tensor.height % 32, 0);
    expect(tensor.data.length, 3 * tensor.width * tensor.height);
  });

  test('识别预处理把长条压成高 48、按比例算宽', () {
    final img.Image source = img.Image(width: 200, height: 50);
    img.fill(source, color: img.ColorRgb8(0, 0, 0));
    final ChwTensor tensor = preprocessRecognition(
      source,
      quad: const <Offset>[
        Offset(0, 0),
        Offset(200, 0),
        Offset(200, 50),
        Offset(0, 50),
      ],
      recHeight: 48,
    );
    expect(tensor.height, 48);
    expect(tensor.width, greaterThan(48));
    expect(tensor.data.length, 3 * 48 * tensor.width);
  });
}
