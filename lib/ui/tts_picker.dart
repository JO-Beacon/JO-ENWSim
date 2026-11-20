// 挑一份 TTS：内置 / 系统 / 接口。
//
// 角色、世界、全局三个入口共用这个对话框。返回 null = 取消；
// cleared = true = 显式设为“不设（继承上层）”。

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../model/provider.dart';
import '../model/tts_api.dart';
import '../theme/tokens.dart';
import '../tts/audio_player.dart';
import '../tts/builtin_models.dart';
import '../tts/builtin_tts.dart';
import '../tts/installed_models.dart';
import '../tts/kokoro_voices.dart';
import '../tts/system_tts.dart';
import '../tts/tts_file.dart';
import 'common.dart';
import 'icons.dart';

class TtsPickChoice {
  const TtsPickChoice({this.pick, this.cleared = false});

  final TtsPick? pick;
  final bool cleared;
}

Future<TtsPickChoice?> showTtsPicker(
  BuildContext context, {
  required List<Provider> providers,
  TtsPick? current,
  bool allowClear = true,
  String clearLabel = '不设（跟随上层）',
  String? modelRoot,
}) {
  return showDialog<TtsPickChoice>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (BuildContext c) => _TtsPickerDialog(
      providers: providers,
      current: current,
      allowClear: allowClear,
      clearLabel: clearLabel,
      modelRoot: modelRoot,
    ),
  );
}

class _TtsPickerDialog extends StatefulWidget {
  const _TtsPickerDialog({
    required this.providers,
    required this.current,
    required this.allowClear,
    required this.clearLabel,
    this.modelRoot,
  });

  final List<Provider> providers;
  final TtsPick? current;
  final bool allowClear;
  final String clearLabel;
  final String? modelRoot;

  @override
  State<_TtsPickerDialog> createState() => _TtsPickerDialogState();
}

class _TtsPickerDialogState extends State<_TtsPickerDialog> {
  List<TtsVoice> _system = const <TtsVoice>[];
  bool _loadingSystem = true;
  BuiltinTtsManager? _previewManager;
  String? _previewRoot;
  bool _previewBusy = false;
  String _previewStatus = '';
  int _previewRun = 0;
  String _modelRoot = '';

  @override
  void initState() {
    super.initState();
    _loadSystem();
    _loadModelRoot();
  }

  Future<void> _loadModelRoot() async {
    final String support = (await getApplicationSupportDirectory()).path;
    final String root = (widget.modelRoot ?? '').trim().isNotEmpty
        ? widget.modelRoot!.trim()
        : '$support/models';
    if (!mounted) return;
    setState(() => _modelRoot = root);
  }

  @override
  void dispose() {
    _previewRun++;
    final BuiltinTtsManager? manager = _previewManager;
    if (manager != null) unawaited(manager.dispose());
    unawaited(const BuiltinAudioPlayer().stop());
    super.dispose();
  }

