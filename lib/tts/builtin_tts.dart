// 内置 TTS：按需加载模型、合成 WAV，再按生命周期决定留不留。
//
// 用户已定：
//   · 同一时间只驻留一个模型；
//   · 默认完全冷启动（用完立刻卸载）；
//   · 多角色先不做，全走 Melo；
//   · 不在运行时按语言切模型：要 Melo 还是 Kokoro，由上层显式传。
//
// 这里只管“加载 / 合成 / 卸载”，播放由 `audio_player.dart` 负责。

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

import '../model/tts_types.dart';
import 'builtin_models.dart';
import 'tts_cache.dart';

class BuiltinAudioInfo {
  const BuiltinAudioInfo({required this.seconds, required this.sampleRate});

  final double seconds;
  final int sampleRate;
}

abstract interface class BuiltinTtsEngine {
  Future<void> load(BuiltinModel model, String modelDir);

  Future<BuiltinAudioInfo> synthesizeToWave(
    String text,
    String outputPath, {
    int sid = 0,
    double speed = 1.0,
  });

  Future<void> unload();
}

/// 建一个 OfflineTts。主 isolate 和 worker isolate 共用。
so.OfflineTts _createOfflineTts(BuiltinModel model, String modelDir) {
  if (!Directory(modelDir).existsSync()) {
    throw StateError('模型目录不存在：$modelDir');
  }

  final so.OfflineTtsModelConfig config;
  switch (model) {
    case BuiltinModel.melo:
      _requireModel(modelDir, <String>[
        'model.onnx',
        'lexicon.txt',
        'tokens.txt',
      ]);
      config = so.OfflineTtsModelConfig(
        vits: so.OfflineTtsVitsModelConfig(
          model: '$modelDir/model.onnx',
          lexicon: '$modelDir/lexicon.txt',
          tokens: '$modelDir/tokens.txt',
        ),
        numThreads: 4,
        debug: false,
      );
    case BuiltinModel.kokoro:
      final String onnx = File('$modelDir/model.onnx').existsSync()
          ? 'model.onnx'
          : 'model.int8.onnx';
      _requireModel(modelDir, <String>[onnx, 'voices.bin', 'tokens.txt']);
      config = so.OfflineTtsModelConfig(
        kokoro: so.OfflineTtsKokoroModelConfig(
          model: '$modelDir/$onnx',
          voices: '$modelDir/voices.bin',
          tokens: '$modelDir/tokens.txt',
          lexicon: '$modelDir/lexicon-zh.txt,$modelDir/lexicon-us-en.txt',
        ),
        numThreads: 4,
        debug: false,
      );
  }

  final String fsts = _existingFsts(
    modelDir,
    model == BuiltinModel.melo
        ? <String>['date.fst', 'number.fst']
        : <String>['date-zh.fst', 'number-zh.fst'],
  );
  return so.OfflineTts(
    so.OfflineTtsConfig(model: config, maxNumSentences: 1, ruleFsts: fsts),
  );
}

void _requireModel(String dir, List<String> names) {
  for (final String n in names) {
    if (!File('$dir/$n').existsSync()) {
      throw StateError('模型缺文件：$dir/$n');
    }
  }
}

String _existingFsts(String dir, List<String> names) {
  final List<String> out = <String>[];
  for (final String n in names) {
    if (File('$dir/$n').existsSync()) out.add('$dir/$n');
  }
  return out.join(',');
}

/// 真正的 sherpa-onnx 实现（主 isolate；留给直接调用和排查）。
class SherpaTtsEngine implements BuiltinTtsEngine {
  so.OfflineTts? _tts;
  BuiltinModel? _model;

  @override
  Future<void> load(BuiltinModel model, String modelDir) async {
    await so.initBindingsAsync();
    await unload();
    _tts = _createOfflineTts(model, modelDir);
    _model = model;
  }

  @override
  Future<BuiltinAudioInfo> synthesizeToWave(
    String text,
    String outputPath, {
    int sid = 0,
    double speed = 1.0,
  }) async {
    final so.OfflineTts? tts = _tts;
    if (tts == null) throw StateError('内置模型还没加载');
    final so.GeneratedAudio audio = tts.generate(
      text: text,
      sid: sid,
      speed: speed,
    );
    if (audio.samples.isEmpty) {
      throw StateError('模型没有生成音频');
    }
    so.writeWave(
      filename: outputPath,
      samples: audio.samples,
      sampleRate: audio.sampleRate,
    );
    return BuiltinAudioInfo(
      seconds: audio.samples.length / audio.sampleRate,
      sampleRate: audio.sampleRate,
    );
  }

  @override
  Future<void> unload() async {
    _tts?.free();
    _tts = null;
    _model = null;
  }

  BuiltinModel? get loadedModel => _model;
}

