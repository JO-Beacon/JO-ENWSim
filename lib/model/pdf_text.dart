// PDF 文本层抽取；扫描页没有文本层时，渲染成图片再走内置 PP-OCR。
//
// 文本层优先：有文本的页不 OCR，只有空文本页才 OCR。
// OCR 不上云，全部在进程内完成。

import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';

import 'local_ocr.dart';

Future<void>? _pdfInit;

/// 默认给纯 Dart / 测试用；Flutter 启动时替换成 pdfrxFlutterInitialize。
Future<void> Function() pdfInitializer = pdfrxInitialize;

Future<void> _ensurePdfrx() => _pdfInit ??= pdfInitializer();

/// 扫描页 OCR 的进度回调。
///
/// [page] / [total] 从 1 开始；[needsOcr] 表示这一页没有文本层，正在 OCR。
typedef PdfOcrProgress = void Function(int page, int total, bool needsOcr);

/// PDF / OCR 取消令牌。
class PdfOcrCancellation {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

/// 一次 PDF 抽取的结果。
class PdfTextExtraction {
  const PdfTextExtraction({
    required this.text,
    required this.pageCount,
    required this.ocrPages,
    required this.skippedPages,
    required this.warnings,
    this.cancelled = false,
  });

  final String text;
  final int pageCount;

  /// 实际 OCR 的页数。
  final int ocrPages;

  /// 因为超过 [maxOcrPages] 而没有 OCR 的扫描页数。
  final int skippedPages;

  final List<String> warnings;

  /// 用户中途取消。
  final bool cancelled;
}

/// 抽取一个 PDF 的全部文本层，页与页之间留一个换行。
///
/// 这是纯文本层版本，不触发 OCR；扫描版请用 [extractPdfTextWithOcr]。
Future<String> extractPdfText(String path) async {
  await _ensurePdfrx();
  final PdfDocument doc = await PdfDocument.openFile(path);
  try {
    final StringBuffer out = StringBuffer();
    for (final PdfPage page in doc.pages) {
      final PdfPageRawText? text = await page.loadText();
      final String pageText = text?.fullText.trim() ?? '';
      if (pageText.isEmpty) continue;
      if (out.isNotEmpty) out.writeln();
      out.write(pageText);
    }
    return out.toString();
  } finally {
    await doc.dispose();
  }
}

/// 抽取 PDF：有文本层的页直接用文本层，空文本页渲染成图后走 PP-OCR。
///
/// [maxOcrPages] 防止一本几百页的扫描书把手机跑死；超出的页会记在
/// [PdfTextExtraction.skippedPages] 里，调用方应提示用户。
Future<PdfTextExtraction> extractPdfTextWithOcr(
  String path, {
  int maxOcrPages = 50,
  PdfOcrProgress? onProgress,
  PdfOcrCancellation? cancellation,
}) async {
  await _ensurePdfrx();
  final PdfDocument doc = await PdfDocument.openFile(path);
  final StringBuffer out = StringBuffer();
  final List<String> warnings = <String>[];
  int ocrPages = 0;
  int skippedPages = 0;
  bool cancelled = false;
  final int total = doc.pages.length;

  try {
    for (final PdfPage page in doc.pages) {
      if (cancellation?.isCancelled == true) {
        cancelled = true;
        break;
      }
      final PdfPageRawText? raw = await page.loadText();
      final String pageText = raw?.fullText.trim() ?? '';
      if (pageText.isNotEmpty) {
        if (out.isNotEmpty) out.writeln();
        out.write(pageText);
        onProgress?.call(page.pageNumber, total, false);
        continue;
      }

      if (ocrPages >= maxOcrPages) {
        skippedPages++;
        onProgress?.call(page.pageNumber, total, false);
        continue;
      }

      onProgress?.call(page.pageNumber, total, true);
      PdfImage? raster;
      try {
        await page.ensureLoaded();
        // 1600 px 宽足够 PP-OCR；太大会浪费内存，太小会掉字。
        const double targetWidth = 1600;
        final double scale = page.width > 0 ? targetWidth / page.width : 1;
        final double targetHeight = page.height > 0 ? page.height * scale : 2000;
        raster = await page.render(
          fullWidth: targetWidth,
          fullHeight: targetHeight.clamp(1, 4000).toDouble(),
        );
        if (raster == null) {
          warnings.add('第 ${page.pageNumber} 页渲染失败。');
          continue;
        }
        final Uint8List bgra = Uint8List.fromList(raster.pixels);
        final img.Image bitmap = img.Image.fromBytes(
          width: raster.width,
          height: raster.height,
          bytes: bgra.buffer,
          numChannels: 4,
          order: img.ChannelOrder.bgra,
        );
        final Uint8List png = Uint8List.fromList(img.encodePng(bitmap));
        if (cancellation?.isCancelled == true) {
          cancelled = true;
          break;
        }
        final ({String text, String? error}) result =
            await LocalOcrEngine.instance.recognizeBytes(png);
        if (result.error != null) {
          warnings.add('第 ${page.pageNumber} 页 OCR 失败：${result.error}');
        } else if (result.text.trim().isNotEmpty) {
          if (out.isNotEmpty) out.writeln();
          out.write(result.text.trim());
          ocrPages++;
        }
      } catch (err) {
        warnings.add('第 ${page.pageNumber} 页 OCR 异常：$err');
      } finally {
        raster?.dispose();
      }
      if (cancellation?.isCancelled == true) {
        cancelled = true;
        break;
      }
    }
  } finally {
    await doc.dispose();
  }

  return PdfTextExtraction(
    text: out.toString().trim(),
    pageCount: total,
    ocrPages: ocrPages,
    skippedPages: skippedPages,
    warnings: warnings,
    cancelled: cancelled,
  );
}