  Future<void> _preview(TtsPick pick) async {
    if (_previewBusy) return;
    final int run = ++_previewRun;
    setState(() {
      _previewBusy = true;
      _previewStatus = '正在准备试听…';
    });
    try {
      final String support = (await getApplicationSupportDirectory()).path;
      switch (pick.source) {
        case TtsSource.system:
          TtsVoice? voice;
          for (final TtsVoice v in _system) {
            if (v.id == pick.voiceId) {
              voice = v;
              break;
            }
          }
          final String sample = (voice?.language ?? '').toLowerCase().contains(
                'zh',
              )
              ? '你好，这是系统 TTS 试听。'
              : 'Hello, this is a system TTS preview.';
          final SystemSpeakResult r = await SystemTts.instance.speak(
            sample,
            voice: voice,
          );
          if (!mounted || run != _previewRun) return;
          setState(() {
            _previewBusy = false;
            _previewStatus = r.ok ? '正在试听：${voice?.name ?? '系统声音'}' : r.message;
          });
          return;
        case TtsSource.api:
          Provider? provider;
          for (final Provider x in widget.providers) {
            if (x.id == pick.providerId) {
              provider = x;
              break;
            }
          }
          if (provider == null) {
            throw StateError('服务商不存在：${pick.providerId}');
          }
          final List<TtsVoice> voices = TtsService(provider).voices;
          String language = '';
          for (final TtsVoice v in voices) {
            if (v.id == pick.voiceId) {
              language = v.language;
              break;
            }
          }
          final String sample = language.contains('中')
              ? '你好，这是云 TTS 试听。'
              : 'Hello, this is a cloud TTS preview.';
          final TtsResult r = await TtsService(provider).synthesize(
            sample,
            model: pick.modelId,
            voice: pick.voiceId,
            format: 'wav',
          );
          if (!r.ok || r.bytes == null || r.bytes!.isEmpty) {
            throw StateError(r.message);
          }
          final Directory out = Directory('$support/tts_cache/preview');
          await out.create(recursive: true);
          final String path = await saveTtsAudio(
            r,
            directory: out,
            fileName: 'preview_${DateTime.now().microsecondsSinceEpoch}',
          );
          if (!mounted || run != _previewRun) return;
          await const BuiltinAudioPlayer().play(path);
          if (!mounted || run != _previewRun) return;
          setState(() {
            _previewBusy = false;
            _previewStatus = '正在试听：${provider!.name} · ${pick.voiceId}';
          });
          return;
        case TtsSource.builtin:
          break;
      }

      final BuiltinModel? model = switch (pick.modelId) {
        'melo' => BuiltinModel.melo,
        'kokoro' => BuiltinModel.kokoro,
        _ => null,
      };
      if (model == null) {
        throw StateError('内置模型不存在：${pick.modelId}');
      }
      final int sid = int.tryParse(pick.voiceId) ?? 0;
      String sample;
      if (model == BuiltinModel.melo) {
        sample = KokoroLanguage.chinese.sample;
      } else {
        final KokoroVoice? voice = kokoroVoiceOf(sid);
        if (voice == null) throw StateError('Kokoro 声线不存在：$sid');
        sample = voice.language.sample;
      }
      final String root = (widget.modelRoot ?? '').trim().isNotEmpty
          ? widget.modelRoot!.trim()
          : '$support/models';
      if (!isBuiltinModelInstalled(model, root)) {
        throw StateError(builtinModelMissingMessage(model));
      }
      if (_previewManager == null || _previewRoot != root) {
        final BuiltinTtsManager? old = _previewManager;
        if (old != null) unawaited(old.dispose());
        _previewManager = BuiltinTtsManager(
          modelRoot: root,
          lifecycle: TtsLifecycle.keepLoaded,
        );
        _previewRoot = root;
      }
      final Directory out = Directory('$support/tts_cache/preview');
      await out.create(recursive: true);
      final String path =
          '${out.path}/preview_${DateTime.now().microsecondsSinceEpoch}.wav';
      final BuiltinTtsResult r = await _previewManager!.synthesize(
        sample,
        model: model,
        sid: sid,
        outputPath: path,
      );
      if (!mounted || run != _previewRun) return;
      if (!r.ok || r.path == null) {
        setState(() {
          _previewBusy = false;
          _previewStatus = r.message;
        });
        return;
      }
      await const BuiltinAudioPlayer().play(r.path!);
      if (!mounted || run != _previewRun) return;
      setState(() {
        _previewBusy = false;
        _previewStatus = '正在试听：${pick.modelId == 'kokoro' ? 'Kokoro' : 'Melo'}';
      });
    } catch (e) {
      if (!mounted || run != _previewRun) return;
      setState(() {
        _previewBusy = false;
        _previewStatus = '试听失败：$e';
      });
    }
  }