/// 在独立 isolate 里加载 / 合成 / 卸载，主 isolate 只等消息。
///
/// 为什么需要它：sherpa-onnx 的模型加载和 generate 是同步 FFI，直接在主
/// isolate 调用会把 UI 卡住 8 秒左右。worker 有自己的事件循环，主线程照常
/// 画加载状态、响应停止。
class SherpaIsolateEngine implements BuiltinTtsEngine {
  Isolate? _isolate;
  ReceivePort? _receive;
  SendPort? _send;
  Future<void>? _starting;
  final Map<int, Completer<Map<String, Object?>>> _pending =
      <int, Completer<Map<String, Object?>>>{};
  int _nextId = 1;

  Future<void> _ensureStarted() async {
    if (_send != null) return;
    _starting ??= _start();
    await _starting;
  }

  Future<void> _start() async {
    final ReceivePort receive = ReceivePort();
    _receive = receive;
    final Completer<SendPort> ready = Completer<SendPort>();
    receive.listen((Object? raw) {
      if (raw is SendPort) {
        if (!ready.isCompleted) ready.complete(raw);
        return;
      }
      if (raw is Map) {
        final Map<String, Object?> msg = Map<String, Object?>.from(raw);
        final Object? id = msg['id'];
        if (id is int) {
          final Completer<Map<String, Object?>>? c = _pending.remove(id);
          if (c != null) c.complete(msg);
        }
      }
    });
    final Isolate isolate = await Isolate.spawn(
      _ttsWorkerMain,
      receive.sendPort,
    );
    _isolate = isolate;
    _send = await ready.future;
  }

  Future<Map<String, Object?>> _request(Map<String, Object?> msg) async {
    await _ensureStarted();
    final int id = _nextId++;
    final Completer<Map<String, Object?>> completer =
        Completer<Map<String, Object?>>();
    _pending[id] = completer;
    _send!.send(<String, Object?>{...msg, 'id': id});
    final Map<String, Object?> reply = await completer.future;
    if (reply['ok'] != true) {
      throw StateError('${reply['error'] ?? '内置 TTS worker 失败'}');
    }
    return reply;
  }

  @override
  Future<void> load(BuiltinModel model, String modelDir) async {
    await _request(<String, Object?>{
      'cmd': 'load',
      'model': model.name,
      'dir': modelDir,
    });
  }

