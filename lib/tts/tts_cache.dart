// WAV 缓存：按“文本 + 模型 + 声线 + 速度”找同一段音频。
//
// 只存 WAV 和一份很小的 JSON 说明（时长 / 模型 / 创建时间），不存文本。
// 清理由设置页触发；缓存只是加速，删掉不会影响功能。

import 'dart:convert';
import 'dart:io';

class TtsCacheEntry {
  const TtsCacheEntry({
    required this.file,
    required this.seconds,
    required this.createdAt,
  });

  final File file;
  final double seconds;
  final DateTime createdAt;
}

class TtsCacheStats {
  const TtsCacheStats({required this.count, required this.bytes});

  final int count;
  final int bytes;

  String get sizeLabel {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

class TtsCache {
  TtsCache(this.directory);

  final Directory directory;

  Future<void> ensure() => directory.create(recursive: true);

  Future<TtsCacheEntry?> find({
    required String text,
    required String model,
    int sid = 0,
    double speed = 1.0,
    String extra = '',
  }) async {
    await ensure();
    final String key = _key(text, model, sid, speed, extra);
    final File wav = File('${directory.path}/$key.wav');
    if (!wav.existsSync()) return null;
    final File meta = File('${directory.path}/$key.json');
    double seconds = 0;
    DateTime createdAt = wav.lastModifiedSync();
    if (meta.existsSync()) {
      try {
        final Map<String, Object?> m =
            jsonDecode(meta.readAsStringSync()) as Map<String, Object?>;
        seconds = (m['seconds'] as num?)?.toDouble() ?? 0;
        final String? iso = m['createdAt'] as String?;
        if (iso != null) createdAt = DateTime.tryParse(iso) ?? createdAt;
      } catch (_) {
        // 说明文件坏了不影响音频本身，时长按 0 处理。
      }
    }
    if (seconds <= 0) seconds = _wavSeconds(wav);
    return TtsCacheEntry(file: wav, seconds: seconds, createdAt: createdAt);
  }

  Future<TtsCacheEntry> store({
    required File source,
    required String text,
    required String model,
    required double seconds,
    int sid = 0,
    double speed = 1.0,
    String extra = '',
  }) async {
    await ensure();
    final String key = _key(text, model, sid, speed, extra);
    final File target = File('${directory.path}/$key.wav');
    if (target.existsSync()) target.deleteSync();
    await source.copy(target.path);
    final DateTime now = DateTime.now();
    File('${directory.path}/$key.json').writeAsStringSync(
      jsonEncode(<String, Object?>{
        'seconds': seconds,
        'model': model,
        'sid': sid,
        'speed': speed,
        'createdAt': now.toIso8601String(),
      }),
    );
    return TtsCacheEntry(file: target, seconds: seconds, createdAt: now);
  }

  Future<TtsCacheStats> stats() async {
    await ensure();
    int count = 0;
    int bytes = 0;
    await for (final FileSystemEntity e in directory.list()) {
      if (e is File && e.path.endsWith('.wav')) {
        count++;
        bytes += e.lengthSync();
      }
    }
    return TtsCacheStats(count: count, bytes: bytes);
  }

  Future<void> clear() async {
    await ensure();
    await for (final FileSystemEntity e in directory.list()) {
      if (e is File && (e.path.endsWith('.wav') || e.path.endsWith('.json'))) {
        try {
          await e.delete();
        } catch (_) {
          // 正在播放的文件可能短暂占用；下次再清。
        }
      }
    }
  }

  /// 把缓存里的 WAV 复制到用户选的目录；返回复制了几个。
  Future<int> exportTo(Directory target) async {
    await ensure();
    await target.create(recursive: true);
    int n = 0;
    await for (final FileSystemEntity e in directory.list()) {
      if (e is File && e.path.endsWith('.wav')) {
        final String name = e.uri.pathSegments.last;
        await e.copy('${target.path}${Platform.pathSeparator}$name');
        n++;
      }
    }
    return n;
  }

  String _key(
    String text,
    String model,
    int sid,
    double speed,
    String extra,
  ) {
    final String input = '$model\u0000$sid\u0000$speed\u0000$extra\u0000$text';
    int a = 0x811c9dc5;
    int b = 0x9e3779b9;
    for (final int byte in utf8.encode(input)) {
      a ^= byte;
      a = (a * 0x01000193) & 0xFFFFFFFF;
      b ^= byte;
      b = (b * 0x85ebca6b) & 0xFFFFFFFF;
    }
    return '${a.toRadixString(16).padLeft(8, '0')}'
        '${b.toRadixString(16).padLeft(8, '0')}';
  }

  /// 读 WAV 头算时长；缓存说明文件缺失时兜底。
  double _wavSeconds(File file) {
    try {
      final RandomAccessFile f = file.openSync();
      final List<int> head = f.readSync(44);
      f.closeSync();
      if (head.length < 44 ||
          String.fromCharCodes(head.sublist(0, 4)) != 'RIFF' ||
          String.fromCharCodes(head.sublist(8, 12)) != 'WAVE') {
        return 0;
      }
      final int channels = _u16(head, 22);
      final int rate = _u32(head, 24);
      final int bits = _u16(head, 34);
      int offset = 12;
      while (offset + 8 <= head.length) {
        final String id = String.fromCharCodes(
          head.sublist(offset, offset + 4),
        );
        final int size = _u32(head, offset + 4);
        if (id == 'data') {
          final int bytesPerSec = rate * channels * (bits ~/ 8);
          return bytesPerSec == 0 ? 0 : size / bytesPerSec;
        }
        offset += 8 + size + (size % 2);
      }
    } catch (_) {
      // ignore
    }
    return 0;
  }

  int _u16(List<int> b, int i) => b[i] | (b[i + 1] << 8);

  int _u32(List<int> b, int i) =>
      b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);
}

/// 读 WAV 头算时长；不是 WAV / 读不了就返回 0。
double wavDurationSeconds(File file) {
  try {
    final RandomAccessFile f = file.openSync();
    final List<int> head = f.readSync(44);
    f.closeSync();
    if (head.length < 44 ||
        String.fromCharCodes(head.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(head.sublist(8, 12)) != 'WAVE') {
      return 0;
    }
    final int channels = head[22] | (head[23] << 8);
    final int rate =
        head[24] | (head[25] << 8) | (head[26] << 16) | (head[27] << 24);
    final int bits = head[34] | (head[35] << 8);
    int offset = 12;
    while (offset + 8 <= head.length) {
      final String id = String.fromCharCodes(head.sublist(offset, offset + 4));
      final int size =
          head[offset + 4] |
          (head[offset + 5] << 8) |
          (head[offset + 6] << 16) |
          (head[offset + 7] << 24);
      if (id == 'data') {
        final int bytesPerSec = rate * channels * (bits ~/ 8);
        return bytesPerSec == 0 ? 0 : size / bytesPerSec;
      }
      offset += 8 + size + (size % 2);
    }
  } catch (_) {
    // ignore
  }
  return 0;
}
