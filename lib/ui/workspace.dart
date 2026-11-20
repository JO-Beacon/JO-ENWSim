import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:camera/camera.dart' as cam;
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/gestures.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../data/world_store.dart';
import '../engine/agents/llm_agent_runner.dart';
import '../engine/agents/model_request_limiter.dart';
import '../engine/agents/step_config.dart';
import '../engine/character_memory.dart';
import '../engine/causal_context.dart';
import '../engine/engine_state.dart';
import '../engine/local_turn_scope.dart';
import '../engine/memory_agent.dart';
import '../engine/state_delta.dart';
import '../engine/perception.dart';
import '../engine/player_input.dart';
import '../engine/render_view.dart';
import '../engine/sequence.dart';
import '../engine/turn_loop.dart';
import '../engine/turn_session.dart';
import '../engine/world_adapter.dart';
import '../engine/world_schedule.dart';
import '../theme/settings_store.dart';
import '../model/demo.dart';
import '../model/turn.dart';
import '../model/world_search.dart';
import '../model/char_choices.dart';
import '../model/llm_client.dart';
import '../model/model_plan.dart';
import '../model/local_ocr.dart';
import '../model/ocr/ocr_models.dart';
import '../model/pack_rows.dart';
import '../model/pdf_text.dart';
import '../model/provider.dart';
import '../model/search_api.dart';
import '../model/shortcuts.dart';
import '../model/tts_api.dart';
import '../theme/tokens.dart';
import '../markdown/md_view.dart';
import '../tts/audio_player.dart';
import '../tts/builtin_models.dart';
import '../tts/builtin_tts.dart';
import '../tts/installed_models.dart';
import '../tts/script_reader.dart';
import '../tts/system_tts.dart';
import '../tts/tts_cache.dart';
import '../tts/tts_file.dart';
import '../tts/tts_resolver.dart';
import 'common.dart';
import 'card_extra.dart';
import 'icons.dart';
import 'parallel_place_focus.dart';
import 'char_choices_dialog.dart';
import 'model_plan_dialog.dart';
import 'splitter.dart';
import 'tooltip.dart';
import 'turn_flow.dart';
import 'world_settings.dart';
import 'new_world_dialog.dart';
import 'settings_page.dart';
import 'timeline_panel.dart';

// —— 画布几何 ——
const double _rulerW = 58; // 左侧步号
const double _padX = 16;
const double _wCompact = 260;
const double _wFocus = 540;
const double _wShrunk = 150;
const double _padBottom = 40;

/// 画布最右边“添加地点”那格占的宽度；它在地点列表右侧，不算进任何一列。
const double _addPlaceW = 88;

enum _Page { main, settings }

class _TimelineFrozen implements Exception {
  const _TimelineFrozen();
}

class _TimelineStepEdited implements Exception {
  const _TimelineStepEdited();
}

class _TimelineRun {
  _TimelineRun({
    required this.world,
    required this.branchId,
    required this.placeId,
    required this.pov,
    required this.input,
    required this.attachmentIds,
    required this.searchMaterial,
    required this.session,
    required this.snapshot,
  });

  World world;
  final String branchId;
  String? placeId;
  final RenderPov pov;
  final String input;
  final List<String> attachmentIds;
  String searchMaterial;
  TurnSession? session;
  TurnSession? completedProgress;
  TimelineSnapshot? snapshot;
  TurnTrace? trace;
  bool presentationPending = false;
  final Set<String> checkedPlaces = <String>{};
  WorldWorkQueue? workQueue;
  String? lastSettledPlace;
  bool timeBoundaryPass = false;
  bool noReadyWork = false;
  bool committed = false;
  bool inLocalWave = false;
  Future<void>? settleAfter;
  final List<_TimelineRun> wavePeers = <_TimelineRun>[];
  BackgroundRunMode? backgroundMode;
  final List<PlayerAnswer> answers = <PlayerAnswer>[];
  String? flowActive;
  final Set<String> flowDone = <String>{};

  (String, String) get key => (world.id, branchId);
  bool get frozen => backgroundMode == BackgroundRunMode.freeze;
}

class _TtsReply {
  const _TtsReply(
    this.ok,
    this.message, {
    this.seconds = 0,
    this.cached = false,
  });

  final bool ok;
  final String message;
  final double seconds;
  final bool cached;
}

class _PreparedTts {
  const _PreparedTts(
    this.ok,
    this.message, {
    this.path,
    this.seconds = 0,
    this.cached = false,
  });

  final bool ok;
  final String message;
  final String? path;
  final double seconds;
  final bool cached;
}

class Workspace extends StatefulWidget {
  const Workspace({
    super.key,
    required this.settings,
    required this.onSettingsChanged,
    required this.providers,
    required this.onProvidersChanged,
    required this.globalPlan,
    required this.onGlobalPlanChanged,
    this.servicesNote,
    this.globalPlanNote,
    this.worldPlans = const <String, ModelPlan>{},
    this.onWorldPlansChanged,
    this.worldPlansNote,
    this.keys = const <String, String>{},
    this.onKeysChanged,
    required this.store,
    this.worlds = const <World>[],
    this.worldsNote,
    this.prompts = const <String, String>{},
    this.onPromptsChanged,
    this.settingsStore,
    this.engineSender,
  });

  /// 全局模型默认（设置 → 引擎里那两级）。
  final ModelPlan globalPlan;
  final ValueChanged<ModelPlan> onGlobalPlanChanged;

  /// 存档读不出来时的提示语（如实说，不藏）。
  final String? servicesNote;
  final String? globalPlanNote;

  /// 每个世界的模型配置（世界默认 + 逐步骤），存在存档里。
  final Map<String, ModelPlan> worldPlans;
  final ValueChanged<Map<String, ModelPlan>>? onWorldPlansChanged;
  final String? worldPlansNote;

  /// 快捷键：动作 id → 键位字符串。全局绑定从这里读，不再写死。
  final Map<String, String> keys;
  final ValueChanged<Map<String, String>>? onKeysChanged;

  final JoSettings settings;
  final ValueChanged<JoSettings> onSettingsChanged;

  /// 世界和回合存在这儿。界面上改了什么都要写回去。
  final WorldStore store;

  /// 打开时从库里读出来的世界。
  final List<World> worlds;

  /// 世界存档读不出来时的一句话（如实说，不藏）。
  final String? worldsNote;

  /// 引擎的提示词（设置 → 引擎）。引擎真的读它。
  final Map<String, String> prompts;
  final ValueChanged<Map<String, String>>? onPromptsChanged;
  final List<Provider> providers;
  final ValueChanged<List<Provider>> onProvidersChanged;

  /// 存档：两侧栏拖出来的宽度存这儿（没有就每次用默认值）。
  final SettingsStore? settingsStore;

  /// 注入模型传输，供核心回合入口的集成验证使用。
  final LlmSender? engineSender;

  @override
  State<Workspace> createState() => _WorkspaceState();
}

/// 两侧栏宽度的边界与默认值（像素）。
///
/// 最大宽度不写死：每次布局按“窗口宽 − 另一栏 − 画布最小宽”现算，
/// 所以窗口拉小也不会把画布挤没。默认值 = 双击复位的地方。
const double _kRailMin = 160;
const double _kRailDef = 196;
const double _kSideMin = 200;
const double _kSideDef = 300;

/// 画布至少要留这么宽（两侧栏算最大宽度时扣它）。
const double _kCanvasMin = 320;

class _WorkspaceState extends State<Workspace> with TickerProviderStateMixin {
  final TextEditingController _input = TextEditingController();
  final TransformationController _tc = TransformationController();

  /// 挂在本次玩家输入上的附件；发送成功后清空。
  final List<AssetRecord> _attachments = <AssetRecord>[];
  Size _viewport = Size.zero;

  _Page _page = _Page.main;
  late List<World> _worlds = List<World>.of(widget.worlds);
  late String _worldId = _worlds.isEmpty ? '' : _worlds.first.id;
  String _branchId = mainTimelineId;
  int? _viewedVersionId;
  TimelineSnapshot? _timelineSnapshot;
  final Map<(String, String), _TimelineRun> _timelineRuns = {};
  int _latestTaskNumber = 0;
  late final ModelRequestLimiter _modelRequests =
      ModelRequestLimiter(widget.settings.modelRequestConcurrency);
  final Map<(String, String), String> _timelineSearch = {};
  TurnSession? _activeSession;
  TurnTrace? _lastTurnTrace;

  /// 手动搜索面板查到的材料，下一次环境更新时带给模型。
  String _pendingSearchMaterial = '';

  /// 本回合已经发起的独立搜索次数；上限来自设置，默认 10，最大 100。
  int _searchQueriesThisTurn = 0;

  int get _searchQueryLimit {
    final int n = widget.settings.searchMaxQueriesPerTurn;
    return n < 1 ? 1 : (n > 100 ? 100 : n);
  }

  bool _takeSearchSlot() {
    if (_searchQueriesThisTurn >= _searchQueryLimit) {
      _engineSay(
        '本回合搜索次数已达上限（$_searchQueryLimit 次）。'
        '可以在 设置 → 搜索服务 调整“每回合搜索上限”（1–100）。',
      );
      return false;
    }
    _searchQueriesThisTurn++;
    return true;
  }

  /// 两侧栏宽度。**记着的人想要的宽度**，实际画的时候再按窗口收一道，
  /// 所以窗口拉小了不会被撑破，拉回去又能恢复。
  late double _railW = widget.settingsStore?.loadRailW() ?? _kRailDef;
  late double _sideW = widget.settingsStore?.loadSideW() ?? _kSideDef;

  /// 栏宽存盘（松手时调）。
  void _saveWidths() {
    widget.settingsStore?.saveWidths(railW: _railW, sideW: _sideW);
  }

  /// 右栏流程图展开状态；全局设置，立刻存盘。
  void _toggleFlow() {
    final bool next = !_flowOpen;
    setState(() => _flowOpen = next);
    widget.onSettingsChanged(widget.settings.copyWith(flowOpen: next));
  }

  /// 流式时正在写出来的正文。**只给眼睛看**：只留尾巴，回合结束就清空。
  String _liveText = '';

  void _onStreamDelta(String step, String text) {
    if (!mounted) return;
    final String next = '$_liveText$text';
    setState(() {
      // 留最后 600 字就够了，别让它在内存里无限长。
      _liveText = next.length > 600 ? next.substring(next.length - 600) : next;
    });
  }

