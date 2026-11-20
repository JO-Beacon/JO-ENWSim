import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/tts/tts_cache.dart';

void main() {
  test('缓存键区分 provider / voice / style 等额外字段', () async {
    final Directory dir = await Directory.systemTemp.createTemp('joenws_cache');
    addTearDown(() => dir.delete(recursive: true));
    final TtsCache cache = TtsCache(dir);
    final File source = File('${dir.path}/source.wav');
    await source.writeAsBytes(<int>[1, 2, 3]);

    await cache.store(
      source: source,
      text: '你好',
      model: 'api:p1:tts-1:alloy',
      seconds: 1.2,
      speed: 1.25,
      extra: '温柔',
    );

    final TtsCacheEntry? hit = await cache.find(
      text: '你好',
      model: 'api:p1:tts-1:alloy',
      speed: 1.25,
      extra: '温柔',
    );
    expect(hit, isNotNull);
    expect(hit!.seconds, 1.2);

    final TtsCacheEntry? missStyle = await cache.find(
      text: '你好',
      model: 'api:p1:tts-1:alloy',
      speed: 1.25,
      extra: '低沉',
    );
    expect(missStyle, isNull);

    final TtsCacheEntry? missVoice = await cache.find(
      text: '你好',
      model: 'api:p1:tts-1:echo',
      speed: 1.25,
      extra: '温柔',
    );
    expect(missVoice, isNull);
  });
}
