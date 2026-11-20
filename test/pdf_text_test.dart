import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/model/pdf_text.dart';

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
  test('PDF 文本层能抽出来，且不会触发 OCR', () async {
    final Directory dir = Directory.systemTemp.createTempSync('joenws_pdf_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final File file = File('${dir.path}${Platform.pathSeparator}test.pdf');
    file.writeAsStringSync(_minimalPdf());

    final String text = await extractPdfText(file.path);
    expect(text, contains('Hello PDF'));

    final PdfTextExtraction detailed = await extractPdfTextWithOcr(file.path);
    expect(detailed.text, contains('Hello PDF'));
    expect(detailed.pageCount, 1);
    expect(detailed.ocrPages, 0);
    expect(detailed.skippedPages, 0);

    final PdfOcrCancellation cancelled = PdfOcrCancellation()..cancel();
    final PdfTextExtraction stopped = await extractPdfTextWithOcr(
      file.path,
      cancellation: cancelled,
    );
    expect(stopped.cancelled, isTrue);
    expect(stopped.text, isEmpty);
  });
}
