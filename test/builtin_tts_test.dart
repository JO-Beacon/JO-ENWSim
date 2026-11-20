import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/model/tts_types.dart';
import 'package:joenws/tts/builtin_models.dart';
import 'package:joenws/tts/builtin_tts.dart';
import 'package:joenws/tts/tts_cache.dart';

class FakeEngine implements BuiltinTtsEngine {
  int loads = 0;
  int unloads = 0;
  int synths = 0;
  BuiltinModel? loaded;
  String? loadedDir;
  bool failLoad = false;

  @override
  Future<void> load(BuiltinModel model, String modelDir) async {
    loads++;
    if (failLoad) throw StateError('假的加载失败');
    loaded = model;
    loadedDir = modelDir;
  }

  @override
  Future<BuiltinAudioInfo> synthesizeToWave(
    String text,
    String outputPath, {
    int sid = 0,
    double speed = 1.0,
  }) async {
    synths++;
    File(outputPath).writeAsBytesSync(<int>[1, 2, 3]);
    return const BuiltinAudioInfo(seconds: 1.5, sampleRate: 24000);
  }

  @override
  Future<void> unload() async {
    unloads++;
    loaded = null;
    loadedDir = null;
  }
}

void main() {
  test('不再按语言自动路由：默认 Melo，显式传 Kokoro 才用 Kokoro', () async {
    final FakeEngine engine = FakeEngine();
    final BuiltinTtsManager manager = BuiltinTtsManager(
      modelRoot: 'root',
      engine: engine,
      lifecycle: TtsLifecycle.keepLoaded,
    );
    await manager.synthesize('This is English.');
    expect(manager.loadedModel, BuiltinModel.melo);
    await manager.synthesize('This is English.', model: BuiltinModel.kokoro);
    expect(manager.loadedModel, BuiltinModel.kokoro);
    expect(engine.loads, 2);
  });

  test('默认完全冷启动：合成完立刻卸载', () async {
    final FakeEngine engine = FakeEngine();
    final BuiltinTtsManager manager = BuiltinTtsManager(
      modelRoot: 'root',
      engine: engine,
    );
    final BuiltinTtsResult r = await manager.synthesize('你好。');
    expect(r.ok, isTrue);
    expect(engine.loads, 1);
    expect(engine.synths, 1);
    expect(engine.unloads, 1);
    expect(manager.loadedModel, isNull);
  });

  test('常驻：第二次合成不重新加载；切回冷启动就卸载', () async {
    final FakeEngine engine = FakeEngine();
    final BuiltinTtsManager manager = BuiltinTtsManager(
      modelRoot: 'root',
      engine: engine,
      lifecycle: TtsLifecycle.keepLoaded,
    );
    await manager.synthesize('第一句。');
    await manager.synthesize('第二句。');
    expect(engine.loads, 1);
    expect(engine.unloads, 0);
    expect(manager.loadedModel, BuiltinModel.melo);

    manager.setLifecycle(TtsLifecycle.coldStart);
    await manager.unload();
    expect(engine.unloads, 1);
    expect(manager.loadedModel, isNull);
  });

  test('空闲卸载：超时后释放', () async {
    final FakeEngine engine = FakeEngine();
    final BuiltinTtsManager manager = BuiltinTtsManager(
      modelRoot: 'root',
      engine: engine,
      lifecycle: TtsLifecycle.idleUnload,
      idleTimeout: const Duration(milliseconds: 40),
    );
    await manager.synthesize('你好。');
    expect(manager.loadedModel, BuiltinModel.melo);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(manager.loadedModel, isNull);
    expect(engine.unloads, 1);
  });

  test('显式指定 Kokoro：旧模型先卸，再装新模型', () async {
    final FakeEngine engine = FakeEngine();
    final BuiltinTtsManager manager = BuiltinTtsManager(
      modelRoot: 'root',
      engine: engine,
      lifecycle: TtsLifecycle.keepLoaded,
    );
    await manager.synthesize('中文。');
    await manager.synthesize('This is English.', model: BuiltinModel.kokoro);
    expect(engine.loads, 2);
    expect(engine.unloads, 1);
    expect(manager.loadedModel, BuiltinModel.kokoro);
    expect(engine.loadedDir, 'root/kokoro');
  });

  test('空文本不加载模型；加载失败如实返回', () async {
    final FakeEngine engine = FakeEngine();
    final BuiltinTtsManager manager = BuiltinTtsManager(
      modelRoot: 'root',
      engine: engine,
    );
    final BuiltinTtsResult empty = await manager.synthesize('   ');
    expect(empty.ok, isFalse);
    expect(engine.loads, 0);

    engine.failLoad = true;
    final BuiltinTtsResult bad = await manager.synthesize('你好。');
    expect(bad.ok, isFalse);
    expect(bad.message, contains('假的加载失败'));
    expect(manager.loadedModel, isNull);
  });

  test('缓存命中后不再加载模型；清理会删掉 WAV', () async {
    final Directory dir = await Directory.systemTemp.createTemp('tts_cache_');
    addTearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });
    final FakeEngine engine = FakeEngine();
    final TtsCache cache = TtsCache(dir);
    final BuiltinTtsManager manager = BuiltinTtsManager(
      modelRoot: 'root',
      engine: engine,
      cache: cache,
    );

    final BuiltinTtsResult first = await manager.synthesize('你好。');
    expect(first.ok, isTrue);
    expect(first.cached, isFalse);
    expect(engine.loads, 1);

    final BuiltinTtsResult second = await manager.synthesize('你好。');
    expect(second.ok, isTrue);
    expect(second.cached, isTrue);
    expect(engine.loads, 1);
    expect(engine.synths, 1);
    expect((await cache.stats()).count, 1);

    final Directory out = await Directory.systemTemp.createTemp('tts_export_');
    addTearDown(() async {
      if (out.existsSync()) await out.delete(recursive: true);
    });
    expect(await cache.exportTo(out), 1);
    expect(
      out
          .listSync()
          .whereType<File>()
          .where((File f) => f.path.endsWith('.wav'))
          .length,
      1,
    );

    await cache.clear();
    expect((await cache.stats()).count, 0);
  });
}