  @override
  void initState() {
    super.initState();
    _ensureInitialParallelPlaces();
    _loadPersisted();
    if (_worlds.isNotEmpty) _restoreTimelinePlace();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_maybeAskOcrDownload());
    });
  }

  /// 启动时若 OCR 模型没装，弹窗询问是否下载。
  /// 只在真正弹出并得到回答后，才记住这次会话已处理，避免反复打扰。
  Future<void> _maybeAskOcrDownload() async {
    if (!mounted) return;
    try {
      final bool ok = await LocalOcrEngine.instance.isInstalled();
      if (ok || !mounted) return;
      final bool? yes = await showDialog<bool>(
        context: context,
        builder: (BuildContext dialog) => AlertDialog(
          title: const Text('下载 OCR 模型'),
          content: const Text(
            '内置 OCR 的三个模型（约 21 MB）还没安装，OCR图片与扫描 PDF 识别需要它们。'
            '现在下载吗？也可以之后在 设置 → 行为 里下载。',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('以后再说'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('下载'),
            ),
          ],
        ),
      );
      if (yes == true && mounted) await _downloadOcrFromPrompt();
    } catch (_) {
      // 检查 / 下载失败不阻塞主界面，设置页里还能重试。
    }
  }

  Future<void> _downloadOcrFromPrompt() async {
    final String root = await _effectiveOcrModelRoot();
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialog) => AlertDialog(
        title: const Text('正在下载 OCR 模型'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            LinearProgressIndicator(),
            SizedBox(height: 12),
            Text('来源：RapidOCR（Apache-2.0），下载后校验 SHA-256。'),
          ],
        ),
      ),
    );
    try {
      await OcrModelManager(modelsRoot: root).installAll();
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
  }

  Future<String> _effectiveOcrModelRoot() async {
    final String? override = Platform.environment['JOENWS_TTS_MODEL_ROOT'];
    if (override != null && override.trim().isNotEmpty) return override.trim();
    final Directory support = await getApplicationSupportDirectory();
    return '${support.path}${Platform.pathSeparator}models';
  }

  @override
  void didUpdateWidget(covariant Workspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings.modelRequestConcurrency !=
        widget.settings.modelRequestConcurrency) {
      _modelRequests.limit = widget.settings.modelRequestConcurrency;
    }
  }

  /// 老存档 / 新世界可能没有序列：启动时自动补第一条，不靠用户点按钮。
  void _ensureInitialParallelPlaces() {
    for (int i = 0; i < _worlds.length; i++) {
      if (_worlds[i].parallelPlaces.isNotEmpty) continue;
      final World w = _worlds[i].withInitialParallelPlace();
      _worlds[i] = w;
      widget.store.saveWorldMeta(w);
    }
  }

  /// 从库里把“记忆”和“每个角色自己的模型 / 选择”读进来。
  void _loadPersisted() {
    for (final World w in _worlds) {
      final List<CharacterMemory> memory = widget.store.loadWorldMemory(w.id);
      if (memory.isNotEmpty) {
        _memory[w.id] = memory;
      }
      final TurnSession? session = widget.store.loadTurnSession(w.id);
      if (session != null && w.id == _worldId) {
        _activeSession = session;
        if (_input.text.trim().isEmpty) _input.text = session.rawInput;
      }
      final ({Map<String, ModelPlan> plans, Map<String, CharChoices> choices})
      cfg = widget.store.loadCharCfg(w.id);
      if (cfg.plans.isNotEmpty) _charModel[w.id] = cfg.plans;
      if (cfg.choices.isNotEmpty) _choices[w.id] = cfg.choices;
    }
  }

  /// 记忆：按世界分；整份存在 `TurnState.memory` 里。
  final Map<String, List<CharacterMemory>> _memory =
      <String, List<CharacterMemory>>{};

  /// 底部那个“编辑”按钮**常驻**；编辑与记忆都是弹窗，不占右栏。

  /// 顶栏“推进方式”的三个档位，从最细到最粗。只决定手动推进（发送 / 回车）这一次跑多远；
  /// 切走之后原线怎么续跑，看设置里的“后台推演”，那是另一套。
  static const List<String> kRunModes = <String>['单步', '单回合', '直到交互点'];

  /// 顶栏那个推进按钮的 key，用来算下拉浮层的位置。
  final GlobalKey _modeKey = GlobalKey();

  /// 工具栏上“搜索”那个 chip 的 key，用来算上拉菜单的位置。
  final GlobalKey _searchKey = GlobalKey();

  /// 工具栏上“操控”那个 chip 的 key，用来算上拉菜单的位置。
  final GlobalKey _controlKey = GlobalKey();

  /// 推进方式。默认“单回合” —— 点一下跑一整回合，跟以前一样。
  /// 不落盘、不按分支存：它只管手动这一下。
  String _mode = '单回合';
  RenderPov _pov = RenderPov.omniscient;

  /// 引擎在跑吗。“单步”跑一圈的期间为 true。
  bool _legacyBusy = false;
  bool get _engineBusy => _legacyBusy || _timelineRuns.containsKey((_worldId, _branchId));
  bool _ocrBusy = false;

  /// 右栏那张流程图的进度：正在跑哪一步、哪些跑过了。
  String? _flowActive;
  final Set<String> _flowDone = <String>{};

  /// 右栏那张流程图展开着没有。
  ///
  /// 这个选择是全局的，跨重启记住；点标题切换。
  late bool _flowOpen = widget.settings.flowOpen;

  /// 右栏的滚动（展开流程图后详情被顶到下面，靠它滚过去；推演开始时滚回顶部看图）。
  final ScrollController _sideScroll = ScrollController();

  /// 角色的“选择”（采样策略 / 最大输出 / 流式 / 推理档位 / JSON）。
  /// 按世界分，世界里再按角色名分——**每个角色各有一套**。
  final Map<String, Map<String, CharChoices>> _choices =
      <String, Map<String, CharChoices>>{};

  /// 每个角色一份模型配置（只管“角色感知”和“角色行为”两步）。
  /// 没设的顺次往下：世界这两步 → 世界默认 → 全局。
  final Map<String, Map<String, ModelPlan>> _charModel =
      <String, Map<String, ModelPlan>>{};

  /// 当前聚焦的列（地点）与选中的事件。
  String? _focused;
  int? _selected;

  /// 内置 TTS（正文朗读）。模型按设置的生命周期加载，同一时间只留一个。
  BuiltinTtsManager? _builtinTts;
  String? _builtinRoot;
  final BuiltinAudioPlayer _audio = const BuiltinAudioPlayer();
  bool _reading = false;
  bool _readPaused = false;
  bool _readSystem = false;
  String _readStatus = '';
  int _readRun = 0;

  /// 每世界的模型配置（世界默认 + 逐步骤）。**存盘**，重启还在。
  ///
  /// 以前只在内存里：选完模型一重启就没，行动输入框又写回“未选择”。
  late final Map<String, ModelPlan> _plans = <String, ModelPlan>{
    ...widget.worldPlans,
  };

  /// 改一块世界的模型配置（null = 删掉），并写盘。
  void _putPlan(String worldId, ModelPlan? plan) {
    if (plan == null) {
      _plans.remove(worldId);
    } else {
      _plans[worldId] = plan;
    }
    widget.onWorldPlansChanged?.call(_plans);
  }

  /// 画布上“展开某一列”的过渡。
  ///
  /// **每列各走各的**，所以从 A 换到 B 时，A 一边收回、B 一边展开，
  /// 两个方向同时在动（以前一根全局 0→1 进度条做不到，换列时没动画）。
  final ParallelPlaceFocus _parallelPlaceFocus = ParallelPlaceFocus();

  /// 推进过渡的节拍器。走到位就停，不白占每一帧。
  late final Ticker _focusTicker = createTicker(_tickFocus);
  Duration? _lastTick;

  /// 每张“正在变高 / 正在收回去”的卡多出来多少高度。
  ///
  /// 按卡（列 id + 行）分别记，因为换选中时**旧的要收、新的要长**，
  /// 两件事得同时成立；只记一个数就会“旧的直接缩没、新的那段位移投错地方”。
  final CardExtra _extra = CardExtra();

  /// 现在这个选中状态对应的那张卡、它该多高。
  (String, int)? get _selKey {
    final String? parallelPlaceId = _focused;
    final int row = _selRow;
    return (parallelPlaceId != null && row >= 0)
        ? (parallelPlaceId, row)
        : null;
  }

  World get _world {
    if (_timelineSnapshot case final TimelineSnapshot snapshot) {
      return snapshot.world;
    }
    for (final World w in _worlds) {
      if (w.id == _worldId) return w;
    }
    return _worlds.first;
  }

  World get _displayWorld {
    final World world = _world;
    final int? versionId = _timelineSnapshot?.version.id ??
        widget.store.loadTimelineBranch(world.id, _branchId)?.headVersionId;
    return widget.store.projectTimelineNarration(
      world, versionId ?? -1, _narrationScope(_pov, world.controlledCharacterName),
      branchId: _branchId,
    );
  }

  String _narrationScope(RenderPov pov, String controlled) =>
      pov == RenderPov.player ? 'char:$controlled' : 'god';

  ParallelPlace? get _focusedParallelPlace {
    for (final ParallelPlace l in _displayWorld.parallelPlaces) {
      if (l.id == _focused) return l;
    }
    return null;
  }

  TurnStep? get _selectedEvent {
    final ParallelPlace? parallelPlace = _focusedParallelPlace;
    if (parallelPlace == null || _selected == null) return null;
    if (_selected! < 0 || _selected! >= parallelPlace.events.length)
      return null;
    return parallelPlace.events[_selected!];
  }

  Future<String> _builtinModelRoot() async {
    final String? override = Platform.environment['JOENWS_TTS_MODEL_ROOT'];
    if (override != null && override.trim().isNotEmpty) return override.trim();
    final Directory support = await getApplicationSupportDirectory();
    return '${support.path}/models';
  }

  void _dropBuiltinManager() {
    final BuiltinTtsManager? old = _builtinTts;
    _builtinTts = null;
    _builtinRoot = null;
    if (old != null) unawaited(old.dispose());
  }

  /// 读当前选中的这一步正文。
  ///
  /// 只用 `ScriptReader` 清洗 Markdown，然后整段一次合成——这样不会在
  /// 句子中间换模型/换声线，也只需要加载一次模型。
  Future<BuiltinTtsManager> _ensureBuiltinTts() async {
    final String root = await _builtinModelRoot();
    final Directory support = await getApplicationSupportDirectory();
    final Directory cache = Directory('${support.path}/tts_cache');
    await cache.create(recursive: true);
    if (_builtinTts == null || _builtinRoot != root) {
      _dropBuiltinManager();
      _builtinTts = BuiltinTtsManager(modelRoot: root, cache: TtsCache(cache));
      _builtinRoot = root;
    }
    final BuiltinTtsManager manager = _builtinTts!;
    return manager;
  }

  Future<_TtsReply> _speakBuiltin(
    String text, {
    required TtsPick pick,
    bool batch = false,
  }) async {
    BuiltinModel? model;
    for (final BuiltinModel m in BuiltinModel.values) {
      if (m.name == pick.modelId) model = m;
    }
    if (model == null) {
      return _TtsReply(false, '内置模型不存在：${pick.modelId}');
    }
    final int sid;
    final String sidText = pick.voiceId.trim();
    if (sidText.isEmpty) {
      sid = 0;
    } else {
      final int? parsed = int.tryParse(sidText);
      if (parsed == null) {
        return _TtsReply(false, '内置声线不是数字：$sidText');
      }
      sid = parsed;
    }
    final BuiltinTtsManager manager = await _ensureBuiltinTts();
    final String modelRoot = await _builtinModelRoot();
    if (!isBuiltinModelInstalled(model, modelRoot)) {
      return _TtsReply(false, builtinModelMissingMessage(model));
    }
    if (!batch) manager.setLifecycle(widget.settings.ttsLifecycle);
    final Directory support = await getApplicationSupportDirectory();
    final Directory cache = Directory('${support.path}/tts_cache');
    await cache.create(recursive: true);
    final String path =
        '${cache.path}/read_${DateTime.now().microsecondsSinceEpoch}.wav';
    final BuiltinTtsResult r = await manager.synthesize(
      text,
      model: model,
      sid: sid,
      outputPath: path,
    );
    if (!r.ok || r.path == null) {
      return _TtsReply(false, r.message);
    }
    await _audio.play(r.path!);
    return _TtsReply(
      true,
      r.message,
      seconds: r.seconds ?? 0,
      cached: r.cached,
    );
  }

  Future<_TtsReply> _speakSystem(String text, TtsPick pick) async {
    try {
      final List<TtsVoice> voices = await SystemTts.instance.voices();
      TtsVoice? choose;
      final String wanted = pick.voiceId.trim();
      if (wanted.isNotEmpty) {
        for (final TtsVoice v in voices) {
          if (v.id == wanted || v.name == wanted) {
            choose = v;
            break;
          }
        }
        if (choose == null) {
          return _TtsReply(false, '未找到已配置的系统音色：$wanted');
        }
      } else {
        final bool zh = RegExp(r'[\u3400-\u9fff]').hasMatch(text);
        for (final TtsVoice v in voices) {
          final bool matches = zh
              ? v.language.toLowerCase().startsWith('zh')
              : v.language.toLowerCase().startsWith('en');
          if (!matches) continue;
          if (!v.networkRequired) {
            choose = v;
            break;
          }
          choose ??= v;
        }
        choose ??= voices.isEmpty ? null : voices.first;
      }
      final SystemSpeakResult r = await SystemTts.instance.speak(
        text,
        voice: choose,
      );
      return _TtsReply(r.ok, r.message);
    } catch (e) {
      return _TtsReply(false, '系统 TTS 不可用：$e');
    }
  }

  Future<_PreparedTts> _prepareApi(String text, TtsPick pick) async {
    final String wantedId = pick.providerId.trim();
    if (wantedId.isEmpty) {
      return const _PreparedTts(false, '接口 TTS 没有配置服务商');
    }
    Provider? provider;
    for (final Provider p in widget.providers) {
      if (p.id == wantedId && p.kind == ServiceKind.tts) {
        provider = p;
        break;
      }
    }
    if (provider == null) {
      return _PreparedTts(false, '接口 TTS 服务商不存在：$wantedId');
    }
    if (provider.apiKey.trim().isEmpty) {
      return _PreparedTts(false, '接口 TTS 服务商没有 Key：${provider.name}');
    }
    final Directory support = await getApplicationSupportDirectory();
    final Directory cacheDir = Directory('${support.path}/tts_cache');
    final TtsCache cache = TtsCache(cacheDir);
    final String modelKey =
        'api:${provider.id}:${pick.modelId}:${pick.voiceId}';
    final String style = widget.settings.ttsStyle.trim();
    final double speed = widget.settings.ttsSpeed;
    try {
      final TtsCacheEntry? hit = await cache.find(
        text: text,
        model: modelKey,
        speed: speed,
        extra: style,
      );
      if (hit != null) {
        return _PreparedTts(
          true,
          '缓存命中',
          path: hit.file.path,
          seconds: hit.seconds,
          cached: true,
        );
      }
      final TtsResult r = await TtsService(provider).synthesize(
        text,
        model: pick.modelId.trim().isEmpty ? null : pick.modelId,
        voice: pick.voiceId.trim().isEmpty ? null : pick.voiceId,
        format: 'wav',
        speed: speed,
        style: style,
      );
      if (!r.ok || r.bytes == null || r.bytes!.isEmpty) {
        return _PreparedTts(false, r.message);
      }
      final String path = await saveTtsAudio(
        r,
        directory: cacheDir,
        fileName: 'api_${DateTime.now().microsecondsSinceEpoch}',
      );
      final double seconds = wavDurationSeconds(File(path));
      await cache.store(
        source: File(path),
        text: text,
        model: modelKey,
        seconds: seconds,
        speed: speed,
        extra: style,
      );
      return _PreparedTts(
        true,
        r.message,
        path: path,
        seconds: seconds,
      );
    } catch (e) {
      return _PreparedTts(false, '接口 TTS 不可用：$e');
    }
  }

  Future<_TtsReply> _speakApi(String text, TtsPick pick) async {
    final _PreparedTts p = await _prepareApi(text, pick);
    if (!p.ok || p.path == null) {
      return _TtsReply(false, p.message);
    }
    await _audio.play(p.path!);
    return _TtsReply(
      true,
      p.message,
      seconds: p.seconds,
      cached: p.cached,
    );
  }

  /// 预取下一句的云 TTS 音频：只合成并写缓存，不播放。
  Future<void> _prefetchApi(Utterance u) async {
    try {
      final TtsPick pick = const TtsResolver().resolve(
        speaker: u.speaker,
        world: _world,
        settings: widget.settings,
      );
      if (pick.source != TtsSource.api) return;
      await _prepareApi(u.text, pick);
    } catch (_) {
      // 预取失败不影响正式朗读，下一句会自己再试。
    }
  }

  /// 严格按解析出的 TtsPick 念；失败就如实报错，不换来源、不换声线。
  Future<_TtsReply> _speakText(
    String text, {
    String speaker = '',
    bool batch = false,
  }) async {
    final TtsPick pick = const TtsResolver().resolve(
      speaker: speaker,
      world: _world,
      settings: widget.settings,
    );
    _readSystem = pick.source == TtsSource.system;
    switch (pick.source) {
      case TtsSource.builtin:
        return _speakBuiltin(text, pick: pick, batch: batch);
      case TtsSource.system:
        return _speakSystem(text, pick);
      case TtsSource.api:
        return _speakApi(text, pick);
    }
  }

  List<Utterance> _lastTurnUtterances() {
    if (_pov == RenderPov.player) return const <Utterance>[];
    final TurnTrace? trace = _lastTurnTrace;
    if (trace == null) return const <Utterance>[];
    final ScriptReader reader = ScriptReader(
      scope: widget.settings.readNarration
          ? ReadScope.narrationAndDialogue
          : ReadScope.dialogueOnly,
    );
    final List<Utterance> fromEvents = reader.readEvents(<WorldEvent>[
      ...trace.environmentEvents,
      ...trace.events,
    ]);
    if (fromEvents.isNotEmpty) return fromEvents;
    return reader.readMarkdown('${trace.render?['public_text'] ?? ''}');
  }

  /// 整回合逐句朗读：念稿模块拆句，句间用 pauseAfterMs。
  Future<void> _readLastTurn() async {
    if (_reading) return;
    final List<Utterance> units = _lastTurnUtterances();
    if (units.isEmpty) {
      _engineSay('这一回合没有可朗读的正文。');
      return;
    }
    final int run = ++_readRun;
    setState(() {
      _reading = true;
      _readPaused = false;
      _readSystem = false;
      _readStatus = '正在准备朗读本回合（${units.length} 句）…';
    });
    BuiltinTtsManager? batchManager;
    TtsLifecycle? oldLifecycle;
    try {
      if (widget.settings.ttsSource == TtsSource.builtin) {
        batchManager = await _ensureBuiltinTts();
        oldLifecycle = batchManager.lifecycle;
        batchManager.setLifecycle(TtsLifecycle.keepLoaded);
      }
      for (int i = 0; i < units.length; i++) {
        if (!mounted || run != _readRun) return;
        final Utterance u = units[i];
        setState(() => _readStatus = '正在朗读 ${i + 1}/${units.length}…');
        final _TtsReply r = await _speakText(
          u.text,
          speaker: u.speaker,
          batch: true,
        );
        if (!mounted || run != _readRun) return;
        if (!r.ok) {
          setState(() {
            _reading = false;
            _readStatus = r.message;
          });
          return;
        }
        if (i + 1 < units.length) {
          unawaited(_prefetchApi(units[i + 1]));
        }
        final int wait = ((r.seconds * 1000).round() + u.pauseAfterMs);
        if (wait > 0) {
          await _waitPlayback(
            run: run,
            seconds: r.seconds,
            extraMs: u.pauseAfterMs,
            index: i + 1,
            total: units.length,
          );
        }
      }
      if (!mounted || run != _readRun) return;
      setState(() {
        _reading = false;
        _readStatus = '本回合朗读完毕。';
      });
    } catch (e) {
      if (!mounted || run != _readRun) return;
      setState(() {
        _reading = false;
        _readStatus = '朗读失败：$e';
      });
    } finally {
      if (batchManager != null) {
        batchManager.setLifecycle(oldLifecycle ?? TtsLifecycle.coldStart);
        if ((oldLifecycle ?? TtsLifecycle.coldStart) ==
            TtsLifecycle.coldStart) {
          await batchManager.unload();
        }
      }
    }
  }

  Future<void> _readSelectedEvent() async {
    final TurnStep? e = _selectedEvent;
    if (e == null || _reading) return;
    if (!widget.settings.readNarration && e.isNarration) {
      setState(() => _readStatus = '当前为“仅对白”模式，旁白不朗读。');
      return;
    }
    final String text = const ScriptReader()
        .readMarkdown(e.text)
        .map((Utterance u) => u.text)
        .join('\n')
        .trim();
    if (text.isEmpty) {
      setState(() => _readStatus = '这一步没有可朗读的正文。');
      return;
    }

    final int run = ++_readRun;
    setState(() {
      _reading = true;
      _readPaused = false;
      _readSystem = false;
      _readStatus = '正在准备朗读…';
    });
    try {
      final _TtsReply r = await _speakText(text, speaker: e.who);
      if (!mounted || run != _readRun) return;
      if (!r.ok) {
        setState(() {
          _reading = false;
          _readStatus = r.message;
        });
        return;
      }
      setState(() => _readStatus = r.cached ? '缓存命中，正在朗读…' : '正在朗读…');
      await _waitPlayback(run: run, seconds: r.seconds, index: 1, total: 1);
      if (!mounted || run != _readRun) return;
      setState(() {
        _reading = false;
        _readStatus = '朗读完毕。';
      });
    } catch (e) {
      if (!mounted || run != _readRun) return;
      setState(() {
        _reading = false;
        _readStatus = '朗读失败：$e';
      });
    }
  }

  Future<void> _stopReading() async {
    _readRun++;
    _readPaused = false;
    await _audio.stop();
    await SystemTts.instance.stop();
    if (!mounted) return;
    setState(() {
      _reading = false;
      _readStatus = '已停止。';
    });
  }

  Future<void> _pauseReading() async {
    if (!_reading || _readPaused) return;
    if (_readSystem) {
      setState(() => _readStatus = '系统 TTS 不支持暂停。');
      return;
    }
    try {
      await _audio.pause();
      if (!mounted) return;
      setState(() {
        _readPaused = true;
        _readStatus = '已暂停。';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _readStatus = '暂停失败：$e');
    }
  }

  Future<void> _resumeReading() async {
    if (!_reading || !_readPaused) return;
    try {
      await _audio.resume();
      if (!mounted) return;
      setState(() {
        _readPaused = false;
        _readStatus = '继续朗读…';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _readStatus = '继续失败：$e');
    }
  }

  Future<void> _waitPlayback({
    required int run,
    required double seconds,
    required int index,
    required int total,
    int extraMs = 0,
  }) async {
    final int fallbackMs = (seconds * 1000).round() + extraMs + 500;
    final DateTime started = DateTime.now();
    DateTime? pausedAt;
    Duration pausedTotal = Duration.zero;
    while (mounted && run == _readRun && _reading) {
      final DateTime now = DateTime.now();
      if (_readPaused) {
        pausedAt ??= now;
      } else if (pausedAt != null) {
        pausedTotal += now.difference(pausedAt);
        pausedAt = null;
      }
      final int elapsed =
          now.difference(started).inMilliseconds - pausedTotal.inMilliseconds;
      final ({int positionMs, int durationMs})? pos = await _audio.position();
      if (pos != null && pos.durationMs > 0) {
        if (!_readPaused) {
          final String next =
              '朗读 $index/$total · ${_formatMs(pos.positionMs)} / '
              '${_formatMs(pos.durationMs)}';
          if (next != _readStatus) {
            setState(() => _readStatus = next);
          }
        }
        if (pos.positionMs >= pos.durationMs - 80) return;
      }
      // 原生查询不可用、或 MCI 播完把位置归零时，用时长兜底。
      if (!_readPaused && elapsed >= fallbackMs) return;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }

  String _formatMs(int ms) {
    final int total = (ms / 1000).round();
    final int m = total ~/ 60;
    final int s = total % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// 排版：每条序列的事件各占一行，且换地点线要经过的格子留空。
  /// 算法在 `packRows`（`model/pack_rows.dart`）里，那边能直接单元测试。
  Map<String, List<int>> get _rows =>
      packRows(_world.parallelPlaces, _world.moves);

  int get _maxRows {
    int max = 1;
    for (final ParallelPlace l in _world.parallelPlaces) {
      final List<int> r = _rows[l.id]!;
      if (r.isNotEmpty && r.last + 1 > max) max = r.last + 1;
    }
    return max;
  }

  double get _rowH => kRowH;

  /// 选中的那张卡要额外多高：**按正文量出来**，不钉死。
  ///
  /// 量不出（没选 / 找不到）就是 0，跟原来一样。
  /// 选中那张卡“正文”的**实际渲染高度**（列 id + 行 → px）。
  ///
  /// 为什么需要它：以前正文高度是用 `TextPainter` 按**纯文字**量的，
  /// Markdown 一渲染（列表、表格、标题）就比那高，卡不够高就会被裁。
  /// 现在由卡里的 [_MeasureSize] 把真实高度报上来。
  final Map<(String, int), double> _bodyH = <(String, int), double>{};

  /// 卡里正文报上来的高度。变了才 setState（不然每帧都重建）。
  void _setBodyHeight(String parallelPlaceId, int row, double h) {
    if (!mounted) return;
    final (String, int) k = (parallelPlaceId, row);
    final double? old = _bodyH[k];
    // 允许半像素误差：排版取整会让高度来回抖一个零头，
    // 用相等去比就会“永远不等 → 每帧 setState → pumpAndSettle 转圈”。
    if (old != null && (old - h).abs() < 0.5) return;
    setState(() => _bodyH[k] = h);
  }

  double get _selExtra {
    final String? parallelPlaceId = _focused;
    final int? idx = _selected;
    if (parallelPlaceId == null || idx == null) return 0;
    final ParallelPlace? parallelPlace = _world.parallelPlaces
        .where((ParallelPlace x) => x.id == parallelPlaceId)
        .firstOrNull;
    if (parallelPlace == null || idx < 0 || idx >= parallelPlace.events.length)
      return 0;

    final JoPalette p = JoTheme.of(context);
    final double w = _colW(parallelPlaceId) - JoSpace.s4 * 2;
    // 正文以外的东西全部**实量**：内边距、顶行（谁 + 时间）、行间距、边框。
    // 不拿一个估计的数字蒙。
    const double pad = JoSpace.s4; // 选中时不是 compact，用 s4
    final int row = _rows[parallelPlaceId]?[idx] ?? -1;

    // 正文高度：优先用卡里报上来的**真实渲染高度**；
    // 还没测到（第一帧）才用纯文字的估算，免得卡一下子跳太高。
    final double? measured = row >= 0 ? _bodyH[(parallelPlaceId, row)] : null;
    final TextPainter bodyTp = TextPainter(
      text: TextSpan(
        text: parallelPlace.events[idx].text,
        style: widget.settings.bodyStyle(p.text),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: w);
    final double bodyH = measured ?? bodyTp.height;

    final TextPainter rowTp = TextPainter(
      text: TextSpan(
        text:
            '${parallelPlace.events[idx].who}  ${parallelPlace.events[idx].time}',
        style: JoFonts.meta.copyWith(color: p.text),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: w);

    final double total = bodyH + rowTp.height + JoSpace.s3 + pad * 2 + 2;
    return total > kCardH ? total - kCardH : 0;
  }

  /// 选中那一步在第几行（没有就是 -1）。
  int get _selRow {
    final String? parallelPlace = _focused;
    final int? idx = _selected;
    if (parallelPlace == null || idx == null) return -1;
    final List<int>? rows = _rows[parallelPlace];
    if (rows == null || idx < 0 || idx >= rows.length) return -1;
    return rows[idx];
  }

  /// 列宽：常规 → （有人展开时）收窄 → （自己展开时）整列宽。
  /// 过渡中卡片、表头、**底层连线**都用这一个值算，所以它们一起动、不会错位。
  double _colW(String id) => _parallelPlaceFocus.width(
    id,
    compact: _wCompact,
    shrunk: _wShrunk,
    focus: _wFocus,
  );

  /// 每帧把各列的展开程度往目标推一点（指数趋近，和帧率无关）。
  void _tickFocus(Duration elapsed) {
    final double dt = _lastTick == null
        ? 1 / 60
        : (elapsed - _lastTick!).inMicroseconds / 1000000;
    _lastTick = elapsed;
    bool moving = _parallelPlaceFocus.advance(
      dt,
      _world.parallelPlaces.map((ParallelPlace l) => l.id),
    );

    // 各张卡的高度也跟着同一套节拍长 / 缩。
    // 目标：被选中那张 → _selExtra；其它（含刚被取消选中的那张）→ 0。
    if (_extra.advance(dt, target: _selKey, targetValue: _selExtra)) {
      moving = true;
    }

    if (moving) {
      setState(() {});
    } else {
      _focusTicker.stop();
    }
  }

  /// 目标变了就喊一声，让节拍器跑起来。
  void _kickFocus() {
    if (_focusTicker.isActive) return;
    _lastTick = null;
    _focusTicker.start();
  }

  Map<String, double> get _colX {
    final Map<String, double> map = <String, double>{};
    double x = _rulerW + _padX;
    for (final ParallelPlace l in _world.parallelPlaces) {
      map[l.id] = x;
      x += _colW(l.id) + kGap;
    }
    return map;
  }

  double get _totalW {
    double x = _rulerW + _padX;
    for (final ParallelPlace l in _world.parallelPlaces) {
      x += _colW(l.id) + kGap;
    }
    return x;
  }

  /// 画布实际宽度：地点列 + 最右边那个“添加地点”。
  double get _canvasW => _totalW + _addPlaceW;

  double get _totalH =>
      kHeaderH + _maxRows * _rowH + _padBottom + _extra.padAbove(_maxRows);

  // 选中那行之后整体下移，免得拉高的卡片盖住下面的。
  // 让位量是动画值：选中时慢慢让开，取消选中时慢慢收回去。
  double _rowTop(int i) => kHeaderH + i * _rowH + _extra.padAbove(i);

  bool _switching = false;

  /// 换世界时那一下淡出 / 淡入。
  ///
  /// 直接换世界＝画面一秒换一张，观感很突然；换的时候先把整个工作台淡下去，
  /// 换完再淡回来。连点不会叠（正在换就忽略）。
  late final AnimationController _worldFade = AnimationController(
    vsync: this,
    value: 1,
    duration: const Duration(milliseconds: 200),
    reverseDuration: const Duration(milliseconds: 110),
  );

  /// 换到一个世界：淡出 → 真换 → 淡入。
  Future<void> _switchWorld(String id) async {
    if (id == _worldId || _switching || _engineBusy) return;
    _saveTimelinePlace();
    _switching = true;
    // 先清选中：不然淡出的时候还看着上一份的展开卡。
    setState(() {
      _focused = null;
      _selected = null;
      // 列 id 会重名（l1/l2…），旧的动画进度不能带过去。
      _parallelPlaceFocus.clear();
      _extra.clear();
      // 量过的正文高度也是按“列 + 行”记的，换世界一并清。
      _bodyH.clear();
      // 附件属于上一个世界的输入，不能带到下一个世界。
      for (final AssetRecord a in _attachments) {
        widget.store.deleteAsset(a.id);
      }
      _attachments.clear();
    });
    await _worldFade.reverse();
    if (!mounted) {
      _switching = false;
      return;
    }
    setState(() {
      _worldId = id;
      _branchId = mainTimelineId;
      _viewedVersionId = null;
      _timelineSnapshot = null;
      _pendingSearchMaterial = '';
      _activeSession = widget.store.loadTurnSession(id);
    });
    _input.text = _activeSession?.rawInput ?? '';
    // 旧存档/空世界没有序列：第一次打开时自动补第一条，不让用户先点按钮。
    if (_world.parallelPlaces.isEmpty)
      _putWorld(_world.withInitialParallelPlace());
    setState(_restoreTimelinePlace);
    await _worldFade.forward();
    _switching = false;
  }

  void _pickWorld(String id) {
    _switchWorld(id);
  }

  Future<void> _newWorld() async {
    final World? w = await showWorldDialog(context);
    if (w == null || !mounted) return;
    setState(() {
      _worlds.add(w);
      widget.store.saveWorld(w);
    });
    await _switchWorld(w.id);
  }

  /// 卡片上的“编辑”：跟右栏底部那个是**同一个入口** —— 打开编辑弹窗。
  /// 之前它开的是“创建向导”那个合体弹窗，那才是要修的。
  Future<void> _editWorld(World w) async {
    if (w.id != _worldId) await _switchWorld(w.id);
    await _openEdit();
  }

  Future<void> _openHistory() async {
    final String worldId = _worldId;
    final List<TimelineBranch> branches = widget.store.listTimelineBranches(worldId);
    if (branches.isEmpty) {
      _engineSay('当前世界没有可查看的版本。');
      return;
    }
    final TimelineSelection? selection = await showDialog<TimelineSelection>(
      context: context,
      builder: (BuildContext context) => TimelinePanel(
        branches: branches,
        histories: <String, List<TimelineVersion>>{
          for (final TimelineBranch branch in branches)
            branch.id: widget.store.timelineHistory(worldId, branch.id),
        },
        currentBranchId: _branchId,
        viewingVersionId: _viewedVersionId,
        statuses: <String, String>{
          for (final TimelineBranch branch in branches)
            branch.id: _timelineStatus(branch),
        },
      ),
    );
    if (!mounted || selection == null || _worldId != worldId) return;
    await _applyTimelineSelection(selection);
  }

  String _timelineStatus(TimelineBranch branch) {
    if (_timelineRuns.containsKey((branch.worldId, branch.id))) return '推演中';
    final TurnSession? session = widget.store.loadTimelineSession(branch.worldId, branch.id);
    if (session == null && widget.store.loadPendingNarration(branch.worldId, branch.id) != null) {
      return '正文待继续';
    }
    return switch (session?.status) {
      'waiting_player' || 'needs_review' => '等待玩家',
      null => '未运行',
      _ => '已暂停',
    };
  }

  Future<void> _applyTimelineSelection(TimelineSelection selection) async {
    try {
      switch (selection.action) {
        case TimelineAction.openHead:
          _viewTimeline(selection.branchId);
        case TimelineAction.readVersion:
          _viewTimeline(selection.branchId, versionId: selection.versionId);
        case TimelineAction.fork:
        case TimelineAction.replay:
          final bool replay = selection.action == TimelineAction.replay;
          final int? start = replay
              ? widget.store.loadTimelineSnapshot(_worldId, selection.versionId).version.parentId
              : selection.versionId;
          if (start == null) return;
          final TimelineBranch branch = widget.store.createTimelineBranch(
            worldId: _worldId,
            sourceBranchId: selection.branchId,
            versionId: start,
            requestId: 'fork-${DateTime.now().microsecondsSinceEpoch}',
          );
          _viewTimeline(branch.id);
          if (replay) await _runTurnStep();
      }
    } catch (error) {
      if (mounted) _engineSay('无法打开时间线：$error');
    }
  }

  void _viewTimeline(String branchId, {int? versionId, bool keepPosition = false}) {
    final TimelineBranch? branch = widget.store.loadTimelineBranch(_worldId, branchId);
    if (branch == null) return;
    final TimelineSnapshot? snapshot = branchId == mainTimelineId && versionId == null
        ? null
        : widget.store.loadTimelineSnapshot(_worldId, versionId ?? branch.headVersionId);
    _saveTimelinePlace();
    final String? placeId = keepPosition
        ? _focused
        : widget.store.loadTimelinePlace(_worldId, branchId);
    final int? card = keepPosition ? _selected : null;
    final (String, String) previous = (_worldId, _branchId);
    _timelineSearch[previous] = _pendingSearchMaterial;
    if (branchId != _branchId) _backgroundCurrentRun();
    setState(() {
      _branchId = branchId;
      _viewedVersionId = versionId;
      _timelineSnapshot = snapshot;
      _activeSession = _timelineRuns[(_worldId, branchId)]?.session ??
          widget.store.loadTimelineSession(_worldId, branchId);
      _pendingSearchMaterial = _timelineSearch[(_worldId, branchId)] ?? '';
      _lastTurnTrace = null;
      final _TimelineRun? run = versionId == null ? _timelineRuns[(_worldId, branchId)] : null;
      _flowActive = run?.flowActive;
      _flowDone
        ..clear()
        ..addAll(run?.flowDone ?? const <String>{});
      _attachments.clear();
      _input.text = _activeSession?.rawInput ?? '';
      _parallelPlaceFocus.clear();
      _extra.clear();
      _bodyH.clear();
      final ParallelPlace? place = _world.parallelPlaces
          .where((ParallelPlace place) => place.id == placeId).firstOrNull
          ?? _world.parallelPlaces.where((ParallelPlace place) => place.isActive).firstOrNull
          ?? _world.parallelPlaces.firstOrNull;
      _focused = place?.id;
      _selected = place != null && place.events.isNotEmpty
          ? math.min(card ?? place.events.length - 1, place.events.length - 1)
          : null;
    });
    _parallelPlaceFocus.focus(_focused);
    _kickFocus();
  }

  void _saveTimelinePlace() {
    final String? placeId = _focused;
    if (_viewedVersionId == null && placeId != null) {
      widget.store.saveTimelinePlace(_worldId, _branchId, placeId);
    }
  }

  void _restoreTimelinePlace() {
    final String? saved = widget.store.loadTimelinePlace(_worldId, _branchId);
    if (saved == null) return;
    final ParallelPlace? place = _world.parallelPlaces.where(
      (ParallelPlace place) => place.id == saved,
    ).firstOrNull;
    if (place == null) return;
    _focused = place.id;
    _selected = place.events.isEmpty ? null : place.events.length - 1;
    _parallelPlaceFocus.focus(_focused);
    _kickFocus();
  }

  void _backgroundCurrentRun() {
    final _TimelineRun? run = _timelineRuns[(_worldId, _branchId)];
    if (run == null) return;
    final BackgroundRunMode mode = widget.settings.backgroundRunMode;
    for (final _TimelineRun task in <_TimelineRun>[run, ...run.wavePeers]) {
      task.backgroundMode = mode;
      if (!task.frozen) continue;
      final TurnSession? completed = task.completedProgress;
      if (completed != null) {
        final String status = task.session?.status == 'waiting_player' ? 'waiting_player' : 'paused';
        widget.store.saveTimelineSession(task.branchId, completed.withStatus(status));
      } else if (task.session case final TurnSession session) {
        widget.store.clearTimelineSession(task.world.id, task.branchId, taskId: session.id);
      }
    }
    if (!run.frozen) return;
    _timelineRuns.remove(run.key);
  }

  Future<void> _openRoundActions(String placeId, int cardIndex) async {
    final String worldId = _worldId;
    final String source = _branchId;
    final TimelineVersion? version =
        widget.store.timelineVersionForCard(worldId, source, placeId, cardIndex);
    if (version == null) return;
    final List<TimelineBranch> all = widget.store.listTimelineBranches(worldId);
    final List<TimelineBranch> direct = all.where(
      (TimelineBranch branch) => branch.forkVersionId == version.id,
    ).toList();
    final Set<String> sources = <String>{
      for (final TimelineBranch branch in direct) if (branch.sourceBranchId != null) branch.sourceBranchId!,
    };
    final List<TimelineBranch> routes = <TimelineBranch>[
      for (final TimelineBranch branch in all)
        if (sources.contains(branch.id) || direct.contains(branch)) branch,
    ];
    final TimelineSelection? selection = await showDialog<TimelineSelection>(
      context: context,
      builder: (BuildContext dialog) => SimpleDialog(
        title: Text('第 ${version.round} 回合'),
        children: <Widget>[
          if (widget.store.loadCompletedTimelineTask(worldId, version.id) != null)
            SimpleDialogOption(
              onPressed: () {
                Navigator.pop(dialog);
                unawaited(_openStoredSteps(versionId: version.id));
              },
              child: const Text('查看和编辑 AI 步骤'),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialog, (
              action: TimelineAction.fork, branchId: source, versionId: version.id,
            )),
            child: const Text('从此处创建分支'),
          ),
          if (version.parentId case final int previous)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialog, (
                action: TimelineAction.readVersion, branchId: source, versionId: previous,
              )),
              child: const Text('回到本次结算前'),
            ),
          if ((version.round ?? 0) > 1)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialog, (
                action: TimelineAction.replay, branchId: source, versionId: version.id,
              )),
              child: const Text('重新推演本回合'),
            ),
          if (routes.isNotEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 6),
              child: Text('查看后续'),
            ),
          for (final TimelineBranch route in routes)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialog, (
                action: TimelineAction.readVersion, branchId: route.id, versionId: version.id,
              )),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Flexible(child: Text(route.id == source ? '${route.name}（当前）' : route.name)),
                  const SizedBox(width: JoSpace.s3),
                  Text(_timelineProgress(worldId, route.id)),
                ],
              ),
            ),
        ],
      ),
    );
    if (!mounted || selection == null || _worldId != worldId || _branchId != source) return;
    if (selection.action == TimelineAction.readVersion) {
      _focusParallelPlace(placeId, index: cardIndex);
      _viewTimeline(selection.branchId, versionId: selection.versionId, keepPosition: true);
      return;
    }
    await _applyTimelineSelection(selection);
  }

  String _timelineProgress(String worldId, String branchId) {
    final int? round = widget.store.timelineHeadRound(worldId, branchId);
    return round == null ? '最新进度为开场' : '最新进度为第 $round 回合';
  }

  Future<void> _openStoredSteps({int? versionId}) async {
    final String worldId = _worldId;
    final String branchId = _branchId;
    final _TimelineRun? run = _timelineRuns[(worldId, branchId)];
    final TurnSession? task = versionId == null
        ? run?.session ?? _activeSession
        : widget.store.loadCompletedTimelineTask(worldId, versionId);
    if (task == null) return;
    final Map<String, String> revisions =
        widget.store.timelineStepRevisions(worldId, branchId, task.id);
    final Map<String, String> originals =
        widget.store.timelineStepOriginals(worldId, branchId, task.id);
    final Map<String, String> steps = <String, String>{
      ...task.journal.responses,
      for (final TurnCheckpoint checkpoint in task.checkpoints.values)
        if (checkpoint.stage != StepId.sysRecovery)
          'checkpoint:${checkpoint.stage}': const JsonEncoder.withIndent('  ').convert(checkpoint.data),
      ...originals,
    };
    final String? step = await showDialog<String>(
      context: context,
      builder: (BuildContext dialog) => SimpleDialog(
        title: const Text('AI 步骤'),
        children: <Widget>[
          for (final String key in steps.keys)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialog, key),
              child: Text(key),
            ),
        ],
      ),
    );
    if (!mounted || step == null) return;
    String value = revisions[step] ?? steps[step]!;
    final String? edited = await showDialog<String>(
      context: context,
      builder: (BuildContext dialog) => AlertDialog(
        title: Text(step),
        content: SizedBox(
          width: 620,
          child: TextFormField(
            initialValue: value,
            minLines: 5,
            maxLines: 15,
            onChanged: (String text) => value = text,
          ),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(dialog, value), child: const Text('保存')),
        ],
      ),
    );
    if (!mounted || edited == null || edited == (revisions[step] ?? steps[step])) return;
    try {
      if (jsonDecode(edited) is! Map) {
        throw const FormatException('步骤结果必须是 JSON 对象。');
      }
      widget.store.saveTimelineStepRevision(
        worldId, branchId, task.id, step,
        original: steps[step]!, value: edited,
      );
      setState(() {});
    } on FormatException catch (error) {
      _engineSay(error.message);
    }
  }

  Future<void> _openEdit() async {
    if (_timelineSnapshot != null) return;
    final String envRoot =
        Platform.environment['JOENWS_TTS_MODEL_ROOT']?.trim() ?? '';
    final String voiceModelRoot = envRoot;
    final WorldEditResult? r = await showWorldEditDialog(
      context,
      worldName: _world.name,
      setting: _world.setting,
      opening: _world.opening,
      worldTts: _world.ttsKey,
      narratorTts: _world.narratorTtsKey,
      searchSource: _world.searchSource,
      plan: _plans[_world.id] ?? const ModelPlan(),
      globalPlan: widget.globalPlan,
      groups: _modelGroups,
      memory: _memory[_world.id] ?? const <CharacterMemory>[],
      owners: <String>[
        for (final CharCard c in _world.characters)
          if (c.name.trim().isNotEmpty) c.name.trim(),
      ],
      characters: _world.characters,
      charModels: _charModel[_world.id] ?? const <String, ModelPlan>{},
      charTts: <String, String>{
        for (final CharCard c in _world.characters) c.name: c.ttsKey,
      },
      ttsProviders: widget.providers,
      globalTts: widget.settings.globalTts,
      modelRoot: voiceModelRoot,
      isLastWorld: _worlds.length <= 1,
      loadMemoryVersions: (String memoryId) async =>
          widget.store.loadMemoryVersions(_world.id, memoryId),
    );
    if (r == null || !mounted) return;
    final String id = _world.id;
    setState(() {
      if (r.delete) {
        _worlds.removeWhere((World w) => w.id == id);
        widget.store.deleteWorld(id);
        _putPlan(id, null);
        _memory.remove(id);
        _choices.remove(id);
        _charModel.remove(id);
        if (_worldId == id && _worlds.isNotEmpty) {
          _worldId = _worlds.first.id;
          _attachments.clear();
        }
        _focused = null;
        _selected = null;
        return;
      }
      _plans[id] = r.plan;
      widget.onWorldPlansChanged?.call(_plans);
      _memory[id] = r.memory;
      _charModel[id] = r.charModels;
      // 记忆、每个角色自己的模型：改了立刻进库。
      widget.store.saveWorldMemory(id, r.memory);
      widget.store.saveCharPlans(id, r.charModels);
      for (int i = 0; i < _worlds.length; i++) {
        final World w = _worlds[i];
        if (w.id != id) continue;
        final List<CharCard> chars = <CharCard>[
          for (final CharCard c in r.characters)
            c.copyWith(ttsKey: r.charTts[c.name] ?? ''),
        ];
        _worlds[i] = World(
          id: w.id,
          name: r.name,
          note: w.note,
          setting: r.setting,
          opening: r.opening,
          characters: chars,
          ttsKey: r.worldTts,
          narratorTtsKey: r.narratorTts,
          searchSource: r.searchSource,
          parallelPlaces: w.parallelPlaces,
          moves: w.moves,
        );
        // 弹窗改的只是世界那一行（名字/设定/角色…），**没动步**：
        // 所以走 saveWorldMeta。以前走 saveWorld，会把整张 step 表重写。
        widget.store.saveWorldMeta(_worlds[i]);
      }
    });
  }

  void _focusParallelPlace(String id, {int? index}) {
    final bool closing = _focused == id && index == null;
    setState(() {
      _focused = closing ? null : id;
      _selected = closing ? null : index;
    });
    _saveTimelinePlace();
    // 各列自己往目标走：新点的那列展开、原来那列收回，两边同时动。
    _parallelPlaceFocus.focus(closing ? null : id);
    _kickFocus();
  }

  /// 可选的模型：启用的服务商下面、启用着的模型。
  List<ModelGroup> get _modelGroups {
    final List<ModelGroup> out = <ModelGroup>[];
    for (final Provider pv in widget.providers) {
      if (!pv.enabled) continue;
      final List<String> ids = <String>[
        for (final ModelRef m in pv.models)
          if (m.enabled && m.id.trim().isNotEmpty) m.id,
      ];
      if (ids.isEmpty) continue;
      out.add((providerId: pv.id, providerName: pv.name, models: ids));
    }
    return out;
  }

  /// 一个角色当前用哪个模型，以及那个模型的能力与协议形状。
  ///
  /// **先模型、后选择**：面板拿的就是这个。
  /// 顺序：角色自己 → 世界默认 → 全局总默认。
  ({String label, ModelCaps? caps, ThinkingSpec spec, bool jsonSupported})
  _charInfo(String name) {
    const ({
      String label,
      ModelCaps? caps,
      ThinkingSpec spec,
      bool jsonSupported,
    })
    none = (
      label: '未选模型',
      caps: null,
      spec: ThinkingSpec(),
      jsonSupported: false,
    );

    final ModelPlan? charPlan = _charModel[_world.id]?[name];
    final ModelPlan worldPlan = _plans[_world.id] ?? const ModelPlan();
    // 角色的“自己的模型”就是它的“角色行为”那一步；没设就顺着往下落。
    final String key = (charPlan?.stepKey('CH_ACT') ?? '').isNotEmpty
        ? charPlan!.stepKey('CH_ACT')
        : (worldPlan.stepKey('CH_ACT').isNotEmpty
              ? worldPlan.stepKey('CH_ACT')
              : (worldPlan.defaultRef.isNotEmpty
                    ? worldPlan.defaultRef
                    : widget.globalPlan.defaultRef));
    final ModelPick? pick = ModelPick.of(key);
    if (pick == null) return none;

    for (final Provider pv in widget.providers) {
      if (pv.id != pick.providerId) continue;
      for (final ModelRef m in pv.models) {
        if (m.id != pick.modelId) continue;
        return (
          label: '${pv.name} · ${m.id}',
          caps: m.caps,
          spec: thinkingSpecOf(pv.protocol),
          jsonSupported: pv.protocol.wire == Wire.chatCompletions,
        );
      }
    }
    return (
      label: '${pick.modelId}（服务商已不在）',
      caps: null,
      spec: const ThinkingSpec(),
      jsonSupported: false,
    );
  }

  Future<void> _pickCharModel(String name) async {
    final ModelPick? pick = await showModelPicker(
      context,
      groups: _modelGroups,
      current: _charModel[_world.id]?[name]?.stepKey('CH_ACT') ?? '',
      clearLabel: '不设（跟随世界默认）',
    );
    if (!mounted) return;
    setState(() {
      final Map<String, ModelPlan> m = <String, ModelPlan>{
        ...?_charModel[_world.id],
      };
      final ModelPlan plan = m[name] ?? const ModelPlan();
      m[name] = plan.withStep('CH_ACT', pick?.key ?? '');
      _charModel[_world.id] = m;
      // 角色自己的模型：进库，重启还在。
      widget.store.saveCharPlan(_world.id, name, m[name]!);
    });
  }

  Future<void> _pickChoices() async {
    final Map<String, CharChoices>? next = await showCharChoicesDialog(
      context,
      characters: <String>[for (final CharCard c in _world.characters) c.name],
      values: _choices[_world.id] ?? const <String, CharChoices>{},
      infoOf: _charInfo,
      onPickModel: _pickCharModel,
    );
    if (next == null || !mounted) return;
    setState(() {
      _choices[_world.id] = next;
      // 角色选择：进库，重启还在。
      widget.store.saveCharChoices(_world.id, next);
    });
  }

  /// 提交：把行动输入交给回合循环。
  ///
  /// 输入框里的文字是**玩家声明的行动原文**，不是聊天消息；附件跟着这条
  /// 输入走，不塞进正文。跑多远看顶栏的推进方式：单步就只走一个 stage，
  /// 空着发送就是“接着上一次继续”。
  void _submit() {
    if (_engineBusy) return;
    final bool hasProvider = widget.providers.any(
      (Provider p) =>
          p.enabled && p.apiKey.trim().isNotEmpty && p.models.isNotEmpty,
    );
    if (!hasProvider) return;
    _runByMode();
  }

  String _imageMime(String name) {
    final String ext = name.contains('.')
        ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
        : '';
    return switch (ext) {
      'png' => 'image/png',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      'jpg' || 'jpeg' => 'image/jpeg',
      _ => 'application/octet-stream',
    };
  }

  /// 插入图片：选图 → 存成资产 → 挂到这条玩家输入。
  Future<void> _pickImage() async {
    if (_engineBusy) return;
    if (_worlds.isEmpty) {
      _engineSay('当前还没有世界；创建世界后才能插入图片。');
      return;
    }
    const XTypeGroup group = XTypeGroup(
      label: '图片',
      extensions: <String>['png', 'jpg', 'jpeg', 'webp', 'gif'],
      mimeTypes: <String>['image/png', 'image/jpeg', 'image/webp', 'image/gif'],
    );
    final XFile? picked = await openFile(
      acceptedTypeGroups: <XTypeGroup>[group],
    );
    if (picked == null) return;
    final List<int> bytes = await picked.readAsBytes();
    if (bytes.length > 20 * 1024 * 1024) {
      if (mounted) {
        _engineSay(
          '图片太大：${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB，'
          '上限 20 MB。',
        );
      }
      return;
    }
    try {
      final AssetRecord asset = await widget.store.saveAsset(
        worldId: _world.id,
        kind: 'image',
        mime: picked.mimeType ?? _imageMime(picked.name),
        name: picked.name,
        bytes: bytes,
      );
      if (!mounted) return;
      setState(() => _attachments.add(asset));
    } catch (err) {
      if (mounted) _engineSay('图片保存失败：$err');
    }
  }

  /// 拍照：只拍一张，存成图片附件；不录像，不自动 OCR。
  Future<void> _takePhoto() async {
    if (_engineBusy) return;
    try {
      final List<cam.CameraDescription> cameras = await cam.availableCameras();
      if (cameras.isEmpty) {
        _engineSay('未找到可用的摄像头。');
        return;
      }
      final int initialIndex = cameras.indexWhere(
        (cam.CameraDescription c) =>
            c.lensDirection == cam.CameraLensDirection.back,
      );
      if (!mounted) return;
      final XFile? shot = await showDialog<XFile>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext c) => _CameraDialog(
          cameras: cameras,
          initialIndex: initialIndex < 0 ? 0 : initialIndex,
          palette: JoTheme.of(c),
        ),
      );
      if (shot == null || !mounted) return;
      final List<int> bytes = await shot.readAsBytes();
      if (bytes.length > 20 * 1024 * 1024) {
        _engineSay(
          '照片太大：${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB，'
          '上限 20 MB。',
        );
        return;
      }
      final AssetRecord asset = await widget.store.saveAsset(
        worldId: _world.id,
        kind: 'image',
        mime: 'image/jpeg',
        name: 'camera-${DateTime.now().millisecondsSinceEpoch}.jpg',
        bytes: bytes,
      );
      if (!mounted) return;
      setState(() => _attachments.add(asset));
    } catch (err) {
      if (mounted) _engineSay('拍照失败：$err');
    }
  }

  String _extOf(String name) => name.contains('.')
      ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
      : '';

  String? _decodeText(List<int> bytes) {
    try {
      String text;
      if (bytes.length >= 3 &&
          bytes[0] == 0xEF &&
          bytes[1] == 0xBB &&
          bytes[2] == 0xBF) {
        text = utf8.decode(bytes.sublist(3));
      } else if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
        final List<int> units = <int>[];
        for (int i = 2; i + 1 < bytes.length; i += 2) {
          units.add(bytes[i] | (bytes[i + 1] << 8));
        }
        text = String.fromCharCodes(units);
      } else if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
        final List<int> units = <int>[];
        for (int i = 2; i + 1 < bytes.length; i += 2) {
          units.add((bytes[i] << 8) | bytes[i + 1]);
        }
        text = String.fromCharCodes(units);
      } else {
        text = utf8.decode(bytes);
      }
      if (text.contains('\u0000')) return null;
      return text;
    } catch (_) {
      return null;
    }
  }

  /// 插入文件：文本类 / PDF / 图片。文本类按能否按文本解码判断。
  Future<void> _pickFile() async {
    if (_engineBusy) return;
    if (_worlds.isEmpty) {
      _engineSay('当前还没有世界；创建世界后才能插入文件。');
      return;
    }
    const XTypeGroup group = XTypeGroup(
      label: '文件',
      extensions: <String>[
        'txt',
        'md',
        'markdown',
        'json',
        'yaml',
        'yml',
        'csv',
        'tsv',
        'xml',
        'svg',
        'html',
        'htm',
        'css',
        'js',
        'ts',
        'dart',
        'py',
        'java',
        'c',
        'h',
        'cpp',
        'hpp',
        'rs',
        'go',
        'sql',
        'log',
        'tex',
        'pdf',
        'png',
        'jpg',
        'jpeg',
        'webp',
        'gif',
      ],
      mimeTypes: <String>[
        'text/plain',
        'text/markdown',
        'application/json',
        'application/xml',
        'image/svg+xml',
        'application/pdf',
        'image/png',
        'image/jpeg',
        'image/webp',
        'image/gif',
      ],
    );
    final XFile? picked = await openFile(
      acceptedTypeGroups: <XTypeGroup>[group],
    );
    if (picked == null) return;
    final List<int> bytes = await picked.readAsBytes();
    if (bytes.length > 50 * 1024 * 1024) {
      if (mounted) {
        _engineSay(
          '文件太大：${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB，'
          '上限 50 MB。',
        );
      }
      return;
    }

    final String ext = _extOf(picked.name);
    final String mime = picked.mimeType ?? '';
    final bool isPdf = ext == 'pdf' || mime == 'application/pdf';
    final bool isImage =
        <String>{'png', 'jpg', 'jpeg', 'webp', 'gif'}.contains(ext) ||
        (mime.startsWith('image/') && mime != 'image/svg+xml');

    try {
      if (isImage) {
        if (bytes.length > 20 * 1024 * 1024) {
          if (mounted) {
            _engineSay(
              '图片太大：${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB，'
              '上限 20 MB。',
            );
          }
          return;
        }
        final AssetRecord asset = await widget.store.saveAsset(
          worldId: _world.id,
          kind: 'image',
          mime: mime.startsWith('image/') ? mime : _imageMime(picked.name),
          name: picked.name,
          bytes: bytes,
        );
        if (!mounted) return;
        setState(() => _attachments.add(asset));
        return;
      }
      if (isPdf) {
        final AssetRecord asset = await widget.store.saveAsset(
          worldId: _world.id,
          kind: 'pdf',
          mime: 'application/pdf',
          name: picked.name,
          bytes: bytes,
        );
        if (!mounted) return;
        setState(() => _attachments.add(asset));
        unawaited(_extractPdfForAsset(asset));
        return;
      }
      final String? text = _decodeText(bytes);
      if (text == null) {
        if (mounted) {
          _engineSay('该文件不是可读文本、PDF 或图片，暂不支持作为附件。');
        }
        return;
      }
      final AssetRecord asset = await widget.store.saveAsset(
        worldId: _world.id,
        kind: 'text',
        mime: mime.isEmpty ? 'text/plain' : mime,
        name: picked.name,
        bytes: bytes,
      );
      widget.store.saveAssetText(asset.id, text);
      if (!mounted) return;
      setState(() => _attachments.add(asset));
    } catch (err) {
      if (mounted) _engineSay('文件保存失败：$err');
    }
  }

  /// 在输入框当前光标 / 选区处插入 OCR 文本。
  void _insertAtCursor(String insert) {
    final TextSelection sel = _input.selection;
    final int length = _input.text.length;
    final int start = sel.isValid && sel.start <= length ? sel.start : length;
    final int end = sel.isValid && sel.end <= length ? sel.end : length;
    _input.value = TextEditingValue(
      text: _input.text.replaceRange(start, end, insert),
      selection: TextSelection.collapsed(offset: start + insert.length),
    );
  }

  /// OCR图片：选一张图，走内置 PP-OCR，把文字插到输入框。
  /// 不生成图片附件，也不把 OCR 文本写进图片资产。
  Future<void> _pickOcrImage() async {
    if (_ocrBusy || _engineBusy) return;
    const XTypeGroup group = XTypeGroup(
      label: '图片',
      extensions: <String>['png', 'jpg', 'jpeg', 'webp'],
      mimeTypes: <String>['image/png', 'image/jpeg', 'image/webp'],
    );
    final XFile? picked = await openFile(
      acceptedTypeGroups: <XTypeGroup>[group],
    );
    if (picked == null || !mounted) return;
    setState(() => _ocrBusy = true);
    _engineSay('正在用内置 OCR 识别图片…');
    try {
      final result = await LocalOcrEngine.instance.recognizeText(picked.path);
      if (!mounted) return;
      final String? error = result.error;
      if (error != null) {
        _engineSay('文字识别失败：$error');
        return;
      }
      final String text = result.text.trim();
      if (text.isEmpty) {
        _engineSay('图片里没有识别到文字。');
        return;
      }
      _insertAtCursor(text);
      _engineSay('已插入 ${text.length} 个字符。');
    } finally {
      if (mounted) setState(() => _ocrBusy = false);
    }
  }

  /// 当前世界选中的搜索源对应的独立搜索服务商。
  Provider? _searchProviderFor(WorldSearchSource source) {
    final String wanted = source.id;
    for (final Provider p in widget.providers) {
      if (p.kind == ServiceKind.tts) continue;
      if (SearchService(p).vendor.name == wanted) return p;
    }
    return null;
  }

  void _recordSearch(
    WorldSearchSource source,
    String query, {
    SearchOutcome? outcome,
    String? error,
    String? worldId,
  }) {
    widget.store.saveSearchLog(
      worldId: worldId ?? _world.id,
      source: source.id,
      query: query,
      ok: outcome?.ok ?? false,
      message: outcome?.message ?? error ?? '',
      hits: <Map<String, Object?>>[
        for (final SearchHit hit in outcome?.hits ?? const <SearchHit>[])
          <String, Object?>{
            'title': hit.title,
            'url': hit.url,
            'snippet': hit.snippet,
            'summary': hit.summary,
          },
      ],
    );
  }

  /// 工具栏地球：上拉菜单里换这个世界的搜索源，或者直接搜一次。
  void _pickSearchSource() {
    if (_timelineSnapshot != null) return;
    _openSearchSourceMenu(
      context,
      _searchKey,
      _world.searchSource,
      (WorldSearchSource v) {
        if (v == _world.searchSource) return;
        _putWorld(_world.copyWith(searchSource: v));
        _engineSay('这个世界的搜索源：${v.label}');
      },
      _openSearchPanel,
    );
  }

  /// 世界搜索面板：输入查询、搜一次，结果挂到下回合环境更新。
  Future<void> _openSearchPanel() async {
    final (String, String) timeline = (_worldId, _branchId);
    bool stillHere() => mounted && timeline == (_worldId, _branchId) && _viewedVersionId == null;
    final WorldSearchSource source = _world.searchSource;
    if (source == WorldSearchSource.off) {
      _engineSay(
        '这个世界的搜索源为“不搜索”。\n'
        '点击工具栏最右侧的地球图标即可更换。',
      );
      return;
    }
    final Provider? provider = _searchProviderFor(source);
    if (provider == null) {
      _engineSay(
        '世界选择了“${source.label}”，但设置中尚未配置对应的 ${source.label} 搜索服务商。\n'
        '请先在“设置 → 服务商”中添加服务商并填写 API Key。',
      );
      return;
    }
    final String? query = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext c) => _SearchQueryDialog(
        palette: JoTheme.of(c),
        source: source,
      ),
    );
    if (query == null || query.trim().isEmpty || !stillHere()) return;
    if (!_takeSearchSlot()) return;
    try {
      final SearchOutcome outcome = await SearchService(
        provider,
      ).search(query.trim(), count: 5);
      if (!stillHere()) return;
      if (!outcome.ok) {
        _recordSearch(source, query.trim(), outcome: outcome);
        _engineSay('搜索失败：${outcome.message}');
        return;
      }
      if (outcome.hits.isEmpty) {
        _recordSearch(source, query.trim(), outcome: outcome);
        _engineSay('未获取到搜索结果：${outcome.message}');
        return;
      }
      _recordSearch(source, query.trim(), outcome: outcome);
      final StringBuffer material = StringBuffer(
        '查询：${query.trim()}\n来源：${source.label}\n',
      );
      for (final SearchHit hit in outcome.hits.take(5)) {
        material.writeln();
        material.writeln('标题：${hit.title}');
        material.writeln('链接：${hit.url}');
        final String body = hit.summary.trim().isNotEmpty
            ? hit.summary.trim()
            : (hit.snippet.trim().isNotEmpty ? hit.snippet.trim() : hit.content.trim());
        if (body.isNotEmpty) material.writeln('摘要：$body');
      }
      _pendingSearchMaterial = material.toString().trim();
      _engineSay(
        '搜索完成，找到 ${outcome.hits.length} 条结果。\n'
        '结果已附加到下一回合的环境更新，不会直接写入正文，也不会直接提供给角色。',
      );
    } catch (err) {
      if (stillHere()) {
        _recordSearch(source, query.trim(), error: '$err');
        _engineSay('搜索失败：$err');
      }
    }
  }

  /// 把角色 CH_ACT 里提出的搜索意图变成下一次环境更新的材料。
  Future<void> _queueSearchFromAction(_TimelineRun run, TurnTrace trace) async {
    final Object? raw = trace.action?['search'];
    if (raw is! String) return;
    final String query = raw.trim();
    if (query.isEmpty) return;
    final WorldSearchSource source = run.world.searchSource;
    if (source == WorldSearchSource.off) {
      return;
    }
    final Provider? provider = _searchProviderFor(source);
    if (provider == null) {
      _timelineSay(run,
        '角色想查“$query”，但当前世界选择的 ${source.label} 搜索服务商尚未配置。',
      );
      return;
    }
    try {
      final SearchOutcome outcome = await SearchService(
        provider,
      ).search(query, count: 5);
      if (!mounted || run.frozen) return;
      if (!outcome.ok) {
        _recordSearch(source, query, outcome: outcome, worldId: run.world.id);
        _timelineSay(run, '角色想查“$query”，搜索失败：${outcome.message}');
        return;
      }
      if (outcome.hits.isEmpty) {
        _recordSearch(source, query, outcome: outcome, worldId: run.world.id);
        _timelineSay(run, '角色想查“$query”，但未找到结果。');
        return;
      }
      _recordSearch(source, query, outcome: outcome, worldId: run.world.id);
      final StringBuffer material = StringBuffer(
        '角色提出的查询：$query\n来源：${source.label}\n',
      );
      for (final SearchHit hit in outcome.hits.take(5)) {
        material.writeln();
        material.writeln('标题：${hit.title}');
        material.writeln('链接：${hit.url}');
        final String body = hit.summary.trim().isNotEmpty
            ? hit.summary.trim()
            : (hit.snippet.trim().isNotEmpty
                  ? hit.snippet.trim()
                  : hit.content.trim());
        if (body.isNotEmpty) material.writeln('摘要：$body');
      }
      _saveTimelineSearch(run, material.toString().trim());
      _timelineSay(run,
        '角色想查“$query”，已找到 ${outcome.hits.length} 条结果；'
        '结果会在下一次环境更新里作为外部材料使用。',
      );
    } catch (err) {
      if (mounted && !run.frozen) {
        _recordSearch(source, query, error: '$err', worldId: run.world.id);
        _timelineSay(run, '角色想查“$query”，搜索失败：$err');
      }
    }
  }

  void _saveTimelineSearch(_TimelineRun run, String material) {
    run.searchMaterial = material;
    _timelineSearch[run.key] = material;
    if (_visibleRun(run)) _pendingSearchMaterial = material;
  }

  Future<void> _extractPdfForAsset(AssetRecord asset) async {
    if (mounted) setState(() => _ocrBusy = true);
    final PdfOcrCancellation cancellation = PdfOcrCancellation();
    final ValueNotifier<String> progress = ValueNotifier<String>('正在读取 PDF…');
    BuildContext? progressContext;
    bool progressOpen = false;

    void openProgress() {
      if (progressOpen || !mounted) return;
      progressOpen = true;
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (BuildContext c) {
            progressContext = c;
            return _PdfOcrProgressDialog(
              progress: progress,
              onCancel: () {
                cancellation.cancel();
                Navigator.of(c).pop();
              },
            );
          },
        ),
      );
    }

    void closeProgress() {
      final BuildContext? c = progressContext;
      if (c != null && c.mounted) Navigator.of(c).maybePop();
    }

    try {
      final PdfTextExtraction extracted = await extractPdfTextWithOcr(
        widget.store.assetFile(asset).path,
        cancellation: cancellation,
        onProgress: (int page, int total, bool needsOcr) {
          progress.value = needsOcr
              ? '扫描版 PDF：正在识别第 $page / $total 页文字…'
              : '正在读取 PDF 第 $page / $total 页…';
          if (needsOcr) openProgress();
        },
      );
      // 对话框的 builder 可能比 OCR 的首帧晚一个事件循环，给它一帧再关。
      await Future<void>.delayed(const Duration(milliseconds: 30));
      closeProgress();
      widget.store.saveAssetText(asset.id, extracted.text);
      if (!mounted) return;
      if (extracted.cancelled) {
        _engineSay(
          '已取消扫描版 PDF 的文字识别；已识别出的 ${extracted.text.length} 字仍保留，附件不会移除。',
        );
        return;
      }
      if (extracted.text.isEmpty) {
        _engineSay('该 PDF 没有文本层，文字识别也未获取到文字；附件仍保留。');
        return;
      }
      final StringBuffer note = StringBuffer(
        'PDF 已处理：${extracted.text.length} 字',
      );
      if (extracted.ocrPages > 0) {
        note.write('，其中 ${extracted.ocrPages} 页来自文字识别');
      } else {
        note.write('，来自文本层');
      }
      if (extracted.skippedPages > 0) {
        note.write('；另有 ${extracted.skippedPages} 页扫描页因数量上限未做文字识别');
      }
      note.write('。发送时会一并提供给模型。');
      _engineSay(note.toString());
    } catch (err) {
      closeProgress();
      if (mounted) {
        _engineSay('PDF 解析失败：$err\nPDF 仍作为附件保留。');
      }
    } finally {
      progress.dispose();
      if (mounted) setState(() => _ocrBusy = false);
    }
  }

  Future<void> _openAttachment(AssetRecord a) async {
    if (a.kind == 'pdf') {
      final JoPalette p = JoTheme.of(context);
      await showDialog<void>(
        context: context,
        barrierColor: Colors.black.withValues(alpha: 0.6),
        builder: (BuildContext c) => Dialog(
          backgroundColor: p.bg,
          insetPadding: const EdgeInsets.all(JoSpace.s5),
          child: FractionallySizedBox(
            widthFactor: 0.94,
            heightFactor: 0.92,
            child: Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    JoSpace.s4,
                    JoSpace.s2,
                    JoSpace.s2,
                    JoSpace.s2,
                  ),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          a.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: JoFonts.ui.copyWith(
                            fontSize: 13,
                            color: p.text,
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: () => Navigator.of(c).pop(),
                        child: Padding(
                          padding: const EdgeInsets.all(JoSpace.s2),
                          child: Text(
                            '×',
                            style: JoFonts.ui.copyWith(
                              fontSize: 20,
                              color: p.secondary,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: PdfViewer.file(
                    widget.store.assetFile(a).path,
                    params: const PdfViewerParams(),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      return;
    }

    if (a.kind == 'image') {
      final JoPalette p = JoTheme.of(context);
      await showDialog<void>(
        context: context,
        barrierColor: Colors.black.withValues(alpha: 0.6),
        builder: (BuildContext c) => Dialog(
          backgroundColor: p.bg,
          insetPadding: const EdgeInsets.all(JoSpace.s5),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900, maxHeight: 700),
            child: Image.file(widget.store.assetFile(a), fit: BoxFit.contain),
          ),
        ),
      );
      return;
    }

    // 文本文件：优先读缓存的抽取文本。
    final String text =
        widget.store.loadAssetText(a.id) ??
        await widget.store.assetFile(a).readAsString();
    if (!mounted) return;
    final JoPalette p = JoTheme.of(context);
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      builder: (BuildContext c) => Dialog(
        backgroundColor: p.bg,
        insetPadding: const EdgeInsets.all(JoSpace.s5),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760, maxHeight: 640),
          child: Padding(
            padding: const EdgeInsets.all(JoSpace.s4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  a.name,
                  style: JoFonts.ui.copyWith(fontSize: 13, color: p.text),
                ),
                const SizedBox(height: JoSpace.s3),
                Expanded(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      text,
                      style: widget.settings.bodyStyle(p.text),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _removeAttachment(AssetRecord asset) {
    widget.store.deleteAsset(asset.id);
    setState(() => _attachments.remove(asset));
  }

  @override
  void dispose() {
    _readRun++;
    unawaited(_audio.stop());
    final BuiltinTtsManager? tts = _builtinTts;
    _builtinTts = null;
    if (tts != null) unawaited(tts.dispose());
    _input.dispose();
    _tc.dispose();
    _focusTicker.dispose();
    _worldFade.dispose();
    _sideScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 选中 / 取消选中共之后，卡高和下面让位都得动一下。
    // 不管从哪个入口改的选中（点卡、右栏的 ×、换世界……），
    // 都会走到 build，所以在这儿统一叫醒节拍器，不用每个入口各写一遍。
    // 选中 / 取消选中之后，卡高和下面让位都要动一下。
    // 不管从哪个入口改的选中（点卡、右栏的 ×、换世界……），
    // 都会走到 build，所以在这儿统一叫醒节拍器，不用每个入口各写一遍。
    if (!_focusTicker.isActive &&
        _extra.needsAdvance(target: _selKey, targetValue: _selExtra)) {
      _kickFocus();
    }

    final Widget body = _page == _Page.settings
        ? SettingsPage(
            settings: widget.settings,
            onChanged: widget.onSettingsChanged,
            worldStore: widget.store,
            providers: widget.providers,
            onProvidersChanged: widget.onProvidersChanged,
            globalPlan: widget.globalPlan,
            onGlobalPlanChanged: widget.onGlobalPlanChanged,
            servicesNote: widget.servicesNote,
            globalPlanNote: widget.globalPlanNote,
            worldPlansNote: widget.worldPlansNote,
            keys: widget.keys,
            prompts: widget.prompts,
            onPromptsChanged: (Map<String, String> next) =>
                widget.onPromptsChanged?.call(next),
            onKeysChanged: (Map<String, String> next) =>
                widget.onKeysChanged?.call(next),
            onBack: () => setState(() => _page = _Page.main),
          )
        : _mainPage();
    // 页面切换：160ms 淡入淡出（克制，不做位移 / 缩放）
    // layoutBuilder 给紧约束：里面有 Row + Expanded，默认那个松散 Stack 撑不起来。
    // 快捷键。全局这几条**从设置里读**，不再写死；“发送”不在这里，
    // 它落在输入框上（输入框自己吃 Enter）。
    // 认不出来的键位不会绑上去 —— 设置那页会当场标出来。
    return CallbackShortcuts(
      bindings: _bindings(),
      child: Focus(
        autofocus: true,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 160),
          layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
            fit: StackFit.expand,
            children: <Widget>[...previous, ?current],
          ),
          transitionBuilder: (Widget child, Animation<double> a) =>
              FadeTransition(opacity: a, child: child),
          child: body,
        ),
      ),
    );
  }

  /// 全局那几条绑定。键位**从设置里读**，不再写死。
  /// “发送”不在其中 —— 它落在输入框上。
  /// 认不出来的键位不绑（设置那页会标出来）。
  Map<ShortcutActivator, VoidCallback> _bindings() {
    final Map<ShortcutActivator, VoidCallback> out =
        <ShortcutActivator, VoidCallback>{};

    void put(String id, VoidCallback fn) {
      final ShortcutActivator? a = joActivator(widget.keys[id] ?? '');
      if (a != null) out[a] = fn;
    }

    put(JoKey.newWorld, _newWorld);
    put(JoKey.edit, _openEdit);
    put(JoKey.settings, () => setState(() => _page = _Page.settings));
    // 不绑 Esc —— 它是多功能键，只留给弹窗自己用。
    return out;
  }

  /// 按当前推进方式决定这次跑多远。手动推进只有一个入口（发送 / 回车），走这里，不各自硬跑。
  ///
  /// - 单步：只走一个阶段就停；
  /// - 单回合：跑完一回合；
  /// - 直到交互点：连跑回合，直到只剩玩家 / 需要人处理。
  Future<void> _runByMode() async {
    if (_mode == '单步') {
      await _runStepOnce();
      return;
    }
    if (_mode == '直到交互点') {
      await _runUntilStop();
      return;
    }
    await _runTurnStep();
  }

  /// 单步：这次只推一个阶段就停。模式选“单步”时，发送走这里。
  Future<void> _runStepOnce() async {
    await _runTurnStep(singleStage: true);
  }

  /// 推演到交互点：连续跑 NPC 回合，直到只剩玩家 / 需要人处理。
  Future<void> _runUntilStop() async {
    final _TimelineRun? run = _beginTimelineRun();
    if (run == null) return;
    try {
      await _runTimelineUntilStop(run);
    } finally {
      _finishTimelineRun(run);
    }
  }

  Future<void> _runTimelineUntilStop(_TimelineRun run) async {
    final int configured = widget.settings.autoRunMaxTurns;
    final int maxTurns = configured <= 0 ? 0 : configured;
    bool first = true;
    int settled = 0;
    while (maxTurns == 0 || settled < maxTurns) {
      run.trace = null;
      run.presentationPending = false;
      run.noReadyWork = false;
      final bool auto = !first || (run.input.isEmpty && run.session == null);
      if (auto && (maxTurns == 0 || maxTurns - settled >= 2)) {
        final List<String> places = _localWavePlaces(run);
        if (places.isNotEmpty) {
          final ({int committed, bool stop}) result = await _runLocalWave(run, places);
          first = false;
          settled += result.committed;
          if (result.stop) return;
          continue;
        }
      }
      await _executeTimelineStep(run, autoEvents: auto ? const <WorldEvent>[] : null);
      first = false;
      if (run.presentationPending || run.noReadyWork) return;
      if (run.frozen || !mounted || run.backgroundMode == BackgroundRunMode.round ||
          run.backgroundMode == BackgroundRunMode.step) {
        return;
      }
      if (run.session == null &&
          widget.store.loadTimelineSession(run.world.id, run.branchId) != null) {
        return;
      }
      final TurnTrace? trace = run.trace;
      if (trace == null) {
        if (run.session != null) {
          _timelineSay(run, '推演暂停：有一步需要你回答，点击发送即可继续作答。');
        } else {
          _timelineSay(run, '推演暂停：当前地点没有可继续行动的角色，轮到你行动。');
        }
        return;
      }
      if (trace.stop?.code == 'no_environment_event' && run.placeId != null) {
        if (run.timeBoundaryPass) return;
        run.checkedPlaces.add(run.placeId!);
        run.placeId = null;
        continue;
      }
      if (trace.openPlaceErrors.isNotEmpty ||
          trace.routeErrors.isNotEmpty ||
          trace.castErrors.isNotEmpty ||
          trace.selectActorErrors.isNotEmpty ||
          trace.environmentErrors.isNotEmpty ||
          trace.perceiveErrors.isNotEmpty ||
          trace.resolveErrors.isNotEmpty ||
          (trace.stop != null && trace.stop!.code != 'player_action')) {
        final StopPoint stop = StopPoint(
          reason: 'error',
          question: '这一步需要你确认后才能继续：${trace.stop?.reason ?? '校验失败'}',
        );
        _timelineSay(run, '推演暂停：${stop.question}');
        return;
      }
      if (trace.stop?.code == 'player_action') {
        _timelineSay(run, '推演暂停：${trace.stop!.reason}');
        return;
      }
      if (trace.needsReview || trace.renderViolations.isNotEmpty) {
        const StopPoint stop = StopPoint(
          reason: 'needs_review',
          question: '这一回合需要你检查后再继续。',
        );
        _timelineSay(run, '推演暂停：${stop.question}');
        return;
      }
      if (trace.route != 'env' && (trace.eligible.isEmpty || trace.chosen == null)) {
        const StopPoint stop = StopPoint(
          reason: 'player_action',
          question: '轮到你行动了。',
        );
        _timelineSay(run, '推演暂停：${stop.question}');
        return;
      }
      final List<WorldEvent> next = <WorldEvent>[
        ...trace.environmentEvents,
        ...trace.events,
      ];
      if (next.isEmpty) {
        _timelineSay(run, '推演暂停：这一回合没有产生新事件，轮到你行动。');
        return;
      }
      settled++;
      run.checkedPlaces.clear();
      run.timeBoundaryPass = false;
    }
    if (maxTurns > 0) {
      _timelineSay(run, '推演暂停：已连续推演 $maxTurns 个回合，达到回合上限。');
    }
  }

  List<String> _localWavePlaces(_TimelineRun run) {
    final int limit = widget.settings.modelRequestConcurrency;
    if (limit < 2 || run.placeId != null || run.session != null ||
        run.attachmentIds.isNotEmpty || run.searchMaterial.isNotEmpty ||
        run.backgroundMode == BackgroundRunMode.freeze ||
        run.backgroundMode == BackgroundRunMode.step ||
        run.backgroundMode == BackgroundRunMode.round ||
        widget.store.loadTimelineBranch(run.world.id, run.branchId) == null ||
        widget.store.loadTimelineSessions(run.world.id, run.branchId).isNotEmpty ||
        widget.store.loadPendingNarration(run.world.id, run.branchId) != null) {
      return const <String>[];
    }
    final TurnState state = run.snapshot?.state ?? widget.store.loadTurnState(run.world.id) ?? TurnState.empty;
    const WorldSchedule schedule = WorldSchedule();
    final WorldWorkQueue queue = run.workQueue ?? WorldWorkQueue(
      widget.store.loadTimelineWork(run.world.id, run.branchId) ?? state.worldWork,
    );
    final List<ParallelPlace> ready = schedule.readyPlaces(run.world, state,
      afterPlaceId: run.lastSettledPlace, alreadyChecked: run.checkedPlaces, queue: queue);
    if (ready.length < 2) return const <String>[];
    // 首版每批只接两个地点；一批收尾后才重新调度。
    final List<String> pair = <String>[ready[0].id, ready[1].id];
    return pair.every((id) => LocalTurnScope.capture(run.world, state, id) != null)
        ? pair : const <String>[];
  }

  Future<({int committed, bool stop})> _runLocalWave(_TimelineRun run, List<String> places) async {
    final _TimelineRun peer = _TimelineRun(
      world: run.world, branchId: run.branchId, placeId: places[1], pov: run.pov,
      input: '', attachmentIds: const <String>[], searchMaterial: '', session: null,
      snapshot: run.snapshot,
    )..backgroundMode = run.backgroundMode;
    final Completer<void> firstSettled = Completer<void>();
    run.placeId = places[0];
    run.inLocalWave = true;
    run.committed = false;
    peer.inLocalWave = true;
    peer.settleAfter = firstSettled.future;
    run.wavePeers.add(peer);
    try {
      await Future.wait(<Future<void>>[
        _executeTimelineStep(run, autoEvents: const <WorldEvent>[])
            .whenComplete(firstSettled.complete),
        _executeTimelineStep(peer, autoEvents: const <WorldEvent>[]),
      ]);
    } finally {
      run.inLocalWave = false;
      run.wavePeers.clear();
    }
    final List<_TimelineRun> tasks = <_TimelineRun>[run, peer];
    final int committed = tasks.where((task) => task.committed).length;
    if (run.frozen || !mounted) return (committed: committed, stop: true);
    if (peer.committed) {
      run.world = peer.world;
      run.snapshot = peer.snapshot;
      run.lastSettledPlace = peer.lastSettledPlace;
      if (_visibleRun(run) && run.snapshot != null) setState(() => _timelineSnapshot = run.snapshot);
    }
    run.workQueue = null;
    if (committed > 0) run.checkedPlaces.clear();
    for (final (_TimelineRun task, String place) in <(_TimelineRun, String)>[(run, places[0]), (peer, places[1])]) {
      if (task.trace?.stop?.code == 'no_environment_event') run.checkedPlaces.add(place);
    }
    run.session = widget.store.loadTimelineSession(run.world.id, run.branchId);
    run.placeId = run.session?.parallelPlaceId;
    final bool stop = run.session != null || tasks.any((task) => task.noReadyWork ||
        task.presentationPending || (task.trace == null) ||
        (!task.committed && task.trace?.stop?.code != 'no_environment_event')) ||
        run.backgroundMode == BackgroundRunMode.round || run.backgroundMode == BackgroundRunMode.step;
    if (peer.session?.status == 'waiting_player' && run.session?.id == peer.session?.id) {
      _timelineSay(run, '轮到你行动；其他正在运行的回合已结束。');
    }
    return (committed: committed, stop: stop);
  }

  /// 退回上一回合：删掉最后一个世界状态和对应的画布步。
  /// 上一回合的完整状态还在前一行，不需要反向操作。
  Future<void> _rollbackTurn() async {
    if (_engineBusy) return;
    if (_worlds.isEmpty) return;
    final TimelineBranch? branch = widget.store.loadTimelineBranch(_worldId, _branchId);
    if (branch != null) {
      final int current = _viewedVersionId ?? branch.headVersionId;
      final int? previous =
          widget.store.loadTimelineSnapshot(_worldId, current).version.parentId;
      if (previous != null) {
        _viewTimeline(_branchId, versionId: previous, keepPosition: true);
      } else {
        _engineSay('已经到达开场。');
      }
      return;
    }
    final String focusParallelPlace =
        _focused ??
        (_world.parallelPlaces.isEmpty ? '' : _world.parallelPlaces.first.id);
    if (focusParallelPlace.isEmpty) return;

    setState(() => _legacyBusy = true);
    try {
      final bool stateRemoved = widget.store.deleteLatestWorldTurn(_world.id);
      widget.store.clearTurnSession(_world.id);
      _activeSession = null;
      final String? stepParallelPlace = widget.store.deleteLatestEngineStep(
        _world.id,
      );
      final String parallelPlaceId = stepParallelPlace ?? focusParallelPlace;
      final WorldsLoad r = widget.store.loadWorlds();
      setState(() => _worlds = r.worlds);
      // 开启并行地点后还没跑过的新列是空列：退回上一回合时一起收掉。
      final World loaded = _world;
      final List<ParallelPlace> cleaned = <ParallelPlace>[
        for (final ParallelPlace l in loaded.parallelPlaces)
          if (!(l.isActive &&
              l.parentId.isNotEmpty &&
              l.events.every(
                (TurnStep e) =>
                    e.kind == 'GM_OPEN_PLACE' || e.kind == 'GM_MERGE_PLACE',
              )))
            l,
      ];
      if (cleaned.length != loaded.parallelPlaces.length) {
        _putWorld(loaded.copyWith(parallelPlaces: cleaned));
      }
      for (final ParallelPlace l in _world.parallelPlaces) {
        if (l.id == parallelPlaceId) {
          setState(() {
            _focused = parallelPlaceId;
            _selected = l.events.isEmpty ? -1 : l.events.length - 1;
          });
          _parallelPlaceFocus.focus(parallelPlaceId);
          _kickFocus();
          break;
        }
      }
      _engineSay(
        stateRemoved
            ? '已退回上一回合。${stepParallelPlace == null ? '（画布上没有对应的步骤）' : ''}'
            : '当前没有可退回的回合。',
      );
    } catch (err) {
      if (mounted) _engineSay('退回失败：$err');
    } finally {
      if (mounted) setState(() => _legacyBusy = false);
    }
  }

  /// 换掉内存里的某个世界并落盘（只动世界那一行，不碰 step 表）。
  void _putWorld(World w) {
    if (_timelineSnapshot != null) return;
    final int i = _worlds.indexWhere((World x) => x.id == w.id);
    if (i < 0) return;
    setState(() => _worlds[i] = w);
    widget.store.saveWorldMeta(w);
  }

  /// 只在回合之间换当前操控角色；换掉的角色下一回合由 AI 接管。
  /// 操控角色是上拉菜单，跟世界搜索同一个控件样式。
  void _switchControlledCharacter() {
    if (_timelineSnapshot != null) return;
    if (_engineBusy || _activeSession != null) {
      _engineSay('只能在回合结束、下一回合开始前切换操控角色。');
      return;
    }
    final List<String> names = <String>[
      for (final CharCard c in _world.characters)
        if (c.name.trim().isNotEmpty) c.name.trim(),
    ];
    if (names.isEmpty) {
      _engineSay('当前世界还没有角色。');
      return;
    }
    _openUpMenu(context, _controlKey, <_UpMenuItem>[
      (
        label: '全部交给 AI',
        on: _world.controlledCharacterName.isEmpty,
        onPick: () => _applyControlledCharacter(''),
      ),
      for (final String name in names)
        (
          label: name,
          on: name == _world.controlledCharacterName,
          onPick: () => _applyControlledCharacter(name),
        ),
    ]);
  }

  void _applyControlledCharacter(String picked) {
    if (picked == _world.controlledCharacterName) return;
    final TurnState state =
        widget.store.loadTurnState(_world.id) ?? TurnState.empty;
    final CharCard? card = _world.characters
        .where((CharCard c) => c.name.trim() == picked)
        .firstOrNull;
    final String place = picked.isEmpty
        ? ''
        : (state.locations[picked]?.trim() ?? card?.location.trim() ?? '');
    _putWorld(_world.withControlledCharacter(picked).withPlayerAt(place));
    _input.clear();
    if (mounted) setState(() => _attachments.clear());
    _engineSay(picked.isEmpty ? '现在全部角色由 AI 接管。' : '现在操控：$picked');
  }

  /// 手动加地点：这是用户控制杆，不是并行地点主路径；GM_OPEN_PLACE 自己也会开启。
  Future<void> _addParallelPlaceManually() async {
    final String? place = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => const _AddPlaceDialog(),
    );
    final String name = (place ?? '').trim();
    if (name.isEmpty) return;
    final World world = _world;
    if (world.parallelPlaces.any(
      (ParallelPlace l) => l.isActive && l.place.trim() == name,
    )) {
      _engineSay('该地点已存在。');
      return;
    }
    final ParallelPlace parallelPlace = ParallelPlace(
      id: world.nextParallelPlaceId(),
      place: name,
      here: false,
      events: const <TurnStep>[],
    );
    _putWorld(
      world.copyWith(
        parallelPlaces: <ParallelPlace>[...world.parallelPlaces, parallelPlace],
      ),
    );
    setState(() {
      _focused = parallelPlace.id;
      _selected = null;
    });
    _parallelPlaceFocus.focus(parallelPlace.id);
    _kickFocus();
  }

  /// 组合根：按旧引擎同样的优先级解析某一步的模型。
  /// 角色步骤（CH_PERCEIVE/CH_ACT）先看角色配置，然后世界、全局。
  String _modelKeyForStep(String worldId, String step, String focus) {
    final ModelPlan? charPlan = focus.isEmpty
        ? null
        : _charModel[worldId]?[focus];
    final String own = charPlan?.stepKey(step) ?? '';
    if (own.isNotEmpty) return own;
    final String charDefault = charPlan?.defaultRef ?? '';
    if (charDefault.isNotEmpty) return charDefault;
    final ModelPlan worldPlan = _plans[worldId] ?? const ModelPlan();
    final String worldStep = worldPlan.stepKey(step);
    if (worldStep.isNotEmpty) return worldStep;
    if (worldPlan.defaultRef.isNotEmpty) return worldPlan.defaultRef;
    final String globalStep = widget.globalPlan.stepKey(step);
    if (globalStep.isNotEmpty) return globalStep;
    return widget.globalPlan.defaultRef;
  }

  StepModelChoice? _stepModel(String worldId, String step, {String focus = ''}) {
    final ModelPick? pick = ModelPick.of(_modelKeyForStep(worldId, step, focus));
    if (pick == null) return null;
    final Provider? provider = widget.providers
        .where(
          (Provider x) =>
              x.id == pick.providerId &&
              x.enabled &&
              x.apiKey.trim().isNotEmpty &&
              x.models.isNotEmpty,
        )
        .firstOrNull;
    if (provider == null) return null;
    final ModelRef? model = provider.models
        .where((ModelRef m) => m.enabled && m.id == pick.modelId)
        .firstOrNull;
    if (model == null) return null;
    return (provider: provider, model: model.id);
  }

  /// 手动推进的主路径：用正式 TurnLoop + LlmAgentRunner 跑一回合；
  /// 跑多远由顶栏的推进方式决定（单步只走一个阶段）。
  ///
  /// 输入框是玩家行动/描述原文，先交给 GM_PARSE_INPUT 解析；这里不再把整段当台词。
  Future<void> _runTurnStep({
    TurnSession? resume,
    bool singleStage = false,
    List<WorldEvent>? autoEvents,
  }) async {
    final _TimelineRun? run = _beginTimelineRun();
    if (run == null) return;
    try {
      await _executeTimelineStep(
        run, resume: resume, singleStage: singleStage, autoEvents: autoEvents,
      );
    } finally {
      _finishTimelineRun(run);
    }
  }

  _TimelineRun? _beginTimelineRun() {
    if (_engineBusy) return null;
    if (_worlds.isEmpty || _switching) return null;
    if (_viewedVersionId != null) {
      _engineSay('正在查看历史。请通过“时间线”回到最新位置，或从此回合创建分支。');
      return null;
    }
    if (_world.parallelPlaces.isEmpty) _putWorld(_world.withInitialParallelPlace());
    final _TimelineRun run = _TimelineRun(
      world: _world,
      branchId: _branchId,
      placeId: _activeSession?.parallelPlaceId,
      pov: _pov,
      input: _input.text.trim(),
      attachmentIds: <String>[for (final AssetRecord asset in _attachments) asset.id],
      searchMaterial: _pendingSearchMaterial,
      session: _activeSession,
      snapshot: _timelineSnapshot,
    )..lastSettledPlace = widget.store.lastSettledTimelinePlace(_worldId, _branchId);
    setState(() {
      _timelineRuns[run.key] = run;
      _flowActive = null;
      _flowDone.clear();
    });
    return run;
  }

  bool _visibleRun(_TimelineRun run) =>
      mounted && run.key == (_worldId, _branchId) && _viewedVersionId == null &&
      identical(_timelineRuns[run.key], run);

  void _showRunStep(_TimelineRun run, String step, {bool completed = false}) {
    final FlowStep? block = flowStepOf(step);
    if (run.frozen || block == null) return;
    if (completed) {
      run.flowDone.add(step);
      if (flowStepOf(run.flowActive) == block) run.flowActive = null;
    } else {
      run.flowActive = step;
    }
    if (_visibleRun(run)) {
      setState(() {
        _flowActive = run.flowActive;
        if (completed) {
          _flowDone.add(step);
          // 这一步写完了，正在写的尾巴清掉。
          _liveText = '';
        }
      });
    }
  }

  TurnSession _copySession(TurnSession session) => TurnSession.fromJson(
    (jsonDecode(jsonEncode(session.toJson())) as Map).cast<String, Object?>(),
  );

  void _timelineSay(_TimelineRun run, String text) {
    if (_visibleRun(run)) _engineSay(text);
  }

  void _finishTimelineRun(_TimelineRun run) {
    if (!mounted || !identical(_timelineRuns[run.key], run)) return;
    setState(() {
      if (_visibleRun(run)) {
        _activeSession = widget.store.loadTimelineSession(run.world.id, run.branchId);
        _flowActive = null;
      }
      _timelineRuns.remove(run.key);
    });
  }

  TurnSession _applyTaskRevisions(TurnSession session, Map<String, String> revisions) {
    TurnSession result = _copySession(session);
    final Set<String> reparse = <String>{};
    for (final MapEntry<String, String> edit in revisions.entries) {
      if (!edit.key.startsWith('checkpoint:')) {
        final String? original = result.journal.responses[edit.key];
        if (original != null) {
          final List<String> call = edit.key.split('#');
          final String step = call.first;
          final String scope = call.length > 2 ? call[1] : '';
          for (final TurnCheckpoint checkpoint in session.checkpoints.values) {
            final String stage = checkpoint.stage;
            if (revisions.containsKey('checkpoint:$stage')) continue;
            final Object? source = checkpoint.data['response_key'];
            if (source != null && source != edit.key) continue;
            if (step == StepId.gmObserveScene &&
                (stage == step || stage.startsWith('$step:'))) {
              final Object? raw = LlmAgentRunner.parseStoredResponse(original);
              final Object? observations = checkpoint.data['observations'];
              if (raw is Map && raw['observations'] is Map && observations is Map &&
                  mapEquals(raw['observations'] as Map, observations)) {
                final Map edited = jsonDecode(edit.value) as Map;
                result = result.withCheckpoint(stage, <String, Object?>{
                  ...checkpoint.data,
                  'observations': edited['observations'],
                });
              }
            } else if (step == StepId.chAct) {
              if ((stage == step || stage == '$step:contest:$scope') &&
                  checkpoint.data['actor'] == scope) {
                final Map<String, Object?>? edited = LlmAgentRunner.parseStoredResponse(edit.value);
                if (edited != null) {
                  result = result.withCheckpoint(stage, <String, Object?>{
                    ...checkpoint.data, 'action': edited, 'response_key': edit.key,
                  });
                }
              }
            } else if (step == StepId.gmResolveAction && stage == step && scope.isEmpty) {
              final Map<String, Object?>? edited = LlmAgentRunner.parseStoredResponse(edit.value);
              if (edited != null) {
                result = result.withCheckpoint(stage, <String, Object?>{
                  ...checkpoint.data, 'arbitration': edited, 'response_key': edit.key,
                });
              }
            } else if (step == StepId.chMemoryWrite && source == edit.key) {
              final Map edited = jsonDecode(edit.value) as Map;
              final Object? operations = edited['operations'];
              if (operations is! List || operations.any((Object? op) =>
                  op is! Map || MemoryOperation.fromJson(op.cast<String, Object?>()) == null)) {
                reparse.add(stage);
                continue;
              }
              final Map<String, Object?> data = <String, Object?>{
                ...checkpoint.data,
                'operations': operations,
              }..remove('changed');
              result = result.withCheckpoint(stage, data);
            } else if (step == StepId.chMemoryRecall &&
                checkpoint.data.containsKey('recall_protocol')) {
              continue;
            } else if ((stage == step && (scope.isEmpty || scope == 'time_boundary')) ||
                (scope.isNotEmpty && (stage == '$step:$scope' || stage.startsWith('$step:$scope:')))) {
              reparse.add(stage);
            }
          }
        }
      } else {
        final String stage = edit.key.substring('checkpoint:'.length);
        final TurnCheckpoint? checkpoint = result.checkpoints[stage];
        if (checkpoint != null) {
          final Map<String, Object?> data = (jsonDecode(edit.value) as Map).cast<String, Object?>();
          if (stage == StepId.gmResolveAction && checkpoint.data.containsKey('action')) {
            data['action'] = checkpoint.data['action'];
            data['actor'] = checkpoint.data['actor'];
          }
          if (stage.startsWith('${StepId.chMemoryWrite}:') &&
              jsonEncode(data['operations']) != jsonEncode(checkpoint.data['operations']) &&
              jsonEncode(data['changed']) == jsonEncode(checkpoint.data['changed'])) {
            data.remove('changed');
          }
          result = result.withCheckpoint(stage, data);
        }
      }
    }
    return result.withoutCheckpoints(reparse).withStage(session.stage);
  }

  Future<void> _presentTimelineRun(
    _TimelineRun run,
    TimelineNarrationJob job,
    Provider provider,
    String model,
    void Function() ensureRunning,
  ) async {
    final String worldId = run.world.id;
    try {
      final TimelineSnapshot snapshot = widget.store.loadTimelineSnapshot(worldId, job.versionId);
      final TurnState state = snapshot.state;
      final WorldAdapter adapter = WorldAdapter(
        world: snapshot.world,
        parallelPlaceId: job.placeId,
        priorEvents: state.events,
        priorLocations: state.locations,
        priorStates: state.states,
      );
      final Set<String> assets = <String>{
        for (final WorldEvent event in job.events) ...event.attachmentIds,
      };
      final Map<String, TurnCheckpoint> checkpoints =
          widget.store.loadTimelineNarrationCheckpoints(worldId, job.versionId);
      final TurnCheckpoint? saved = checkpoints[StepId.gmNarrate];
      final bool hasBudget = (saved?.data['attempts'] as int? ?? 0) < 3;
      final Object? warnings = saved?.data['warnings'];
      final Object? violations = saved?.data['violations'];
      final bool awaitingReview = warnings == null && violations is List && violations.isEmpty;
      final bool mayResume = hasBudget || awaitingReview || warnings is List && warnings.isEmpty;
      final TurnJournal journal = mayResume && saved != null
          ? widget.store.loadTimelineNarrationJournal(worldId, job.versionId)
          : TurnJournal();
      Map<String, Object?> reviseDraft(Map<String, Object?> draft) {
        final String? taskId = job.taskId;
        if (taskId == null) return draft;
        final Map<String, String> revisions =
            widget.store.timelineStepRevisions(worldId, run.branchId, taskId);
        final Map<String, String> originals =
            widget.store.timelineStepOriginals(worldId, run.branchId, taskId);
        for (final (String key, String textField, String noteField) in <(String, String, String)>[
          ('checkpoint:${StepId.gmNarrate}', 'publicText', 'godNote'),
          ('${StepId.gmNarrate}#1', 'public_text', 'god_note'),
        ]) {
          final String? value = revisions[key];
          final String? original = originals[key];
          if (value == null || original == null) continue;
          final Object? before = jsonDecode(original);
          final Object? after = jsonDecode(value);
          if (before is! Map || after is! Map || before[textField] != draft['public_text']) continue;
          return <String, Object?>{
            ...draft,
            if (after[textField] is String) 'public_text': after[textField],
            if (job.scope == 'god' && after[noteField] is String) 'god_note': after[noteField],
          };
        }
        return draft;
      }
      void archive() {
        ensureRunning();
        widget.store.saveTimelineNarrationSteps(worldId, job.versionId, journal, checkpoints);
      }
      AssetRecord? resolve(String id) {
        ensureRunning();
        if (!assets.contains(id)) return null;
        final AssetRecord? asset = widget.store.findAsset(id);
        return asset?.worldId == worldId ? asset : null;
      }
      final LlmAgentRunner narration = LlmAgentRunner(
        provider: provider,
        apiKey: provider.apiKey,
        model: model,
        thinking: false,
        choices: _choices[worldId] ?? const <String, CharChoices>{},
        sender: widget.engineSender,
        requestLimiter: _modelRequests,
        prompts: widget.prompts,
        journal: journal,
        onJournalChanged: archive,
        checkRunActive: ensureRunning,
        modelResolver: (String step, {String focus = ''}) {
          _showRunStep(run, step);
          return _stepModel(worldId, step, focus: focus);
        },
        loadImage: (String id) async {
          final AssetRecord? asset = resolve(id);
          if (asset == null || asset.kind != 'image') return null;
          return LlmImage(bytes: await widget.store.assetFile(asset).readAsBytes(), mime: asset.mime);
        },
        readImageCaption: (String id) =>
            resolve(id) == null ? null : widget.store.loadAssetText('caption:$id'),
        writeImageCaption: (String id, String text) {
          if (resolve(id) == null) return;
          widget.store.saveAssetText('caption:$id', text);
        },
        loadAttachmentText: (String id) async {
          final AssetRecord? asset = resolve(id);
          if (asset == null) return null;
          return widget.store.loadAssetText(id) ?? (asset.kind == 'text'
              ? await widget.store.assetFile(asset).readAsString() : null);
        },
      );
      final TurnPresentation result = await TurnLoop(
        scene: adapter.scene(),
        agents: narration,
        rCheck: narration.checkRender,
        pov: job.scope == 'god' ? RenderPov.omniscient : RenderPov.player,
        controlledCharacter: job.scope.startsWith('char:') ? job.scope.substring(5) : '',
        onCheckpoint: (String stage, Map<String, Object?> data) {
          if (stage != StepId.sysRecovery) {
            checkpoints[stage] = TurnCheckpoint(stage: stage, data: data);
            archive();
            _showRunStep(run, StepId.gmNarrate, completed: true);
            if (data.containsKey('warnings')) {
              _showRunStep(run, StepId.gmReviewNarration, completed: true);
            }
          }
          if (run.backgroundMode == BackgroundRunMode.step &&
              (stage == StepId.sysRecovery ||
                  (stage == StepId.gmNarrate && !data.containsKey('warnings')))) {
            throw StagePause(StepId.gmNarrate);
          }
        },
      ).presentCommitted(job.events, checkpoint: mayResume ? saved : null, reviseDraft: reviseDraft);
      ensureRunning();
      if (!result.check.ok || result.warnings.isNotEmpty) {
        throw StateError('正文未通过复核。');
      }
      widget.store.finishTimelineNarration(worldId, job.versionId, job.scope, result.publicText);
      run.presentationPending = false;
      if (mounted) setState(() {});
    } on StagePause {
      run.presentationPending = true;
    } on _TimelineFrozen {
      rethrow;
    } catch (error) {
      if (run.frozen || !mounted) return;
      run.presentationPending = true;
      _timelineSay(run, '本回合已结算。正文尚未生成，点击发送可重新生成正文，也可跳过。');
    }
  }

  Future<void> _executeTimelineStep(
    _TimelineRun run, {
    TurnSession? resume,
    bool singleStage = false,
    List<WorldEvent>? autoEvents,
  }) async {
    if (run.frozen || !mounted) return;
    final String branchId = run.branchId;
    final World world = run.world;
    final TimelineSnapshot? branchBase = run.snapshot;
    void say(String message) => _timelineSay(run, message);
    void ensureRunning() {
      if (run.frozen || !mounted) throw const _TimelineFrozen();
    }
    void saveProgress(TurnSession progress) {
      ensureRunning();
      run.session = progress;
      widget.store.saveTimelineSession(branchId, progress);
      if (_visibleRun(run)) _activeSession = progress;
    }
    void saveStatus(String status) {
      if (run.session case final TurnSession progress) {
        saveProgress(progress.withStatus(status));
      }
    }
    void clearProgress() {
      if (run.session case final TurnSession task) {
        widget.store.clearTimelineSession(world.id, branchId, taskId: task.id);
      }
      run.session = null;
      run.completedProgress = null;
      if (_visibleRun(run)) _activeSession = null;
    }
    final bool auto = autoEvents != null;
    if (run.pov == RenderPov.player && world.controlledCharacterName.trim().isEmpty) {
      say('角色视角需要先选择操控角色，或切换为全知视角。');
      return;
    }

    // 组合根解析模型配置；引擎本身只接收 TurnAgents，不读 ModelPlan/provider。
    final ModelPlan plan = _plans[world.id] ?? const ModelPlan();
    final String modelRef = plan.defaultRef.isNotEmpty
        ? plan.defaultRef
        : widget.globalPlan.defaultRef;
    final ModelPick? pick = ModelPick.of(modelRef);
    Provider? p;
    String model = '';
    if (pick != null) {
      p = widget.providers
          .where(
            (Provider x) =>
                x.id == pick.providerId &&
                x.enabled &&
                x.apiKey.trim().isNotEmpty &&
                x.models.isNotEmpty,
          )
          .firstOrNull;
      if (p != null) {
        for (final ModelRef m in p.models) {
          if (m.enabled && m.id == pick.modelId) {
            model = m.id;
            break;
          }
        }
      }
    }
    p ??= widget.providers
        .where(
          (Provider x) =>
              x.enabled && x.apiKey.trim().isNotEmpty && x.models.isNotEmpty,
        )
        .firstOrNull;
    if (p == null) {
      say('当前没有可用的服务商；可在“设置 → 模型服务”填写 API Key。');
      return;
    }
    if (model.isEmpty) {
      for (final ModelRef m in p.models) {
        if (m.enabled) {
          model = m.id;
          break;
        }
      }
    }
    if (model.isEmpty) {
      say('该服务商没有启用的模型。');
      return;
    }
    final Provider narrationProvider = p;
    final String narrationModel = model;
    Future<void> present(TimelineNarrationJob job) =>
        _presentTimelineRun(run, job, narrationProvider, narrationModel, ensureRunning);
    final int? headVersionId = widget.store.loadTimelineBranch(world.id, branchId)?.headVersionId;
    final bool versioned = headVersionId != null;
    final TimelineNarrationJob? pending = widget.store.loadPendingNarration(world.id, branchId);
    if (pending != null) {
      run.presentationPending = true;
      try {
        await present(pending);
      } on _TimelineFrozen {
        return;
      }
      return;
    }
    final TurnState fullPrior = branchBase?.state ??
        widget.store.loadTurnState(world.id) ?? TurnState.empty;
    const WorldSchedule schedule = WorldSchedule();
    _showRunStep(run, FlowStep.schedule.id, completed: true);
    final int? baseId = branchBase?.version.id ?? headVersionId;
    final WorldWorkQueue work = run.workQueue ??= WorldWorkQueue(
      widget.store.loadTimelineWork(world.id, branchId) ?? fullPrior.worldWork,
    );
    final String? nextPlace = schedule.readyPlaces(
      world,
      fullPrior,
      afterPlaceId: run.lastSettledPlace,
      alreadyChecked: run.checkedPlaces,
      hasPlayerInput: !auto && run.input.isNotEmpty,
      queue: auto ? work : null,
    ).firstOrNull?.id;
    final List<FactRecord> boundaries = schedule.futureBoundaries(fullPrior);
    final Set<String> futureBoundaryIds = boundaries.map((FactRecord fact) => fact.id).toSet();
    final String? timeInput = boundaries.isEmpty ? null : schedule.timeInput(fullPrior);
    final bool timeBoundaryPass = resume?.checkpoints.containsKey('SYS_TIME_SCAN') == true ||
        run.session?.checkpoints.containsKey('SYS_TIME_SCAN') == true ||
        (auto && nextPlace == null && run.placeId == null && timeInput != null &&
           !work.isChecked(WorldSchedule.timeWork, timeInput, fullPrior,
              futureBoundaryIds));
    run.timeBoundaryPass = timeBoundaryPass;
    final String parallelPlaceId = run.placeId ?? nextPlace ??
        (timeBoundaryPass
          ? (world.parallelPlaces.where((ParallelPlace place) => place.isActive).firstOrNull?.id ?? '')
          : '');
    if (parallelPlaceId.isEmpty) {
      run.noReadyWork = true;
      say('当前没有可推进的地点。');
      return;
    }
    run.placeId = parallelPlaceId;
    final ParallelPlace? focusedParallelPlace = world.parallelPlaces
        .where((ParallelPlace l) => l.id == parallelPlaceId)
        .firstOrNull;
    if (focusedParallelPlace == null || !focusedParallelPlace.isActive) {
      say('这条线已并入其他序列；选择另一条线后可继续。');
      return;
    }
    if (world.characters.isEmpty) {
      say('当前世界还没有角色；添加角色后即可开始。');
      return;
    }

    final String typed = auto ? '' : run.input;
    final TurnSession? effectiveResume = resume ??
        (auto
        ? null
        :
              (run.session != null &&
                      run.session!.parallelPlaceId == parallelPlaceId &&
                      (typed.isEmpty ||
                          typed == run.session!.rawInput ||
                          run.session!.rawInput.trim().isEmpty)
                  ? run.session
                  : null));
    if (effectiveResume != null &&
        effectiveResume.id.isNotEmpty &&
        fullPrior.turnSessionId == effectiveResume.id) {
      clearProgress();
      say('上一回合已提交，未完成记录已清理。');
      return;
    }
    final int? savedBase = effectiveResume?.baseVersionId;
    final String? savedScope = effectiveResume?.localFingerprint;
    final bool scoped = run.inLocalWave || savedScope != null;
    final LocalTurnScope? scope = scoped ? LocalTurnScope.capture(
        world, fullPrior.withWorldWork(work.toJson()), parallelPlaceId) : null;
    final bool scopeChanged = scoped && (scope == null ||
        (savedScope != null && scope.fingerprint != savedScope));
    final bool blockedScope = effectiveResume?.status == 'blocked_scope';
    if (scopeChanged || blockedScope ||
        (effectiveResume != null && !scoped && savedBase != headVersionId)) {
      run.noReadyWork = true;
      if (_visibleRun(run)) {
        final bool? discard = await showDialog<bool>(
          context: context,
          builder: (BuildContext dialog) => AlertDialog(
            title: const Text('旧回合无法继续'),
            content: Text(blockedScope
                ? '旧回合涉及当前并行地点范围以外的变化。可以保留旧步骤，或放弃后重新发送，按串行方式推演。'
                : savedBase == null
                ? '旧回合没有记录开始时的世界版本。可以保留旧步骤，或放弃这次推演。'
                : '当前世界版本与旧回合的起点不同。可以保留旧步骤，或放弃这次推演。'),
            actions: <Widget>[
              TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('保留')),
              TextButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('放弃旧回合')),
            ],
          ),
        );
        if (discard == true && _visibleRun(run)) clearProgress();
      }
      return;
    }
    final TurnState prior = scope?.state ?? fullPrior;
    final World reasoningWorld = scope?.world ?? world;
    final WorldAdapter adapter = WorldAdapter(
      world: reasoningWorld,
      parallelPlaceId: parallelPlaceId,
      priorEvents: prior.events,
      priorMemory: prior.memory,
      priorLocations: prior.locations,
      priorStates: prior.states,
      priorInventories: prior.inventories,
      priorInjuries: prior.injuries,
      priorConstraints: prior.constraints,
      priorAnswers: prior.playerAnswers,
    );
    final List<ParallelPlaceCandidate> parallelPlaceCandidates = adapter.parallelPlaceCandidates();
    final String rawInput = (typed.isNotEmpty ? typed : effectiveResume?.rawInput ?? '').trim();
    final List<String> attachmentIds = effectiveResume?.attachmentIds ??
        (auto ? const <String>[] : run.attachmentIds);
    if (!auto && effectiveResume == null && mounted) {
      widget.store.savePlayerInput(
        worldId: world.id,
        parallelPlaceId: parallelPlaceId,
        rawText: rawInput,
        assetIds: attachmentIds,
      );
    }
    final String now = DateTime.now().toIso8601String();
    if (effectiveResume == null && run.session != null) clearProgress();
    final TurnSession baseSession =
        effectiveResume ??
        TurnSession(
          id: '${_latestTaskNumber = math.max(_latestTaskNumber + 1, DateTime.now().microsecondsSinceEpoch)}',
          worldId: world.id,
          parallelPlaceId: parallelPlaceId,
          baseVersionId: baseId,
          localFingerprint: scope?.fingerprint,
          rawInput: rawInput,
          attachmentIds: attachmentIds,
          journal: TurnJournal(),
          createdAt: now,
          updatedAt: now,
        );
    TurnSession originalSession = baseSession.rawInput == rawInput
        ? baseSession
        : baseSession.withRawInput(rawInput);
    if (timeBoundaryPass && !originalSession.checkpoints.containsKey('SYS_TIME_SCAN')) {
      originalSession = originalSession.withCheckpoint('SYS_TIME_SCAN', <String, Object?>{
        'places': run.checkedPlaces.toList(),
      });
    }
    final Map<String, String> savedRevisions =
        widget.store.timelineStepRevisions(world.id, branchId, originalSession.id);
    final bool recorded = originalSession.checkpoints.containsKey(StepId.sysRecord);
    final bool actionConsumed = recorded ||
        originalSession.checkpoints.containsKey(StepId.gmResolveAction) ||
        originalSession.checkpoints.containsKey('${StepId.gmResolveAction}:contest');
    // 裁定后的行动修订只供 SYS_RECORD 记账，不改变已保存的裁定输入和结果。
    final Map<String, String> appliedRevisions = Map<String, String>.of(savedRevisions)
      ..removeWhere((String key, String _) {
        final String step = StepId.base(key.replaceFirst('checkpoint:', '').split('#').first);
        return (actionConsumed && step == StepId.gmParseInput) ||
            (recorded && (step == StepId.chAct || step == StepId.gmResolveAction));
      });
    final TurnSession session = appliedRevisions.isEmpty
        ? originalSession
        : _applyTaskRevisions(originalSession, appliedRevisions);
    final String skipThrough = session.checkpoints.isEmpty ? session.stage : '';
    bool passedSkip = session.checkpoints.isNotEmpty || skipThrough.isEmpty;
    String? pauseStage;
    saveProgress(session.withStatus('running'));
    run.completedProgress = _copySession(session);
    final String? resumeFrom = session.lastCheckpointStage;
    if (resumeFrom != null) {
      say('从 checkpoint $resumeFrom 继续…');
    }

    run.answers.clear();
    try {
      final Set<String> permittedAssets = <String>{
        ...attachmentIds,
        for (final WorldEvent event in prior.events) ...event.attachmentIds,
        for (final WorldEvent event in prior.pendingEvents) ...event.attachmentIds,
      };
      final NarrativeScene scene = adapter.scene();
      final String searchMaterial = run.searchMaterial;
      final TurnState authoritativeState = TurnState(
        events: prior.events,
        pendingEvents: prior.pendingEvents,
        memory: prior.memory,
        injuries: prior.injuries,
        constraints: prior.constraints,
        entities: <String, EntityRecord>{
          ...adapter.seedEntities(),
          ...prior.entities,
        },
        locations: <String, String>{
          for (final MapEntry<String, List<String>> e
              in adapter.charactersByPlace.entries)
            for (final String name in e.value) name: e.key,
        },
        states: prior.states,
        inventories: prior.inventories,
        facts: prior.facts,
        inner: prior.inner,
        playerAnswers: prior.playerAnswers,
      );
      final CausalContext causalContext = CausalContext(
        state: authoritativeState,
        rules: world.setting,
        opening: world.opening,
      );
      final MemoryStore memory = MemoryStore(<CharacterMemory>[
        ...prior.memory,
        ...adapter.memorySeed(),
      ]);
      final List<ParallelPlaceInfo> allParallelPlaces = adapter
          .parallelPlaceInfos();
      final LlmAgentRunner runner = LlmAgentRunner(
        sender: widget.engineSender,
        requestLimiter: _modelRequests,
        provider: p,
        apiKey: p.apiKey,
        model: model,
        thinking: false,
        choices: _choices[world.id] ?? const <String, CharChoices>{},
        onDelta: _onStreamDelta,
        builtinSearch: p.builtinSearch && scope == null
            ? p.builtinSearchShape
            : BuiltinSearch.none,
        profiles: adapter.profiles,
        causalContext: causalContext,
        currentPlace: scene.place,
        roleAliases: <String, Map<String, String>>{
          for (final CharacterSnapshot c in scene.cast) c.name: c.aliases,
        },
        modelResolver: (String step, {String focus = ''}) {
          ensureRunning();
          _showRunStep(run, step);
          return _stepModel(world.id, step, focus: focus);
        },
        loadImage: (String id) async {
          ensureRunning();
          if (!permittedAssets.contains(id)) return null;
          final AssetRecord? a = widget.store.findAsset(id);
          if (a == null || a.worldId != world.id || a.kind != 'image') return null;
          final List<int> bytes = await widget.store.assetFile(a).readAsBytes();
          return LlmImage(bytes: bytes, mime: a.mime);
        },
        // 图片转述跟原图并存：图还在附件里，转述存在它旁边，
        // 不收图的模型取转述，收图的模型取原图。
        readImageCaption: (String id) => permittedAssets.contains(id)
            ? widget.store.loadAssetText('caption:$id')
            : null,
        writeImageCaption: (String id, String text) {
          if (!permittedAssets.contains(id)) return;
          widget.store.saveAssetText('caption:$id', text);
        },
        loadAttachmentText: (String id) async {
          ensureRunning();
          if (!permittedAssets.contains(id)) return null;
          final AssetRecord? a = widget.store.findAsset(id);
          if (a == null || a.worldId != world.id || (a.kind != 'text' && a.kind != 'pdf')) {
            return null;
          }
          final String? cached = widget.store.loadAssetText(id);
          if (cached != null) return cached;
          if (a.kind == 'text') {
            return widget.store.assetFile(a).readAsString();
          }
          final String text = await extractPdfText(
            widget.store.assetFile(a).path,
          );
          widget.store.saveAssetText(id, text);
          return text;
        },
        prompts: widget.prompts,
        parallelPlaces: allParallelPlaces,
        parallelPlaceCandidates: parallelPlaceCandidates,
        currentParallelPlaceId: parallelPlaceId,
        journal: session.journal,
        responseRevisions: appliedRevisions,
        checkRunActive: ensureRunning,
        onJournalChanged: () => saveProgress(run.session ?? session),
      );

      List<WorldEvent> newEvents = <WorldEvent>[
        ...prior.pendingEvents,
        if (auto) ...autoEvents,
      ];
      List<InnerEntry> newInner = <InnerEntry>[];

      // 玩家输入不再提前变成 WorldEvent。它是“人控角色 CH_ACT”的行动记录，
      // 只有 GM_SELECT_ACTOR 选中当前操控角色时才解析和消费。
      Future<Map<String, Object?>?> playerActionHandler({
        required String actor,
        required NarrativeScene scene,
      }) async {
        if (auto || rawInput.isEmpty) return null;
        final ParallelPlace? actorPlace = _parallelPlaceAtPlace(world, scene.place);
        final WorldAdapter inputAdapter = actorPlace == null || actorPlace.id == parallelPlaceId
            ? adapter : WorldAdapter(
                world: world, parallelPlaceId: actorPlace.id,
                priorLocations: prior.locations, priorEvents: prior.events,
                priorMemory: prior.memory, priorInventories: prior.inventories,
                priorStates: prior.states, priorConstraints: prior.constraints,
              );
        PlayerInputContext pContext = _playerInputContext(
          prior,
          inputAdapter,
          actor,
        );
        final List<Map<String, String>> clarifications =
            <Map<String, String>>[];
        PlayerParseResult? resolved;
        while (true) {
          PlayerParseResult parsed;
          try {
            parsed = await runner.parsePlayer(
              raw: rawInput,
              scene: scene,
              playerName: actor,
              context: pContext,
              recentDialogue: _recentDialogue(inputAdapter, actor),
              attachmentIds: attachmentIds,
            );
          } on AskPlayerException catch (error) {
            if (error is RetryExhaustedException) rethrow;
            String? answer = error.answer;
            if (answer == null) {
              answer = await _askPlayerQuestion(run, error.request);
              ensureRunning();
              if (answer != null) {
                runner.recordPlayerAnswer(error.journalKey, answer);
              }
            }
            if (answer == null) {
              saveStatus('waiting_player');
              say('已暂停：玩家输入还需要你回答一个问题，点击发送即可继续作答。');
              return null;
            }
            runner.setPlayerHelp(<String, String>{'GM_PARSE_INPUT': answer});
            continue;
          }

          PlayerParseResult candidate = parsed;
          for (final PlayerUnresolved u in parsed.audienceQuestions) {
            _showRunStep(run, StepId.sysRecovery);
            final Audience? audience = _visibleRun(run) ? await _askPlayerAudience(u) : null;
            ensureRunning();
            if (audience == null) {
              saveStatus('waiting_player');
              say('已暂停：玩家输入中还有未确认的“感知范围”，点击发送即可继续作答。');
              return null;
            }
            _showRunStep(run, StepId.sysRecovery, completed: true);
            candidate = candidate.resolveAudience(
              audience,
              segmentIds: u.segmentIds.isEmpty ? null : u.segmentIds.toSet(),
            );
          }

          final List<PlayerUnresolved> pending = candidate.unresolved
              .where((PlayerUnresolved u) => !u.isAudience)
              .toList();
          if (pending.isEmpty) {
            resolved = candidate;
            break;
          }
          if (clarifications.length >= 3) {
            throw RetryExhaustedException(
              step: 'GM_PARSE_INPUT',
              reason:
                  '玩家输入经过 3 次补充仍有未决字段：'
                  '${pending.map((PlayerUnresolved u) => u.field).join('、')}',
            );
          }
          final PlayerUnresolved question = pending.first;
          final String? answer = await _askPlayerClarification(run, question);
          ensureRunning();
          if (answer == null) {
            saveStatus('waiting_player');
            say('已暂停：玩家输入还需要你补充“${question.field}”，点击发送即可继续作答。');
            return null;
          }
          clarifications.add(<String, String>{
            'field': question.field,
            'question': question.question,
            'answer': answer,
          });
          pContext = pContext.withClarifications(
            List<Map<String, String>>.unmodifiable(clarifications),
          );
        }

        final PlayerParseResult finalParsed = resolved;
        if (finalParsed.unresolved.isNotEmpty) {
          saveStatus('needs_review');
          say(
            '玩家输入还有未决字段：'
            '${finalParsed.unresolved.map((PlayerUnresolved u) => u.field).join('、')}，先不推进。',
          );
          return null;
        }
        newInner = finalParsed.innerEntries(actor);
        final action = finalParsed.toActionRecord(actorName: actor, scene: scene);
        _showRunStep(run, StepId.gmParseInput, completed: true);
        return action;
      }

      String? timeStopReason;
      Object? worldWait;
      bool askedAboutTime = false;
      final TurnLoop loop = TurnLoop(
        scene: scene,
        memoryStore: memory,
        agents: runner,
        causalContext: causalContext,
        constraints: prior.constraints,
        entityNames: prior.entities.values
            .map((EntityRecord e) => e.name)
            .where((String n) => n.trim().isNotEmpty)
            .toList(),
        pov: run.pov,
        deferPresentation: versioned,
        contestDecider: scope == null ? runner.adjudicateContest : null,
        responseRevisions: appliedRevisions,
        actorsDue: auto || scope != null ? (List<String> eligible) => work.actorsDue(parallelPlaceId, eligible) : null,
        openPlaceDecider: runner.decideOpenParallelPlace,
        routeDecider: timeBoundaryPass
            ? ({required NarrativeScene scene, required List<WorldEvent> events, List<String>? errors, String? previous}) async => 'env'
            : runner.decideNext,
        environmentSource: ({required NarrativeScene scene, required List<WorldEvent> events, String? feedback}) async {
          if (!timeBoundaryPass) {
            return runner.environmentEvents(
              scene: scene,
              events: events,
              feedback: feedback,
              searchMaterial: searchMaterial,
              onWait: (Object? wait) => worldWait = wait,
              eventBatchId: scope == null ? null : session.id,
            );
          }
          final Object? savedPlaces = session.checkpoints['SYS_TIME_SCAN']?.data['places'];
          final Map<String, Object?> proposal = await runner.proposeTimeAdvance(
            boundaries: boundaries,
            state: prior,
            evaluatedPlaces: savedPlaces is List ? savedPlaces.whereType<String>().toList() : <String>[],
            feedback: feedback ?? '',
          );
          final List<String> problems = schedule.timeAdvanceErrors(prior, proposal);
          if (problems.isNotEmpty) {
            runner.prepareRetry(StepId.gmEnvironment);
            throw FormatException(problems.join('；'));
          }
          if (proposal['decision'] != 'advance') {
            timeStopReason = '${proposal['reason']}';
            if (proposal['decision'] == 'ambiguous' && !askedAboutTime) {
              askedAboutTime = true;
              throw AskPlayerException(PlayerQuestion(
                step: StepId.gmEnvironment, code: 'unresolved_action',
                reason: timeStopReason!,
                question: '尚无法确定下一道世界时间边界。哪些过程或角色应先处理？',
              ));
            }
            return <WorldEvent>[];
          }
          final FactRecord boundary = boundaries.firstWhere((FactRecord fact) => fact.id == proposal['boundary_id']);
          return <WorldEvent>[
            WorldEvent(
              id: 'TIME-${session.id}', kind: WorldEventKind.action,
              content: '世界时间到达：${boundary.object}', actor: '',
              target: boundary.id, source: 'world_time', placeId: scene.place,
              delivery: const Delivery(channel: DeliveryChannel.other, form: 'narration', audience: Audience.hidden),
            ),
          ];
        },
        castDecider: runner.decideCast,
        mergePlaceDecider: runner.decideMerge,
        rCheck: runner.checkRender,
        sceneForPlace: (String place) => adapter.scene(atPlace: place),
        sceneObserver: runner.observeScene,
        controlledCharacter: adapter.controlledCharacterName,
        playerActionHandler: playerActionHandler,
        parallelPlaceCandidates: parallelPlaceCandidates,
        otherParallelPlaces: <ParallelPlaceInfo>[
          for (final ParallelPlaceInfo l in allParallelPlaces)
            if (l.id != parallelPlaceId) l,
        ],
        askPlayer: (PlayerQuestion question) async {
          if (run.inLocalWave) return null;
          return _askPlayerQuestion(run, question);
        },
        recoveryContext: jsonEncode(<String, Object?>{
          'profiles': <String, Object?>{
            for (final MapEntry<String, CharacterProfile> e
                in adapter.profiles.entries)
              e.key: <String, Object?>{
                'persona': e.value.persona,
                'state': e.value.state,
              },
          },
          'prompts': widget.prompts,
          'aliases': <String, Object?>{
            for (final CharCard c in reasoningWorld.characters) c.name: c.aliases,
          },
          if (scope == null) 'rawInput': rawInput,
          'attachmentIds': attachmentIds,
        }),
        onStage: (String stage) {
          ensureRunning();
          if (!passedSkip) {
            if (stage == skipThrough) passedSkip = true;
            return;
          }
          final TurnSession updated = (run.session ?? session).withStage(
            stage,
          );
          saveProgress(updated);
          pauseStage = stage;
        },
        onCheckpoint: (String stage, Map<String, Object?> data) {
          ensureRunning();
          TurnSession current = run.session ?? session;
          final Object? previousRecall = current.checkpoints[stage]?.data['history'];
          final Object? recall = data['history'];
          final bool recallStepCompleted = stage.startsWith('${StepId.chMemoryRecall}:') &&
              recall is List && recall.length > (previousRecall is List ? previousRecall.length : 0);
          if (stage == 'SYS_RECOVERY' && data['invalidate'] is List) {
            current = current.withoutCheckpoints(
              (data['invalidate'] as List).map((Object? value) => '$value'),
            );
          }
          final String? responseKey = runner.lastResponseKey;
          final bool trackResponse = responseKey != null && <String>{
            StepId.chMemoryWrite, StepId.chAct, StepId.gmObserveScene, StepId.gmResolveAction,
          }.contains(StepId.base(stage)) && responseKey.startsWith('${StepId.base(stage)}#');
          final TurnSession updated = current.withCheckpoint(stage, <String, Object?>{
            ...data,
            if (trackResponse) 'response_key': responseKey,
          });
          saveProgress(updated);
          if (stage == StepId.sysRecovery) {
            if (data['pending'] == true) {
              _showRunStep(run, stage);
            } else if (data['pending'] == false &&
                current.checkpoints[stage]?.data['pending'] == true) {
              _showRunStep(run, stage, completed: true);
            }
          } else {
            final queryingMemory = StepId.base(stage) == StepId.chMemoryRecall && data['complete'] == false;
            _showRunStep(run, stage, completed: !queryingMemory);
          }
          if (pauseStage == stage || recallStepCompleted) {
            run.completedProgress = _copySession(updated);
            if (singleStage || run.backgroundMode == BackgroundRunMode.step) {
              throw StagePause(stage);
            }
            final Map<String, String> latest =
                widget.store.timelineStepRevisions(world.id, branchId, session.id);
            if (!mapEquals(latest, savedRevisions)) {
              throw const _TimelineStepEdited();
            }
          }
        },
        eventNamespace: scope == null ? '' : session.id,
        startSeq: scope == null ? adapter.startSeq : 1,
      );
      final String scheduleInput = schedule.placeInput(world, fullPrior, focusedParallelPlace);
      final TurnTrace trace = await loop.run(
        newEvents: newEvents,
        actorNames: <String>[
          for (final String actor in adapter.actorNames)
            if ((!auto && run.input.isNotEmpty && actor == adapter.controlledCharacterName) ||
                !work.actorWaiting(actor, scheduleInput, prior, futureBoundaryIds)) actor,
        ],
        perceptionNames: adapter.perceptionNames,
        resume: session,
      );
      ensureRunning();
      run.trace = trace;
      TurnState commitPrior = fullPrior;
      World commitWorld = world;
      int? commitBaseId = baseId;
      WorldWorkQueue commitWork = work;
      if (scope != null && trace.stop?.code != 'player_action') {
        if (!scope.accepts(trace)) {
          run.noReadyWork = true;
          saveStatus('blocked_scope');
          say('这一回合涉及地点外的变化，已保留步骤，需串行处理。');
          return;
        }
        final Future<void>? predecessor = run.settleAfter;
        if (predecessor != null) await predecessor;
        ensureRunning();
        commitBaseId = widget.store.loadTimelineBranch(world.id, branchId)?.headVersionId;
        if (commitBaseId == null) throw TimelineBaseChanged();
        if (branchBase == null) {
          commitWorld = widget.store.loadWorlds().worlds.firstWhere((w) => w.id == world.id);
          commitPrior = widget.store.loadTurnState(world.id) ?? TurnState.empty;
        } else {
          final TimelineSnapshot latest = widget.store.loadTimelineSnapshot(world.id, commitBaseId);
          commitWorld = latest.world;
          commitPrior = latest.state;
        }
        commitWork = WorldWorkQueue(
          widget.store.loadTimelineWork(world.id, branchId) ?? commitPrior.worldWork,
        );
        final LocalTurnScope? current = LocalTurnScope.capture(
          commitWorld, commitPrior.withWorldWork(commitWork.toJson()), parallelPlaceId,
        );
        if (current?.fingerprint != scope.fingerprint) throw TimelineBaseChanged();
      }
      if (trace.stop?.code == 'no_environment_event') {
        if (!timeBoundaryPass) {
          final savedWait = session.journal.responses.entries
              .where((entry) => entry.key.startsWith('${StepId.gmEnvironment}#')).lastOrNull;
          final String? waitResponse = appliedRevisions[savedWait?.key] ?? savedWait?.value;
          worldWait ??= waitResponse == null ? null :
              LlmAgentRunner.parseStoredResponse(waitResponse)?['wait_for'];
          commitWork.checked(parallelPlaceId, scheduleInput, commitPrior, wait: worldWait);
        } else if (timeInput != null) {
          work.checked(WorldSchedule.timeWork, timeInput, prior);
        }
        if (commitBaseId != null) {
          widget.store.saveTimelineWork(world.id, branchId, commitBaseId, commitWork.toJson());
        }
        clearProgress();
        if (timeStopReason != null) say('世界时间暂未推进：$timeStopReason');
        return;
      }
      if (trace.route == 'env' && searchMaterial.isNotEmpty) {
        _saveTimelineSearch(run, '');
      }
      await _queueSearchFromAction(run, trace);
      ensureRunning();

      if (trace.stop?.code == 'player_action') {
        saveStatus('waiting_player');
        run.trace = trace;
        if (_visibleRun(run)) _lastTurnTrace = trace;
        say('轮到你行动：${trace.stop?.reason ?? '请输入当前操控角色的行动。'}');
        return;
      }

      final String chosen = trace.chosen ?? '';
      final bool hasEvents =
          trace.events.isNotEmpty || trace.environmentEvents.isNotEmpty;
      if (hasEvents &&
          trace.stop == null &&
          trace.perceiveErrors.isEmpty &&
          (versioned || trace.renderViolations.isEmpty) &&
          !trace.needsReview) {
        final List<WorldEvent> generated = <WorldEvent>[
          ...trace.environmentEvents, ...trace.events,
        ];
        final List<WorldEvent> incoming = scope == null ? newEvents : <WorldEvent>[
          ...commitPrior.pendingEvents, ...newEvents,
        ];
        final List<WorldEvent> settled = scope == null ? generated : <WorldEvent>[
          for (final WorldEvent event in generated)
            event.copyWith(turnIndex: commitPrior.worldStep + 1),
        ];
        final Map<String, String> nextLocations = <String, String>{
          ...commitPrior.locations,
          if (commitPrior.locations.isEmpty)
            for (final CharCard c in commitWorld.characters)
              if (c.name.trim().isNotEmpty)
                c.name.trim(): c.location.trim().isEmpty
                    ? (adapter.presentNames.contains(c.name.trim())
                          ? scene.place
                          : '')
                    : c.location,
        };
        final Map<String, String> nextStates = <String, String>{
          ...commitPrior.states,
          if (commitPrior.states.isEmpty)
            for (final CharCard c in commitWorld.characters)
              if (c.name.trim().isNotEmpty) c.name.trim(): c.state,
        };
        final Map<String, List<String>> nextInventories =
            <String, List<String>>{
              for (final MapEntry<String, List<String>> e
                  in commitPrior.inventories.entries)
                e.key: List<String>.of(e.value),
            };
        final Map<String, EntityRecord> nextEntities = commitPrior.entities.isEmpty
            ? (scope == null ? adapter.seedEntities() : WorldAdapter(
                world: commitWorld, parallelPlaceId: parallelPlaceId,
                priorLocations: nextLocations,
              ).seedEntities())
            : <String, EntityRecord>{...commitPrior.entities};
        final List<PlayerAnswer> allAnswers = <PlayerAnswer>[];
        final Set<String> seenAnswers = <String>{};
        for (final PlayerAnswer a in <PlayerAnswer>[
          ...commitPrior.playerAnswers,
          ...run.answers,
          ..._answersFromSession(session),
        ]) {
          final String mark = '${a.step}|${a.question}|${a.answer}';
          if (seenAnswers.add(mark)) allAnswers.add(a);
        }
        final List<FactRecord> nextFacts = <FactRecord>[...commitPrior.facts];
        for (final PlayerAnswer a in allAnswers) {
          if (a.kind != 'fact') continue;
          final String id = 'fact:player:${a.step}:${a.question}';
          if (nextFacts.any((FactRecord f) => f.id == id)) continue;
          nextFacts.add(
            FactRecord(
              id: id,
              subject: 'player',
              predicate: 'answer',
              object: '${a.question} => ${a.answer}',
            ),
          );
        }
        TurnState nextState = TurnState(
          events: historyAfterDelivery(
            events: <WorldEvent>[
              ...commitPrior.events,
              ...incoming,
              ...settled.take(trace.environmentEvents.length),
              ...trace.rejectedEvents,
              ...settled.skip(trace.environmentEvents.length),
            ],
            receipts: loop.deliveryReceipts,
          ),
          pendingEvents: pendingAfterDelivery(
            incoming: incoming,
            generated: settled,
            receipts: loop.deliveryReceipts,
          ),
          memory: <CharacterMemory>[
            if (scope != null) ...commitPrior.memory.where((entry) => !scope.ownsActor(entry.characterId)),
            ...memory.allEntries(),
          ],
          locations: nextLocations,
          states: nextStates,
          inventories: nextInventories,
          injuries: commitPrior.injuries,
          constraints: commitPrior.constraints,
          entities: <String, EntityRecord>{
            ...authoritativeState.entities,
            ...nextEntities,
          },
          facts: nextFacts,
          inner: <InnerEntry>[
            ...commitPrior.inner,
            ...newInner,
            if (chosen.isNotEmpty &&
                '${trace.action?['intent'] ?? ''}'.trim().isNotEmpty)
              InnerEntry(
                id: 'inner:intent:${session.id}',
                characterId: 'char:$chosen',
                text: '${trace.action!['intent']}',
                visibility: 'self+god',
              ),
          ],
          playerAnswers: allAnswers,
          worldWork: commitWork.toJson(),
          turnSessionId: session.id,
          stopPoint: _stopPointOf(trace),
        );
        if (trace.orderedDeltas.isNotEmpty) {
          for (final StateDelta delta in trace.orderedDeltas) {
            nextState = nextState.applyDelta(delta, atTurn: authoritativeState.worldStep + 1);
          }
        } else if (trace.stateDelta != null) {
          nextState = nextState.applyDelta(
            trace.stateDelta!, atTurn: authoritativeState.worldStep + 1,
          );
        }
        // 这一回合的时间标记取自事件本身；没写就是没标，不伪造。
        final String turnTimeLabel =
            trace.events.isEmpty ? '' : trace.events.first.timeLabel.trim();
        final TurnStep mainStep = TurnStep(
          kind: trace.events.isEmpty ? 'GM_ENV_UPDATE' : 'CH_ACT',
          who: trace.events.isEmpty ? '旁白' : chosen,
          time: turnTimeLabel,
          text: versioned ? '本回合已结算，正文待生成。'
              : (trace.render?['public_text'] as String? ?? ''),
          candidates: trace.eligible,
          chosen: chosen,
          judgment: trace.events.isEmpty
              ? '引擎：GM_ROUTE 走环境更新，GM_ENV_UPDATE 生成环境事件'
              : '引擎：GM_SELECT_ACTOR 从 ${trace.eligible.join('、')} 中选中 $chosen',
          attachmentIds: attachmentIds,
          perceptions: <String, String>{
            for (final MapEntry<String, Map<String, Object?>> e
                in trace.percepts.entries)
              e.key: jsonEncode(e.value),
          },
        );

        // GM_OPEN_PLACE 开启并行地点：新建一列（不复制状态；世界状态本来就只有一份）。
        World nextWorld = commitWorld;
        final String playerPlace =
            nextState.locations[adapter.controlledCharacterName]?.trim() ?? '';
        if (adapter.controlledCharacterName.isNotEmpty &&
            playerPlace.isNotEmpty) {
          nextWorld = nextWorld.withPlayerAt(playerPlace);
        }
        String focusParallelPlace = parallelPlaceId;
        for (final ParallelPlaceOpening opening in trace.openPlace.allOpenings) {
          final String place = opening.place.trim();
          if (place.isEmpty) continue;
          final bool playerThere =
              playerPlace == place ||
              (playerPlace.isEmpty &&
                  opening.members.contains(adapter.controlledCharacterName));
          nextWorld = nextWorld.addParallelPlaceAt(
            place,
            parentId: parallelPlaceId,
            here: playerThere,
          );
        }
        bool mergedParallelPlace = false;
        if (trace.mergePlace.merge) {
          final World merged = nextWorld.mergeParallelPlace(
            parallelPlaceId,
            trace.mergePlace.into,
          );
          if (!identical(merged, nextWorld)) {
            nextWorld = merged;
            focusParallelPlace = trace.mergePlace.into;
            mergedParallelPlace = true;
          }
        }
        final List<({String parallelPlaceId, TurnStep step})> extraSteps =
            <({String parallelPlaceId, TurnStep step})>[];
        for (final ParallelPlaceOpening opening in trace.openPlace.allOpenings) {
          final String place = opening.place.trim();
          if (place.isEmpty) continue;
          final ParallelPlace? opened = _parallelPlaceAtPlace(nextWorld, place);
          if (opened != null) {
            final String why = opening.why.trim().isEmpty
                ? trace.openPlace.why
                : opening.why;
            extraSteps.add((
              parallelPlaceId: opened.id,
              step: TurnStep(
                kind: 'GM_OPEN_PLACE',
                who: '旁白',
                time: turnTimeLabel,
                text:
                    '开启并行地点：在“$place”新建一列'
                    '${opening.members.isEmpty ? '' : '，现场：${opening.members.join('、')}'}'
                    '${why.isEmpty ? '' : '。$why'}',
              ),
            ));
          }
        }
        if (mergedParallelPlace) {
          extraSteps.add((
            parallelPlaceId: parallelPlaceId,
            step: TurnStep(
              kind: 'GM_MERGE_PLACE',
              who: '旁白',
              time: turnTimeLabel,
              text:
                  '合并并行地点：本列并入“${_parallelPlaceLabel(trace.mergePlace.into, world: world)}”'
                  '${trace.mergePlace.why.isEmpty ? '' : '。${trace.mergePlace.why}'}',
            ),
          ));
        }

        final List<WorldEvent> committedEvents = <WorldEvent>[
          for (int i = 0; i < nextState.events.length; i++)
            nextState.events[i].uid.trim().isEmpty
                ? nextState.events[i].copyWith(uid: 'evt-${session.id}-$i')
                : nextState.events[i],
        ];
        nextState = nextState.withEvents(committedEvents);
        if (chosen.isNotEmpty && trace.events.isNotEmpty) {
          commitWork.actorsServed(parallelPlaceId, trace.eligible, <String>{
            chosen,
            if (trace.orderedDeltas.isNotEmpty)
              for (final WorldEvent event in trace.events) event.actor.replaceFirst('char:', ''),
          });
        }
        final Object? segments = trace.action?['segments'];
        if (chosen.isNotEmpty && segments is List && segments.any((Object? segment) =>
            segment is Map && segment['kind'] == 'action' && segment['action_kind'] == 'wait') &&
            trace.stateDelta == null) {
          commitWork.actorWaits(chosen, schedule.placeInput(nextWorld, nextState, focusedParallelPlace),
              nextState, trace.action?['wait_for']);
        }
        nextState = nextState.withWorldWork(commitWork.toJson());
        final TimelineNarrationInput narration = (
          scope: _narrationScope(run.pov, world.controlledCharacterName),
          placeId: parallelPlaceId,
          events: settled,
        );

        // 世界快照、主 step、GM_OPEN_PLACE/GM_MERGE_PLACE 记录一次事务提交，避免半截回合。
        if (branchBase == null) {
          widget.store.commitTurn(
            worldId: world.id,
            baseVersionId: scope == null ? session.baseVersionId : commitBaseId,
            stateJson: nextState.encodeCheckpoint(),
            parallelPlaceId: parallelPlaceId,
            mainStep: mainStep,
            extraSteps: extraSteps,
            events: nextState.events,
            memory: nextState.memory,
            sessionId: session.id,
            world: nextWorld,
            session: run.session,
            narration: narration,
          );
          _memory[world.id] = nextState.memory;
          final WorldsLoad r = widget.store.loadWorlds();
          setState(() => _worlds = r.worlds);
          run.world = r.worlds.firstWhere((World saved) => saved.id == world.id);
        } else {
          final int versionId = widget.store.commitTimelineTurn(
            worldId: world.id,
            branchId: branchId,
            baseVersionId: commitBaseId ?? branchBase.version.id,
            taskId: session.id,
            world: nextWorld,
            state: nextState,
            session: run.session,
            narration: narration,
            newSteps: <({String placeId, TurnStep step})>[
              (placeId: parallelPlaceId, step: mainStep),
              for (final extra in extraSteps)
                (placeId: extra.parallelPlaceId, step: extra.step),
            ],
          );
          final TimelineSnapshot snapshot =
              widget.store.loadTimelineSnapshot(world.id, versionId);
          run.snapshot = snapshot;
          run.world = snapshot.world;
          if (_visibleRun(run)) setState(() => _timelineSnapshot = snapshot);
        }
        run.committed = true;
        _showRunStep(run, StepId.sysCommit, completed: true);
        run.lastSettledPlace = parallelPlaceId;
        run.placeId = null;
        if (_visibleRun(run)) {
          for (final ParallelPlace l in run.world.parallelPlaces) {
            if (l.id == focusParallelPlace && l.events.isNotEmpty) {
              setState(() {
                _focused = focusParallelPlace;
                _selected = l.events.length - 1;
              });
              _saveTimelinePlace();
              _parallelPlaceFocus.focus(focusParallelPlace);
              _kickFocus();
              break;
            }
          }
        }
        clearProgress();
        run.trace = trace;
        if (_visibleRun(run)) _lastTurnTrace = trace;
        final int? committedVersionId = widget.store.loadTimelineBranch(world.id, branchId)?.headVersionId;
        final TimelineNarrationJob? job = committedVersionId == null ? null :
            widget.store.loadPendingNarration(world.id, branchId, versionId: committedVersionId);
        if (job != null) {
          run.presentationPending = true;
          if (run.backgroundMode != BackgroundRunMode.round &&
              run.backgroundMode != BackgroundRunMode.step) {
            await present(job);
            if (run.presentationPending) return;
          }
        }
      }
      if (!run.inLocalWave && trace.blocked.isEmpty &&
          trace.stop == null &&
          trace.renderViolations.isEmpty &&
          !trace.needsReview &&
          (rawInput.isEmpty ||
              trace.chosen == adapter.controlledCharacterName)) {
        if (_visibleRun(run)) {
          _input.clear();
          setState(() => _attachments.clear());
        }
      }
      if (_visibleRun(run) && run.pov == RenderPov.omniscient) {
        say(_summaryOfRun(trace));
      }
    } on _TimelineFrozen {
      return;
    } on TimelineBaseChanged {
      run.noReadyWork = true;
      saveStatus('paused');
      say('该时间线在推演期间已推进，本回合未记录结果。');
    } on _TimelineStepEdited {
      await _executeTimelineStep(
        run, resume: run.session, singleStage: singleStage, autoEvents: autoEvents,
      );
    } on StagePause catch (pause) {
      if (run.frozen || !mounted) return;
      saveStatus('paused');
      say('单步完成：${pause.stage}。点击发送可继续下一步。');
    } on PlayerPausedException catch (pause) {
      if (run.frozen || !mounted) return;
      saveStatus('waiting_player');
      if (_visibleRun(run)) {
        say(
          '已暂停：${pause.request.step} 需要你回答。\n'
          '${pause.request.question}\n\n'
          '点击发送即可继续作答。',
        );
      }
    } catch (err) {
      if (run.frozen || !mounted) return;
      saveStatus('error');
      say('引擎出错：$err');
    }
  }

  /// GM_PARSE_INPUT 需要的只读上下文：玩家状态、背包、现场物品、已知地点。
  PlayerInputContext _playerInputContext(
    TurnState prior,
    WorldAdapter adapter,
    String actor,
  ) {
    String bareId(String value) => value
        .trim()
        .replaceFirst('char:', '')
        .replaceFirst('place:', '')
        .replaceFirst('item:', '');
    String nameOf(String id) {
      final EntityRecord? e = prior.entities[id];
      final String n = e?.name.trim() ?? '';
      return n.isEmpty ? id : n;
    }

    final String place = adapter.parallelPlace?.place.trim() ?? '';
    final List<Map<String, String>> inventory = <Map<String, String>>[
      for (final String id in prior.inventories[actor] ?? const <String>[])
        <String, String>{'id': id, 'name': nameOf(id)},
    ];
    final List<Map<String, String>> placeItems = <Map<String, String>>[
      for (final EntityRecord e in prior.entities.values)
        if (e.kind == 'item' &&
            place.isNotEmpty &&
            bareId(e.location) == bareId(place))
          <String, String>{'id': e.id, 'name': nameOf(e.id)},
    ];
    final List<String> knownPlaces = <String>[
      for (final ParallelPlace l in _world.parallelPlaces)
        if (l.place.trim().isNotEmpty) l.place.trim(),
    ];
    final List<Map<String, Object?>> constraints = <Map<String, Object?>>[
      for (final FunctionalConstraint c in prior.constraints)
        if (c.who == actor)
          <String, Object?>{
            'capability': c.capability,
            'state': c.state.name,
            if (c.reason.isNotEmpty) 'reason': c.reason,
          },
    ];
    return PlayerInputContext(
      playerState: adapter.profiles[actor]?.state ?? '',
      inventory: inventory,
      placeItems: placeItems,
      knownPlaces: knownPlaces,
      constraints: constraints,
    );
  }

  List<Map<String, String>> _recentDialogue(WorldAdapter adapter, String actor) {
    final NarrativeScene scene = adapter.scene();
    final List<WorldEvent> visible = renderView(
      adapter.priorEvents.where((WorldEvent event) => event.placeId == scene.place).toList(),
      scene, 'char:$actor',
    );
    return <Map<String, String>>[
      for (final WorldEvent event in visible.reversed.take(2).toList().reversed)
        <String, String>{'who': '', 'text': event.content},
    ];
  }

  /// 问玩家补充 GM_PARSE_INPUT 的未决字段，例如背包/现场找不到物品 id。
  Future<String?> _askPlayerClarification(_TimelineRun run, PlayerUnresolved u) {
    return _askPlayerQuestion(run,
      PlayerQuestion(
        step: 'GM_PARSE_INPUT',
        code: 'p_clarification',
        reason: u.why,
        question: u.question,
        options: u.options,
      ),
    );
  }

  Future<Audience?> _askPlayerAudience(PlayerUnresolved u) async {
    final List<String> options = u.options.isEmpty
        ? <String>['target（只给目标）', 'nearby（附近可闻）', 'scene（全场可闻）']
        : u.options;
    return showDialog<Audience>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('这句话谁能感知'),
          content: Text('${u.question}\n\n${u.why}'),
          actions: <Widget>[
            for (final String option in options)
              TextButton(
                onPressed: () =>
                    Navigator.of(context).pop(_audienceFromOption(option)),
                child: Text(option),
              ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
          ],
        );
      },
    );
  }

  StopPoint? _stopPointOf(TurnTrace trace) {
    if (trace.stop?.code == 'player_action') {
      return StopPoint(
        reason: 'player_action',
        question: trace.stop?.reason ?? '轮到你行动了。',
      );
    }
    if (trace.openPlaceErrors.isNotEmpty ||
        trace.routeErrors.isNotEmpty ||
        trace.castErrors.isNotEmpty ||
        trace.selectActorErrors.isNotEmpty ||
        trace.environmentErrors.isNotEmpty ||
        trace.perceiveErrors.isNotEmpty ||
        trace.resolveErrors.isNotEmpty ||
        trace.stop != null) {
      return StopPoint(
        reason: 'error',
        question: trace.stop?.reason ?? '这一回合校验失败，需要你处理。',
      );
    }
    if (trace.needsReview || trace.renderViolations.isNotEmpty) {
      return const StopPoint(
        reason: 'needs_review',
        question: '这一回合需要你检查后再继续。',
      );
    }
    if (trace.route != 'env' && (trace.eligible.isEmpty || trace.chosen == null)) {
      return const StopPoint(reason: 'player_action', question: '轮到你行动了。');
    }
    return null;
  }

  List<PlayerAnswer> _answersFromSession(TurnSession session) {
    final List<PlayerAnswer> out = <PlayerAnswer>[];
    final Set<String> seen = <String>{};
    for (final MapEntry<String, String> e in session.journal.answers.entries) {
      final String key = e.key;
      final String answer = e.value.trim();
      if (answer.isEmpty) continue;
      final String question = session.journal.questions[key] ?? '';
      final List<String> parts = key.split('#');
      final String step = parts.first == 'SYS_RECOVERY' && parts.length > 1
          ? parts[1]
          : parts.first;
      final String mark = '$step|$question|$answer';
      if (!seen.add(mark)) continue;
      out.add(
        PlayerAnswer(
          step: step,
          question: question,
          answer: answer,
          kind: session.journal.kinds[key] ?? 'direction',
          createdAt: session.updatedAt,
        ),
      );
    }
    return out;
  }

  Future<String?> _askPlayerQuestion(_TimelineRun run, PlayerQuestion q) async {
    if (!_visibleRun(run) || run.frozen) return null;
    _showRunStep(run, StepId.sysRecovery);
    final bool recovery = q.code == 'retry_exhausted' || q.code == 'unresolved_action';
    final TextEditingController controller = TextEditingController();
    final String? answer = await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(recovery ? '推演需要你处理' : '${StepId.label(q.step)} 需要你帮忙'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(q.question),
                if (q.reason.trim().isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 180),
                    child: SingleChildScrollView(
                      child: SelectableText(q.reason),
                    ),
                  ),
                ],
                if (q.options.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      for (final String option in q.options)
                        OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(option),
                          child: Text(option),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  minLines: 2,
                  maxLines: 5,
                  decoration: InputDecoration(
                    hintText: recovery ? '给推演引擎的处理指令，不是角色台词' : '也可以自己写',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(recovery ? '先修改，稍后继续' : '取消'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(controller.text.trim()),
              child: Text(recovery ? '按指令继续' : '提交'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    final String text = (answer ?? '').trim();
    if (text.isEmpty) return null;
    if (run.frozen || !mounted) return null;
    _showRunStep(run, StepId.sysRecovery, completed: true);
    run.answers.add(
      PlayerAnswer(
        step: q.step,
        question: q.question,
        answer: text,
        kind: q.kind,
        createdAt: DateTime.now().toIso8601String(),
      ),
    );
    return text;
  }

  Audience? _audienceFromOption(String option) {
    final String s = option.trim().toLowerCase();
    if (s.startsWith('target')) return Audience.target;
    if (s.startsWith('nearby')) return Audience.nearby;
    if (s.startsWith('scene')) return Audience.scene;
    return null;
  }

  ParallelPlace? _parallelPlaceAtPlace(World world, String place) {
    final String p = place.trim();
    for (final ParallelPlace l in world.parallelPlaces) {
      if (l.isActive && l.place.trim() == p) return l;
    }
    return null;
  }

  String _parallelPlaceLabel(String id, {World? world}) {
    for (final ParallelPlace l in (world ?? _world).parallelPlaces) {
      if (l.id == id) return l.place;
    }
    return id;
  }

  String _summaryOfRun(TurnTrace t) {
    final StringBuffer b = StringBuffer();
    b.writeln('【引擎 · 当前世界】');
    b.writeln(
      'GM_OPEN_PLACE 开启并行地点：${t.openPlace.allOpenings.isEmpty ? '否' : '是'}'
      '${t.openPlace.allOpenings.isEmpty ? '' : '（${t.openPlace.allOpenings.map((ParallelPlaceOpening o) => '${o.place}${o.members.isEmpty ? '' : '，${o.members.join('、')}'}').join('；')}）'}'
      '${t.openPlace.why.isEmpty ? '' : '（${t.openPlace.why}）'}',
    );
    if (t.openPlaceErrors.isNotEmpty) {
      b.writeln('GM_OPEN_PLACE 校验：${t.openPlaceErrors.join('；')}');
    }
    b.writeln(
      'GM_ROUTE 路径：${t.route == 'env'
          ? '环境更新'
          : t.route == 'player'
          ? '等待玩家 CH_ACT'
          : t.route == 'turn'
          ? '角色回合'
          : t.openPlaceErrors.isNotEmpty
          ? '未决定（GM_OPEN_PLACE 输出不合格）'
          : t.castErrors.isNotEmpty
          ? '未决定（GM_ELIGIBILITY 输出不合格）'
          : t.selectActorErrors.isNotEmpty
          ? '未决定（GM_SELECT_ACTOR 输出不合格）'
          : '未决定（GM_ROUTE 输出不合格）'}',
    );
    if (t.routeErrors.isNotEmpty) {
      b.writeln('GM_ROUTE 校验：${t.routeErrors.join('；')}');
    }
    if (t.castErrors.isNotEmpty) {
      b.writeln('GM_ELIGIBILITY 校验：${t.castErrors.join('；')}');
    }
    if (t.selectActorErrors.isNotEmpty) {
      b.writeln('GM_SELECT_ACTOR 校验：${t.selectActorErrors.join('；')}');
    }
    b.writeln('GM_CAST 在场名单：${t.cast.join('、')}');
    b.writeln('GM_ELIGIBILITY 行动资格：${t.eligible.join('、')}');
    b.writeln('GM_SELECT_ACTOR 选中：${t.chosen ?? '（没有选出人）'}');
    b.writeln(
      'GM_MERGE_PLACE 合并：${t.mergePlace.merge}'
      '${t.mergePlace.into.isEmpty ? '' : '（并入：${_parallelPlaceLabel(t.mergePlace.into)}）'}'
      '（${t.mergePlace.why}）',
    );
    if (t.environmentEvents.isNotEmpty) {
      b.writeln(
        'GM_ENV_UPDATE 环境事件：${t.environmentEvents.map((e) => e.summary).join('；')}',
      );
    }
    if (t.arbitration != null) {
      b.writeln('GM_RESOLVE_ACTION：${jsonEncode(t.arbitration)}');
    }
    if (t.perceiveErrors.isNotEmpty) {
      b.writeln('CH_PERCEIVE 校验：${t.perceiveErrors.join('；')}');
    }
    if (t.environmentErrors.isNotEmpty) {
      b.writeln('GM_ENV_UPDATE 校验：${t.environmentErrors.join('；')}');
    }
    if (t.resolveErrors.isNotEmpty) {
      b.writeln('GM_RESOLVE_ACTION 校验：${t.resolveErrors.join('；')}');
    }
    if (t.needsReview) {
      b.writeln('需要人工看：GM_RESOLVE_ACTION unresolved 或 GM_REVIEW_NARRATION 警告。');
    }
    if (t.blocked.isNotEmpty) {
      b.writeln(
        '兜底硬拦：${t.blocked.map((c) => '${c.capability}（${c.reason}）').join('、')}',
      );
    }
    if (t.stop != null) {
      b.writeln('回合中止：${t.stop!.code}（${t.stop!.reason}）');
      if (t.stop!.question.isNotEmpty) {
        b.writeln('问：${t.stop!.question}');
      }
      if (t.stop!.options.isNotEmpty) {
        b.writeln('选项：${t.stop!.options.join('、')}');
      }
    }
    if (t.actErrors.isNotEmpty) {
      b.writeln(
        'CH_ACT 校验：${t.actErrors.map((e) => '${e.code}：${e.message}').join('；')}',
      );
    }
    if (t.renderViolations.isNotEmpty) {
      b.writeln(
        'GM_NARRATE 校验：${t.renderViolations.map((v) => '${v.code}：${v.message}').join('；')}',
      );
    }
    if (t.reviewWarnings.isNotEmpty) {
      b.writeln('GM_REVIEW_NARRATION：${t.reviewWarnings.join('；')}');
    }
    if (t.rejectedEvents.isNotEmpty) {
      b.writeln(
        '拒绝留痕：${t.rejectedEvents.map((e) => '${e.id} ${e.content}').join('；')}',
      );
    }
    if (t.stateDelta != null) {
      b.writeln('状态变化：${jsonEncode(t.stateDelta!.toJson())}');
    }
    b.writeln();
    b.writeln('【事件】');
    if (t.events.isEmpty) b.writeln('  （没有落账事件）');
    for (final WorldEvent e in t.events) {
      b.writeln('  [${e.id}] ${e.summary}');
    }
    b.writeln();
    b.writeln('【正文】');
    b.writeln('${t.render?['public_text'] ?? '（没有正文）'}');
    final Object? godNote = t.render?['god_note'];
    if ('${godNote ?? ''}'.trim().isNotEmpty) {
      b.writeln();
      b.writeln('【上帝注】');
      b.writeln('$godNote');
    }
    return b.toString().trimRight();
  }

  /// 改完正文存回去。
  ///
  /// [index] 是**画布上的步序**（只有 GM_ENV_UPDATE / CH_ACT 上画布），跟 step 表里
  /// 用同样的过滤顺序对应。
  void _saveStepText(String parallelPlaceId, int index, String text) {
    final TimelineVersion? version = widget.store.timelineVersionForCard(
      _worldId, _branchId, parallelPlaceId, index,
    );
    if (version != null && widget.store.editTimelineNarration(
      _worldId, _branchId, version.id,
      _narrationScope(_pov, _world.controlledCharacterName), text,
    )) {
      setState(() {});
      return;
    }
    if (_timelineSnapshot != null || _pov == RenderPov.player) return;
    widget.store.updateStepText(_world.id, parallelPlaceId, index, text);
    final WorldsLoad r = widget.store.loadWorlds();
    setState(() => _worlds = r.worlds);
  }

  /// 把一句话说给用户听。用我们自己的弹窗样式，不走 Material。
  void _engineSay(String text) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (BuildContext c) {
        final JoPalette p = JoTheme.of(c);
        return Dialog(
          backgroundColor: p.bg,
          shape: const RoundedRectangleBorder(),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(JoSpace.s4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // 内容可能很长（一整回合），所以要能滚。
                  Flexible(
                    child: SingleChildScrollView(
                      child: SelectableText(
                        text,
                        style: JoFonts.ui.copyWith(
                          fontSize: 13,
                          color: p.text,
                          height: 1.7,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: JoSpace.s4),
                  Align(
                    alignment: Alignment.centerRight,
                    child: JoButton(
                      text: '知道了',
                      onTap: () => Navigator.of(c).maybePop(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _mainPage() {
    final JoPalette p = JoTheme.of(context);
    final TimelineNarrationJob? pending = _viewedVersionId == null
        ? widget.store.loadPendingNarration(_worldId, _branchId) : null;
    final int? storedStepsVersion = _viewedVersionId ?? pending?.versionId;
    final bool hasStoredSteps = storedStepsVersion == null
        ? _activeSession != null
        : widget.store.loadCompletedTimelineTask(_worldId, storedStepsVersion) != null;

    return Container(
      color: p.bg,
      child: LayoutBuilder(
        builder: (BuildContext c, BoxConstraints k) {
          // 两侧栏的最大宽度按窗口现算：先把画布那一块守住（_kCanvasMin），
          // 剩下的才能归侧栏。窗口一变，两边会自动收回去，但不会把画布挤没。
          final double total = k.maxWidth;
          final double railMax = math.max(
            _kRailMin,
            total - _sideW - _kCanvasMin - kJoSplitterTotal,
          );
          final double sideMax = math.max(
            _kSideMin,
            total - _railW - _kCanvasMin - kJoSplitterTotal,
          );
          // 存的宽度可能比现在窗口能容纳的大（上次拉大了）：画的时候再收一道。
          final double railW = _railW.clamp(_kRailMin, railMax);
          final double sideW = _sideW.clamp(_kSideMin, sideMax);

          // 换世界的过渡：**只淡内容**（画布 + 右栏），左边世界列表不动 ——
          // 它是导航，跟着闪一下反而看不清点到哪了。
          final Animation<double> fade = CurvedAnimation(
            parent: _worldFade,
            curve: Curves.easeOut,
          );
          final Animation<Offset> lift =
              Tween<Offset>(
                begin: const Offset(0, 0.012),
                end: Offset.zero,
              ).animate(
                CurvedAnimation(parent: _worldFade, curve: Curves.easeOutCubic),
              );
          Widget worldFade(Widget child) => FadeTransition(
            opacity: fade,
            child: SlideTransition(position: lift, child: child),
          );

          return Row(
            children: <Widget>[
              SizedBox(
                width: railW,
                child: _WorldRail(
                  palette: p,
                  worlds: _worlds,
                  currentId: _worldId,
                  lastPlayedOf: widget.store.lastPlayedAt,
                  onPick: _pickWorld,
                  onNew: _newWorld,
                  onEdit: _editWorld,
                  isDark: widget.settings.isDark,
                  onSettings: () => setState(() => _page = _Page.settings),
                  onTheme: () => widget.onSettingsChanged(
                    widget.settings.copyWith(isDark: !widget.settings.isDark),
                  ),
                ),
              ),
              JoSplitter(
                palette: p,
                width: railW,
                minWidth: _kRailMin,
                maxWidth: railMax,
                defaultWidth: _kRailDef,
                growsRight: true,
                onResize: (double w) => setState(() => _railW = w),
                onResizeEnd: _saveWidths,
              ),
              Expanded(
                child: worldFade(
                  Column(
                    // stretch：不然子项拿松约束，顶栏只按内容宽度居中排，
                    // 右边那两个按钮就贴不到右边界。
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _TopBar(
                        palette: p,
                        worldName: _timelineSnapshot == null
                            ? _world.name
                            : '${_world.name} · ${widget.store.loadTimelineBranch(_worldId, _branchId)?.name ?? ''}',
                        mode: _mode,
                        busy: _engineBusy,
                        playerless:
                            _world.controlledCharacterName.trim().isEmpty,
                        onMode: (String v) => setState(() => _mode = v),
                        modeKey: _modeKey,
                        onHistory: _openHistory,
                        povLabel: _pov == RenderPov.omniscient ? '全知' : '角色',
                        onPov: () => setState(() {
                          _pov = _pov == RenderPov.omniscient
                              ? RenderPov.player
                              : RenderPov.omniscient;
                        }),
                      ),
                      if (pending != null && !_engineBusy)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: JoSpace.s4),
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: JoButton(
                              text: '跳过正文',
                              onTap: () => setState(() {
                                widget.store.finishTimelineNarration(
                                  _worldId, pending.versionId, pending.scope, null,
                                );
                              }),
                            ),
                          ),
                        ),
                      Expanded(
                        child: _world.parallelPlaces.isEmpty
                            ? _EmptyWorld(palette: p)
                            : _canvas(p),
                      ),
                      // 工具条始终保留“操控”入口；即使全部交给 AI 也能切回来。
                      if (_world.characters.isNotEmpty && _viewedVersionId == null)
                        _ActionToolbar(
                          palette: p,
                          controlled: _world.controlledCharacterName,
                          controlKey: _controlKey,
                          onSwitchControlled: _switchControlledCharacter,
                          onChoices: _pickChoices,
                          onPickImage: _pickImage,
                          onOcrImage: _pickOcrImage,
                          onPickFile: _pickFile,
                          onCamera: _takePhoto,
                          searchLabel: _world.searchSource.label,
                          searchKey: _searchKey,
                          onPickSearchSource: _pickSearchSource,
                        ),
                      if (_viewedVersionId != null)
                        Padding(
                          padding: const EdgeInsets.all(JoSpace.s3),
                          child: DefaultTextStyle(
                            style: JoFonts.meta.copyWith(color: p.secondary),
                            child: Wrap(
                              spacing: JoSpace.s3,
                              children: <Widget>[
                                Text(_timelineSnapshot!.version.round == null
                                    ? '正在查看开场'
                                    : '正在查看第 ${_timelineSnapshot!.version.round} 回合'),
                                Text(_timelineProgress(_worldId, _branchId)),
                              ],
                            ),
                          ),
                        )
                      else if (_world
                          .controlledCharacterName
                          .isNotEmpty) ...<Widget>[
                        if (_attachments.isNotEmpty)
                          _AttachmentBar(
                            palette: p,
                            assets: _attachments,
                            fileOf: widget.store.assetFile,
                            onOpen: _openAttachment,
                            onRemove: _removeAttachment,
                          ),
                        // 输入框只在**当前有操控角色**时出现。
                        // 没有操控角色 = 一切交给 AI，人不用输入行动。
                        _InputBar(
                          palette: p,
                          settings: widget.settings,
                          controller: _input,
                          onSubmit: _submit,
                          sendKey:
                              widget.keys[JoKey.send] ?? joFallback(JoKey.send),
                          newlineKey:
                              widget.keys[JoKey.newline] ??
                              joFallback(JoKey.newline),
                        ),
                      ] else
                        _InputBar(
                          palette: p,
                          settings: widget.settings,
                          controller: _input,
                          onSubmit: _submit,
                          sendKey:
                              widget.keys[JoKey.send] ?? joFallback(JoKey.send),
                          newlineKey:
                              widget.keys[JoKey.newline] ??
                              joFallback(JoKey.newline),
                          readOnly: true,
                        ),
                    ],
                  ),
                ),
              ),
              JoSplitter(
                palette: p,
                width: sideW,
                minWidth: _kSideMin,
                maxWidth: sideMax,
                defaultWidth: _kSideDef,
                growsRight: false,
                onResize: (double w) => setState(() => _sideW = w),
                onResizeEnd: _saveWidths,
              ),
              SizedBox(
                width: sideW,
                child: worldFade(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Expanded(
                        child: _SidePanel(
                          palette: p,
                          settings: widget.settings,
                          world: _world,
                          onEditText: _saveStepText,
                          onReadStep: _readSelectedEvent,
                          onStopRead: _stopReading,
                          onPauseRead: _readPaused
                              ? _resumeReading
                              : _pauseReading,
                          reading: _reading,
                          readPaused: _readPaused,
                          readStatus: _readStatus,
                          focusedParallelPlace: _focusedParallelPlace,
                          selectedEvent: _selectedEvent,
                          selectedIndex: _selected,
                          store: widget.store,
                          onRollback: _rollbackTurn,
                          onStoredSteps: hasStoredSteps
                              ? () => _openStoredSteps(versionId: storedStepsVersion)
                              : null,
                          flowActive: !_engineBusy && _viewedVersionId == null &&
                                  _activeSession?.status == 'waiting_player'
                              ? StepId.sysRecovery
                              : _flowActive,
                          flowDone: _flowDone,
                          flowOpen: _flowOpen,
                          liveText: _liveText,
                          onToggleFlow: _toggleFlow,
                          sideScroll: _sideScroll,
                          onClear: () => setState(() {
                            _focused = null;
                            _selected = null;
                          }),
                        ),
                      ),
                      // 常驻按钮；编辑与记忆都走弹窗。
                      if (_timelineSnapshot == null)
                        WorldEditButton(palette: p, onTap: _openEdit),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 滚轮 = 上下平移；Ctrl + 滚轮 = 以指针为中心缩放。
  void _onSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(e, (
      PointerSignalEvent ev,
    ) {
      if (ev is! PointerScrollEvent) return;
      if (HardwareKeyboard.instance.isControlPressed) {
        _zoomAt(ev.localPosition, ev.scrollDelta.dy < 0 ? 1.1 : 1 / 1.1);
      } else {
        _panBy(-ev.scrollDelta.dx, -ev.scrollDelta.dy);
      }
    });
  }

  void _panBy(double dx, double dy) {
    _tc.value = _clampPan(
      Matrix4.identity()
        ..translateByDouble(dx, dy, 0, 1)
        ..multiply(_tc.value),
    );
  }

  void _zoomAt(Offset focal, double factor) {
    final double cur = _tc.value.getMaxScaleOnAxis();
    final double next = (cur * factor).clamp(0.3, 2.2);
    if ((next - cur).abs() < 0.0001) return;
    final double f = next / cur;
    _tc.value = _clampPan(
      Matrix4.identity()
        ..translateByDouble(focal.dx, focal.dy, 0, 1)
        ..scaleByDouble(f, f, 1, 1)
        ..translateByDouble(-focal.dx, -focal.dy, 0, 1)
        ..multiply(_tc.value),
    );
  }

  /// 平移边界：左、上不许拖出内容之外；右、下允许留白 480。
  Matrix4 _clampPan(Matrix4 m) {
    if (_viewport.isEmpty) return m;
    final double s = m.getMaxScaleOnAxis();
    final double cw = _canvasW * s;
    final double ch = _totalH * s;
    final double tx = m.storage[12];
    final double ty = m.storage[13];
    final double minTx = (_viewport.width - cw - 480).clamp(-1e6, 0.0);
    final double minTy = (_viewport.height - ch - 480).clamp(-1e6, 0.0);
    final double nx = tx.clamp(minTx, 0.0);
    final double ny = ty.clamp(minTy, 0.0);
    if (nx == tx && ny == ty) return m;
    return m.clone()
      ..storage[12] = nx
      ..storage[13] = ny;
  }

  Widget _canvas(JoPalette p) {
    return ClipRect(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints c) {
          _viewport = Size(c.maxWidth, c.maxHeight);
          return Listener(
            onPointerSignal: _onSignal,
            child: InteractiveViewer(
              transformationController: _tc,
              constrained: false,
              panEnabled: true,
              scaleEnabled: false,
              boundaryMargin: const EdgeInsets.only(right: 480, bottom: 480),
              // 聚焦展开的动画：卡片 / 表头 / 底层连线都在这里重建，
              // 用的是同一份插值后的列宽，所以不会错位。
              // 帧由 _focusTicker 推（它每帧 setState），不用 AnimatedBuilder。
              child: Builder(
                builder: (BuildContext context) {
                  final Map<String, double> colX = _colX;
                  return SizedBox(
                    width: _canvasW,
                    height: _totalH,
                    child: Stack(
                      children: <Widget>[
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _CanvasPainter(
                              palette: p,
                              colX: colX,
                              colW: _colW,
                              headerH: kHeaderH,
                              cardH: kCardH,
                              rowH: _rowH,
                              extra: _extra.values,
                              gap: kGap,
                              maxRows: _maxRows,
                              rows: _rows,
                              rulerW: _rulerW,
                              totalW: _canvasW,
                              parallelPlaces: _world.parallelPlaces,
                              moves: _world.moves,
                            ),
                          ),
                        ),
                        ..._headers(p, colX),
                        ..._steps(p, colX),
                      ],
                    ),
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }

  List<Widget> _headers(JoPalette p, Map<String, double> colX) {
    final List<Widget> out = <Widget>[];
    for (final ParallelPlace parallelPlace in _world.parallelPlaces) {
      final bool on = _focused == parallelPlace.id;
      out.add(
        Positioned(
          left: colX[parallelPlace.id]!,
          top: 10,
          width: _colW(parallelPlace.id),
          height: kHeaderH - 14,
          child: JoTap(
            onTap: () => _focusParallelPlace(parallelPlace.id),
            builder: (BuildContext context, bool hover, bool down) {
              return AnimatedContainer(
                duration: kJoTapMs,
                curve: Curves.easeOut,
                padding: const EdgeInsets.symmetric(horizontal: JoSpace.s3),
                decoration: BoxDecoration(
                  color: on
                      ? p.surface
                      : (hover ? p.surface.withValues(alpha: 0.5) : p.bg),
                  border: JoShape.border(on || hover ? p.accent : p.border),
                  borderRadius: JoShape.br,
                ),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 3,
                      height: 14,
                      color: parallelPlace.here ? p.accent : p.border,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        parallelPlace.place,
                        overflow: TextOverflow.ellipsis,
                        style: JoFonts.ui.copyWith(
                          fontSize: 13,
                          color: on || parallelPlace.here ? p.accent : p.text,
                          fontWeight: parallelPlace.here
                              ? FontWeight.w700
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                    if (parallelPlace.here)
                      Text('在此', style: JoFonts.meta.copyWith(color: p.accent)),
                    if (!parallelPlace.isActive)
                      Text(
                        parallelPlace.mergeInto.isEmpty ? '已关闭' : '已合并',
                        style: JoFonts.meta.copyWith(color: p.secondary),
                      ),
                    if (on) ...<Widget>[
                      const SizedBox(width: 6),
                      Text('▲', style: JoFonts.meta.copyWith(color: p.accent)),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      );
    }
    // 地点列表最右边那一格：加地点。放在画布内，跟列头同一行。
    if (_timelineSnapshot == null) {
      out.add(
        Positioned(
          left: _totalW,
          top: 10,
          width: _addPlaceW,
          height: kHeaderH - 14,
          child: Center(
            child: JoButton(text: '添加地点', onTap: _addParallelPlaceManually),
          ),
        ),
      );
    }
    return out;
  }

  List<Widget> _steps(JoPalette p, Map<String, double> colX) {
    final List<Widget> out = <Widget>[];
    for (final ParallelPlace parallelPlace in _displayWorld.parallelPlaces) {
      final List<int> r = _rows[parallelPlace.id]!;
      for (int i = 0; i < parallelPlace.events.length; i++) {
        final bool on = _focused == parallelPlace.id && _selected == i;
        // 这张卡现在多出来的高度（动画值；没在长 / 没收过就是 0）。
        final double extra = _extra.of(parallelPlace.id, r[i]);
        out.add(
          Positioned(
            left: colX[parallelPlace.id]!,
            top: _rowTop(r[i]),
            width: _colW(parallelPlace.id),
            // 选中的那张拉高 —— 否则正文看不全（卡片高固定 92）。
            // 高度是动画值；**边框按这个高度画**，所以长高的过程中
            // 扩出去的那一段也有轮廓（以前外面裁一刀，那一段没边框）。
            height: kCardH + extra,
            child: GestureDetector(
              onSecondaryTap: () => _openRoundActions(parallelPlace.id, i),
              onLongPress: () => _openRoundActions(parallelPlace.id, i),
              child: _StepCard(
              key: ValueKey<String>('card-${parallelPlace.id}-${r[i]}'),
              palette: p,
              settings: widget.settings,
              store: widget.store,
              event: parallelPlace.events[i],
              onOpenAttachment: (AssetRecord a) {
                unawaited(_openAttachment(a));
              },
              focused: _focused == parallelPlace.id,
              selected: on,
              // 内容按“展开后应有高度”排，露出多少由卡片自己裁：
              // 收回去的时候内容不会半路重排，不会抽。
              contentHeight: math.max(
                kCardH + (on ? _selExtra : 0),
                kCardH + extra,
              ),
              extra: extra,
              // 只有选中的那张需要把正文真实高度报回来。
              onBodySize: on
                  ? (double h) => _setBodyHeight(parallelPlace.id, r[i], h)
                  : null,
              onTap: () => _focusParallelPlace(parallelPlace.id, index: i),
              ),
            ),
          ),
        );
      }
    }
    return out;
  }
}

/// 正文编辑框。
///
/// 用 `EditableText`（项目一直用它，不用 Material 的 TextField）。
/// **失焦时**把改后的文字交回去 —— 没有保存按钮，也不会“关掉就丢”。
class _BodyEditor extends StatefulWidget {
  const _BodyEditor({
    required this.text,
    required this.style,
    required this.onDone,
  });

  final String text;
  final TextStyle style;
  final ValueChanged<String> onDone;

  @override
  State<_BodyEditor> createState() => _BodyEditorState();
}

class _BodyEditorState extends State<_BodyEditor> {
  late final TextEditingController _c = TextEditingController(
    text: widget.text,
  );
  final FocusNode _f = FocusNode();

  @override
  void initState() {
    super.initState();
    _f.addListener(() {
      if (!_f.hasFocus && _c.text != widget.text) widget.onDone(_c.text);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    _f.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final JoPalette p = JoTheme.of(context);
    return Container(
      padding: const EdgeInsets.all(JoSpace.s2),
      decoration: BoxDecoration(border: Border.all(color: p.border)),
      child: JoTextField(
        controller: _c,
        focusNode: _f,
        maxLines: null,
        style: widget.style,
        verticalPadding: 0,
      ),
    );
  }
}

// ————————————————————————————— 顶栏

/// 没有玩家的世界没有“交互点”可等：同一个档位在界面上显示成“自动”。
String _runModeLabel(String mode, bool playerless) =>
    mode == '直到交互点' && playerless ? '自动' : mode;

/// 加地点的小弹窗。
///
/// 控制器必须由这个 State 自己持有：以前是在外面 new 一个、`showDialog` 一返回就
/// `dispose()`，关窗动画还在播、输入框还要读控制器，debug 下直接报
/// “A TextEditingController was used after being disposed”。
class _AddPlaceDialog extends StatefulWidget {
  const _AddPlaceDialog();

  @override
  State<_AddPlaceDialog> createState() => _AddPlaceDialogState();
}

class _AddPlaceDialogState extends State<_AddPlaceDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加地点'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: '地点名称，例如：仓房'),
        onSubmitted: (String v) => Navigator.of(context).pop(v),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('添加'),
        ),
      ],
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.palette,
    required this.worldName,
    required this.mode,
    required this.busy,
    required this.playerless,
    required this.onMode,
    required this.modeKey,
    required this.onHistory,
    required this.povLabel,
    required this.onPov,
  });

  final JoPalette palette;
  final String worldName;

  /// 推进方式：单步 / 单回合 / 直到交互点。只管手动推进（发送 / 回车）这一下。
  final String mode;

  /// 引擎在跑：按钮上写“跑着……”。
  final bool busy;

  /// 这个世界没有玩家：没有交互点可等，“直到交互点”显示成“自动”。
  final bool playerless;

  final ValueChanged<String> onMode;
  final GlobalKey modeKey;
  final VoidCallback onHistory;
  final String povLabel;
  final VoidCallback onPov;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = palette;
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: JoSpace.s4),
      decoration: BoxDecoration(border: Border(bottom: JoShape.side(p.border))),
      child: Row(
        children: <Widget>[
          // 用 Expanded 而不是 Flexible + Spacer：
          // 那两个各占一半剩余空间，会把按钮挤到中间。
          Expanded(
            child: Text(
              worldName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: JoFonts.ui.copyWith(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: p.text,
              ),
            ),
          ),
          // 下拉：当前方式写在按钮上，点开选别的。
          KeyedSubtree(
            key: modeKey,
            child: JoButton(
              text: '${busy ? '推演中…' : _runModeLabel(mode, playerless)} ▾',
              onTap: () =>
                  _openRunModeMenu(context, modeKey, mode, onMode, playerless),
              color: p.accent,
              tip: playerless
                  ? '推进方式：点击发送后本次推演的推进范围。'
                      '没有玩家角色时，“直到交互点”等同“自动”，会持续推演，直到没有可推进的工作或达到回合上限。'
                  : '推进方式：点击发送后本次推演的推进范围。'
                      '切换到其他时间线后，原线如何继续，见“设置 → 行为 → 后台推演”。',
            ),
          ),
          const SizedBox(width: JoSpace.s2),
          JoButton(text: '时间线', onTap: onHistory),
        ],
      ),
    );
  }
}

/// 推进方式的下拉菜单：自己画的小浮层，不走 Material 那套。
void _openRunModeMenu(
  BuildContext context,
  GlobalKey buttonKey,
  String value,
  ValueChanged<String> onPick,
  bool playerless,
) {
  // 按**按钮的实际位置**算，别写死：写死的值一换布局/一缩窗口就错位。
  final RenderBox? box =
      buttonKey.currentContext?.findRenderObject() as RenderBox?;
  final Offset at = box?.localToGlobal(Offset.zero) ?? Offset.zero;
  final Size boxSize = box?.size ?? Size.zero;
  final OverlayState overlay = Overlay.of(context);
  late OverlayEntry entry;
  void close() => entry.remove();
  entry = OverlayEntry(
    builder: (BuildContext c) {
      final JoPalette p = JoTheme.of(c);
      // Overlay 的 entry **不保证给尺寸**，而下面全是 Positioned：
      // 不给个明确尺寸的话约束会变成无限大，整层布局直接失败
      // （表现为"点了没反应"）。所以这里先撑满整个窗口。
      final Size size = MediaQuery.of(c).size;
      return SizedBox(
        width: size.width,
        height: size.height,
        child: Stack(
          children: <Widget>[
            // 点外面就收起
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: close,
                child: const SizedBox.shrink(),
              ),
            ),
            Positioned(
              // 贴在按钮下沿
              top: at.dy + boxSize.height + 6,
              left: at.dx,
              child: Container(
                padding: const EdgeInsets.all(JoSpace.s1),
                decoration: BoxDecoration(
                  color: p.bg,
                  border: JoShape.border(p.border),
                  borderRadius: JoShape.br,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  // 这里**不能**用 stretch：Positioned 只给了 top/right，
                  // 宽度是无约束的，"拉伸"就等于拉伸到无限宽 → 断言 + 撑不出尺寸。
                  // 让它按内容自适应就行。
                  children: <Widget>[
                    for (final String m in _WorkspaceState.kRunModes)
                      JoTap(
                        onTap: () {
                          close();
                          onPick(m);
                        },
                        opaque: false,
                        builder: (BuildContext context, bool hover, bool down) {
                          final bool on = m == value;
                          return AnimatedContainer(
                            duration: kJoTapMs,
                            curve: Curves.easeOut,
                            padding: const EdgeInsets.symmetric(
                              horizontal: JoSpace.s3,
                              vertical: JoSpace.s2,
                            ),
                            decoration: BoxDecoration(
                              color: on ? p.surface : Colors.transparent,
                              border: JoShape.border(
                                on || hover ? p.accent : Colors.transparent,
                              ),
                              borderRadius: JoShape.br,
                            ),
                            child: AnimatedDefaultTextStyle(
                              duration: kJoTapMs,
                              curve: Curves.easeOut,
                              style: JoFonts.meta.copyWith(
                                color: on ? p.accent : p.secondary,
                              ),
                              child: Text(_runModeLabel(m, playerless)),
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
  overlay.insert(entry);
}

/// 搜索源的上拉菜单：工具栏贴着窗口底，所以菜单往上开。
void _openSearchSourceMenu(
  BuildContext context,
  GlobalKey buttonKey,
  WorldSearchSource value,
  ValueChanged<WorldSearchSource> onPick,
  VoidCallback onSearch,
) {
  _openUpMenu(context, buttonKey, <_UpMenuItem>[
    for (final WorldSearchSource s in WorldSearchSource.values)
      (label: s.label, on: s == value, onPick: () => onPick(s)),
    (label: '搜索一次…', on: false, onPick: onSearch),
  ]);
}

/// 工具栏上拉菜单的一项。
typedef _UpMenuItem = ({String label, bool on, VoidCallback onPick});

/// 工具栏通用的上拉菜单：贴着按钮往上开，上面放不下就往下开。
void _openUpMenu(
  BuildContext context,
  GlobalKey buttonKey,
  List<_UpMenuItem> items,
) {
  final RenderBox? box =
      buttonKey.currentContext?.findRenderObject() as RenderBox?;
  final Offset at = box?.localToGlobal(Offset.zero) ?? Offset.zero;
  final OverlayState overlay = Overlay.of(context);
  late OverlayEntry entry;
  void close() => entry.remove();
  entry = OverlayEntry(
    builder: (BuildContext c) {
      final JoPalette p = JoTheme.of(c);
      final Size size = MediaQuery.of(c).size;
      Widget row(_UpMenuItem item) {
        final bool on = item.on;
        return JoTap(
          onTap: () {
            close();
            item.onPick();
          },
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
                color: on ? p.surface : Colors.transparent,
                border: JoShape.border(
                  on || hover ? p.accent : Colors.transparent,
                ),
                borderRadius: JoShape.br,
              ),
              child: AnimatedDefaultTextStyle(
                duration: kJoTapMs,
                curve: Curves.easeOut,
                style: JoFonts.meta.copyWith(
                  color: on ? p.accent : p.secondary,
                ),
                child: Text(item.label),
              ),
            );
          },
        );
      }

      return SizedBox(
        width: size.width,
        height: size.height,
        child: Stack(
          children: <Widget>[
            // 点外面就收起
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: close,
                child: const SizedBox.shrink(),
              ),
            ),
            // 用布局代理定位：菜单有多高要等它量完才知道，直接写 top/bottom 会算错。
            Positioned.fill(
              child: CustomSingleChildLayout(
                delegate: _UpMenuLayout(anchor: at),
                child: Container(
                  padding: const EdgeInsets.all(JoSpace.s1),
                  decoration: BoxDecoration(
                    color: p.bg,
                    border: JoShape.border(p.border),
                    borderRadius: JoShape.br,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      for (final _UpMenuItem item in items) row(item),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
  overlay.insert(entry);
}

/// 上拉菜单的摆放：先量出菜单自己的高度，再顶到锚点上方；上面放不下就改往下开。
class _UpMenuLayout extends SingleChildLayoutDelegate {
  _UpMenuLayout({required this.anchor});

  final Offset anchor;

  /// 菜单和锚点之间留的空。
  static const double gap = 6;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final double maxX =
        (size.width - childSize.width).clamp(0.0, double.infinity).toDouble();
    final double x = anchor.dx.clamp(0.0, maxX).toDouble();
    final double above = anchor.dy - childSize.height - gap;
    final double top = above >= 0 ? above : anchor.dy + gap;
    return Offset(x, top);
  }

  @override
  bool shouldRelayout(_UpMenuLayout oldDelegate) =>
      oldDelegate.anchor != anchor;
}

// ————————————————————————————— 左：世界列表

class _WorldRail extends StatelessWidget {
  const _WorldRail({
    required this.palette,
    required this.worlds,
    required this.currentId,
    required this.lastPlayedOf,
    required this.onPick,
    required this.onNew,
    required this.onEdit,
    required this.isDark,
    required this.onSettings,
    required this.onTheme,
  });

  final JoPalette palette;
  final List<World> worlds;
  final String currentId;
  final String? Function(String worldId) lastPlayedOf;
  final ValueChanged<String> onPick;
  final VoidCallback onNew;
  final ValueChanged<World> onEdit;
  final bool isDark;
  final VoidCallback onSettings;
  final VoidCallback onTheme;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = palette;
    return Container(
      color: p.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              JoSpace.s4,
              JoSpace.s4,
              JoSpace.s2,
              JoSpace.s2,
            ),
            child: Row(
              children: <Widget>[
                Text(
                  '世界',
                  style: JoFonts.meta.copyWith(
                    color: p.secondary,
                    letterSpacing: 2,
                  ),
                ),
                const Spacer(),
                JoButton(text: '＋ 新建世界', onTap: onNew, color: p.accent),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: JoSpace.s2),
              children: <Widget>[
                for (final World w in worlds)
                  _WorldTile(
                    palette: p,
                    world: w,
                    lastPlayed: lastPlayedOf(w.id),
                    on: w.id == currentId,
                    onTap: () => onPick(w.id),
                    onEdit: () => onEdit(w),
                  ),
              ],
            ),
          ),
          Container(
            decoration: BoxDecoration(
              border: Border(top: JoShape.side(p.border)),
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: JoSpace.s3,
              vertical: JoSpace.s2,
            ),
            child: Row(
              children: <Widget>[
                // 左下角只剩一个：进设置。
                // 主题切换**不摆在这儿** —— 它要选“跟随系统 / 暗 / 明”三态，
                // 那是设置 → 外观 的事，放这里名不正言不顾。
                JoIconAction(
                  icon: JoIcons.settings,
                  tip: '设置',
                  onTap: onSettings,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 世界卡片上的“上次游玩”短标签；解析不了就返回 null。
String? _shortPlayed(String? iso) {
  if (iso == null || iso.trim().isEmpty) return null;
  final DateTime? parsed = DateTime.tryParse(iso);
  if (parsed == null) return null;
  final DateTime t = parsed.toLocal();
  final DateTime now = DateTime.now();
  final String hh = t.hour.toString().padLeft(2, '0');
  final String mm = t.minute.toString().padLeft(2, '0');
  final String hm = '$hh:$mm';
  final DateTime today = DateTime(now.year, now.month, now.day);
  final DateTime day = DateTime(t.year, t.month, t.day);
  final int delta = today.difference(day).inDays;
  if (delta == 0) return '今天 $hm';
  if (delta == 1) return '昨天 $hm';
  if (t.year == now.year) return '${t.month}-${t.day} $hm';
  return '${t.year}-${t.month}-${t.day} $hm';
}

class _WorldTile extends StatelessWidget {
  const _WorldTile({
    required this.palette,
    required this.world,
    required this.lastPlayed,
    required this.on,
    required this.onTap,
    required this.onEdit,
  });

  final JoPalette palette;
  final World world;
  final String? lastPlayed;
  final bool on;
  final VoidCallback onTap;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = palette;
    final String? played = _shortPlayed(lastPlayed);
    final String subtitle = played == null
        ? world.note
        : (world.note.trim().isEmpty
              ? '上次 $played'
              : '${world.note} · 上次 $played');
    return Padding(
      padding: const EdgeInsets.only(bottom: JoSpace.s2),
      child: JoTap(
        onTap: onTap,
        builder: (BuildContext context, bool hover, bool down) {
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
                  : (hover ? p.surface.withValues(alpha: 0.5) : p.bg),
              border: JoShape.border(on || hover ? p.accent : p.border),
              borderRadius: JoShape.br,
            ),
            child: Row(
              // 名字 + 副标题在左，铅笔在右、上下居中；
              // 铅笔跟右栏底部那个是同一个图标，点开也是同一张弹窗。
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        world.name,
                        overflow: TextOverflow.ellipsis,
                        style: JoFonts.ui.copyWith(
                          fontSize: 13,
                          color: on ? p.accent : p.text,
                          fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        overflow: TextOverflow.ellipsis,
                        style: JoFonts.meta.copyWith(
                          color: p.secondary,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: JoSpace.s2),
                JoIconAction(
                  icon: JoIcons.pencil,
                  tip: '编辑这个世界',
                  size: 18,
                  onTap: onEdit,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ————————————————————————————— 右：侧栏

class _SidePanel extends StatelessWidget {
  const _SidePanel({
    required this.palette,
    required this.settings,
    required this.world,
    required this.focusedParallelPlace,
    required this.selectedEvent,
    required this.selectedIndex,
    required this.store,
    required this.onClear,
    required this.onEditText,
    required this.onReadStep,
    required this.onStopRead,
    required this.onPauseRead,
    required this.reading,
    required this.readPaused,
    required this.readStatus,
    this.onRollback,
    this.flowActive,
    this.flowDone = const <String>{},
    this.flowOpen = false,
    this.liveText = '',
    this.onToggleFlow,
    this.sideScroll,
    this.onStoredSteps,
  });

  final JoPalette palette;
  final JoSettings settings;
  final World world;
  final ParallelPlace? focusedParallelPlace;
  final TurnStep? selectedEvent;
  final int? selectedIndex;
  final WorldStore store;
  final VoidCallback onClear;

  /// 右栏里也放一个回退入口，避免顶栏按钮太窄点错。
  final VoidCallback? onRollback;

  /// 右栏改了正文之后交回给上层（存库 + 刷新）。
  /// 参数：序列 id、画布上的步序、新正文。
  final void Function(String parallelPlaceId, int index, String text)
  onEditText;

  /// 读选中这一步的正文（整段一次合成，句中不换声线）。
  final VoidCallback onReadStep;
  final VoidCallback onStopRead;
  final VoidCallback onPauseRead;
  final bool reading;
  final bool readPaused;
  final String readStatus;

  /// 流程图：正在跑的步骤、跑过的步骤。
  final String? flowActive;
  /// 流式时正在写出来的正文（只给眼睛看）。
  final String liveText;
  final Set<String> flowDone;

  /// 流程图展开着没有，以及点标题时怎么切。
  final bool flowOpen;
  final VoidCallback? onToggleFlow;
  final VoidCallback? onStoredSteps;

  /// 右栏自己的滚动：展开流程图后整个右栏一起滚（推演开始时滚回顶部）。
  final ScrollController? sideScroll;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = palette;
    final TurnStep? e = selectedEvent;
    final ParallelPlace? parallelPlace = focusedParallelPlace;

    return Container(
      color: p.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.fromLTRB(
              JoSpace.s4,
              JoSpace.s4,
              JoSpace.s3,
              JoSpace.s2,
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    e != null
                        ? '这一步'
                        : (parallelPlace != null ? '这个地点' : '这个世界'),
                    style: JoFonts.meta.copyWith(
                      color: p.secondary,
                      letterSpacing: 2,
                    ),
                  ),
                ),
                if (e != null || parallelPlace != null)
                  Padding(
                    padding: const EdgeInsets.only(left: JoSpace.s3),
                    child: JoTooltip(
                      text: e != null ? '取消选中这一步' : '取消选中这个地点',
                      child: GestureDetector(
                        onTap: onClear,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: Text(
                            '×',
                            style: JoFonts.meta.copyWith(color: p.secondary),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // 回合流程图：默认收起成一行；点开就把整张图展开——
          // **不覆盖也不挤走**后边的内容，详情顺着往下排，整个右栏一起滚。
          Expanded(
            child: ListView(
              key: const ValueKey<String>('side-scroll'),
              controller: sideScroll,
              children: <Widget>[
                TurnFlow(
                  palette: p,
                  active: flowActive,
                  done: flowDone,
                  expanded: flowOpen,
                  liveText: liveText,
                  onToggle: onToggleFlow ?? () {},
                ),
                if (onStoredSteps != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: JoSpace.s4),
                    child: JoButton(text: 'AI 步骤', onTap: onStoredSteps!),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    JoSpace.s4,
                    JoSpace.s3,
                    JoSpace.s4,
                    JoSpace.s4,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      if (e != null)
                        ..._stepDetail(p, parallelPlace!, e)
                      else if (parallelPlace != null)
                        ..._parallelPlaceDetail(p, parallelPlace)
                      else
                        ..._worldDetail(p),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _stepDetail(
    JoPalette p,
    ParallelPlace parallelPlace,
    TurnStep e,
  ) {
    return <Widget>[
      _kv(p, '谁', e.who),
      _kv(p, '时间标签', e.time),
      _kv(p, '地点', parallelPlace.place),
      _kv(p, '步序', '第 ${(selectedIndex ?? 0) + 1} 步'),
      const SizedBox(height: JoSpace.s4),
      Text('正文', style: JoFonts.meta.copyWith(color: p.secondary)),
      const SizedBox(height: JoSpace.s2),
      _BodyEditor(
        text: e.text,
        style: settings.bodyStyle(p.text),
        onDone: (String v) =>
            onEditText(parallelPlace.id, selectedIndex ?? 0, v),
      ),
      const SizedBox(height: JoSpace.s3),
      Row(
        children: <Widget>[
          JoButton(
            text: reading ? '朗读中…' : '朗读这一步',
            bordered: true,
            onTap: reading ? () {} : onReadStep,
          ),
          const SizedBox(width: JoSpace.s2),
          if (reading)
            JoButton(
              text: readPaused ? '继续' : '暂停',
              bordered: true,
              onTap: onPauseRead,
            ),
          if (reading) const SizedBox(width: JoSpace.s2),
          JoButton(
            text: '停止',
            bordered: true,
            onTap: reading ? onStopRead : () {},
          ),
        ],
      ),
      if (readStatus.isNotEmpty) ...<Widget>[
        const SizedBox(height: JoSpace.s2),
        Text(
          readStatus,
          style: JoFonts.meta.copyWith(color: p.secondary, height: 1.7),
        ),
      ],
      if (e.attachmentIds.isNotEmpty) ...<Widget>[
        const SizedBox(height: JoSpace.s4),
        Text('附件', style: JoFonts.meta.copyWith(color: p.secondary)),
        const SizedBox(height: JoSpace.s2),
        Wrap(
          spacing: JoSpace.s3,
          runSpacing: JoSpace.s2,
          children: _attachmentTiles(p, e.attachmentIds),
        ),
      ],
      // —— 过程：框了谁、谁感知到什么、最后选中谁 ——
      if (e.candidates.isNotEmpty) ...<Widget>[
        const SizedBox(height: JoSpace.s4),
        Text('候选参与', style: JoFonts.meta.copyWith(color: p.secondary)),
        const SizedBox(height: JoSpace.s2),
        Text(e.candidates.join('、'), style: settings.bodyStyle(p.text)),
      ],
      if (e.chosen.isNotEmpty) ...<Widget>[
        const SizedBox(height: JoSpace.s4),
        Text('选中', style: JoFonts.meta.copyWith(color: p.secondary)),
        const SizedBox(height: JoSpace.s2),
        Text(e.chosen, style: settings.bodyStyle(p.text)),
      ],
      if (e.perceptions.isNotEmpty) ...<Widget>[
        const SizedBox(height: JoSpace.s4),
        Text('感知', style: JoFonts.meta.copyWith(color: p.secondary)),
        for (final MapEntry<String, String> m
            in e.perceptions.entries) ...<Widget>[
          const SizedBox(height: JoSpace.s3),
          Text(m.key, style: JoFonts.meta.copyWith(color: p.text)),
          const SizedBox(height: JoSpace.s1),
          Text(m.value, style: settings.bodyStyle(p.text)),
        ],
      ],
      if (e.judgment.isNotEmpty) ...<Widget>[
        const SizedBox(height: JoSpace.s4),
        Text('判断', style: JoFonts.meta.copyWith(color: p.secondary)),
        const SizedBox(height: JoSpace.s2),
        Text(e.judgment, style: settings.bodyStyle(p.text)),
      ],
      if (e.usage != null) ...<Widget>[
        const SizedBox(height: JoSpace.s4),
        Text(
          '用量：输入 ${e.usage!.input} · 输出 ${e.usage!.output} · 缓存命中 ${e.usage!.cacheHit}',
          style: JoFonts.meta.copyWith(color: p.secondary),
        ),
      ],
      if (onRollback != null) ...<Widget>[
        const SizedBox(height: JoSpace.s4),
        JoButton(text: '退回上一回合', onTap: onRollback!),
      ],
    ];
  }

  List<Widget> _attachmentTiles(JoPalette p, List<String> ids) {
    final List<Widget> out = <Widget>[];
    for (final String id in ids) {
      final AssetRecord? a = store.findAsset(id);
      if (a != null) out.add(_attachmentTile(p, a));
    }
    return out;
  }

  Widget _attachmentTile(JoPalette p, AssetRecord a) {
    return SizedBox(
      width: 72,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: p.surface,
              border: JoShape.border(p.border),
              borderRadius: JoShape.br,
            ),
            clipBehavior: Clip.antiAlias,
            child: a.kind == 'image'
                ? Image.file(
                    store.assetFile(a),
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) =>
                        Icon(JoIcons.image, size: 20, color: p.secondary),
                  )
                : Center(
                    child: Icon(JoIcons.file, size: 20, color: p.secondary),
                  ),
          ),
          const SizedBox(height: 2),
          Text(
            a.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: JoFonts.meta.copyWith(color: p.secondary, fontSize: 9),
          ),
        ],
      ),
    );
  }

  List<Widget> _parallelPlaceDetail(JoPalette p, ParallelPlace parallelPlace) {
    final List<String> who = <String>[];
    for (final TurnStep e in parallelPlace.events) {
      if (!e.isNarration && !who.contains(e.who)) who.add(e.who);
    }
    return <Widget>[
      _kv(p, '地点', parallelPlace.place),
      _kv(p, '步数', '${parallelPlace.events.length}'),
      _kv(p, '在场', who.isEmpty ? '无人' : who.join('、')),
      if (parallelPlace.here) _kv(p, '操控角色', '在此'),
      const SizedBox(height: JoSpace.s4),
      Text('每一步', style: JoFonts.meta.copyWith(color: p.secondary)),
      const SizedBox(height: JoSpace.s2),
      for (int i = 0; i < parallelPlace.events.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: JoSpace.s2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: 22,
                child: Text(
                  '${i + 1}',
                  style: JoFonts.meta.copyWith(color: p.secondary),
                ),
              ),
              Expanded(
                child: Text(
                  '${parallelPlace.events[i].who} · ${parallelPlace.events[i].text}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: JoFonts.meta.copyWith(color: p.text, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
    ];
  }

  List<Widget> _worldDetail(JoPalette p) {
    int steps = 0;
    for (final ParallelPlace l in world.parallelPlaces) {
      steps += l.events.length;
    }
    return <Widget>[
      _kv(p, '世界', world.name),
      _kv(p, '地点', '${world.parallelPlaces.length}'),
      _kv(p, '事件', '$steps'),
      _kv(p, '换地点', '${world.moves.length}'),
      _kv(p, '角色', '${world.characters.length}'),
      if (world.setting.trim().isNotEmpty) ...<Widget>[
        const SizedBox(height: JoSpace.s3),
        Text('世界观', style: JoFonts.meta.copyWith(color: p.secondary)),
        const SizedBox(height: JoSpace.s2),
        Text(
          world.setting,
          style: settings.bodyStyle(p.text).copyWith(fontSize: 12, height: 1.7),
        ),
      ],
      if (world.opening.trim().isNotEmpty) ...<Widget>[
        const SizedBox(height: JoSpace.s3),
        Text('开场', style: JoFonts.meta.copyWith(color: p.secondary)),
        const SizedBox(height: JoSpace.s2),
        Text(
          world.opening,
          style: settings.bodyStyle(p.text).copyWith(fontSize: 12, height: 1.7),
        ),
      ],
      if (world.characters.isNotEmpty) ...<Widget>[
        const SizedBox(height: JoSpace.s3),
        Text('角色', style: JoFonts.meta.copyWith(color: p.secondary)),
        const SizedBox(height: JoSpace.s2),
        for (final CharCard c in world.characters)
          Padding(
            padding: const EdgeInsets.only(bottom: JoSpace.s3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  c.name,
                  style: JoFonts.ui.copyWith(fontSize: 12, color: p.text),
                ),
                if (c.persona.trim().isNotEmpty)
                  Text(
                    c.persona,
                    style: JoFonts.meta.copyWith(
                      color: p.secondary,
                      height: 1.5,
                    ),
                  ),
              ],
            ),
          ),
      ],
      const SizedBox(height: JoSpace.s4),
      Text(
        '在左侧选择世界，或点击画布上的地点、某一步，这里会显示详细信息。',
        style: JoFonts.meta.copyWith(color: p.secondary, height: 1.6),
      ),
    ];
  }

  Widget _kv(JoPalette p, String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: JoSpace.s3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 62,
            child: Text(k, style: JoFonts.meta.copyWith(color: p.secondary)),
          ),
          Expanded(
            child: Text(
              v,
              style: JoFonts.ui.copyWith(
                color: p.text,
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyWorld extends StatelessWidget {
  const _EmptyWorld({required this.palette});

  final JoPalette palette;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = palette;
    return Center(
      child: Text(
        '当前世界还没有序列',
        style: JoFonts.meta.copyWith(color: p.secondary),
      ),
    );
  }
}

// ————————————————————————————— 步骤卡

class _StepCard extends StatelessWidget {
  const _StepCard({
    super.key,
    required this.palette,
    required this.settings,
    required this.store,
    required this.event,
    required this.focused,
    required this.selected,
    required this.contentHeight,
    required this.extra,
    required this.onTap,
    this.onOpenAttachment,
    this.onBodySize,
  });

  final JoPalette palette;
  final JoSettings settings;
  final WorldStore store;
  final TurnStep event;
  final ValueChanged<AssetRecord>? onOpenAttachment;
  final bool focused;
  final bool selected;

  /// 卡里正文的**真实渲染高度**报回去（只有选中的那张要）。
  final ValueChanged<double>? onBodySize;

  /// 里面内容按多高排版（展开后应有的高度）。
  final double contentHeight;

  /// 现在多出来的高度（动画值）。>0 就还在长 / 还在收。
  final double extra;

  final VoidCallback onTap;

  /// 画布卡右上角的附件缩略图。只给前 3 个，剩下的显示 +N。
  Widget _attachmentStrip(JoPalette p) {
    final List<Widget> out = <Widget>[];
    for (final String id in event.attachmentIds.take(3)) {
      final AssetRecord? a = store.findAsset(id);
      if (a == null) continue;
      if (out.isNotEmpty) out.add(const SizedBox(width: 3));
      final Widget tile;
      if (a.kind == 'image') {
        tile = Image.file(
          store.assetFile(a),
          width: 20,
          height: 20,
          fit: BoxFit.cover,
          cacheWidth: 40,
          errorBuilder:
              (BuildContext context, Object error, StackTrace? stack) =>
                  const SizedBox(width: 20, height: 20),
        );
      } else {
        tile = Container(
          width: 20,
          height: 20,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: p.surface,
            border: JoShape.border(p.border),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Text(
            a.kind == 'pdf' ? 'PDF' : 'T',
            style: JoFonts.meta.copyWith(fontSize: 7, color: p.secondary),
          ),
        );
      }
      out.add(
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onOpenAttachment == null ? null : () => onOpenAttachment!(a),
          child: ClipRRect(borderRadius: BorderRadius.circular(3), child: tile),
        ),
      );
    }
    if (event.attachmentIds.length > 3) {
      if (out.isNotEmpty) out.add(const SizedBox(width: 3));
      out.add(
        Text(
          '+${event.attachmentIds.length - 3}',
          style: JoFonts.meta.copyWith(fontSize: 8, color: p.secondary),
        ),
      );
    }
    return Row(mainAxisSize: MainAxisSize.min, children: out);
  }

  @override
  Widget build(BuildContext context) {
    final JoPalette p = palette;
    // 过渡中不切“紧凑样式”：不然字号、行数会半路跳一下，看着抽。
    final bool compact = !focused && !selected && extra < 1;
    final Color whoColor = event.isNarration ? p.accent : p.text;
    final double pad = compact ? JoSpace.s3 : JoSpace.s4;
    return JoTap(
      onTap: onTap,
      builder: (BuildContext context, bool hover, bool down) {
        return SizedBox.expand(
          child: AnimatedContainer(
            duration: kJoTapMs,
            curve: Curves.easeOut,
            padding: EdgeInsets.all(pad),
            // 高度由外面那层定（动画值），这里只跟着走；
            // 内容按 contentHeight 排，露不出来的部分裁掉。
            clipBehavior: Clip.hardEdge,
            decoration: BoxDecoration(
              color: event.isNarration
                  ? p.accent.withValues(alpha: hover ? 0.11 : 0.06)
                  : (hover ? p.surface.withValues(alpha: 0.92) : p.surface),
              border: JoShape.border(
                selected
                    ? p.accent
                    : (event.isNarration
                          ? p.accent.withValues(alpha: 0.4)
                          : p.border),
              ),
              borderRadius: JoShape.br,
            ),
            child: OverflowBox(
              alignment: Alignment.topLeft,
              minHeight: contentHeight - pad * 2,
              maxHeight: contentHeight - pad * 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          event.who,
                          overflow: TextOverflow.ellipsis,
                          style: JoFonts.meta.copyWith(
                            color: selected ? p.accent : whoColor,
                            fontWeight: event.isNarration
                                ? FontWeight.w400
                                : FontWeight.w600,
                          ),
                        ),
                      ),
                      if (event.attachmentIds.isNotEmpty) ...<Widget>[
                        const SizedBox(width: 6),
                        _attachmentStrip(p),
                      ],
                      Text(
                        event.time,
                        style: JoFonts.meta.copyWith(
                          color: p.secondary,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: compact ? 6 : JoSpace.s3),
                  Expanded(
                    // 正文按 Markdown 画：小卡片只要两行摘要，
                    // 展开的那张才排版（标题/列表/引用/代码/表格/图片）。
                    //
                    // 选中那张会把正文的**真实高度**报回去（`_MeasureSize`），
                    // 否则卡高按纯文字算，长列表/表格会被裁掉一截。
                    // 外面这层裁剪只是**保底**：报上来之前的一帧、或者报得慢一拍，
                    // 也不会把下面的卡顶开。
                    child: ClipRect(
                      child: OverflowBox(
                        alignment: Alignment.topLeft,
                        // **minHeight 必须显式给 0**：不写默认沿用父级的 minHeight
                        // （= 卡片当前给的高度），子控件会被撑到“至少那么高”，
                        // 于是“卡变高 → 量到更高 → 卡再变高”无限循环。
                        minHeight: 0,
                        maxHeight: double.infinity,
                        child: _maybeMeasure(
                          onBodySize,
                          JoMarkdown(
                            data: event.text,
                            compact: compact,
                            style: settings
                                .bodyStyle(p.text)
                                .copyWith(
                                  fontSize: compact
                                      ? settings.bodySize - 3
                                      : settings.bodySize,
                                ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ————————————————————————————— 量尺寸

/// 包一层就是在布局之后把**子控件的真实尺寸**报出来。
///
/// 用途：卡片里的 Markdown 正文到底多高，只有真排一遍才知道；
/// 文字量出来的数在列表/表格面前是不准的。
Widget _maybeMeasure(ValueChanged<double>? onSize, Widget child) =>
    onSize == null ? child : _MeasureSize(onSize: onSize, child: child);

class _MeasureSize extends SingleChildRenderObjectWidget {
  const _MeasureSize({required this.onSize, required Widget super.child});

  final ValueChanged<double> onSize;

  @override
  _RenderMeasureSize createRenderObject(BuildContext context) =>
      _RenderMeasureSize(onSize);

  @override
  void updateRenderObject(BuildContext context, _RenderMeasureSize render) {
    render.onSize = onSize;
  }
}

class _RenderMeasureSize extends RenderProxyBox {
  _RenderMeasureSize(this.onSize);

  ValueChanged<double> onSize;
  double? _last;

  @override
  void performLayout() {
    super.performLayout();
    final double h = size.height;
    if (_last == h) return;
    _last = h;
    // 不能在 layout 里 setState：排完这一帧再报。
    final ValueChanged<double> cb = onSize;
    WidgetsBinding.instance.addPostFrameCallback((_) => cb(h));
  }
}

// ————————————————————————————— 行动输入框上方的工具栏

/// 相机预览 + 拍一张。只拍照，不录像。
// ————————————————————————————— 扫描 PDF 进度

/// PDF OCR 的非阻塞进度框；只显示状态，真正的取消由调用方处理。
class _PdfOcrProgressDialog extends StatelessWidget {
  const _PdfOcrProgressDialog({required this.progress, required this.onCancel});

  final ValueNotifier<String> progress;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = JoTheme.of(context);
    return Dialog(
      backgroundColor: p.bg,
      shape: const RoundedRectangleBorder(),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(JoSpace.s4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '扫描版 PDF',
                style: JoFonts.ui.copyWith(fontSize: 14, color: p.text),
              ),
              const SizedBox(height: JoSpace.s3),
              ValueListenableBuilder<String>(
                valueListenable: progress,
                builder: (BuildContext context, String value, Widget? child) {
                  return Text(
                    value,
                    style: JoFonts.ui.copyWith(
                      fontSize: 12,
                      color: p.secondary,
                    ),
                  );
                },
              ),
              const SizedBox(height: JoSpace.s2),
              Text(
                '文字识别在本机完成，PDF 不会上传。',
                style: JoFonts.meta.copyWith(color: p.secondary),
              ),
              const SizedBox(height: JoSpace.s4),
              Align(
                alignment: Alignment.centerRight,
                child: JoButton(text: '取消识别', onTap: onCancel),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ————————————————————————————— 搜索输入

/// 世界搜索面板的一次性查询输入。
class _SearchQueryDialog extends StatefulWidget {
  const _SearchQueryDialog({required this.palette, required this.source});

  final JoPalette palette;
  final WorldSearchSource source;

  @override
  State<_SearchQueryDialog> createState() => _SearchQueryDialogState();
}

class _SearchQueryDialogState extends State<_SearchQueryDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final JoPalette p = widget.palette;
    return Dialog(
      backgroundColor: p.bg,
      shape: const RoundedRectangleBorder(),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(JoSpace.s4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '搜索 · ${widget.source.label}',
                style: JoFonts.ui.copyWith(fontSize: 14, color: p.text),
              ),
              const SizedBox(height: JoSpace.s2),
              Text(
                '查到的内容将作为外部材料，用于下一次环境更新。',
                style: JoFonts.meta.copyWith(color: p.secondary),
              ),
              const SizedBox(height: JoSpace.s3),
              JoInput(
                initial: '',
                hint: '请输入搜索内容',
                onChanged: (String v) => _query = v,
              ),
              const SizedBox(height: JoSpace.s4),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  JoButton(
                    text: '取消',
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: JoSpace.s2),
                  JoButton(
                    text: '搜索',
                    onTap: () {
                      final String q = _query.trim();
                      if (q.isEmpty) return;
                      Navigator.of(context).pop(q);
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CameraDialog extends StatefulWidget {
  const _CameraDialog({
    required this.cameras,
    required this.initialIndex,
    required this.palette,
  });

  final List<cam.CameraDescription> cameras;
  final int initialIndex;
  final JoPalette palette;

  @override
  State<_CameraDialog> createState() => _CameraDialogState();
}

class _CameraDialogState extends State<_CameraDialog> {
  cam.CameraController? _controller;
  String? _error;
  bool _taking = false;
  bool _switching = false;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.cameras.length - 1);
    _init();
  }

  Future<void> _init() async {
    cam.CameraController? controller;
    try {
      controller = cam.CameraController(
        widget.cameras[_index],
        cam.ResolutionPreset.high,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } catch (err) {
      await controller?.dispose();
      if (mounted) setState(() => _error = '$err');
    }
  }

  /// 有多个摄像头时前后翻转；切换期间禁用拍照。
  Future<void> _switchCamera() async {
    if (_switching || _taking || widget.cameras.length < 2) return;
    setState(() {
      _switching = true;
      _error = null;
    });
    final cam.CameraController? old = _controller;
    _controller = null;
    await old?.dispose();
    if (!mounted) return;
    _index = (_index + 1) % widget.cameras.length;
    try {
      await _init();
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  Future<void> _capture() async {
    final cam.CameraController? controller = _controller;
    if (controller == null || _taking) return;
    setState(() => _taking = true);
    try {
      final XFile shot = await controller.takePicture();
      if (mounted) Navigator.of(context).pop(shot);
    } catch (err) {
      if (mounted) {
        setState(() {
          _taking = false;
          _error = '拍照失败：$err';
        });
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final JoPalette p = widget.palette;
    final cam.CameraController? controller = _controller;
    return Dialog(
      backgroundColor: p.bg,
      insetPadding: const EdgeInsets.all(JoSpace.s5),
      child: FractionallySizedBox(
        widthFactor: 0.94,
        heightFactor: 0.92,
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                JoSpace.s4,
                JoSpace.s2,
                JoSpace.s2,
                JoSpace.s2,
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '拍照',
                      style: JoFonts.ui.copyWith(fontSize: 13, color: p.text),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: Padding(
                      padding: const EdgeInsets.all(JoSpace.s2),
                      child: Text(
                        '×',
                        style: JoFonts.ui.copyWith(
                          fontSize: 20,
                          color: p.secondary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ColoredBox(
                color: Colors.black,
                child: controller == null
                    ? Center(
                        child: Text(
                          _error ?? '正在打开摄像头…',
                          textAlign: TextAlign.center,
                          style: JoFonts.ui.copyWith(color: p.secondary),
                        ),
                      )
                    : Center(
                        child: AspectRatio(
                          aspectRatio: controller.value.aspectRatio,
                          child: cam.CameraPreview(controller),
                        ),
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(JoSpace.s3),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  if (widget.cameras.length > 1) ...<Widget>[
                    JoButton(
                      text: _switching ? '切换中…' : '翻转',
                      onTap: () {
                        if (!_switching) _switchCamera();
                      },
                    ),
                    const SizedBox(width: JoSpace.s3),
                  ],
                  JoButton(
                    text: '取消',
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: JoSpace.s3),
                  JoButton(
                    text: _taking ? '保存中…' : '拍照',
                    onTap: () {
                      if (controller != null && !_taking && !_switching) {
                        _capture();
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 行动输入框上方那一条：操控 / 选择 + 插入图片 / OCR图片 / 插入文件 /
/// 拍照 / 世界搜索。
class _ActionToolbar extends StatelessWidget {
  const _ActionToolbar({
    required this.palette,
    required this.controlled,
    required this.controlKey,
    required this.onSwitchControlled,
    required this.onChoices,
    required this.onPickImage,
    required this.onOcrImage,
    required this.onPickFile,
    required this.onCamera,
    required this.searchLabel,
    required this.searchKey,
    required this.onPickSearchSource,
  });

  final JoPalette palette;

  /// 当前由人控制的角色；空 = 全部交给 AI。
  final String controlled;

  /// 操控 chip 的 key：上拉菜单按它的位置算。
  final GlobalKey controlKey;

  /// 在当前操控角色之间切换。
  final VoidCallback onSwitchControlled;

  /// 打开“选择”面板（跟着角色走的那一套）。
  final VoidCallback onChoices;

  final VoidCallback onPickImage;
  final VoidCallback onOcrImage;
  final VoidCallback onPickFile;
  final VoidCallback onCamera;
  final String searchLabel;

  /// 搜索源 chip 的 key：上拉菜单按它的位置算。
  final GlobalKey searchKey;

  /// 点搜索源 chip：开上拉菜单。
  final VoidCallback onPickSearchSource;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = palette;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: JoSpace.s4,
        vertical: JoSpace.s1 + 2,
      ),
      decoration: BoxDecoration(border: Border(top: JoShape.side(p.border))),
      // 一条：操控 [角色 ▾] 选择 [▾] …… [5 个工具图标]
      //
      // 右边五个工具**固定贴右**；左边那一簇（操控 / 选择）占剩下的宽度，
      // 实在放不下就自己懒滚——不会把整条撑溢出。
      child: Row(
        children: <Widget>[
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: <Widget>[
                  KeyedSubtree(
                    key: controlKey,
                    child: _BarChip(
                      palette: p,
                      label: '操控',
                      value: controlled.isEmpty ? 'AI' : controlled,
                      onTap: onSwitchControlled,
                    ),
                  ),
                  const SizedBox(width: JoSpace.s2),
                  _BarChip(
                    palette: p,
                    label: '选择',
                    value: '',
                    onTap: onChoices,
                  ),

                ],
              ),
            ),
          ),
          const SizedBox(width: JoSpace.s3),
          JoIconAction(icon: JoIcons.image, tip: '插入图片', onTap: onPickImage),
          JoIconAction(icon: JoIcons.eye, tip: '识别图片文字', onTap: onOcrImage),
          JoIconAction(icon: JoIcons.file, tip: '插入文件', onTap: onPickFile),
          JoIconAction(icon: JoIcons.camera, tip: '拍照', onTap: onCamera),
          // 世界搜索只有一个入口：点地球开上拉菜单（换搜索源 / 搜一次）。
          JoIconAction(
            key: searchKey,
            icon: JoIcons.global,
            tip: '世界搜索（当前：$searchLabel）',
            onTap: onPickSearchSource,
          ),
        ],
      ),
    );
  }
}

/// 本次玩家输入的附件预览：缩略图 + 文件名 + 删除。
class _AttachmentBar extends StatelessWidget {
  const _AttachmentBar({
    required this.palette,
    required this.assets,
    required this.fileOf,
    required this.onOpen,
    required this.onRemove,
  });

  final JoPalette palette;
  final List<AssetRecord> assets;
  final File Function(AssetRecord) fileOf;
  final ValueChanged<AssetRecord> onOpen;
  final ValueChanged<AssetRecord> onRemove;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = palette;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        JoSpace.s4,
        JoSpace.s2,
        JoSpace.s4,
        JoSpace.s2,
      ),
      decoration: BoxDecoration(border: Border(top: JoShape.side(p.border))),
      child: SizedBox(
        height: 64,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: assets.length,
          separatorBuilder: (_, _) => const SizedBox(width: JoSpace.s3),
          itemBuilder: (BuildContext c, int i) {
            final AssetRecord a = assets[i];
            final File f = fileOf(a);
            return GestureDetector(
              onTap: () => onOpen(a),
              child: Stack(
                children: <Widget>[
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: p.surface,
                      border: JoShape.border(p.border),
                      borderRadius: JoShape.br,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: a.kind == 'image'
                        ? Image.file(
                            f,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => Icon(
                              JoIcons.image,
                              size: 20,
                              color: p.secondary,
                            ),
                          )
                        : Center(
                            child: Icon(
                              JoIcons.file,
                              size: 20,
                              color: p.secondary,
                            ),
                          ),
                  ),
                  Positioned(
                    top: 2,
                    right: 2,
                    child: GestureDetector(
                      onTap: () => onRemove(a),
                      child: Container(
                        width: 16,
                        height: 16,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: p.bg,
                          border: JoShape.border(p.border),
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          '×',
                          style: JoFonts.meta.copyWith(
                            color: p.text,
                            fontSize: 10,
                            height: 1,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 行动输入框上方那种小格子：左边一个小标签，右边一个值，右端一个 ▾。
///
/// 只是为了让“模型 / 选择”两件事看起来是**同一类东西**，
/// 而不是两个颜色不一的文字按钮。
class _BarChip extends StatelessWidget {
  const _BarChip({
    required this.palette,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final JoPalette palette;
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = palette;
    final TextStyle meta = JoFonts.meta.copyWith(fontSize: 10);
    return JoTap(
      onTap: onTap,
      opaque: false,
      builder: (BuildContext c, bool hover, bool down) {
        final bool lit = hover || down;
        return AnimatedContainer(
          duration: kJoTapMs,
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(
            horizontal: JoSpace.s2,
            vertical: 3,
          ),
          decoration: BoxDecoration(
            color: lit ? p.surface : Colors.transparent,
            border: JoShape.border(lit ? p.accent : p.border),
            borderRadius: JoShape.br,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(label, style: meta.copyWith(color: p.secondary)),
              if (value.isNotEmpty) ...<Widget>[
                const SizedBox(width: JoSpace.s2),
                Flexible(
                  child: Text(
                    value,
                    overflow: TextOverflow.ellipsis,
                    style: meta.copyWith(color: p.text),
                  ),
                ),
              ],
              const SizedBox(width: JoSpace.s1),
              Text(
                '▾',
                style: meta.copyWith(
                  color: lit ? p.accent : p.secondary,
                  fontSize: 9,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ————————————————————————————— 输入栏

class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.palette,
    required this.settings,
    required this.controller,
    required this.onSubmit,
    required this.sendKey,
    required this.newlineKey,
    this.readOnly = false,
  });

  final JoPalette palette;
  final JoSettings settings;
  final TextEditingController controller;
  final VoidCallback onSubmit;

  /// 只读：没有操控角色时框还在、发送还能点，但字打不进去。
  final bool readOnly;

  /// “发送”用哪个键（从设置里读）。
  final String sendKey;

  /// “换行”用哪个键（从设置里读）。行动输入框是多行的，两个动作各占一个键。
  final String newlineKey;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = palette;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: JoSpace.s4,
        vertical: JoSpace.s3,
      ),
      child: Row(
        children: <Widget>[
          Text('>', style: JoFonts.meta.copyWith(color: p.accent)),
          const SizedBox(width: JoSpace.s3),
          Expanded(
            child: _JoInput(
              controller: controller,
              settings: settings,
              onSubmit: onSubmit,
              sendKey: sendKey,
              newlineKey: newlineKey,
              readOnly: readOnly,
            ),
          ),
          const SizedBox(width: JoSpace.s2),
          JoIconAction(
            icon: JoIcons.send,
            tip: '发送',
            onTap: onSubmit,
            size: 18,
            inverted: true,
          ),
        ],
      ),
    );
  }
}

class _JoInput extends StatefulWidget {
  const _JoInput({
    required this.controller,
    required this.settings,
    required this.onSubmit,
    required this.sendKey,
    required this.newlineKey,
    this.readOnly = false,
  });

  final TextEditingController controller;
  final JoSettings settings;
  final VoidCallback onSubmit;
  final String sendKey;

  /// 只读：框还在、还能看，但打不进字（没有操控角色时用）。
  final bool readOnly;

  /// “换行”键。行动输入框是多行的，两个动作各占一个键，都能在设置里改。
  final String newlineKey;

  @override
  State<_JoInput> createState() => _JoInputState();
}

class _JoInputState extends State<_JoInput> {
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  /// 在光标处插一个换行（选中的话先替换掉）。
  ///
  /// 两个细节：
  ///   1. 光设 `controller.value` 就够了，但**输入法那边的输出状态还是旧的**，
  ///      光标会留在原处不动。所以下一帧再把选区显式设一次，并保住焦点。
  ///   2. 换行键如果是**裸 Enter**，根本不该走到这里 —— 那就交给输入框自己
  ///      处理（它会把光标、滚动、输入法状态全带对），见 `build`。
  void _insertNewline() {
    final TextEditingValue v = widget.controller.value;
    final TextSelection s = v.selection;
    final int at = s.isValid ? s.start : v.text.length;
    final int end = s.isValid ? s.end : v.text.length;
    final int caret = at + 1;
    widget.controller.value = TextEditingValue(
      text: v.text.replaceRange(at, end, '\n'),
      selection: TextSelection.collapsed(offset: caret),
    );
    _focus.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 输入法可能会把选区推回去；下一帧再钉一次。
      if (widget.controller.selection.baseOffset != caret) {
        widget.controller.selection = TextSelection.collapsed(offset: caret);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final JoSettings s = JoTheme.settingsOf(context);
    // 不用 s.palette —— 那个 getter 已被删除（它算不出跟随系统）。
    final JoPalette p = JoTheme.of(context);
    // “发送”和“换行”都**从设置里读**（设置 → 快捷键）。
    //
    // 框是**多行**的：长句自动折行、框跟着长高（1~6 行，再多自己滚）。
    // 多行框会把回车当换行吃下去，所以两个键都走快捷键表、不靠输入框默认：
    // 填 `Enter` 就是回车发送；要换行就给“换行”绑另一个键。
    final ShortcutActivator? a = joActivator(widget.sendKey);
    final ShortcutActivator? nl = joActivator(widget.newlineKey);
    // 裸 Enter 不绑：让它落到输入框自己手里。多行框自己插换行时，
    // 光标、滚动、输入法状态都是对的；我们自己插入做不到这么齐。
    final bool bareEnterNl = widget.newlineKey.trim().toLowerCase() == 'enter';
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        if (a != null) a: widget.onSubmit,
        if (nl != null && !bareEnterNl) nl: _insertNewline,
      },
      child: JoTextField(
        controller: widget.controller,
        focusNode: _focus,
        autofocus: !widget.readOnly,
        readOnly: widget.readOnly,
        minLines: 1,
        maxLines: 6,
        style: s.bodyStyle(p.text).copyWith(fontSize: 15),
        hint: widget.readOnly ? '当前没有操控角色，全部交由 AI 接管' : '请输入当前操控角色的行动',
        hintStyle: s.bodyStyle(p.secondary).copyWith(fontSize: 15),
        verticalPadding: 2,
      ),
    );
  }
}

// ————————————————————————————— 画布

/// 画布：一列 = 一个地点；列内向下箭头推进；跨列箭头 = 人物换地点（最多两折）。
class _CanvasPainter extends CustomPainter {
  _CanvasPainter({
    required this.palette,
    required this.colX,
    required this.colW,
    required this.headerH,
    required this.cardH,
    required this.rowH,
    required this.extra,
    required this.gap,
    required this.maxRows,
    required this.rows,
    required this.rulerW,
    required this.totalW,
    required this.parallelPlaces,
    required this.moves,
  });

  final JoPalette palette;
  final Map<String, double> colX;
  final double Function(String) colW;
  final double headerH;
  final double cardH;
  final double rowH;

  /// 每张正在变高 / 收回去的卡多出来的高度，键 = （列 id, 行号）。
  /// 拉高的卡片会把下面整体推下去，连线必须算进去，否则会穿在卡片中间。
  final Map<(String, int), double> extra;
  final double gap;
  final int maxRows;
  final Map<String, List<int>> rows;
  final double rulerW;
  final double totalW;
  final List<ParallelPlace> parallelPlaces;
  final List<MoveLink> moves;

  @override
  void paint(Canvas canvas, Size size) {
    // 第 i 行**以上**累计让出去多少（拉高的卡把下面整体推下去）。
    double padAbove(int i) {
      double s = 0;
      for (final MapEntry<(String, int), double> e in extra.entries) {
        if (e.key.$2 < i) s += e.value;
      }
      return s;
    }

    double rowTop(int i) => headerH + i * rowH + padAbove(i);
    // 卡片底边：**只有真正变高的那张**要多加它自己的增量，
    // 别的列同行是正常高度（早先只看行号不看列，于是别的列的连线起点
    // 被抬高，竖段整段悬空、跟源卡断开）。
    double cardBottom(String parallelPlaceId, int i) =>
        rowTop(i) + cardH + (extra[(parallelPlaceId, i)] ?? 0);
    double colCenter(String id) => colX[id]! + colW(id) / 2;

    // —— 地点列底 ——
    final Paint band = Paint()..color = palette.surface.withValues(alpha: 0.55);
    for (final ParallelPlace parallelPlace in parallelPlaces) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            colX[parallelPlace.id]! - 10,
            headerH - 10,
            colW(parallelPlace.id) + 20,
            size.height - headerH + 2,
          ),
          const Radius.circular(8),
        ),
        band,
      );
    }

    // —— 步号 ——
    for (int i = 0; i < maxRows; i++) {
      final TextPainter tp = TextPainter(
        text: TextSpan(
          text: (i + 1).toString().padLeft(2, '0'),
          style: JoFonts.meta.copyWith(color: palette.secondary, fontSize: 11),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset(rulerW - 18 - tp.width, rowTop(i) + cardH / 2 - tp.height / 2),
      );
    }

    // —— 列内：上一步 → 下一步 ——
    final Paint flow = Paint()
      ..color = palette.border
      ..strokeWidth = 1.4;
    for (final ParallelPlace parallelPlace in parallelPlaces) {
      final List<int> r = rows[parallelPlace.id]!;
      for (int i = 0; i + 1 < parallelPlace.events.length; i++) {
        final double cx = colCenter(parallelPlace.id);
        final double y0 = cardBottom(parallelPlace.id, r[i]);
        final double y1 = rowTop(r[i + 1]);
        canvas.drawLine(Offset(cx, y0), Offset(cx, y1 - 9), flow);
        _arrowDown(canvas, Offset(cx, y1), flow.color);
      }
    }

    // —— 跨列：人物换地点。永远只两折 ——
    final Paint move = Paint()
      ..color = palette.accent.withValues(alpha: 0.9)
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;
    for (final MoveLink m in moves) {
      if (!colX.containsKey(m.fromParallelPlace) ||
          !colX.containsKey(m.toParallelPlace))
        continue;
      final List<int>? sr = rows[m.fromParallelPlace];
      final List<int>? dr = rows[m.toParallelPlace];
      if (sr == null || dr == null) continue;
      if (m.fromStep >= sr.length || m.toStep >= dr.length) continue;

      final double srcCx = colCenter(m.fromParallelPlace);
      final double dstCx = colCenter(m.toParallelPlace);
      final double srcBottom = cardBottom(m.fromParallelPlace, sr[m.fromStep]);
      final double dstTop = rowTop(dr[m.toStep]);

      // 水平段走在目标行上方那条空隙里
      final double yH = dstTop - gap / 2;

      canvas.drawPath(
        Path()
          ..moveTo(srcCx, srcBottom)
          ..lineTo(srcCx, yH)
          ..lineTo(dstCx, yH)
          ..lineTo(dstCx, dstTop - 9),
        move,
      );
      _arrowDown(canvas, Offset(dstCx, dstTop), move.color);

      // 标签直接压在横线上：先垫一块跟列底同色的实底，再把字盖上去，
      // 这样横线从字底下穿过而不是贴着字底边。
      // 列底是 surface@55% 叠在 bg 上，填纯 bg 会露出一块更深的补丁，
      // 所以垫底的颜色要按同样的叠法算出来。
      final TextPainter tp = TextPainter(
        text: TextSpan(
          text: '换地点',
          style: JoFonts.meta.copyWith(color: palette.accent, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final Offset labelAt = Offset(
        (srcCx + dstCx) / 2 - tp.width / 2,
        yH - tp.height / 2,
      );
      canvas.drawRect(
        Rect.fromLTWH(
          labelAt.dx - 4,
          labelAt.dy - 1,
          tp.width + 8,
          tp.height + 2,
        ),
        Paint()
          ..color = Color.alphaBlend(
            palette.surface.withValues(alpha: 0.55),
            palette.bg,
          ),
      );
      tp.paint(canvas, labelAt);
    }

    // —— 跨列：合并线。只画“已合并”的源列 → 目标列 ——
    final Paint merge = Paint()
      ..color = palette.secondary.withValues(alpha: 0.9)
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;
    for (final ParallelPlace parallelPlace in parallelPlaces) {
      if (parallelPlace.isActive || parallelPlace.mergeInto.isEmpty) continue;
      if (!colX.containsKey(parallelPlace.id) ||
          !colX.containsKey(parallelPlace.mergeInto)) {
        continue;
      }
      final List<int>? sr = rows[parallelPlace.id];
      final List<int>? dr = rows[parallelPlace.mergeInto];
      if (sr == null || dr == null || sr.isEmpty) continue;
      final int fromRow = sr.last;
      final int toRow = dr.isEmpty ? 0 : dr.first;
      final double srcCx = colCenter(parallelPlace.id);
      final double dstCx = colCenter(parallelPlace.mergeInto);
      final double srcBottom = cardBottom(parallelPlace.id, fromRow);
      final double dstTop = rowTop(toRow);
      final double yH = dstTop - gap / 2;
      canvas.drawPath(
        Path()
          ..moveTo(srcCx, srcBottom)
          ..lineTo(srcCx, yH)
          ..lineTo(dstCx, yH)
          ..lineTo(dstCx, dstTop - 9),
        merge,
      );
      _arrowDown(canvas, Offset(dstCx, dstTop), merge.color);

      final TextPainter tp = TextPainter(
        text: TextSpan(
          text: '并入',
          style: JoFonts.meta.copyWith(color: palette.secondary, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final Offset labelAt = Offset(
        (srcCx + dstCx) / 2 - tp.width / 2,
        yH - tp.height / 2,
      );
      canvas.drawRect(
        Rect.fromLTWH(
          labelAt.dx - 4,
          labelAt.dy - 1,
          tp.width + 8,
          tp.height + 2,
        ),
        Paint()
          ..color = Color.alphaBlend(
            palette.surface.withValues(alpha: 0.55),
            palette.bg,
          ),
      );
      tp.paint(canvas, labelAt);
    }
  }

  void _arrowDown(Canvas canvas, Offset tip, Color color) {
    const double len = 7;
    const double half = 3.5;
    canvas.drawPath(
      Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(tip.dx - half, tip.dy - len)
        ..lineTo(tip.dx + half, tip.dy - len)
        ..close(),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_CanvasPainter old) =>
      old.palette != palette ||
      old.headerH != headerH ||
      old.cardH != cardH ||
      old.rowH != rowH ||
      !_sameExtra(old.extra, extra) ||
      old.maxRows != maxRows ||
      old.totalW != totalW ||
      old.colX.toString() != colX.toString() ||
      old.rows.toString() != rows.toString();

  /// 两张“多出来的高度”表内容一样吗（每帧都会新一双，不能拿引用比）。
  static bool _sameExtra(
    Map<(String, int), double> a,
    Map<(String, int), double> b,
  ) {
    if (a.length != b.length) return false;
    for (final MapEntry<(String, int), double> e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }
}