  Future<void> _loadSystem() async {
    try {
      final List<TtsVoice> voices = await SystemTts.instance.voices();
      if (!mounted) return;
      setState(() {
        _system = voices;
        _loadingSystem = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingSystem = false);
    }
  }

  bool _isCurrent(TtsPick p) => widget.current?.key == p.key;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = JoTheme.of(context);
    final Size mq = MediaQuery.of(context).size;
    final double w = (mq.width - 64).clamp(360.0, 680.0);
    final double h = (mq.height - 64).clamp(320.0, 680.0);
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: Container(
        width: w,
        height: h,
        padding: const EdgeInsets.all(JoSpace.s4),
        decoration: BoxDecoration(
          color: p.bg,
          border: JoShape.border(p.border),
          borderRadius: JoShape.br,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '选择 TTS',
                    style: JoFonts.ui.copyWith(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: p.text,
                    ),
                  ),
                ),
                JoButton(
                  text: '关闭',
                  bordered: true,
                  onTap: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: JoSpace.s3),
            if (widget.allowClear) ...<Widget>[
              JoButton(
                text: widget.clearLabel,
                bordered: true,
                onTap: () => Navigator.of(
                  context,
                ).pop(const TtsPickChoice(cleared: true)),
              ),
              const SizedBox(height: JoSpace.s3),
            ],
            if (_previewStatus.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: JoSpace.s2),
                child: Text(
                  _previewStatus,
                  style: JoFonts.meta.copyWith(color: p.secondary),
                ),
              ),
            Expanded(
              child: ListView(
                children: <Widget>[
                  _group(p, '内置 TTS'),
                  if (_modelRoot.isNotEmpty &&
                      (!isBuiltinModelInstalled(
                            BuiltinModel.melo,
                            _modelRoot,
                          ) ||
                          !isBuiltinModelInstalled(
                            BuiltinModel.kokoro,
                            _modelRoot,
                          )))
                    _hint(
                      p,
                      'Melo / Kokoro 模型未下载：请到 设置 → TTS 服务 → 模型 → '
                      '可下载模型 下载。',
                    ),
                  _row(
                    p,
                    const TtsPick(
                      source: TtsSource.builtin,
                      modelId: 'melo',
                      voiceId: '0',
                    ),
                    'MeloTTS 中文女声',
                    preview: true,
                  ),
                  for (final (String title, KokoroLanguage language)
                      in <(String, KokoroLanguage)>[
                        ('Kokoro · 英文女声', KokoroLanguage.english),
                        ('Kokoro · 中文女声', KokoroLanguage.chinese),
                        ('Kokoro · 中文男声', KokoroLanguage.chinese),
                      ]) ...<Widget>[
                    _group(p, title),
                    for (final KokoroVoice v in kKokoroVoices)
                      if (v.language == language &&
                          (language == KokoroLanguage.english
                              ? v.sid <= 2
                              : (title.contains('男声') ? !v.female : v.female)))
                        _row(
                          p,
                          TtsPick(
                            source: TtsSource.builtin,
                            modelId: 'kokoro',
                            voiceId: '${v.sid}',
                          ),
                          v.displayName,
                          preview: true,
                        ),
                  ],
                  const SizedBox(height: JoSpace.s3),
                  _group(p, '系统 TTS'),
                  if (_loadingSystem)
                    _hint(p, '正在读取系统声音…')
                  else if (_system.isEmpty)
                    _hint(p, '系统里没有可用的声音。')
                  else
                    for (final TtsVoice v in _system)
                      _row(
                        p,
                        TtsPick(source: TtsSource.system, voiceId: v.id),
                        '${v.name}（${v.language}）',
                        preview: true,
                      ),
                  const SizedBox(height: JoSpace.s3),
                  _group(p, '接口 TTS'),
                  if (widget.providers.every(
                    (Provider x) => x.kind != ServiceKind.tts,
                  ))
                    _hint(p, 'TTS 服务里还没有服务商。')
                  else
                    for (final Provider provider in widget.providers)
                      if (provider.kind == ServiceKind.tts)
                        for (final TtsVoice v in TtsService(provider).voices)
                          _row(
                            p,
                            TtsPick(
                              source: TtsSource.api,
                              providerId: provider.id,
                              voiceId: v.id,
                              modelId: TtsService(provider).defaultModel,
                            ),
                            '${provider.name} · ${v.name}',
                            preview: true,
                          ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _group(JoPalette p, String text) => Padding(
    padding: const EdgeInsets.only(bottom: JoSpace.s2),
    child: Text(
      text,
      style: JoFonts.meta.copyWith(color: p.secondary, letterSpacing: 1.2),
    ),
  );

  Widget _hint(JoPalette p, String text) => Padding(
    padding: const EdgeInsets.only(bottom: JoSpace.s2),
    child: Text(text, style: JoFonts.meta.copyWith(color: p.secondary)),
  );

  Widget _row(
    JoPalette p,
    TtsPick pick,
    String label, {
    bool preview = false,
  }) {
    final bool on = _isCurrent(pick);
    return Padding(
      padding: const EdgeInsets.only(bottom: JoSpace.s1),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: JoSpace.s3,
          vertical: JoSpace.s2 + 2,
        ),
        decoration: BoxDecoration(
          color: on ? p.accent.withValues(alpha: 0.10) : Colors.transparent,
          border: JoShape.border(on ? p.accent : p.border),
          borderRadius: JoShape.br,
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: JoTap(
                onTap: () =>
                    Navigator.of(context).pop(TtsPickChoice(pick: pick)),
                opaque: false,
                builder: (BuildContext context, bool hover, bool down) => Text(
                  label,
                  style: JoFonts.ui.copyWith(
                    fontSize: 13,
                    color: hover ? p.accent : p.text,
                  ),
                ),
              ),
            ),
            if (preview)
              JoIconAction(
                icon: JoIcons.play,
                tip: '试听',
                onTap: () {
                  if (!_previewBusy) _preview(pick);
                },
              ),
            if (on) ...[
              const SizedBox(width: JoSpace.s2),
              Text('当前', style: JoFonts.meta.copyWith(color: p.accent)),
            ],
          ],
        ),
      ),
    );
  }
}
