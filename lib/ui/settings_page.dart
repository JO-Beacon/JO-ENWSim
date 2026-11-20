import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/world_store.dart';
import '../model/languages.dart';
import '../model/model_plan.dart';
import '../model/network.dart';
import '../model/ocr/ocr_models.dart';
import '../model/provider.dart';
import '../model/shortcuts.dart';
import '../model/tts_types.dart';
import '../theme/tokens.dart';
import '../tts/audio_player.dart';
import '../tts/builtin_models.dart';
import '../tts/builtin_tts.dart';
import '../tts/installed_models.dart';
import '../tts/downloadable_models.dart';
import '../tts/model_downloader.dart';
import '../tts/model_store.dart';
import '../tts/kokoro_voices.dart';
import '../tts/system_tts.dart';
import '../tts/tts_cache.dart';
import 'tts_picker.dart';
import 'common.dart';
import 'licenses_page.dart';
import 'model_plan_dialog.dart';
import 'provider_panel.dart';

/// 本地导入的 TTS 模型。现在只记路径和识别出的类型，合成接入还没做。
class _LocalTtsModel {
  const _LocalTtsModel({required this.path, required this.family});

  final String path;
  final String family;

  String get name => path.split(Platform.pathSeparator).last;
}

/// 设置：左边分类列表，右边内容。
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.settings,
    required this.onChanged,
    required this.providers,
    required this.onProvidersChanged,
    required this.globalPlan,
    required this.onGlobalPlanChanged,
    this.servicesNote,
    this.globalPlanNote,
    this.worldPlansNote,
    this.prompts = const <String, String>{},
    this.onPromptsChanged,
    required this.keys,
    required this.onKeysChanged,
    required this.onBack,
    this.worldStore,
  });

  final JoSettings settings;
  final ValueChanged<JoSettings> onChanged;

  /// 全局模型默认：总默认 + 每种步骤的全局默认。
  final ModelPlan globalPlan;
  final ValueChanged<ModelPlan> onGlobalPlanChanged;

  /// 存档读不出来时的提示语（如实说，不藏）。
  final String? servicesNote;
  final String? globalPlanNote;
  final String? worldPlansNote;

  /// 快捷键：动作 id → 键位字符串。
  final Map<String, String> keys;
  final ValueChanged<Map<String, String>> onKeysChanged;

  /// 引擎的提示词（设置 → 引擎里那几步）。缺的已用默认补上。
  ///
  /// **引擎读的就是这份** —— 界面上看见什么，引擎就用什么。
  final Map<String, String> prompts;
  final ValueChanged<Map<String, String>>? onPromptsChanged;
  final List<Provider> providers;
  final ValueChanged<List<Provider>> onProvidersChanged;
  final VoidCallback onBack;

  /// 数据页的只读统计从这里读。测试里可以不传。
  final WorldStore? worldStore;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const List<String> _tabs = <String>[
    '语言',
    '外观',
    '行为',
    '快捷键',
    '模型服务',
    '搜索服务',
    'TTS 服务',
    'ASR 服务',
    '引擎',
    '网络',
    '数据',
    '关于',
  ];

  /// 流程图里各步决策用的提示词。
  ///
  /// 步骤清单与“每世界模型配置”共用 model_plan.dart 里的 kSteps，
  /// 免得以后改步骤要改两处。
  static const List<StepKind> _prompts = kSteps;

  /// 三类服务共用同一块面板：模型 / 搜索 / TTS 只是清单与预设不同。
  Widget _servicePanel(ServiceKind kind) {
    final Widget panel = ProviderPanel(
      providers: <Provider>[
        for (final Provider x in widget.providers)
          if (x.kind == kind) x,
      ],
      note: widget.servicesNote,
      headerText: kind == ServiceKind.tts
          ? '在此配置 TTS 服务商与音色；默认值可在“TTS 服务 → 模型”中选择。'
          : null,
      presets: switch (kind) {
        ServiceKind.model => kProviderPresets,
        ServiceKind.search => kSearchPresets,
        ServiceKind.tts => kTtsPresets,
      },
      onChanged: (List<Provider> next) {
        // 只换这一类，别动其它类。
        widget.onProvidersChanged(<Provider>[
          for (final Provider x in widget.providers)
            if (x.kind != kind) x,
          ...next,
        ]);
      },
    );
    if (kind != ServiceKind.search) return panel;
    final JoPalette p = JoTheme.of(context);
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            JoSpace.s4,
            JoSpace.s3,
            JoSpace.s4,
            JoSpace.s3,
          ),
          child: Row(
            children: <Widget>[
              Text(
                '每回合搜索上限',
                style: JoFonts.ui.copyWith(fontSize: 12, color: p.text),
              ),
              const SizedBox(width: JoSpace.s3),
              SizedBox(
                width: 90,
                child: JoTextField(
                  controller: _searchLimitC,
                  onChanged: _onSearchLimitChanged,
                  onSubmitted: (String raw) {
                    _onSearchLimitChanged(raw);
                    final int? v = _parseSearchLimit(raw);
                    if (v != null) _searchLimitC.text = '$v';
                  },
                  style: JoFonts.ui.copyWith(fontSize: 13, color: p.text),
                  hint: '10',
                  hintStyle: JoFonts.meta.copyWith(color: p.secondary),
                ),
              ),
              const SizedBox(width: JoSpace.s2),
              Text(
                '次（1–100，默认 10）',
                style: JoFonts.meta.copyWith(color: p.secondary),
              ),
            ],
          ),
        ),
        Container(height: 1, color: p.border),
        Expanded(child: panel),
      ],
    );
  }

  /// TTS 服务：模型来源 / 朗读与缓存 / 云服务三块。
  /// 原先放在“行为”里的 TTS 朗读和缓存已经全部搬到这里。
  Widget _ttsServicePanel(JoPalette p) {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            JoSpace.s4,
            JoSpace.s3,
            JoSpace.s4,
            JoSpace.s3,
          ),
          child: Row(
            children: <Widget>[
              JoSegment<int>(
                options: const <({String label, int value})>[
                  (label: '模型', value: 0),
                  (label: '朗读与缓存', value: 1),
                  (label: '云服务', value: 2),
                ],
                value: _ttsView,
                onChanged: (int v) => setState(() => _ttsView = v),
              ),
            ],
          ),
        ),
        Container(height: 1, color: p.border),
        Expanded(
          child: switch (_ttsView) {
            1 => _ttsReadPanel(p),
            2 => _servicePanel(ServiceKind.tts),
            _ => _ttsModelsPanel(p),
          },
        ),
      ],
    );
  }

  Widget _ttsModelsPanel(JoPalette p) {
    final JoSettings s = widget.settings;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(JoSpace.s5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'TTS 模型全部按需下载，不随安装包预装；Melo 与 Kokoro 由内置引擎直接合成，'
            'AISHELL-3 / LJSpeech 等留给以后接入。',
            style: JoFonts.meta.copyWith(color: p.secondary, height: 1.7),
          ),
          const SizedBox(height: JoSpace.s4),
          JoSection(
            title: '默认语音',
            children: <Widget>[
              JoField(
                label: '默认 TTS',
                hint: '当前：${_ttsLabel(s.globalTts)}',
                child: JoButton(
                  text: '选择',
                  bordered: true,
                  onTap: _pickGlobalTts,
                ),
              ),
            ],
          ),
          const SizedBox(height: JoSpace.s5),
          JoSection(
            title: '可下载模型',
            children: <Widget>[
              for (final DownloadableTtsModel m in kDownloadableTtsModels)
                _downloadableModelRow(p, m),
              if (_downloadStatus.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    JoSpace.s4,
                    JoSpace.s2,
                    JoSpace.s4,
                    JoSpace.s3,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _downloadStatus,
                      style: JoFonts.meta.copyWith(
                        color: p.secondary,
                        height: 1.7,
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  JoSpace.s4,
                  0,
                  JoSpace.s4,
                  JoSpace.s3,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '下载后自动校验 SHA-256，解压到应用数据目录下的 models 文件夹；'
                    '不会写入安装包。各模型的许可见对应条目右侧。',
                    style: JoFonts.meta.copyWith(
                      color: p.secondary,
                      height: 1.7,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: JoSpace.s5),
          JoSection(
            title: '本地模型',
            children: <Widget>[
              JoField(
                label: '导入模型目录',
                hint: '只支持 sherpa-onnx 模型目录（model.onnx、tokens.txt 等）',
                child: JoButton(
                  text: '选择目录…',
                  bordered: true,
                  onTap: _importLocalTts,
                ),
              ),
              if (_localTtsModels.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    JoSpace.s4,
                    JoSpace.s3,
                    JoSpace.s4,
                    JoSpace.s3,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '尚未导入本地模型。',
                      style: JoFonts.meta.copyWith(color: p.secondary),
                    ),
                  ),
                )
              else
                for (final _LocalTtsModel m in _localTtsModels)
                  _localTtsRow(p, m),
            ],
          ),
          if (_localTtsStatus.isNotEmpty) ...<Widget>[
            const SizedBox(height: JoSpace.s2),
            Text(
              _localTtsStatus,
              style: JoFonts.meta.copyWith(color: p.secondary, height: 1.7),
            ),
          ],
          const SizedBox(height: JoSpace.s3),
          Text(
            '本地模型目前仅支持目录识别，尚未接入语音合成。',
            style: JoFonts.meta.copyWith(color: p.secondary, fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _ttsReadPanel(JoPalette p) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(JoSpace.s5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          JoSection(
            title: 'TTS 朗读',
            children: <Widget>[
              JoField(
                label: '念稿范围',
                hint: '旁白指动作与叙述，对白指角色台词',
                child: JoSegment<bool>(
                  options: const <({String label, bool value})>[
                    (label: '旁白也念', value: true),
                    (label: '仅对白', value: false),
                  ],
                  value: widget.settings.readNarration,
                  onChanged: (bool v) => widget.onChanged(
                    widget.settings.copyWith(readNarration: v),
                  ),
                ),
              ),
              JoField(
                label: '内置模型生命周期',
                hint: '默认完全冷启动；同一时间只加载一个模型',
                child: JoSegment<TtsLifecycle>(
                  options: const <({String label, TtsLifecycle value})>[
                    (label: '完全冷启动', value: TtsLifecycle.coldStart),
                    (label: '空闲卸载', value: TtsLifecycle.idleUnload),
                    (label: '常驻', value: TtsLifecycle.keepLoaded),
                  ],
                  value: widget.settings.ttsLifecycle,
                  onChanged: (TtsLifecycle v) => widget.onChanged(
                    widget.settings.copyWith(ttsLifecycle: v),
                  ),
                ),
              ),
              JoField(
                label: '语速',
                hint: '仅对云 TTS 生效；内置模型暂不支持',
                child: JoSegment<double>(
                  options: const <({String label, double value})>[
                    (label: '0.75×', value: 0.75),
                    (label: '1×', value: 1.0),
                    (label: '1.25×', value: 1.25),
                    (label: '1.5×', value: 1.5),
                  ],
                  value: widget.settings.ttsSpeed,
                  onChanged: (double v) => widget.onChanged(
                    widget.settings.copyWith(ttsSpeed: v),
                  ),
                ),
              ),
              JoField(
                label: '风格 / 情绪',
                hint: '仅对云 TTS 生效；MiMo 以 user 指令传入，OpenAI 仅 gpt-4o-mini-tts 支持',
                child: SizedBox(
                  width: 420,
                  child: JoTextField(
                    controller: _ttsStyleC,
                    onChanged: (String v) => widget.onChanged(
                      widget.settings.copyWith(ttsStyle: v),
                    ),
                    style: JoFonts.ui.copyWith(fontSize: 13, color: p.text),
                    hint: '例如：平静、压低声音、语速稍慢',
                    hintStyle: JoFonts.meta.copyWith(color: p.secondary),
                  ),
                ),
              ),
              JoField(
                label: '系统 TTS',
                hint: '操作系统自带；无需联网和 API Key',
                child: Wrap(
                  spacing: JoSpace.s2,
                  runSpacing: JoSpace.s1,
                  children: <Widget>[
                    JoButton(
                      text: _systemBusy ? '朗读中…' : '试听一句',
                      bordered: true,
                      onTap: () {
                        if (!_systemBusy) _trySystemTts();
                      },
                    ),
                    JoButton(text: '停止', bordered: true, onTap: _stopSystemTts),
                  ],
                ),
              ),
              JoField(
                label: '内置 TTS（Melo）',
                hint: '普通话女声；先在“模型”页下载 MeloTTS 中文',
                child: Wrap(
                  spacing: JoSpace.s2,
                  runSpacing: JoSpace.s1,
                  children: <Widget>[
                    JoButton(
                      text: _builtinBusy ? '准备中…' : '试听 Melo',
                      bordered: true,
                      onTap: () {
                        if (!_builtinBusy) _tryBuiltinTts();
                      },
                    ),
                    JoButton(
                      text: '停止',
                      bordered: true,
                      onTap: _stopBuiltinTts,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_systemStatus.isNotEmpty) ...<Widget>[
            const SizedBox(height: JoSpace.s3),
            Text(
              _systemStatus,
              style: JoFonts.meta.copyWith(color: p.secondary, height: 1.7),
            ),
          ],
          if (_builtinStatus.isNotEmpty) ...<Widget>[
            const SizedBox(height: JoSpace.s1),
            Text(
              _builtinStatus,
              style: JoFonts.meta.copyWith(color: p.secondary, height: 1.7),
            ),
          ],
          const SizedBox(height: JoSpace.s4),
          JoSection(
            title: 'TTS 缓存',
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  JoSpace.s4,
                  JoSpace.s3,
                  JoSpace.s4,
                  JoSpace.s2,
                ),
                child: Text(
                  _cacheStats == null
                      ? '正在读取缓存…'
                      : '${_cacheStats!.count} 个 WAV，'
                            '${_cacheStats!.sizeLabel}',
                  style: JoFonts.meta.copyWith(color: p.secondary),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  JoSpace.s4,
                  0,
                  JoSpace.s4,
                  JoSpace.s3,
                ),
                child: Wrap(
                  spacing: JoSpace.s2,
                  runSpacing: JoSpace.s1,
                  children: <Widget>[
                    JoButton(
                      text: _cacheBusy ? '处理中…' : '刷新',
                      bordered: true,
                      onTap: () {
                        if (!_cacheBusy) _refreshCacheStats();
                      },
                    ),
                    JoButton(
                      text: '清理',
                      bordered: true,
                      onTap: () {
                        if (!_cacheBusy) _clearTtsCache();
                      },
                    ),
                    JoButton(
                      text: '导出全部',
                      bordered: true,
                      onTap: () {
                        if (!_cacheBusy) _exportTtsCache();
                      },
                    ),
                  ],
                ),
              ),
              if (_cacheStatus.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    JoSpace.s4,
                    0,
                    JoSpace.s4,
                    JoSpace.s3,
                  ),
                  child: Text(
                    _cacheStatus,
                    style: JoFonts.meta.copyWith(
                      color: p.secondary,
                      height: 1.7,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: JoSpace.s4),
          Text(
            '系统 TTS 由操作系统提供；内置 TTS 包括 Melo 普通话与 Kokoro 多语言（可选）；'
            '接口 TTS 指 TTS 服务中配置的服务商。',
            style: JoFonts.meta.copyWith(color: p.secondary, fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _downloadableModelRow(JoPalette p, DownloadableTtsModel m) {
    InstalledTtsModel? installed;
    for (final InstalledTtsModel x in _installedTtsModels) {
      if (x.id == m.id) {
        installed = x;
        break;
      }
    }
    final double? progress = _downloadProgress[m.id];
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: JoSpace.s4,
        vertical: JoSpace.s3,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${m.label} · ${m.language}',
                  style: JoFonts.ui.copyWith(fontSize: 13, color: p.text),
                ),
                const SizedBox(height: 2),
                Text(
                  m.description,
                  style: JoFonts.meta.copyWith(color: p.secondary, height: 1.6),
                ),
                const SizedBox(height: 2),
                Text(
                  '${m.license} · ${_formatBytes(m.archiveBytes)}'
                  ' · ${m.sha256.isEmpty ? '官方未提供 SHA-256，按大小校验' : 'SHA-256 校验'}'
                  '${installed == null ? '' : ' · ${installed.path}'}',
                  overflow: TextOverflow.ellipsis,
                  style: JoFonts.meta.copyWith(
                    color: p.secondary,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: JoSpace.s3),
          if (installed != null) ...<Widget>[
            Text('已安装', style: JoFonts.meta.copyWith(color: p.accent)),
            const SizedBox(width: JoSpace.s2),
            JoButton(
              text: '删除',
              bordered: true,
              onTap: () => _removeInstalledTtsModel(installed!),
            ),
          ] else if (progress != null) ...<Widget>[
            SizedBox(
              width: 92,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    '${(progress * 100).round()}%',
                    style: JoFonts.meta.copyWith(color: p.secondary),
                  ),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(
                    value: progress,
                    minHeight: 3,
                    backgroundColor: p.border,
                    color: p.accent,
                  ),
                ],
              ),
            ),
          ] else ...<Widget>[
            JoButton(
              text: '来源',
              bordered: true,
              tip: m.url,
              onTap: () => launchUrl(
                Uri.parse(m.url),
                mode: LaunchMode.externalApplication,
              ),
            ),
            const SizedBox(width: JoSpace.s2),
            JoButton(
              text: '许可',
              bordered: true,
              onTap: () => launchUrl(
                Uri.parse(m.licenseUrl),
                mode: LaunchMode.externalApplication,
              ),
            ),
            const SizedBox(width: JoSpace.s2),
            JoButton(
              text: '下载',
              onTap: () => _downloadTtsModel(m),
            ),
          ],
        ],
      ),
    );
  }

  Widget _localTtsRow(JoPalette p, _LocalTtsModel m) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: JoSpace.s4,
        vertical: JoSpace.s3,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  m.name,
                  style: JoFonts.ui.copyWith(fontSize: 13, color: p.text),
                ),
                const SizedBox(height: 2),
                Text(
                  m.path,
                  overflow: TextOverflow.ellipsis,
                  style: JoFonts.meta.copyWith(color: p.secondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: JoSpace.s3),
          Text(m.family, style: JoFonts.meta.copyWith(color: p.accent)),
          const SizedBox(width: JoSpace.s2),
          JoButton(
            text: '移除',
            onTap: () => setState(() => _localTtsModels.remove(m)),
          ),
        ],
      ),
    );
  }

  Future<void> _importLocalTts() async {
    final String? picked = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择 TTS 模型目录',
    );
    if (picked == null || picked.trim().isEmpty) return;
    final String dir = picked.trim();
    final List<String> missing = <String>[];
    for (final String f in <String>['model.onnx', 'tokens.txt']) {
      if (!File('$dir${Platform.pathSeparator}$f').existsSync()) missing.add(f);
    }
    if (missing.isNotEmpty) {
      setState(() => _localTtsStatus = '无效的模型目录：缺少 ${missing.join('、')}');
      return;
    }
    final bool kokoro = File(
      '$dir${Platform.pathSeparator}voices.bin',
    ).existsSync();
    setState(() {
      _localTtsStatus = '已识别：${kokoro ? 'Kokoro' : 'VITS'} 目录';
      if (!_localTtsModels.any((_LocalTtsModel m) => m.path == dir)) {
        _localTtsModels.add(
          _LocalTtsModel(path: dir, family: kokoro ? 'Kokoro' : 'VITS'),
        );
      }
    });
  }

  Future<void> _pickGlobalModel(String stepId) async {
    final ModelPick? pick = await showModelPicker(
      context,
      groups: modelGroupsOf(widget.providers),
      current: stepId.isEmpty
          ? widget.globalPlan.defaultRef
          : widget.globalPlan.stepKey(stepId),
      clearLabel: stepId.isEmpty ? '不设（未设置）' : '不设（跟随全局默认）',
    );
    if (!mounted) return;
    widget.onGlobalPlanChanged(
      stepId.isEmpty
          ? widget.globalPlan.copyWith(defaultRef: pick?.key ?? '')
          : widget.globalPlan.withStep(stepId, pick?.key ?? ''),
    );
  }

  /// 全局那两级：总默认 + 每种步骤的全局默认。
  List<Widget> _globalModels(JoPalette p) {
    return <Widget>[
      _modelRow(
        p,
        title: '全局默认',
        hint: '所有步骤的最终默认值',
        stepId: '',
        follow: '未设置',
      ),
      for (final StepKind s in kSteps)
        _modelRow(
          p,
          title: StepId.label(s.id),
          hint: s.hint,
          stepId: s.id,
          follow: '跟随全局默认',
        ),
    ];
  }

  Widget _modelRow(
    JoPalette p, {
    required String title,
    required String hint,
    required String stepId,
    required String follow,
  }) {
    final String key = stepId.isEmpty
        ? widget.globalPlan.defaultRef
        : widget.globalPlan.stepKey(stepId);
    final String value = modelKeyLabel(modelGroupsOf(widget.providers), key);
    return _modelRowBox(
      p,
      title: title,
      hint: hint,
      value: value.isEmpty ? follow : value,
      set: value.isNotEmpty,
      onTap: () => _pickGlobalModel(stepId),
    );
  }

  Widget _modelRowBox(
    JoPalette p, {
    required String title,
    required String hint,
    required String value,
    required bool set,
    required VoidCallback onTap,
  }) {
    return JoTap(
      onTap: onTap,
      opaque: false,
      builder: (BuildContext context, bool hover, bool down) {
        return AnimatedContainer(
          duration: kJoTapMs,
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(
            horizontal: JoSpace.s3,
            vertical: JoSpace.s2,
          ),
          decoration: BoxDecoration(
            color: hover ? p.surface : Colors.transparent,
            border: JoShape.border(hover ? p.accent : p.border),
            borderRadius: JoShape.br,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: JoFonts.ui.copyWith(fontSize: 13, color: p.text),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      hint,
                      overflow: TextOverflow.ellipsis,
                      style: JoFonts.meta.copyWith(
                        color: p.secondary,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: JoSpace.s3),
              Text(
                value,
                overflow: TextOverflow.ellipsis,
                style: JoFonts.meta.copyWith(
                  color: set ? p.accent : p.secondary,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  int _tab = 0;
  late final Future<PackageInfo> _info = PackageInfo.fromPlatform();
  final Map<String, TextEditingController> _promptC =
      <String, TextEditingController>{};
  late final TextEditingController _autoRunC;
  late final TextEditingController _concurrencyC;
  late final TextEditingController _searchLimitC;
  late final TextEditingController _ttsStyleC;

  /// 数据页的只读统计；null = 还没读到 / 读失败。
  DatabaseStats? _stats;
  String? _statsError;

  @override
  void initState() {
    super.initState();
    _autoRunC = TextEditingController(
      text: _autoRunLabel(widget.settings.autoRunMaxTurns),
    );
    _concurrencyC = TextEditingController(
      text: '${widget.settings.modelRequestConcurrency}',
    );
    _searchLimitC = TextEditingController(
      text: '${widget.settings.searchMaxQueriesPerTurn}',
    );
    _ttsStyleC = TextEditingController(text: widget.settings.ttsStyle);
    for (final ({String id, String title, String hint}) p in _prompts) {
      // 框里**显示默认值**，不是空的 —— 看不见提示词就等于改不了它。
      final TextEditingController c = TextEditingController(
        text: widget.prompts[p.id] ?? kDefaultPromptOf(p.id),
      );
      // 边打边存：不用另加保存按钮，也不会“关掉就丢”。
      c.addListener(_savePrompts);
      _promptC[p.id] = c;
    }
    _stats = _readStats();
    unawaited(_initTtsCache());
    unawaited(_loadInstalledTtsModels());
    unawaited(_refreshOcrStatus());
  }

  /// 网络页的输入框：初值来自设置，边打边存。
  late final TextEditingController _proxyHostC = TextEditingController(
    text: widget.settings.proxyHost,
  );
  late final TextEditingController _proxyPortC = TextEditingController(
    text: '${widget.settings.proxyPort}',
  );
  bool _networkBusy = false;
  String _networkStatus = '';

  Future<void> _initTtsCache() async {
    try {
      final Directory support = await getApplicationSupportDirectory();
      if (!mounted) return;
      final TtsCache cache = TtsCache(Directory('${support.path}/tts_cache'));
      setState(() => _ttsCache = cache);
      await _refreshCacheStats();
    } catch (_) {
      // 缓存目录不可用不影响其他设置。
    }
  }

  Future<void> _loadInstalledTtsModels() async {
    try {
      final List<InstalledTtsModel> installed = await TtsModelStore.load();
      final String root = await _effectiveModelRoot();
      if (!mounted) return;
      setState(() {
        _modelsRoot = root;
        _installedTtsModels = installed;
      });
    } catch (_) {
      // 模型目录不可用不影响其他设置。
    }
  }

  Future<void> _downloadTtsModel(DownloadableTtsModel model) async {
    if (_modelsRoot.isEmpty) {
      await _loadInstalledTtsModels();
      if (_modelsRoot.isEmpty) {
        setState(() => _downloadStatus = '模型目录尚未就绪。');
        return;
      }
    }
    setState(() {
      _downloadProgress[model.id] = 0;
      _downloadStatus = '正在下载 ${model.label}…';
    });
    try {
      final InstalledTtsModel installed = await TtsModelDownloader(
        modelsRoot: _modelsRoot,
      ).install(
        model,
        onProgress: (double p) {
          if (!mounted) return;
          final double next = p.clamp(0, 1);
          if ((_downloadProgress[model.id] ?? -1) == next) return;
          setState(() => _downloadProgress[model.id] = next);
        },
      );
      final List<InstalledTtsModel> next = <InstalledTtsModel>[
        ..._installedTtsModels.where(
          (InstalledTtsModel m) => m.id != installed.id,
        ),
        installed,
      ];
      await TtsModelStore.save(next);
      if (!mounted) return;
      setState(() {
        _installedTtsModels = next;
        _downloadProgress.remove(model.id);
        _downloadStatus = '已安装 ${model.label}。';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloadProgress.remove(model.id);
        _downloadStatus = '下载失败：$e';
      });
    }
  }

  Future<void> _removeInstalledTtsModel(InstalledTtsModel model) async {
    try {
      final Directory dir = Directory(model.path);
      if (await dir.exists()) await dir.delete(recursive: true);
      final List<InstalledTtsModel> next = _installedTtsModels
          .where((InstalledTtsModel m) => m.id != model.id)
          .toList();
      await TtsModelStore.save(next);
      if (!mounted) return;
      setState(() {
        _installedTtsModels = next;
        _downloadStatus = '已删除 ${model.label}。';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _downloadStatus = '删除失败：$e');
    }
  }

  String _formatBytes(int bytes) {
    final double mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(1)} MB';
  }

  Future<void> _refreshCacheStats() async {
    final TtsCache? cache = _ttsCache;
    if (cache == null) return;
    setState(() => _cacheBusy = true);
    try {
      final TtsCacheStats stats = await cache.stats();
      if (!mounted) return;
      setState(() {
        _cacheStats = stats;
        _cacheBusy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cacheBusy = false;
        _cacheStatus = '缓存读取失败：$e';
      });
    }
  }

  Future<void> _clearTtsCache() async {
    final TtsCache? cache = _ttsCache;
    if (cache == null) return;
    setState(() => _cacheBusy = true);
    try {
      await cache.clear();
      await _refreshCacheStats();
      if (!mounted) return;
      setState(() => _cacheStatus = '缓存已清理。');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cacheBusy = false;
        _cacheStatus = '清理失败：$e';
      });
    }
  }

  Future<void> _exportTtsCache() async {
    final TtsCache? cache = _ttsCache;
    if (cache == null) return;
    final String? dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '导出 TTS 缓存到',
    );
    if (dir == null || dir.trim().isEmpty) return;
    setState(() => _cacheBusy = true);
    try {
      final int n = await cache.exportTo(Directory(dir.trim()));
      if (!mounted) return;
      setState(() {
        _cacheBusy = false;
        _cacheStatus = '已导出 $n 个 WAV。';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cacheBusy = false;
        _cacheStatus = '导出失败：$e';
      });
    }
  }

  /// 读一次统计。失败就如实记下来，不拿 0 冒充“空库”。
  DatabaseStats? _readStats() {
    final WorldStore? store = widget.worldStore;
    if (store == null) {
      _statsError = '当前没有可读取的世界库。';
      return null;
    }
    try {
      _statsError = null;
      return store.databaseStats();
    } catch (err) {
      _statsError = '$err';
      return null;
    }
  }

  void _refreshStats() {
    setState(() => _stats = _readStats());
  }

  void _savePrompts() {
    widget.onPromptsChanged?.call(<String, String>{
      for (final MapEntry<String, TextEditingController> e in _promptC.entries)
        e.key: e.value.text,
    });
  }

  /// 0 是内部哨兵，表示 +∞；界面上显示成 ∞。
  static String _autoRunLabel(int value) => value <= 0 ? '∞' : '$value';

  static int? _parseAutoRunLimit(String raw) {
    final String text = raw.trim().toLowerCase();
    if (text == '∞' ||
        text == '+∞' ||
        text == 'infinity' ||
        text == '+infinity' ||
        text == 'unlimited' ||
        text == '不限制' ||
        text == '无限') {
      return 0;
    }
    final int? n = int.tryParse(text);
    if (n == null) return null;
    return n <= 0 ? 0 : n;
  }

  void _onAutoRunChanged(String raw) {
    final int? value = _parseAutoRunLimit(raw);
    if (value == null) return;
    widget.onChanged(widget.settings.copyWith(autoRunMaxTurns: value));
  }

  void _onConcurrencyChanged(String raw) {
    final int? value = int.tryParse(raw.trim());
    if (value == null ||
        value < 1 ||
        value == widget.settings.modelRequestConcurrency) {
      return;
    }
    widget.onChanged(widget.settings.copyWith(modelRequestConcurrency: value));
  }

  static int? _parseSearchLimit(String raw) {
    final int? n = int.tryParse(raw.trim());
    if (n == null) return null;
    return n < 1 ? 1 : (n > 100 ? 100 : n);
  }

  void _onSearchLimitChanged(String raw) {
    final int? value = _parseSearchLimit(raw);
    if (value == null) return;
    widget.onChanged(
      widget.settings.copyWith(searchMaxQueriesPerTurn: value),
    );
  }

  @override
  void dispose() {
    _autoRunC.dispose();
    _concurrencyC.dispose();
    _searchLimitC.dispose();
    _ttsStyleC.dispose();
    _proxyHostC.dispose();
    _proxyPortC.dispose();
    for (final TextEditingController c in _promptC.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final JoPalette p = JoTheme.of(context);
    return Container(
      color: p.bg,
      child: Column(
        children: <Widget>[
          JoPageHeader(title: '设置', onBack: widget.onBack),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SizedBox(width: 200, child: _list(p)),
                Container(width: 1, color: p.border),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 160),
                    // 必须给紧约束：默认那个松散 Stack 会把短内容居中。
                    layoutBuilder: (Widget? current, List<Widget> previous) =>
                        Stack(
                          fit: StackFit.expand,
                          children: <Widget>[...previous, ?current],
                        ),
                    transitionBuilder: (Widget child, Animation<double> a) =>
                        FadeTransition(opacity: a, child: child),
                    child: KeyedSubtree(
                      key: ValueKey<int>(_tab),
                      child: _tab == 6
                          ? _ttsServicePanel(p)
                          : (_tab >= 4 && _tab <= 5
                                ? _servicePanel(ServiceKind.values[_tab - 4])
                                : _body(p)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _list(JoPalette p) {
    return ListView(
      padding: const EdgeInsets.symmetric(
        horizontal: JoSpace.s2,
        vertical: JoSpace.s2,
      ),
      children: <Widget>[
        for (int i = 0; i < _tabs.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: JoSpace.s1),
            child: JoTap(
              onTap: () {
                setState(() => _tab = i);
                if (i == 10) _refreshStats();
              },
              opaque: false,
              builder: (BuildContext context, bool hover, bool down) {
                final bool on = _tab == i;
                return AnimatedContainer(
                  duration: kJoTapMs,
                  curve: Curves.easeOut,
                  padding: const EdgeInsets.symmetric(
                    horizontal: JoSpace.s3,
                    vertical: JoSpace.s3,
                  ),
                  decoration: BoxDecoration(
                    color: on
                        ? p.surface
                        : (hover
                              ? p.surface.withValues(alpha: 0.5)
                              : Colors.transparent),
                    border: JoShape.border(on || hover ? p.accent : p.border),
                    borderRadius: JoShape.br,
                  ),
                  child: Text(
                    _tabs[i],
                    style: JoFonts.ui.copyWith(
                      fontSize: 13,
                      color: on ? p.accent : p.text,
                      fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _body(JoPalette p) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(JoSpace.s5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _content(p),
      ),
    );
  }

  /// 界面语言。只有这一个语言设置，没别的。
  String _lang = kJoLangDefault;

  /// 系统 TTS 试听的临时状态（不落盘）。
  bool _systemBusy = false;
  String _systemStatus = '';

  /// 每次试听 / 停止都加一，用来丢弃过期的异步结果。
  int _systemRun = 0;

  /// 内置 Melo 试听（模型文件不在包里，路径指向应用数据目录）。
  BuiltinTtsManager? _builtinTts;
  String? _builtinRoot;
  bool _builtinBusy = false;
  String _builtinStatus = '';
  int _builtinRun = 0;

  /// WAV 缓存。
  TtsCache? _ttsCache;
  TtsCacheStats? _cacheStats;
  bool _cacheBusy = false;
  String _cacheStatus = '';

  /// TTS 服务页：0 = 模型来源，1 = 云服务。
  int _ttsView = 0;

  /// 本地导入的模型目录（只在这次设置会话里记着）。
  final List<_LocalTtsModel> _localTtsModels = <_LocalTtsModel>[];
  String _localTtsStatus = '';

  /// 从网上下载并安装到应用数据目录的模型。
  List<InstalledTtsModel> _installedTtsModels = <InstalledTtsModel>[];
  final Map<String, double> _downloadProgress = <String, double>{};
  String _downloadStatus = '';

  /// OCR 模型安装状态与下载进度（设置 → 行为）。
  bool? _ocrInstalled;
  double _ocrProgress = 0;
  String _ocrStatus = '';
  bool _ocrDownloading = false;
  String _modelsRoot = '';

  /// 系统 TTS：先列声音，挑一个中文的念一句。
  ///
  /// 这里只是设置页的自检入口；正文里的朗读在 workspace 里。
  Future<void> _trySystemTts() async {
    final int run = ++_systemRun;
    setState(() {
      _systemBusy = true;
      _systemStatus = '正在查找系统声音…';
    });
    try {
      final List<TtsVoice> voices = await SystemTts.instance.voices();
      if (!mounted || run != _systemRun) return;
      if (voices.isEmpty) {
        setState(() {
          _systemBusy = false;
          _systemStatus = '系统中没有可用的声音。';
        });
        return;
      }
      TtsVoice? zhOffline;
      TtsVoice? zhAny;
      for (final TtsVoice v in voices) {
        if (!v.language.toLowerCase().startsWith('zh')) continue;
        zhAny ??= v;
        if (!v.networkRequired) {
          zhOffline = v;
          break;
        }
      }
      final TtsVoice pick = zhOffline ?? zhAny ?? voices.first;
      setState(() => _systemStatus = '正在朗读（${pick.name}）…');
      final SystemSpeakResult r = await SystemTts.instance.speak(
        '你好，这是系统语音试听。',
        voice: pick,
      );
      if (!mounted || run != _systemRun) return;
      setState(() {
        _systemBusy = false;
        _systemStatus = r.ok
            ? '朗读完成；系统中共有 ${voices.length} 个声音（${pick.name}）'
            : r.message;
      });
    } catch (e) {
      if (!mounted || run != _systemRun) return;
      setState(() {
        _systemBusy = false;
        _systemStatus = '系统 TTS 不可用：$e';
      });
    }
  }

  Future<void> _stopSystemTts() async {
    _systemRun++;
    await SystemTts.instance.stop();
    if (!mounted) return;
    setState(() {
      _systemBusy = false;
      _systemStatus = '已停止。';
    });
  }

  /// 内置 Melo 试听：模型按设置的生命周期加载，合成后交给原生通道播放。
  Future<void> _tryBuiltinTts() async {
    final int run = ++_builtinRun;
    setState(() {
      _builtinBusy = true;
      _builtinStatus = '正在准备 Melo 模型…';
    });
    try {
      final Directory support = await getApplicationSupportDirectory();
      final String root = await _effectiveModelRoot();
      if (!mounted || run != _builtinRun) return;
      if (!isBuiltinModelInstalled(BuiltinModel.melo, root)) {
        setState(() {
          _builtinBusy = false;
          _builtinStatus = builtinModelMissingMessage(BuiltinModel.melo);
        });
        return;
      }
      if (_builtinTts == null || _builtinRoot != root) {
        _dropBuiltinManager();
        _builtinTts = BuiltinTtsManager(
          modelRoot: root,
          cache: TtsCache(Directory('${support.path}/tts_cache')),
        );
        _builtinRoot = root;
      }
      final BuiltinTtsManager manager = _builtinTts!;
      manager.setLifecycle(widget.settings.ttsLifecycle);

      final Directory cache = Directory('${support.path}/tts_cache');
      await cache.create(recursive: true);
      final String path =
          '${cache.path}/melo_${DateTime.now().microsecondsSinceEpoch}.wav';
      final BuiltinTtsResult r = await manager.synthesize(
        '你好，这是内置 Melo 语音试听。',
        outputPath: path,
      );
      if (!mounted || run != _builtinRun) return;
      if (!r.ok) {
        setState(() {
          _builtinBusy = false;
          _builtinStatus = r.message;
        });
        return;
      }
      await const BuiltinAudioPlayer().play(r.path!);
      if (!mounted || run != _builtinRun) return;
      setState(() {
        _builtinBusy = false;
        _builtinStatus = '已开始朗读（${r.seconds?.toStringAsFixed(1) ?? '?'} 秒音频）';
      });
    } catch (e) {
      if (!mounted || run != _builtinRun) return;
      setState(() {
        _builtinBusy = false;
        _builtinStatus = '内置 TTS 不可用：$e';
      });
    }
  }

  Future<void> _stopBuiltinTts() async {
    _builtinRun++;
    await const BuiltinAudioPlayer().stop();
    if (!mounted) return;
    setState(() {
      _builtinBusy = false;
      _builtinStatus = '已停止。';
    });
  }

  void _dropBuiltinManager() {
    final BuiltinTtsManager? old = _builtinTts;
    _builtinTts = null;
    _builtinRoot = null;
    if (old != null) unawaited(old.dispose());
  }

  String _ttsLabel(TtsPick pick) {
    switch (pick.source) {
      case TtsSource.builtin:
        if (pick.modelId == 'kokoro') {
          final KokoroVoice? v = kokoroVoiceOf(int.tryParse(pick.voiceId) ?? 0);
          if (v != null) return 'Kokoro · ${v.displayName}';
        }
        return pick.modelId == 'kokoro'
            ? 'Kokoro 多语言（音色编号 ${pick.voiceId.isEmpty ? '0' : pick.voiceId}）'
            : 'MeloTTS 中文（音色编号 ${pick.voiceId.isEmpty ? '0' : pick.voiceId}）';
      case TtsSource.system:
        return '系统 TTS${pick.voiceId.isEmpty ? '' : '：${pick.voiceId}'}';
      case TtsSource.api:
        String name = pick.providerId;
        for (final Provider x in widget.providers) {
          if (x.id == pick.providerId) {
            name = x.name;
            break;
          }
        }
        return '$name · ${pick.voiceId}';
    }
  }

  Future<void> _pickGlobalTts() async {
    final String modelRoot = await _effectiveModelRoot();
    if (!mounted) return;
    final TtsPickChoice? choice = await showTtsPicker(
      context,
      providers: widget.providers,
      current: widget.settings.globalTts,
      allowClear: false,
      modelRoot: modelRoot,
    );
    if (choice == null || choice.pick == null) return;
    final TtsPick pick = choice.pick!;
    widget.onChanged(
      widget.settings.copyWith(
        ttsSource: pick.source,
        ttsProviderId: pick.providerId,
        ttsVoiceId: pick.voiceId,
        ttsModelId: pick.modelId,
      ),
    );
  }

  /// 行为页：OCR 模型下载管理。
  List<Widget> _behaviorPanel(JoPalette p) {
    final String state = switch (_ocrInstalled) {
      true => '已安装，内置 OCR 可用。',
      false => '尚未安装；点“下载模型”后才能用 OCR图片与扫描 PDF 识别。',
      null => '正在检查…',
    };
    const int totalMb = 21; // 三个模型合计约 20.5 MB。
    return <Widget>[
      Text(
        'OCR 模型不随安装包，按需下载到应用数据目录；来源与校验值见下方。',
        style: JoFonts.meta.copyWith(color: p.secondary, height: 1.7),
      ),
      const SizedBox(height: JoSpace.s4),
      JoSection(
        title: 'OCR 模型',
        children: <Widget>[
          JoField(
            label: '状态',
            hint: state,
            child: _ocrDownloading
                ? SizedBox(
                    width: 120,
                    child: LinearProgressIndicator(
                      value: _ocrProgress,
                      minHeight: 3,
                      backgroundColor: p.border,
                      color: p.accent,
                    ),
                  )
                : Row(
                    children: <Widget>[
                      JoButton(
                        text: _ocrInstalled == true ? '重新下载' : '下载模型',
                        onTap: _downloadOcrModels,
                      ),
                      JoButton(
                        text: '来源',
                        bordered: true,
                        tip: 'https://github.com/RapidAI/RapidOCR',
                        onTap: () => launchUrl(
                          Uri.parse('https://github.com/RapidAI/RapidOCR'),
                          mode: LaunchMode.externalApplication,
                        ),
                      ),
                    ],
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              JoSpace.s4,
              JoSpace.s2,
              JoSpace.s4,
              JoSpace.s3,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '共约 $totalMb MB（检测 4.6 MB + 识别 15.9 MB + 字典 0.07 MB）；'
                '下载后校验 SHA-256，不写入安装包。许可：PaddleOCR / RapidOCR（Apache-2.0）。',
                style: JoFonts.meta.copyWith(color: p.secondary, height: 1.7),
              ),
            ),
          ),
          if (_ocrStatus.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                JoSpace.s4,
                0,
                JoSpace.s4,
                JoSpace.s3,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _ocrStatus,
                  style: JoFonts.meta.copyWith(color: p.secondary, height: 1.7),
                ),
              ),
            ),
        ],
      ),
    ];
  }

  Future<void> _refreshOcrStatus() async {
    try {
      final String root = await _effectiveModelRoot();
      final bool ok = await OcrModelManager(modelsRoot: root).isInstalled();
      if (!mounted) return;
      setState(() => _ocrInstalled = ok);
    } catch (_) {
      if (!mounted) return;
      setState(() => _ocrInstalled = false);
    }
  }

  Future<void> _downloadOcrModels() async {
    if (_ocrDownloading) return;
    setState(() {
      _ocrDownloading = true;
      _ocrProgress = 0;
      _ocrStatus = '正在下载 OCR 模型…';
    });
    try {
      final String root = await _effectiveModelRoot();
      await OcrModelManager(modelsRoot: root).installAll(
        onProgress: (double progress, String label) {
          if (!mounted) return;
          setState(() {
            _ocrProgress = progress;
            if (label.isNotEmpty) _ocrStatus = '正在下载 $label…';
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _ocrInstalled = true;
        _ocrDownloading = false;
        _ocrStatus = 'OCR 模型已安装。';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ocrDownloading = false;
        _ocrStatus = '下载失败：$e';
      });
    }
  }

  Future<String> _effectiveModelRoot() async {
    final String? override = Platform.environment['JOENWS_TTS_MODEL_ROOT'];
    if (override != null && override.trim().isNotEmpty) return override.trim();
    final Directory support = await getApplicationSupportDirectory();
    return '${support.path}/models';
  }

  // 模型走“可下载模型”清单，装到应用数据目录的 models/。

  /// 页签下标：0 语言 / 1 外观 / 2 行为 / 3 快捷键
  ///           / 4–6 三类服务（外面板接管）/ 7 引擎 / 8 网络 / 9 数据 / 10 关于
  List<Widget> _content(JoPalette p) {
    switch (_tab) {
      case 0: // 语言
        return <Widget>[
          JoSection(
            title: '界面语言',
            children: <Widget>[
              for (final JoLanguage l in kJoLanguages)
                JoTap(
                  onTap: () => setState(() => _lang = l.tag),
                  builder: (BuildContext c, bool hover, bool down) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: JoSpace.s2),
                    child: Row(
                      children: <Widget>[
                        SizedBox(
                          width: 22,
                          child: _lang == l.tag
                              ? Text(
                                  '✓',
                                  style: JoFonts.meta.copyWith(color: p.accent),
                                )
                              : null,
                        ),
                        Expanded(
                          child: Text(
                            l.label,
                            style: JoFonts.ui.copyWith(
                              fontSize: 13,
                              color: _lang == l.tag ? p.text : p.secondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: JoSpace.s3),
          Text(
            '列表按国际标准标注：BCP 47 标签（如 zh-Hans-CN），并附该语言自身的名称。'
            '目前界面仅支持中文（中国）；其他语言尚未生效。',
            style: JoFonts.meta.copyWith(color: p.secondary, fontSize: 10),
          ),
        ];
      case 1: // 外观
        return <Widget>[
          JoSection(
            title: '界面',
            children: <Widget>[
              JoField(
                label: '主题',
                hint: '暗色偏冷峻，亮色偏纸感',
                child: JoSegment<String>(
                  options: const <({String label, String value})>[
                    (label: '跟随系统', value: 'system'),
                    (label: '暗 · 机器', value: 'dark'),
                    (label: '明 · 纸', value: 'light'),
                  ],
                  value: widget.settings.followSystem
                      ? 'system'
                      : (widget.settings.isDark ? 'dark' : 'light'),
                  // 选“跟随系统”时**保留** isDark —— 那是上次选的那套，
                  // 以后关掉跟随时要回到它。
                  onChanged: (String v) => widget.onChanged(
                    widget.settings.copyWith(
                      followSystem: v == 'system',
                      isDark: v == 'dark'
                          ? true
                          : (v == 'light' ? false : widget.settings.isDark),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: JoSpace.s5),
          JoSection(
            title: '叙事正文',
            children: <Widget>[
              JoField(
                label: '字号',
                child: JoSegment<double>(
                  options: const <({String label, double value})>[
                    (label: '小', value: 14),
                    (label: '中', value: 16),
                    (label: '大', value: 18),
                  ],
                  value: widget.settings.bodySize,
                  onChanged: (double v) =>
                      widget.onChanged(widget.settings.copyWith(bodySize: v)),
                ),
              ),
              JoField(
                label: '字体',
                hint: '宋体用于正文（叙事），黑体用于界面',
                child: JoSegment<bool>(
                  options: const <({String label, bool value})>[
                    (label: '宋体', value: true),
                    (label: '黑体', value: false),
                  ],
                  value: widget.settings.serifBody,
                  onChanged: (bool v) =>
                      widget.onChanged(widget.settings.copyWith(serifBody: v)),
                ),
              ),
            ],
          ),
          const SizedBox(height: JoSpace.s5),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(JoSpace.s4),
            decoration: BoxDecoration(
              border: JoShape.border(p.border),
              borderRadius: JoShape.br,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('预览', style: JoFonts.meta.copyWith(color: p.secondary)),
                const SizedBox(height: JoSpace.s2),
                Text(
                  '雨敲在瓦上。你站在旧宅的门廊下，衣角在滴水，'
                  '脚边是一小片暗色的水渍。',
                  style: widget.settings.bodyStyle(p.text),
                ),
              ],
            ),
          ),
        ];
      case 2: // 行为
        return _behaviorPanel(p);
      case 3: // 快捷键
        return <Widget>[
          Text(
            '点击对应的按键框，再按下需要的组合键，即可完成录入。\n'
            '点击其他位置可退出录入；按 Esc 会清除当前项（恢复为未设置）。'
            '无法识别的按键会立即标出。\n'
            '同一个组合键只能分配给一个动作：后设置的生效，先前设置的会被清空。',
            style: JoFonts.meta.copyWith(color: p.secondary, height: 1.7),
          ),
          const SizedBox(height: JoSpace.s5),
          JoSection(
            title: '快捷键',
            children: <Widget>[
              for (final JoKeyItem k in kJoKeys) ...<Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      flex: 2,
                      child: Text(
                        k.label,
                        style: JoFonts.ui.copyWith(fontSize: 13, color: p.text),
                      ),
                    ),
                    const SizedBox(width: JoSpace.s3),
                    Expanded(
                      flex: 3,
                      child: JoKeyField(
                        spec: widget.keys[k.id] ?? k.fallback,
                        // 同一个键只能给一个动作：后设的赢，用着这个键的其它动作清空
                        // （变成“未设置”，不会默默跟着默认值跑）。
                        onChanged: (String v) => widget.onKeysChanged(
                          joSetKey(widget.keys, k.id, v),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 18,
                      // 空 = 没设，不是“认不出”
                      child:
                          (widget.keys[k.id] ?? '').trim().isNotEmpty &&
                              joActivator(widget.keys[k.id] ?? '') == null
                          ? Text(
                              '无法识别',
                              style: JoFonts.meta.copyWith(color: p.accent),
                            )
                          : null,
                    ),
                  ],
                ),
                const SizedBox(height: JoSpace.s3),
              ],
            ],
          ),
          const SizedBox(height: JoSpace.s4),
          Align(
            alignment: Alignment.centerLeft,
            child: JoButton(
              text: '恢复默认',
              bordered: true,
              onTap: () => widget.onKeysChanged(joDefaultKeys()),
            ),
          ),
          const SizedBox(height: JoSpace.s4),
          Text(
            '“发送”仅在输入框内生效，其余快捷键全局生效。'
            '修改后立即生效，并保存到本地。',
            style: JoFonts.meta.copyWith(color: p.secondary, fontSize: 10),
          ),
        ];
      case 7: // ASR 服务
        // 空页占位：ASR 是独立功能，接口和模型都还没接。
        return const <Widget>[];
      case 8: // 引擎
        return <Widget>[
          Text(
            // 统一 TurnLoop 按 step 读取这里；留空才回退到内置任务。
            '此处为各步骤的任务提示词，修改后立即生效。'
            '留空的步骤使用内置默认值。',
            style: JoFonts.meta.copyWith(color: p.secondary, height: 1.7),
          ),
          if (widget.globalPlanNote != null) ...<Widget>[
            const SizedBox(height: JoSpace.s3),
            Text(
              widget.globalPlanNote!,
              style: JoFonts.meta.copyWith(color: p.secondary, height: 1.7),
            ),
          ],
          if (widget.worldPlansNote != null) ...<Widget>[
            const SizedBox(height: JoSpace.s3),
            Text(
              widget.worldPlansNote!,
              style: JoFonts.meta.copyWith(color: p.secondary, height: 1.7),
            ),
          ],
          const SizedBox(height: JoSpace.s5),
          JoSection(title: '全局默认模型', children: _globalModels(p)),
          const SizedBox(height: JoSpace.s5),
          JoSection(
            title: '自动推演',
            children: <Widget>[
              JoField(
                label: '模型并发上限',
                hint: '所有时间线共用；需为正整数，默认 1',
                child: SizedBox(
                  width: 220,
                  child: JoTextField(
                    controller: _concurrencyC,
                    onChanged: _onConcurrencyChanged,
                    onSubmitted: (String raw) {
                      _onConcurrencyChanged(raw);
                      final int? value = int.tryParse(raw.trim());
                      final int applied = value != null && value > 0
                          ? value
                          : widget.settings.modelRequestConcurrency;
                      _concurrencyC.text = '$applied';
                    },
                    style: JoFonts.ui.copyWith(fontSize: 13, color: p.text),
                  ),
                ),
              ),
              JoField(
                label: '后台推演',
                hint: '切换时间线时原时间线的推进范围',
                child: JoSegment<BackgroundRunMode>(
                  options: <({String label, BackgroundRunMode value})>[
                    for (final BackgroundRunMode mode in BackgroundRunMode.values)
                      (label: mode.label, value: mode),
                  ],
                  value: widget.settings.backgroundRunMode,
                  onChanged: (BackgroundRunMode mode) =>
                      widget.onChanged(widget.settings.copyWith(backgroundRunMode: mode)),
                ),
              ),
              Text(
                '后台推演只决定切换时间线后原线的推进程度；顶栏的“推进方式”决定手动推进（点击发送）时的行为。'
                '两者互不影响。',
                style: JoFonts.meta.copyWith(color: p.secondary, height: 1.7),
              ),
              Text(
                '“直到交互点/自动”模式下最多连续推进的回合数。'
                '达到上限会暂停并提示；这是运行保护，不影响剧情规则。',
                style: JoFonts.meta.copyWith(color: p.secondary, height: 1.7),
              ),
              JoField(
                label: '最多回合',
                hint: '填入整数；0、-1、∞、+∞ 均表示不限制',
                child: SizedBox(
                  width: 220,
                  child: JoTextField(
                    controller: _autoRunC,
                    onChanged: _onAutoRunChanged,
                    onSubmitted: (String raw) {
                      _onAutoRunChanged(raw);
                      final int? value = _parseAutoRunLimit(raw);
                      if (value != null) {
                        _autoRunC.text = _autoRunLabel(value);
                      }
                    },
                    style: JoFonts.ui.copyWith(fontSize: 13, color: p.text),
                    hint: '例如 200；填 ∞ 表示不限制',
                    hintStyle: JoFonts.meta.copyWith(color: p.secondary),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: JoSpace.s5),
          for (final ({String id, String title, String hint}) pr in _prompts)
            _prompt(p, StepId.label(pr.id), pr.hint, _promptC[pr.id]!),
        ];
      case 9: // 网络
        return _network(p);
      case 10: // 数据
        return _data(p);
      default: // 关于
        return _about(p);
    }
  }

  /// 网络页：代理与连通性自检。
  ///
  /// 只影响本应用自己发起的 HTTP 请求；不改系统代理，也不碰其他程序。
  List<Widget> _network(JoPalette p) {
    return <Widget>[
      JoSection(
        title: '代理',
        children: <Widget>[
          JoField(
            label: '启用代理',
            hint: '默认直连；启用后，模型、搜索、TTS 与模型下载的请求均经代理发送',
            child: JoSegment<bool>(
              options: const <({String label, bool value})>[
                (label: '直连', value: false),
                (label: '启用代理', value: true),
              ],
              value: widget.settings.proxyEnabled,
              onChanged: (bool v) =>
                  _saveNetwork(widget.settings.copyWith(proxyEnabled: v)),
            ),
          ),
          JoField(
            label: '地址',
            hint: '本机代理通常为 127.0.0.1',
            child: SizedBox(
              width: 260,
              child: JoTextField(
                controller: _proxyHostC,
                onChanged: (String v) =>
                    _saveNetwork(widget.settings.copyWith(proxyHost: v.trim())),
                style: JoFonts.ui.copyWith(fontSize: 13, color: p.text),
                hint: '127.0.0.1',
                hintStyle: JoFonts.meta.copyWith(color: p.secondary),
              ),
            ),
          ),
          JoField(
            label: '端口',
            hint: 'HTTP 代理端口，有效范围 1–65535',
            child: SizedBox(
              width: 120,
              child: JoTextField(
                controller: _proxyPortC,
                onChanged: _onProxyPortChanged,
                style: JoFonts.ui.copyWith(fontSize: 13, color: p.text),
                hint: '7890',
                hintStyle: JoFonts.meta.copyWith(color: p.secondary),
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: JoSpace.s4),
      Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: JoSpace.s2,
          runSpacing: JoSpace.s1,
          children: <Widget>[
            JoButton(
              text: _networkBusy ? '测试中…' : '测试连接',
              bordered: true,
              onTap: () {
                if (!_networkBusy) _testNetwork();
              },
            ),
            JoButton(
              text: '恢复默认',
              bordered: true,
              onTap: () {
                _proxyHostC.text = '127.0.0.1';
                _proxyPortC.text = '7890';
                _saveNetwork(
                  widget.settings.copyWith(
                    proxyHost: '127.0.0.1',
                    proxyPort: 7890,
                  ),
                );
              },
            ),
          ],
        ),
      ),
      if (_networkStatus.isNotEmpty) ...<Widget>[
        const SizedBox(height: JoSpace.s3),
        Text(
          _networkStatus,
          style: JoFonts.meta.copyWith(color: p.secondary, height: 1.7),
        ),
      ],
      const SizedBox(height: JoSpace.s4),
      Text(
        '代理仅作用于本应用发出的请求（模型服务、搜索服务、TTS 与模型下载）。'
        '系统其他程序不受影响；修改后于下一次请求生效。',
        style: JoFonts.meta.copyWith(color: p.secondary, fontSize: 10),
      ),
    ];
  }

  void _saveNetwork(JoSettings next) {
    widget.onChanged(next);
    NetworkRuntime.configure(
      proxyEnabled: next.proxyEnabled,
      proxyHost: next.proxyHost,
      proxyPort: next.proxyPort,
    );
  }

  void _onProxyPortChanged(String raw) {
    final int? port = int.tryParse(raw.trim());
    if (port == null || port <= 0 || port > 65535) return;
    _saveNetwork(widget.settings.copyWith(proxyPort: port));
  }

  /// 真发一个请求，看代理通不通。
  Future<void> _testNetwork() async {
    setState(() {
      _networkBusy = true;
      _networkStatus = '正在连接…';
    });
    final JoSettings s = widget.settings;
    final http.Client client = NetworkRuntime.newClient();
    final Stopwatch sw = Stopwatch()..start();
    try {
      final http.Response r = await client
          .get(Uri.parse('https://api.deepseek.com/'))
          .timeout(const Duration(seconds: 15));
      sw.stop();
      if (!mounted) return;
      setState(() {
        _networkBusy = false;
        _networkStatus =
            '连接成功：HTTP ${r.statusCode}，耗时 ${sw.elapsedMilliseconds} ms'
            '（${s.proxyEnabled ? '经代理 ${s.proxyHost}:${s.proxyPort}' : '直连'}）';
      });
    } catch (e) {
      sw.stop();
      if (!mounted) return;
      setState(() {
        _networkBusy = false;
        _networkStatus =
            '连接失败：$e（${s.proxyEnabled ? '经代理 ${s.proxyHost}:${s.proxyPort}' : '直连'}）';
      });
    } finally {
      client.close();
    }
  }

  /// 数据页：只读统计 + 为什么会长这么大的说明。
  ///
  /// 这里**不清理、不归档、不压缩**；只把真实数字摆出来。
  List<Widget> _data(JoPalette p) {
    final DatabaseStats? s = _stats;
    return <Widget>[
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Text(
              '世界与回合数据都保存在本地 SQLite 数据库中。以下为当前数据库的实际占用；'
              '数字按 UTF-8 字节统计，不是字符数。',
              style: JoFonts.meta.copyWith(color: p.secondary, height: 1.7),
            ),
          ),
          const SizedBox(width: JoSpace.s3),
          JoButton(text: '刷新', bordered: true, onTap: _refreshStats),
        ],
      ),
      if (_statsError != null) ...<Widget>[
        const SizedBox(height: JoSpace.s3),
        _noteBox(p, '无法读取统计数据：$_statsError', warn: true),
      ],
      if (s == null && _statsError == null) ...<Widget>[
        const SizedBox(height: JoSpace.s3),
        Text('正在读取…', style: JoFonts.meta.copyWith(color: p.secondary)),
      ],
      if (s != null) ...<Widget>[
        const SizedBox(height: JoSpace.s5),
        JoSection(
          title: '数据库',
          children: <Widget>[
            _kv(
              p,
              '文件',
              s.isMemory ? '内存库（测试）' : 'joenws.db · ${_fmtBytes(s.fileBytes)}',
            ),
            if (s.walBytes > 0) _kv(p, 'WAL', _fmtBytes(s.walBytes)),
            _kv(
              p,
              '页',
              '${_fmtBytes(s.pageSize)} × ${s.pageCount} 页'
                  ' · 空闲 ${s.freelistCount} 页',
            ),
            _kv(
              p,
              '世界',
              '${s.worldCount} 个 · 设定 ${_fmtBytes(s.worldSettingBytes)}',
            ),
            _kv(p, '附件', '${s.assetRows} 个 · ${_fmtBytes(s.assetBytes)}'),
            const SizedBox(height: JoSpace.s2),
            _noteBox(
              p,
              '空闲页是删除数据或迁移后残留在文件中的空间；只有 VACUUM 才能真正缩小文件，'
              '本次不执行。',
            ),
          ],
        ),
        const SizedBox(height: JoSpace.s5),
        JoSection(
          title: '回合快照',
          children: <Widget>[
            _kv(p, '行数', '${s.turnRows}'),
            _kv(p, '总占用', _fmtBytes(s.turnBytes)),
            _kv(p, '最大一份', _fmtBytes(s.maxTurnBytes)),
            _kv(
              p,
              '平均每份',
              s.turnRows == 0 ? '—' : _fmtBytes(s.averageTurnBytes.round()),
            ),
            const SizedBox(height: JoSpace.s2),
            _noteBox(p, _snapshotNote(s), warn: _snapshotWarn(s)),
          ],
        ),
        const SizedBox(height: JoSpace.s5),
        JoSection(
          title: '画布正文',
          children: <Widget>[
            _kv(p, '行数', '${s.stepRows}'),
            _kv(p, '正文占用', _fmtBytes(s.stepBytes)),
            const SizedBox(height: JoSpace.s2),
            _noteBox(p, '画布上显示的正文会逐段追加，这部分呈线性增长。'),
          ],
        ),
        if (s.worlds.isNotEmpty) ...<Widget>[
          const SizedBox(height: JoSpace.s5),
          JoSection(
            title: '按世界',
            children: <Widget>[
              for (final WorldSnapshotStat w in s.worlds.take(8))
                _worldStat(p, w),
              if (s.worlds.length > 8)
                Text(
                  '还有 ${s.worlds.length - 8} 个世界……',
                  style: JoFonts.meta.copyWith(color: p.secondary),
                ),
            ],
          ),
        ],
      ],
      const SizedBox(height: JoSpace.s5),
      JoSection(
        title: '导入 / 导出（暂未开放）',
        children: <Widget>[
          _pending('导出世界', '打包成一个文件'),
          _pending('导入世界', '从文件恢复世界'),
        ],
      ),
    ];
  }

  /// 快照区的提示：先说清“为什么会大”，再按阈值提醒。
  String _snapshotNote(DatabaseStats s) {
    if (s.turnRows == 0) {
      return '还没有回合快照。开始推演后，每回合会保存一份完整世界状态：'
          '第 N 回合的快照包含前 N 回合的全部事件与记忆，所以总占用会随回合数平方增长。';
    }
    if (s.turnBytes >= 100 * 1024 * 1024 || s.maxTurnBytes >= 4 * 1024 * 1024) {
      return '已经超过 100 MB（或最大一份超过 4 MB）。每回合存的是完整世界状态，'
          '第 N 回合的快照包含前 N 回合的全部事件与记忆，所以总占用按回合数平方增长。'
          '后续版本会优化事件存储，以降低占用。';
    }
    if (s.turnBytes >= 20 * 1024 * 1024 || s.maxTurnBytes >= 1024 * 1024) {
      return '已经超过 20 MB（或单份快照超过 1 MB）。长时间推演前请留意存储占用；'
          '此处仅统计，不做清理。';
    }
    return '每回合保存一份完整世界状态：第 N 回合的快照包含前 N 回合的全部事件与记忆，'
        '所以总占用会随回合数平方增长。当前占用较小，此处仅统计，不做清理。';
  }

  bool _snapshotWarn(DatabaseStats s) =>
      s.turnBytes >= 20 * 1024 * 1024 || s.maxTurnBytes >= 1024 * 1024;

  Widget _worldStat(JoPalette p, WorldSnapshotStat w) {
    return Padding(
      padding: const EdgeInsets.only(bottom: JoSpace.s3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Text(
              w.name.trim().isEmpty ? '（未命名）' : w.name,
              style: JoFonts.ui.copyWith(fontSize: 12, color: p.text),
            ),
          ),
          const SizedBox(width: JoSpace.s3),
          Text(
            w.turnRows == 0
                ? '0 回合'
                : '${w.turnRows} 回合 · ${_fmtBytes(w.turnBytes)}'
                      '（最大 ${_fmtBytes(w.maxTurnBytes)}）',
            style: JoFonts.meta.copyWith(color: p.secondary),
          ),
        ],
      ),
    );
  }

  Widget _noteBox(JoPalette p, String text, {bool warn = false}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(JoSpace.s3),
      decoration: BoxDecoration(
        color: warn ? p.surface : Colors.transparent,
        border: JoShape.border(warn ? p.accent : p.border),
        borderRadius: JoShape.br,
      ),
      child: Text(
        text,
        style: JoFonts.meta.copyWith(
          color: warn ? p.accent : p.secondary,
          height: 1.7,
        ),
      ),
    );
  }

  List<Widget> _about(JoPalette p) {
    return <Widget>[
      _hero(p),
      const SizedBox(height: JoSpace.s6),
      FutureBuilder<PackageInfo>(
        future: _info,
        builder: (BuildContext context, AsyncSnapshot<PackageInfo> snap) {
          final PackageInfo? i = snap.data;
          final String version = i == null
              ? '正在读取…'
              : '${i.version}${i.buildNumber.isEmpty ? '' : '+${i.buildNumber}'}';
          return JoSection(
            title: '信息',
            children: <Widget>[
              _kv(p, '版本', version),
              _kv(p, '发布者', 'JO-Beacon'),
              _kvLink(
                p,
                'GitHub',
                'github.com/JO-Beacon/JO-ENWSim',
                'https://github.com/JO-Beacon/JO-ENWSim',
              ),
              _kvLink(
                p,
                '官网',
                'jo-beacon.github.io/JO-ENWSim',
                'https://jo-beacon.github.io/JO-ENWSim/',
              ),
              _kv(p, '平台', _platformName()),
            ],
          );
        },
      ),
      const SizedBox(height: JoSpace.s5),
      JoSection(
        title: '许可',
        children: <Widget>[
          _kv(p, '本应用', 'Apache-2.0 · © 2026 JO-Beacon'),
          _kv(p, '字体', '思源黑体 / 思源宋体（SIL OFL 1.1）'),
          _kv(p, '图标', 'Remix Icon（Remix Icon License v1.0）'),
          JoField(
            label: '开源依赖',
            hint: 'Flutter / Dart 及 pub 依赖',
            child: JoButton(
              text: '查看开源许可 →',
              onTap: _openLicenses,
              color: p.accent,
            ),
          ),
        ],
      ),
    ];
  }

  Widget _hero(JoPalette p) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'JO-ENWSim',
                style: JoFonts.ui.copyWith(
                  fontSize: 34,
                  fontWeight: FontWeight.w700,
                  color: p.text,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: JoSpace.s2),
              Text(
                'Emergent Narrative World Simulator',
                style: JoFonts.ui.copyWith(fontSize: 15, color: p.secondary),
              ),
              const SizedBox(height: JoSpace.s5),
              Container(
                padding: const EdgeInsets.only(left: JoSpace.s4),
                decoration: BoxDecoration(
                  border: Border(left: BorderSide(color: p.accent, width: 2)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '不编排剧情，只推演因果。',
                      style: JoFonts.ui.copyWith(fontSize: 16, color: p.text),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '设定世界，投放开场，让它自行展开。',
                      style: JoFonts.ui.copyWith(
                        fontSize: 14,
                        color: p.secondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: JoSpace.s5),
        const JoAppIcon(size: 104),
      ],
    );
  }

  /// 当前运行的平台名，如 Windows / Android。
  String _platformName() {
    if (Platform.isWindows) return 'Windows';
    if (Platform.isAndroid) return 'Android';
    if (Platform.isIOS) return 'iOS';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isLinux) return 'Linux';
    if (Platform.isFuchsia) return 'Fuchsia';
    return Platform.operatingSystem;
  }

  Widget _kv(JoPalette p, String k, String v) {
    return JoField(
      label: k,
      child: Text(v, style: JoFonts.meta.copyWith(color: p.secondary)),
    );
  }

  /// 可点的一行：标签 + 链接，点开走系统浏览器。
  Widget _kvLink(JoPalette p, String k, String v, String url) {
    return JoField(
      label: k,
      child: JoTap(
        onTap: () => _open(url),
        builder: (BuildContext context, bool hover, bool down) => Text(
          v,
          style: JoFonts.meta.copyWith(
            color: hover || down ? p.accent : p.secondary,
          ),
        ),
      ),
    );
  }

  Future<void> _open(String url) async {
    final Uri? uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// 开源许可。**自己写的一页** —— 自带那个会把框架的许可按库文件重复几百遍。
  ///
  /// 转场也用我们自己的：160ms 淡入淡出，不做位移（跟页面切换一致）。
  /// 所以这里不用 MaterialPageRoute（它带系统的滑动转场）。
  void _openLicenses() {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 160),
        reverseTransitionDuration: const Duration(milliseconds: 160),
        pageBuilder:
            (
              BuildContext c,
              Animation<double> primary,
              Animation<double> secondary,
            ) => const LicensesPage(),
        transitionsBuilder:
            (
              BuildContext c,
              Animation<double> a,
              Animation<double> secondary,
              Widget child,
            ) => FadeTransition(opacity: a, child: child),
      ),
    );
  }

  Widget _prompt(
    JoPalette p,
    String title,
    String hint,
    TextEditingController c,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: JoSpace.s5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                title,
                style: JoFonts.ui.copyWith(
                  fontSize: 13,
                  color: p.text,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: JoSpace.s2),
              Expanded(
                child: Text(
                  hint,
                  overflow: TextOverflow.ellipsis,
                  style: JoFonts.meta.copyWith(color: p.secondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: JoSpace.s2),
          _Area(controller: c, hint: '系统提示词……'),
        ],
      ),
    );
  }

  Widget _pending(String label, String hint) {
    return JoField(label: label, hint: hint, child: const SizedBox.shrink());
  }
}

/// 多行输入框（提示词用）。
class _Area extends StatelessWidget {
  const _Area({required this.controller, this.hint});

  final TextEditingController controller;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = JoTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: JoSpace.s3,
        vertical: JoSpace.s2,
      ),
      decoration: BoxDecoration(
        color: p.surface,
        border: JoShape.border(p.border),
        borderRadius: JoShape.br,
      ),
      // 现在 `TextField` 带 `minLines: 4` 的“起步高度”，
      // `JoTextField` 没这个参数，所以用 `ConstrainedBox` 给一个最小高度。
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 4 * 20.4),
        child: JoTextField(
          controller: controller,
          maxLines: null,
          style: JoFonts.meta.copyWith(
            color: p.text,
            fontSize: 12,
            height: 1.7,
          ),
          hint: hint,
          hintStyle: JoFonts.meta.copyWith(color: p.secondary),
        ),
      ),
    );
  }
}

/// 字节数给人看的形式。按 1024 进，不按 1000。
String _fmtBytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  if (n < 1024 * 1024 * 1024) {
    return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(n / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// 关于页顶上的应用图标。
///
/// 照 `assets/icon/app-icon.svg` 重画：一块深色圆角底、三面墙围出一间屋子、
/// 屋里一颗发光的球。用 CustomPainter 而不是贴图，是因为项目没引 SVG 依赖，
/// 而图标本身只有几笔——画出来任意尺寸都清楚。
class JoAppIcon extends StatelessWidget {
  const JoAppIcon({super.key, this.size = 64});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: const CustomPaint(painter: _AppIconPainter()),
    );
  }
}

class _AppIconPainter extends CustomPainter {
  const _AppIconPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.width / 256.0;
    canvas.save();
    canvas.scale(s);

    // 底板：深色竖向渐变 + 60 的圆角。
    const Rect tile = Rect.fromLTWH(0, 0, 256, 256);
    canvas.drawRRect(
      RRect.fromRectAndRadius(tile, const Radius.circular(60)),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Color(0xFF17243A), Color(0xFF080D14)],
        ).createShader(tile),
    );

    // 左墙、右墙、地面——围出一间屋子。
    final Path left = Path()
      ..moveTo(128, 51)
      ..lineTo(35.6, 97.2)
      ..lineTo(35.6, 158.8)
      ..lineTo(128, 112.6)
      ..close();
    canvas.drawPath(left, Paint()..color = const Color(0xFF26334A));

    final Path right = Path()
      ..moveTo(128, 51)
      ..lineTo(220.4, 97.2)
      ..lineTo(220.4, 158.8)
      ..lineTo(128, 112.6)
      ..close();
    canvas.drawPath(right, Paint()..color = const Color(0xFF3B4F6B));

    final Path floor = Path()
      ..moveTo(128, 112.6)
      ..lineTo(220.4, 158.8)
      ..lineTo(128, 205)
      ..lineTo(35.6, 158.8)
      ..close();
    canvas.drawPath(floor, Paint()..color = const Color(0xFF75849B));

    // 光晕：裁在两片墙里，别糊到地面上。
    canvas.save();
    canvas.clipPath(Path.combine(PathOperation.union, left, right));
    final Rect glow = Rect.fromCircle(
      center: const Offset(152, 104),
      radius: 120,
    );
    canvas.drawCircle(
      const Offset(152, 104),
      120,
      Paint()
        ..shader = const RadialGradient(
          colors: <Color>[
            Color(0x73FFD77A),
            Color(0x29FFD77A),
            Color(0x00FFD77A),
          ],
          stops: <double>[0, 0.5, 1],
        ).createShader(glow),
    );
    canvas.restore();

    // 屋里那颗球。
    canvas.drawCircle(
      const Offset(152, 104),
      50,
      Paint()..color = const Color(0xFFFFE08A),
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
