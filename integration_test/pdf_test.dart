// 真机验证：pdfrx / PDFium 在 Android 上能打开 PDF 并抽出文本层。
//
// 跑法：
//   flutter test integration_test/pdf_test.dart -d <device-id>

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:joenws/model/pdf_text.dart';
import 'package:pdfrx/pdfrx.dart';

/// 一个最小的、带文本层的 PDF；不依赖任何外部 fixture。
String _minimalPdf() {
  const String content = 'BT /F1 24 Tf 20 100 Td (Hello PDF) Tj ET\n';
  final List<String> objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] '
        '/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>',
    '<< /Length ${content.length} >>\nstream\n${content}endstream',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];

  final StringBuffer out = StringBuffer('%PDF-1.4\n');
  final List<int> offsets = <int>[];
  for (int i = 0; i < objects.length; i++) {
    offsets.add(out.length);
    out.writeln('${i + 1} 0 obj');
    out.writeln(objects[i]);
    out.writeln('endobj');
  }
  final int xref = out.length;
  out.writeln('xref');
  out.writeln('0 ${objects.length + 1}');
  out.writeln('0000000000 65535 f ');
  for (final int offset in offsets) {
    out.writeln('${offset.toString().padLeft(10, '0')} 00000 n ');
  }
  out.writeln('trailer');
  out.writeln('<< /Size ${objects.length + 1} /Root 1 0 R >>');
  out.writeln('startxref');
  out.writeln('$xref');
  out.writeln('%%EOF');
  return out.toString();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android 上能抽 PDF 文本层', (WidgetTester tester) async {
    // 和 main.dart 一样走 Flutter 初始化（纯 Dart 初始化拿不到 Android 的缓存目录）。
    pdfInitializer = () => pdfrxFlutterInitialize();

    final Directory dir = Directory.systemTemp.createTempSync('joenws_pdf_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final File file = File('${dir.path}${Platform.pathSeparator}test.pdf');
    file.writeAsStringSync(_minimalPdf());

    final String text = await extractPdfText(file.path);
    // ignore: avoid_print
    print('PDF_ANDROID chars=${text.length} text=$text');

    expect(text, contains('Hello PDF'));
  });
}
