import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../data/world_store.dart';
import '../engine/engine.dart';
import '../theme/settings_store.dart';
import '../model/demo.dart';
import '../model/turn.dart';
import '../model/char_choices.dart';
import '../model/llm_client.dart';
import '../model/memory.dart';
import '../model/model_plan.dart';
import '../model/pack_rows.dart';
import '../model/provider.dart';
import '../model/shortcuts.dart';
import '../theme/tokens.dart';
import 'common.dart';
import 'card_extra.dart';
import 'icons.dart';
import 'lane_focus.dart';
import 'char_choices_dialog.dart';
import 'model_plan_dialog.dart';
import 'splitter.dart';
import 'tooltip.dart';
import 'turn_flow.dart';
import 'world_settings.dart';
import 'new_world_dialog.dart';
import 'settings_page.dart';

// —— 画布几何 ——
const double _rulerW = 58; // 左侧步号
const double _padX = 16;
const double _wCompact = 260;
const double _wFocus = 540;
const double _wShrunk = 150;
const double _padBottom = 40;

enum _Page { main, settings }

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
    this.keys = const <String, String>{},
    this.onKeysChanged,
    required this.store,
    this.worlds = const <World>[],
    this.worldsNote,
    this.prompts = const <String, String>{},
    this.onPromptsChanged,
    this.settingsStore,
  });

  /// 全局模型默认（设置 → 引擎里那两级）。
  final ModelPlan globalPlan;
  final ValueChanged<ModelPlan> onGlobalPlanChanged;

  /// 存档读不出来时的提示语（如实说，不藏）。
  final String? servicesNote;
  final String? globalPlanNote;

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
  Size _viewport = Size.zero;

  _Page _page = _Page.main;
  late List<World> _worlds = List<World>.of(widget.worlds);
  late String _worldId = _worlds.isEmpty ? '' : _worlds.first.id;

  /// 两侧栏宽度。**记着的人想要的宽度**，实际画的时候再按窗口收一道，
  /// 所以窗口拉小了不会被撑破，拉回去又能恢复。
  late double _railW = widget.settingsStore?.loadRailW() ?? _kRailDef;
  late double _sideW = widget.settingsStore?.loadSideW() ?? _kSideDef;

  /// 栏宽存盘（松手时调）。
  void _saveWidths() {
    widget.settingsStore?.saveWidths(railW: _railW, sideW: _sideW);
  }

  /// 记忆：按世界分。每份里 key 空 = 上帝，其它 = 角色名。
  /// 现在只是孤立的数据，不接入回合流程。
  final Map<String, Map<String, MemoryBook>> _memory =
      <String, Map<String, MemoryBook>>{};

  /// 底部那个“编辑”按钮**常驻**；编辑与记忆都是弹窗，不占右栏。

  /// 推进方式的循环顺序。点一下切下一个。
  static const List<String> kRunModes = <String>['冻结', '单步', '智能', '全自动'];

  /// 顶栏那个推进按钮的 key，用来算下拉浮层的位置。
  final GlobalKey _modeKey = GlobalKey();

  /// 推进方式。**默认冻结** —— 不动它就不会自己跑。
  /// 现在只记着这个选择，真正的推进要引擎。
  String _mode = '冻结';

  /// 引擎在跑吗。“单步”跑一圈的期间为 true。
  bool _engineBusy = false;

  /// 右栏那张流程图的进度：正在跑哪一步、哪些跑过了。
  String? _flowActive;
  final Set<String> _flowDone = <String>{};

  /// 右栏那张流程图展开着没有。
  ///
  /// 默认收起（只占一行）；推演一开始自动展开，跑完保持展开；
  /// 手动点一下就能收起。
  bool _flowOpen = false;

  /// 右栏的滚动（展开流程图后详情被顶到下面，靠它滚过去；推演开始时滚回顶部看图）。
  final ScrollController _sideScroll = ScrollController();

  /// 角色的“选择”（采样策略 / 最大输出 / 流式 / 推理档位 / JSON）。
  /// 按世界分，世界里再按角色名分——**每个角色各有一套**。
  final Map<String, Map<String, CharChoices>> _choices =
      <String, Map<String, CharChoices>>{};

  /// 每个角色一份模型配置（只管 B₁ / B₂）。
  /// 没设的顺次往下：世界的 B₁/B₂ → 世界默认 → 全局。
  final Map<String, Map<String, ModelPlan>> _charModel =
      <String, Map<String, ModelPlan>>{};

  /// 当前聚焦的列（地点）与选中的事件。
  String? _focused;
  int? _selected;

  /// 每世界的模型配置（世界默认 + 逐步骤）。现在只在内存里。
  final Map<String, ModelPlan> _plans = <String, ModelPlan>{};

  /// 画布上“展开某一列”的过渡。
  ///
  /// **每列各走各的**，所以从 A 换到 B 时，A 一边收回、B 一边展开，
  /// 两个方向同时在动（以前一根全局 0→1 进度条做不到，换列时没动画）。
  final LaneFocus _laneFocus = LaneFocus();

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
    final String? laneId = _focused;
    final int row = _selRow;
    return (laneId != null && row >= 0) ? (laneId, row) : null;
  }

  World get _world {
    for (final World w in _worlds) {
      if (w.id == _worldId) return w;
    }
    return _worlds.first;
  }

  SeqLane? get _focusedLane {
    for (final SeqLane l in _world.lanes) {
      if (l.id == _focused) return l;
    }
    return null;
  }

  TurnStep? get _selectedEvent {
    final SeqLane? lane = _focusedLane;
    if (lane == null || _selected == null) return null;
    if (_selected! < 0 || _selected! >= lane.events.length) return null;
    return lane.events[_selected!];
  }

  /// 排版：每条序列的事件各占一行，且换地点线要经过的格子留空。
  /// 算法在 `packRows`（`model/pack_rows.dart`）里，那边能直接单元测试。
  Map<String, List<int>> get _rows => packRows(_world.lanes, _world.moves);

  int get _maxRows {
    int max = 1;
    for (final SeqLane l in _world.lanes) {
      final List<int> r = _rows[l.id]!;
      if (r.isNotEmpty && r.last + 1 > max) max = r.last + 1;
    }
    return max;
  }

  double get _rowH => kRowH;

  /// 选中的那张卡要额外多高：**按正文量出来**，不钉死。
  ///
  /// 量不出（没选 / 找不到）就是 0，跟原来一样。
  double get _selExtra {
    final String? laneId = _focused;
    final int? idx = _selected;
    if (laneId == null || idx == null) return 0;
    final SeqLane? lane = _world.lanes
        .where((SeqLane x) => x.id == laneId)
        .firstOrNull;
    if (lane == null || idx < 0 || idx >= lane.events.length) return 0;

    final JoPalette p = JoTheme.of(context);
    final double w = _colW(laneId) - JoSpace.s4 * 2;
    // 正文以外的东西全部**实量**：内边距、顶行（谁 + 时间）、行间距、边框。
    // 不拿一个估计的数字蒙。
    const double pad = JoSpace.s4; // 选中时不是 compact，用 s4
    final double bodyW = w;
    final TextPainter bodyTp = TextPainter(
      text: TextSpan(
        text: lane.events[idx].text,
        style: widget.settings.bodyStyle(p.text),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: bodyW);

    final TextPainter rowTp = TextPainter(
      text: TextSpan(
        text: '${lane.events[idx].who}  ${lane.events[idx].time}',
        style: JoFonts.meta.copyWith(color: p.text),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: bodyW);

    final double total =
        bodyTp.height + rowTp.height + JoSpace.s3 + pad * 2 + 2;
    return total > kCardH ? total - kCardH : 0;
  }

  /// 选中那一步在第几行（没有就是 -1）。
  int get _selRow {
    final String? lane = _focused;
    final int? idx = _selected;
    if (lane == null || idx == null) return -1;
    final List<int>? rows = _rows[lane];
    if (rows == null || idx < 0 || idx >= rows.length) return -1;
    return rows[idx];
  }

  /// 列宽：常规 → （有人展开时）收窄 → （自己展开时）整列宽。
  /// 过渡中卡片、表头、**底层连线**都用这一个值算，所以它们一起动、不会错位。
  double _colW(String id) => _laneFocus.width(
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
    bool moving = _laneFocus.advance(dt, _world.lanes.map((SeqLane l) => l.id));

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
    for (final SeqLane l in _world.lanes) {
      map[l.id] = x;
      x += _colW(l.id) + kGap;
    }
    return map;
  }

  double get _totalW {
    double x = _rulerW + _padX;
    for (final SeqLane l in _world.lanes) {
      x += _colW(l.id) + kGap;
    }
    return x;
  }

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
    if (id == _worldId || _switching) return;
    _switching = true;
    // 先清选中：不然淡出的时候还看着上一份的展开卡。
    setState(() {
      _focused = null;
      _selected = null;
      // 列 id 会重名（l1/l2…），旧的动画进度不能带过去。
      _laneFocus.clear();
      _extra.clear();
    });
    await _worldFade.reverse();
    if (!mounted) {
      _switching = false;
      return;
    }
    setState(() => _worldId = id);
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

  /// 世界级的东西只有这一个入口：大编辑弹窗（世界观 / 记忆 / 模型）。
  /// 历史记录。回合历史是**只读的**，但现在还没有存储，所以如实说明。
  Future<void> _openHistory() {
    final JoPalette p = JoTheme.of(context);
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (BuildContext c) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 440,
          padding: const EdgeInsets.all(JoSpace.s4),
          decoration: BoxDecoration(
            color: p.bg,
            border: JoShape.border(p.border),
            borderRadius: JoShape.br,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                '历史记录',
                style: JoFonts.ui.copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: p.text,
                ),
              ),
              const SizedBox(height: JoSpace.s3),
              Text(
                '回合历史是一版一版存下来、只读不回改的。'
                '但现在还没有存储层，所以还看不到。',
                style: JoFonts.meta.copyWith(color: p.secondary, height: 1.7),
              ),
              const SizedBox(height: JoSpace.s4),
              Align(
                alignment: Alignment.centerRight,
                child: JoButton(
                  text: '知道了',
                  onTap: () => Navigator.of(c).pop(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openEdit() async {
    final WorldEditResult? r = await showWorldEditDialog(
      context,
      worldName: _world.name,
      setting: _world.setting,
      opening: _world.opening,
      plan: _plans[_world.id] ?? const ModelPlan(),
      globalPlan: widget.globalPlan,
      groups: _modelGroups,
      books: _memory[_world.id] ?? const <String, MemoryBook>{},
      owners: <String>[for (final CharCard c in _world.characters) c.name],
      characters: _world.characters,
      charModels: _charModel[_world.id] ?? const <String, ModelPlan>{},
      isLastWorld: _worlds.length <= 1,
    );
    if (r == null || !mounted) return;
    final String id = _world.id;
    setState(() {
      if (r.delete) {
        _worlds.removeWhere((World w) => w.id == id);
        widget.store.deleteWorld(id);
        _plans.remove(id);
        _memory.remove(id);
        _choices.remove(id);
        _charModel.remove(id);
        if (_worldId == id && _worlds.isNotEmpty) {
          _worldId = _worlds.first.id;
        }
        _focused = null;
        _selected = null;
        return;
      }
      _plans[id] = r.plan;
      _memory[id] = r.books;
      _charModel[id] = r.charModels;
      for (int i = 0; i < _worlds.length; i++) {
        final World w = _worlds[i];
        if (w.id != id) continue;
        _worlds[i] = World(
          id: w.id,
          name: r.name,
          note: w.note,
          setting: r.setting,
          opening: r.opening,
          characters: r.characters,
          lanes: w.lanes,
          moves: w.moves,
        );
        // 改完就落盘。
        widget.store.saveWorld(_worlds[i]);
      }
    });
  }

  void _focusLane(String id, {int? index}) {
    final bool closing = _focused == id && index == null;
    setState(() {
      _focused = closing ? null : id;
      _selected = closing ? null : index;
    });
    // 各列自己往目标走：新点的那列展开、原来那列收回，两边同时动。
    _laneFocus.focus(closing ? null : id);
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

  /// 发言框那张牌上写什么：这个世界默认用的模型。
  /// 世界默认没设就留空，交给全局默认（全局默认在设置里）。
  String get _worldModelLabel {
    final ModelPick? pick = ModelPick.of(_plans[_world.id]?.defaultRef ?? '');
    if (pick == null) return '';
    for (final Provider pv in widget.providers) {
      if (pv.id == pick.providerId) return '${pv.name} · ${pick.modelId}';
    }
    return pick.modelId;
  }

  /// 一个角色当前用哪个模型，以及那个模型的能力与协议形状。
  ///
  /// **先模型、后选择**：面板拿的就是这个。
  /// 顺序：角色自己 → 世界默认 → 全局总默认。
  ({String label, ModelCaps? caps, ThinkingSpec spec}) _charInfo(String name) {
    const ({String label, ModelCaps? caps, ThinkingSpec spec}) none = (
      label: '未选模型',
      caps: null,
      spec: ThinkingSpec(),
    );

    final ModelPlan? charPlan = _charModel[_world.id]?[name];
    final ModelPlan worldPlan = _plans[_world.id] ?? const ModelPlan();
    // 角色的“自己的模型”就是它的 B₂；没设就顺着往下落。
    final String key = (charPlan?.stepKey('B2') ?? '').isNotEmpty
        ? charPlan!.stepKey('B2')
        : (worldPlan.stepKey('B2').isNotEmpty
              ? worldPlan.stepKey('B2')
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
        );
      }
    }
    return (
      label: '${pick.modelId}（服务商已不在）',
      caps: null,
      spec: const ThinkingSpec(),
    );
  }

  Future<void> _pickCharModel(String name) async {
    final ModelPick? pick = await showModelPicker(
      context,
      groups: _modelGroups,
      current: _charModel[_world.id]?[name]?.stepKey('B2') ?? '',
      clearLabel: '不设（跟随世界默认）',
    );
    if (!mounted) return;
    setState(() {
      final Map<String, ModelPlan> m = <String, ModelPlan>{
        ...?_charModel[_world.id],
      };
      final ModelPlan plan = m[name] ?? const ModelPlan();
      m[name] = plan.withStep('B2', pick?.key ?? '');
      _charModel[_world.id] = m;
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
    setState(() => _choices[_world.id] = next);
  }

  Future<void> _pickModel() async {
    final ModelPlan? next = await showModelPlanDialog(
      context,
      plan: _plans[_world.id] ?? const ModelPlan(),
      globalPlan: widget.globalPlan,
      groups: _modelGroups,
      worldName: _world.name,
    );
    if (next == null || !mounted) return;
    setState(() => _plans[_world.id] = next);
  }

  /// 提交。
  ///
  /// **现在什么都不做** —— 发送还没做（引擎没接，也没有地方存这句话）。
  ///
  /// 以前这里会：清空输入、把聚焦写死到 'l1'、再跑一次展开动画。
  /// 三件全错：清空 = 把用户刚打的字扔掉；'l1' 是写死的列 id；
  /// 展开动画会把整个画布布局换一遍（列宽 260→540、其它列缩到 150），
  /// 平移却没跟着调 → 画面整个移出视野，看着就像"东西全没了"。
  void _submit() {}

  @override
  void dispose() {
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
            providers: widget.providers,
            onProvidersChanged: widget.onProvidersChanged,
            globalPlan: widget.globalPlan,
            onGlobalPlanChanged: widget.onGlobalPlanChanged,
            servicesNote: widget.servicesNote,
            globalPlanNote: widget.globalPlanNote,
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

  /// “单步”：让引擎跑**一次完整流程**（A₀ → AD → A₁ 或角色回合 → A₄）。
  ///
  /// 跑完重新从库里读世界——回合已经写进 step 表了，界面跟着刷新就行。
  Future<void> _runStepOnce() async {
    final Provider? p = widget.providers
        .where(
          (Provider x) =>
              x.enabled && x.apiKey.trim().isNotEmpty && x.models.isNotEmpty,
        )
        .firstOrNull;
    if (p == null) {
      _engineSay('还没有能用的服务商。\n去 设置 → 模型服务 里填一个 API Key。');
      return;
    }
    if (_worlds.isEmpty) return;
    final String laneId =
        _focused ?? (_world.lanes.isEmpty ? '' : _world.lanes.first.id);
    if (laneId.isEmpty) {
      _engineSay('这个世界还没有地点，先加一个。');
      return;
    }

    setState(() => _engineBusy = true);
    // 一次新的推演：进度清空，从第一步开始点灯。
    setState(() {
      _flowDone.clear();
      _flowActive = null;
      // 推演开始：自动展开流程图（跑的时候正要看着它亮）。
      _flowOpen = true;
    });
    // 图在右栏顶部：滚回去，否则上一轮手动滚到下面时就看不到点灯了。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_sideScroll.hasClients) _sideScroll.jumpTo(0);
    });
    try {
      final Engine e = Engine(
        EngineInput(
          store: widget.store,
          provider: p,
          apiKey: p.apiKey,
          world: _world,
          laneId: laneId,
          globalPlan: widget.globalPlan,
          prompts: widget.prompts,
          worldPlan: _plans[_world.id] ?? const ModelPlan(),
          charPlans: _charModel[_world.id] ?? const <String, ModelPlan>{},
          charChoices: _choices[_world.id] ?? const <String, CharChoices>{},
          // 每进一个步骤就把流程图上的灯挪过去。
          onStep: (String id) {
            if (!mounted) return;
            setState(() {
              final String? prev = _flowActive;
              if (prev != null) _flowDone.add(prev);
              _flowActive = id;
            });
          },
          memories: (_memory[_world.id] ?? const <String, MemoryBook>{}).values
              .toList(),
        ),
      );
      final List<TurnStep> out = await e.runTurn();
      if (!mounted) return;
      // 重新读库：回合已经落盘了。
      final WorldsLoad r = widget.store.loadWorlds();
      setState(() => _worlds = r.worlds);

      // 把**新的那一步**指出来：选中它、聚焦那条序列——
      // 否则画布上多了一行，用户不知道哪行是新的。
      final TurnStep? fresh = out
          .where((TurnStep x) => x.showsOnCanvas)
          .lastOrNull;
      int freshIndex = -1;
      if (fresh != null) {
        for (final SeqLane l in _world.lanes) {
          if (l.id != laneId) continue;
          freshIndex = l.events.length - 1;
          if (freshIndex >= 0) {
            setState(() {
              _focused = l.id;
              _selected = freshIndex;
            });
            _laneFocus.focus(l.id);
            _kickFocus();
          }
          break;
        }
      }

      final String body = _summaryOf(out);
      _engineSay(
        freshIndex >= 0 ? '新增的是第 ${freshIndex + 1} 步（已在画布上选中）。\n\n$body' : body,
      );
    } catch (err) {
      if (mounted) _engineSay('引擎出错：$err');
    } finally {
      if (mounted) setState(() => _engineBusy = false);
    }
  }

  /// 把一回合的每一步写成给人看的一段。
  ///
  /// 判断（A0 / AD / A2 / A3 / A4）不上画布，但**必须能看见** ——
  /// 否则引擎跑完，用户不知道它在想什么。
  String _summaryOf(List<TurnStep> steps) {
    final StringBuffer b = StringBuffer();
    for (final TurnStep s in steps) {
      final String who = s.who.isEmpty ? '' : ' · ${s.who}';
      b.writeln('【${s.kind}$who】');
      if (s.judgment.isNotEmpty) b.writeln('  判断：${s.judgment}');
      if (s.candidates.isNotEmpty) b.writeln('  参与：${s.candidates.join('、')}');
      if (s.chosen.isNotEmpty) b.writeln('  选中：${s.chosen}');
      if (s.perceptions.isNotEmpty) {
        for (final MapEntry<String, String> e in s.perceptions.entries) {
          b.writeln('  ${e.key} 感知：${e.value}');
        }
      }
      if (s.text.isNotEmpty) b.writeln('  正文：${s.text}');
      if (!s.ok) b.writeln('  错误：${s.error}');
      final LlmUsage? u = s.usage;
      if (u != null) {
        b.writeln('  用量：入 ${u.input} · 出 ${u.output} · 命中 ${u.cacheHit}');
      }
      b.writeln();
    }
    return b.toString().trimRight();
  }

  /// 改完正文存回去。
  ///
  /// [index] 是**画布上的步序**（只有 A1 / B2 上画布），跟 step 表里
  /// 用同样的过滤顺序对应。
  void _saveStepText(String laneId, int index, String text) {
    widget.store.updateStepText(_world.id, laneId, index, text);
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
                        worldName: _world.name,
                        mode: _engineBusy ? '跑着……' : _mode,
                        onMode: (String v) {
                          setState(() => _mode = v);
                          // “单步”不是选个模式就完了：它是让引擎**跑一次**。
                          if (v == '单步') _runStepOnce();
                        },
                        modeKey: _modeKey,
                        onHistory: _openHistory,
                      ),
                      Expanded(
                        child: _world.lanes.isEmpty
                            ? _EmptyWorld(palette: p)
                            : _canvas(p),
                      ),
                      // 没有玩家角色的话，下面这一整套（模型 / 选择 / 工具 / 输入框）都不摆。
                      if (_world.playerName.isNotEmpty) ...<Widget>[
                        _ComposeBar(
                          palette: p,
                          model: _worldModelLabel,
                          onChoices: _pickChoices,
                          onPickModel: _pickModel,
                        ),
                        // 输入框只在**这个世界有玩家角色**时出现。
                        // 没有玩家角色 = 一切交给 AI，人不用说话。
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
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: JoSpace.s4,
                            vertical: JoSpace.s3,
                          ),
                          child: Text(
                            '这个世界没有玩家角色，全交给 AI —— 所以没有输入框。',
                            style: JoFonts.meta.copyWith(
                              color: p.secondary,
                              fontSize: 10,
                            ),
                          ),
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
                          focusedLane: _focusedLane,
                          selectedEvent: _selectedEvent,
                          selectedIndex: _selected,
                          flowActive: _flowActive,
                          flowDone: _flowDone,
                          flowOpen: _flowOpen,
                          onToggleFlow: () =>
                              setState(() => _flowOpen = !_flowOpen),
                          sideScroll: _sideScroll,
                          onClear: () => setState(() {
                            _focused = null;
                            _selected = null;
                          }),
                        ),
                      ),
                      // 常驻按钮；编辑与记忆都走弹窗。
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
    final double cw = _totalW * s;
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
                    width: _totalW,
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
                              totalW: _totalW,
                              lanes: _world.lanes,
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
    for (final SeqLane lane in _world.lanes) {
      final bool on = _focused == lane.id;
      out.add(
        Positioned(
          left: colX[lane.id]!,
          top: 10,
          width: _colW(lane.id),
          height: kHeaderH - 14,
          child: JoTap(
            onTap: () => _focusLane(lane.id),
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
                      color: lane.here ? p.accent : p.border,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        lane.place,
                        overflow: TextOverflow.ellipsis,
                        style: JoFonts.ui.copyWith(
                          fontSize: 13,
                          color: on || lane.here ? p.accent : p.text,
                          fontWeight: lane.here
                              ? FontWeight.w700
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                    if (lane.here)
                      Text('在此', style: JoFonts.meta.copyWith(color: p.accent)),
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
    return out;
  }

  List<Widget> _steps(JoPalette p, Map<String, double> colX) {
    final List<Widget> out = <Widget>[];
    for (final SeqLane lane in _world.lanes) {
      final List<int> r = _rows[lane.id]!;
      for (int i = 0; i < lane.events.length; i++) {
        final bool on = _focused == lane.id && _selected == i;
        // 这张卡现在多出来的高度（动画值；没在长 / 没收过就是 0）。
        final double extra = _extra.of(lane.id, r[i]);
        out.add(
          Positioned(
            left: colX[lane.id]!,
            top: _rowTop(r[i]),
            width: _colW(lane.id),
            // 选中的那张拉高 —— 否则正文看不全（卡片高固定 92）。
            // 高度是动画值；**边框按这个高度画**，所以长高的过程中
            // 扩出去的那一段也有轮廓（以前外面裁一刀，那一段没边框）。
            height: kCardH + extra,
            child: _StepCard(
              palette: p,
              settings: widget.settings,
              event: lane.events[i],
              focused: _focused == lane.id,
              selected: on,
              // 内容按“展开后应有高度”排，露出多少由卡片自己裁：
              // 收回去的时候内容不会半路重排，不会抽。
              contentHeight: math.max(
                kCardH + (on ? _selExtra : 0),
                kCardH + extra,
              ),
              extra: extra,
              onTap: () => _focusLane(lane.id, index: i),
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

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.palette,
    required this.worldName,
    required this.mode,
    required this.onMode,
    required this.modeKey,
    required this.onHistory,
  });

  final JoPalette palette;
  final String worldName;

  /// 推进方式：冻结（默认，谁都不动）/ 单步 / 智能 / 全自动。
  final String mode;
  final ValueChanged<String> onMode;
  final GlobalKey modeKey;
  final VoidCallback onHistory;

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
              text: '$mode ▾',
              onTap: () => _openRunModeMenu(context, modeKey, mode, onMode),
              color: mode == '冻结' ? null : p.accent,
            ),
          ),
          const SizedBox(width: JoSpace.s2),
          JoButton(text: '历史记录', onTap: onHistory),
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
                              child: Text(m),
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

// ————————————————————————————— 左：世界列表

class _WorldRail extends StatelessWidget {
  const _WorldRail({
    required this.palette,
    required this.worlds,
    required this.currentId,
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

class _WorldTile extends StatelessWidget {
  const _WorldTile({
    required this.palette,
    required this.world,
    required this.on,
    required this.onTap,
    required this.onEdit,
  });

  final JoPalette palette;
  final World world;
  final bool on;
  final VoidCallback onTap;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = palette;
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
                        world.note,
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
    required this.focusedLane,
    required this.selectedEvent,
    required this.selectedIndex,
    required this.onClear,
    required this.onEditText,
    this.flowActive,
    this.flowDone = const <String>{},
    this.flowOpen = false,
    this.onToggleFlow,
    this.sideScroll,
  });

  final JoPalette palette;
  final JoSettings settings;
  final World world;
  final SeqLane? focusedLane;
  final TurnStep? selectedEvent;
  final int? selectedIndex;
  final VoidCallback onClear;

  /// 右栏改了正文之后交回给上层（存库 + 刷新）。
  /// 参数：序列 id、画布上的步序、新正文。
  final void Function(String laneId, int index, String text) onEditText;

  /// 流程图：正在跑的步骤、跑过的步骤。
  final String? flowActive;
  final Set<String> flowDone;

  /// 流程图展开着没有，以及点标题时怎么切。
  final bool flowOpen;
  final VoidCallback? onToggleFlow;

  /// 右栏自己的滚动：展开流程图后整个右栏一起滚（推演开始时滚回顶部）。
  final ScrollController? sideScroll;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = palette;
    final TurnStep? e = selectedEvent;
    final SeqLane? lane = focusedLane;

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
                    e != null ? '这一步' : (lane != null ? '这个地点' : '这个世界'),
                    style: JoFonts.meta.copyWith(
                      color: p.secondary,
                      letterSpacing: 2,
                    ),
                  ),
                ),
                if (e != null || lane != null)
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
                  onToggle: onToggleFlow ?? () {},
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
                        ..._stepDetail(p, lane!, e)
                      else if (lane != null)
                        ..._laneDetail(p, lane)
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

  List<Widget> _stepDetail(JoPalette p, SeqLane lane, TurnStep e) {
    return <Widget>[
      _kv(p, '谁', e.who),
      _kv(p, '时间标签', e.time),
      _kv(p, '地点', lane.place),
      _kv(p, '步序', '第 ${(selectedIndex ?? 0) + 1} 步'),
      const SizedBox(height: JoSpace.s4),
      Text('正文', style: JoFonts.meta.copyWith(color: p.secondary)),
      const SizedBox(height: JoSpace.s2),
      _BodyEditor(
        text: e.text,
        style: settings.bodyStyle(p.text),
        onDone: (String v) => onEditText(lane.id, selectedIndex ?? 0, v),
      ),
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
          '用量：入 ${e.usage!.input} · 出 ${e.usage!.output} · 命中 ${e.usage!.cacheHit}',
          style: JoFonts.meta.copyWith(color: p.secondary),
        ),
      ],
    ];
  }

  List<Widget> _laneDetail(JoPalette p, SeqLane lane) {
    final List<String> who = <String>[];
    for (final TurnStep e in lane.events) {
      if (!e.isNarration && !who.contains(e.who)) who.add(e.who);
    }
    return <Widget>[
      _kv(p, '地点', lane.place),
      _kv(p, '步数', '${lane.events.length}'),
      _kv(p, '在场', who.isEmpty ? '无人' : who.join('、')),
      if (lane.here) _kv(p, '玩家角色', '在此'),
      const SizedBox(height: JoSpace.s4),
      Text('每一步', style: JoFonts.meta.copyWith(color: p.secondary)),
      const SizedBox(height: JoSpace.s2),
      for (int i = 0; i < lane.events.length; i++)
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
                  '${lane.events[i].who} · ${lane.events[i].text}',
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
    for (final SeqLane l in world.lanes) {
      steps += l.events.length;
    }
    return <Widget>[
      _kv(p, '世界', world.name),
      _kv(p, '地点', '${world.lanes.length}'),
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
        '点左边选世界，点画布上的地点或某一步，这里会显示细节。',
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
        '这个世界还没有序列',
        style: JoFonts.meta.copyWith(color: p.secondary),
      ),
    );
  }
}

// ————————————————————————————— 步骤卡

class _StepCard extends StatelessWidget {
  const _StepCard({
    required this.palette,
    required this.settings,
    required this.event,
    required this.focused,
    required this.selected,
    required this.contentHeight,
    required this.extra,
    required this.onTap,
  });

  final JoPalette palette;
  final JoSettings settings;
  final TurnStep event;
  final bool focused;
  final bool selected;

  /// 里面内容按多高排版（展开后应有的高度）。
  final double contentHeight;

  /// 现在多出来的高度（动画值）。>0 就还在长 / 还在收。
  final double extra;

  final VoidCallback onTap;

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
                    child: Text(
                      event.text,
                      style: settings
                          .bodyStyle(p.text)
                          .copyWith(
                            fontSize: compact
                                ? settings.bodySize - 3
                                : settings.bodySize,
                          ),
                      maxLines: compact ? 2 : null,
                      overflow: compact ? TextOverflow.ellipsis : null,
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

// ————————————————————————————— 发言框上方的工具栏

/// 发言框上方那一条：模型选择 + 插入媒体 / 文件 / 拍照 / 联网搜索。
///
/// 现在**只有 UI**：只有“模型选择”能真的在已配置的服务商里挑一个（存内存），
/// 其余四个按钮只做了 hover / 按下，点了还不做事。
class _ComposeBar extends StatelessWidget {
  const _ComposeBar({
    required this.palette,
    required this.model,
    required this.onPickModel,
    required this.onChoices,
  });

  final JoPalette palette;
  final String? model;
  final VoidCallback onPickModel;

  /// 打开“选择”面板（跟着角色走的那一套）。
  final VoidCallback onChoices;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = palette;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: JoSpace.s4,
        vertical: JoSpace.s1 + 2,
      ),
      decoration: BoxDecoration(border: Border(top: JoShape.side(p.border))),
      // 窄窗口下这一条会塞不下（实测 260px 就溢出）。
      // 横向可滚 —— 比默默裁掉强。
      // （下面 Row 的缩进没跟着改，dart format 会收拾。）
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: <Widget>[
            JoButton(
              text: '模型 · ${(model ?? '').trim().isEmpty ? '未选择' : model}',
              onTap: onPickModel,
              color: p.accent,
            ),
            const SizedBox(width: JoSpace.s2),
            JoButton(text: '选择', onTap: onChoices, color: p.accent),
            const SizedBox(width: JoSpace.s2),
            Text(
              '（还没接入）',
              style: JoFonts.meta.copyWith(color: p.secondary, fontSize: 10),
            ),
            // 原先是 Spacer —— 横向滚动里没有约束，Spacer 会炸。
            const SizedBox(width: JoSpace.s5),
            // 这四个从文字换成了图标。悬停浮底色、图标亮一档，不描边 ——
            // 跟界面里其它工具栏一个做法。
            for (final ({IconData icon, String tip}) act
                in const <({IconData icon, String tip})>[
                  (icon: JoIcons.image, tip: '插入媒体'),
                  (icon: JoIcons.file, tip: '插入文件'),
                  (icon: JoIcons.camera, tip: '拍照'),
                  (icon: JoIcons.global, tip: '联网搜索'),
                ])
              JoIconAction(icon: act.icon, tip: act.tip, onTap: () {}),
          ],
        ),
      ),
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
  });

  final JoPalette palette;
  final JoSettings settings;
  final TextEditingController controller;
  final VoidCallback onSubmit;

  /// “发送”用哪个键（从设置里读）。
  final String sendKey;

  /// “换行”用哪个键（从设置里读）。发言框是多行的，两个动作各占一个键。
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
  });

  final TextEditingController controller;
  final JoSettings settings;
  final VoidCallback onSubmit;
  final String sendKey;

  /// “换行”键。发言框是多行的，两个动作各占一个键，都能在设置里改。
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
        autofocus: true,
        minLines: 1,
        maxLines: 6,
        style: s.bodyStyle(p.text).copyWith(fontSize: 15),
        hint: '你要做什么……',
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
    required this.lanes,
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
  final List<SeqLane> lanes;
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
    double cardBottom(String laneId, int i) =>
        rowTop(i) + cardH + (extra[(laneId, i)] ?? 0);
    double colCenter(String id) => colX[id]! + colW(id) / 2;

    // —— 地点列底 ——
    final Paint band = Paint()..color = palette.surface.withValues(alpha: 0.55);
    for (final SeqLane lane in lanes) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            colX[lane.id]! - 10,
            headerH - 10,
            colW(lane.id) + 20,
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
    for (final SeqLane lane in lanes) {
      final List<int> r = rows[lane.id]!;
      for (int i = 0; i + 1 < lane.events.length; i++) {
        final double cx = colCenter(lane.id);
        final double y0 = cardBottom(lane.id, r[i]);
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
      if (!colX.containsKey(m.fromLane) || !colX.containsKey(m.toLane))
        continue;
      final List<int>? sr = rows[m.fromLane];
      final List<int>? dr = rows[m.toLane];
      if (sr == null || dr == null) continue;
      if (m.fromStep >= sr.length || m.toStep >= dr.length) continue;

      final double srcCx = colCenter(m.fromLane);
      final double dstCx = colCenter(m.toLane);
      final double srcBottom = cardBottom(m.fromLane, sr[m.fromStep]);
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