  @override
  Future<BuiltinAudioInfo> synthesizeToWave(
    String text,
    String outputPath, {
    int sid = 0,
    double speed = 1.0,
  }) async {
    final Map<String, Object?> reply = await _request(<String, Object?>{
      'cmd': 'synth',
      'text': text,
      'out': outputPath,
      'sid': sid,
      'speed': speed,
    });
    return BuiltinAudioInfo(
      seconds: (reply['seconds'] as num?)?.toDouble() ?? 0,
      sampleRate: (reply['sampleRate'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<void> unload() async {
    if (_send == null) return;
    await _request(<String, Object?>{'cmd': 'unload'});
  }

  Future<void> dispose() async {
    final SendPort? send = _send;
    if (send != null) {
      try {
        send.send(<String, Object?>{'cmd': 'exit'});
      } catch (_) {
        // 已经退出。
      }
    }
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _send = null;
    _starting = null;
    _receive?.close();
    _receive = null;
  }
}

void _ttsWorkerMain(SendPort main) async {
  final ReceivePort port = ReceivePort();
  main.send(port.sendPort);
  so.OfflineTts? tts;
  await for (final Object? raw in port) {
    if (raw is! Map) continue;
    final Map<String, Object?> msg = Map<String, Object?>.from(raw);
    final Object? id = msg['id'];
    try {
      switch (msg['cmd']) {
        case 'load':
          await so.initBindingsAsync();
          tts?.free();
          tts = _createOfflineTts(
            BuiltinModel.values.byName(msg['model']! as String),
            msg['dir']! as String,
          );
          main.send(<String, Object?>{'id': id, 'ok': true});
        case 'synth':
          if (tts == null) throw StateError('内置模型还没加载');
          final so.GeneratedAudio audio = tts.generate(
            text: msg['text']! as String,
            sid: (msg['sid'] as num?)?.toInt() ?? 0,
            speed: (msg['speed'] as num?)?.toDouble() ?? 1.0,
          );
          if (audio.samples.isEmpty) throw StateError('模型没有生成音频');
          so.writeWave(
            filename: msg['out']! as String,
            samples: audio.samples,
            sampleRate: audio.sampleRate,
          );
          main.send(<String, Object?>{
            'id': id,
            'ok': true,
            'seconds': audio.samples.length / audio.sampleRate,
            'sampleRate': audio.sampleRate,
          });
        case 'unload':
          tts?.free();
          tts = null;
          main.send(<String, Object?>{'id': id, 'ok': true});
        case 'exit':
          tts?.free();
          port.close();
          return;
        default:
          throw StateError('未知命令：${msg['cmd']}');
      }
    } catch (e) {
      main.send(<String, Object?>{'id': id, 'ok': false, 'error': '$e'});
    }
  }
}

class BuiltinTtsResult {
  const BuiltinTtsResult({
    required this.ok,
    required this.message,
    this.path,
    this.model,
    this.seconds,
    this.cached = false,
  });

  final bool ok;
  final String message;
  final String? path;
  final BuiltinModel? model;
  final double? seconds;
  final bool cached;
}

/// 管理器：串行处理合成，同一时间只留一个模型。
class BuiltinTtsManager {
  BuiltinTtsManager({
    required this.modelRoot,
    BuiltinTtsEngine? engine,
    TtsLifecycle lifecycle = TtsLifecycle.coldStart,
    this.idleTimeout = const Duration(seconds: 60),
    this.cache,
  }) : _engine = engine ?? SherpaIsolateEngine(),
       // ignore: prefer_initializing_formals
       _lifecycle = lifecycle;

  /// 应用数据目录下的 `models/`；测试可以指向临时目录。
  final String modelRoot;

  final BuiltinTtsEngine _engine;
  final Duration idleTimeout;
  final TtsCache? cache;

  TtsLifecycle _lifecycle;
  BuiltinModel? _loaded;
  Timer? _idleTimer;
  Future<void> _tail = Future<void>.value();

  TtsLifecycle get lifecycle => _lifecycle;

  BuiltinModel? get loadedModel => _loaded;

  void setLifecycle(TtsLifecycle value) {
    _lifecycle = value;
    if (value == TtsLifecycle.coldStart) {
      unawaited(
        _serial<void>(() async {
          await _unloadNow();
        }),
      );
    } else if (value == TtsLifecycle.keepLoaded) {
      _idleTimer?.cancel();
      _idleTimer = null;
    } else {
      _restartIdleTimer();
    }
  }

  Future<BuiltinTtsResult> synthesize(
    String text, {
    BuiltinModel? model,
    String? outputPath,
    int sid = 0,
    double speed = 1.0,
  }) {
    return _serial<BuiltinTtsResult>(() async {
      final String t = text.trim();
      if (t.isEmpty) {
        return const BuiltinTtsResult(ok: false, message: '要念的文本是空的');
      }
      final BuiltinModel target = model ?? BuiltinModel.melo;
      final String dir = '$modelRoot/${target.folder}';
      try {
        final TtsCacheEntry? hit = await cache?.find(
          text: t,
          model: target.name,
          sid: sid,
          speed: speed,
        );
        if (hit != null) {
          return BuiltinTtsResult(
            ok: true,
            message: '缓存命中（${hit.seconds.toStringAsFixed(1)} 秒）',
            path: hit.file.path,
            model: target,
            seconds: hit.seconds > 0 ? hit.seconds : null,
            cached: true,
          );
        }
        if (_loaded != target) {
          await _unloadNow();
          await _engine.load(target, dir);
          _loaded = target;
        }
        _idleTimer?.cancel();
        _idleTimer = null;
        final String path =
            outputPath ??
            '${Directory.systemTemp.path}${Platform.pathSeparator}'
                'joenws_tts_${DateTime.now().microsecondsSinceEpoch}.wav';
        final BuiltinAudioInfo info = await _engine.synthesizeToWave(
          t,
          path,
          sid: sid,
          speed: speed,
        );
        await _afterUse();
        String resultPath = path;
        bool stored = false;
        if (cache != null) {
          try {
            final TtsCacheEntry entry = await cache!.store(
              source: File(path),
              text: t,
              model: target.name,
              seconds: info.seconds,
              sid: sid,
              speed: speed,
            );
            resultPath = entry.file.path;
            stored = true;
            if (path != entry.file.path) {
              try {
                await File(path).delete();
              } catch (_) {
                // 临时文件清不掉不影响播放。
              }
            }
          } catch (_) {
            // 缓存写失败不影响这次播放。
          }
        }
        return BuiltinTtsResult(
          ok: true,
          message: stored
              ? '合成好了（${info.seconds.toStringAsFixed(1)} 秒，已缓存）'
              : '合成好了（${info.seconds.toStringAsFixed(1)} 秒）',
          path: resultPath,
          model: target,
          seconds: info.seconds,
          cached: false,
        );
      } catch (e) {
        if (_lifecycle == TtsLifecycle.coldStart) {
          await _unloadNow();
        }
        return BuiltinTtsResult(
          ok: false,
          message: '内置 TTS 不可用：$e',
          model: target,
        );
      }
    });
  }

  Future<void> unload() => _serial<void>(_unloadNow);

  Future<void> dispose() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    await unload();
    if (_engine is SherpaIsolateEngine) {
      await _engine.dispose();
    }
  }

  Future<void> _afterUse() async {
    switch (_lifecycle) {
      case TtsLifecycle.coldStart:
        await _unloadNow();
      case TtsLifecycle.idleUnload:
        _restartIdleTimer();
      case TtsLifecycle.keepLoaded:
        break;
    }
  }

  void _restartIdleTimer() {
    _idleTimer?.cancel();
    if (_lifecycle != TtsLifecycle.idleUnload || _loaded == null) return;
    _idleTimer = Timer(idleTimeout, () {
      unawaited(_serial<void>(_unloadNow));
    });
  }

  Future<void> _unloadNow() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    if (_loaded == null) return;
    await _engine.unload();
    _loaded = null;
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final Completer<T> completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }
}
