// 真机验证：扫描版 PDF（页面里只有一张位图、没有文本层）能渲染成图片并走内置 PP-OCR。
//
// 跑法：
//   flutter test integration_test/scanned_pdf_test.dart -d <device-id>

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:joenws/model/pdf_text.dart';
import 'package:pdfrx/pdfrx.dart';

/// 生成一张白底黑字的位图，再把它塞进一个没有文本层的 PDF。
Uint8List _scannedPdf() {
  final img.Image canvas = img.Image(width: 900, height: 220, numChannels: 3);
  img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
  img.drawString(
    canvas,
    'Scanned OCR 456',
    font: img.arial48,
    x: 30,
    y: 80,
    color: img.ColorRgb8(0, 0, 0),
  );
  final Uint8List rgb = canvas.getBytes(order: img.ChannelOrder.rgb);
  final List<int> compressed = ZLibCodec(level: 9).encode(rgb);
  const int width = 900;
  const int height = 220;

  final BytesBuilder out = BytesBuilder();
  final List<int> offsets = <int>[];
  void add(String text) => out.add(latin1.encode(text));
  void object(int index, String body) {
    offsets.add(out.length);
    add('$index 0 obj\n$body\nendobj\n');
  }

  add('%PDF-1.4\n');
  object(1, '<< /Type /Catalog /Pages 2 0 R >>');
  object(2, '<< /Type /Pages /Kids [3 0 R] /Count 1 >>');
  object(
    3,
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $width $height] '
    '/Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>',
  );
  offsets.add(out.length);
  add(
    '4 0 obj\n<< /Type /XObject /Subtype /Image /Width $width '
    '/Height $height /ColorSpace /DeviceRGB /BitsPerComponent 8 '
    '/Filter /FlateDecode /Length ${compressed.length} >>\nstream\n',
  );
  out.add(compressed);
  add('\nendstream\nendobj\n');

  const String content = 'q 900 0 0 220 0 0 cm /Im0 Do Q\n';
  object(5, '<< /Length ${content.length} >>\nstream\n${content}endstream');

  final int xref = out.length;
  add('xref\n0 ${offsets.length + 1}\n');
  add('0000000000 65535 f \n');
  for (final int offset in offsets) {
    add('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  add('trailer\n<< /Size ${offsets.length + 1} /Root 1 0 R >>\n');
  add('startxref\n$xref\n%%EOF\n');
  return out.takeBytes();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('扫描版 PDF 能渲染成图片并 OCR', (WidgetTester tester) async {
    pdfInitializer = () => pdfrxFlutterInitialize();

    final Directory dir = Directory.systemTemp.createTempSync('joenws_scan_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final File file = File('${dir.path}${Platform.pathSeparator}scan.pdf');
    file.writeAsBytesSync(_scannedPdf());

    final PdfTextExtraction result = await extractPdfTextWithOcr(
      file.path,
      onProgress: (int page, int total, bool needsOcr) {
        // ignore: avoid_print
        print('SCANNED_PDF progress page=$page/$total ocr=$needsOcr');
      },
    );
    // ignore: avoid_print
    print(
      'SCANNED_PDF text=${result.text} pages=${result.pageCount} '
      'ocr=${result.ocrPages} skipped=${result.skippedPages}',
    );

    expect(result.pageCount, 1);
    expect(result.ocrPages, 1);
    expect(result.text.toUpperCase(), contains('SCANNED'));
    expect(result.text, contains('456'));
  });
}
