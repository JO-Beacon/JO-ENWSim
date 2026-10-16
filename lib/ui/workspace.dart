import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/demo.dart';
import '../model/char_choices.dart';
import '../model/memory.dart';
import '../model/model_plan.dart';
import '../model/provider.dart';
import '../model/shortcuts.dart';
import '../theme/tokens.dart';
import 'common.dart';
import 'icons.dart';
import 'char_choices_dialog.dart';
import 'model_plan_dialog.dart';
import 'world_settings.dart';
import 'new_world_dialog.dart';
import 'settings_page.dart';

// —— 画布几何 ——
const double _rulerW = 58; // 左侧步号
const double _padX = 16;
const double _gap = 28; // 列间空隙
const double _headerH = 56;
const double _cardH = 92;
const double _cardGap = 34; // 行间空隙
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
  final List<Provider> providers;
  final ValueChanged<List<Provider>> onProvidersChanged;

  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace>
    with SingleTickerProviderStateMixin {
  final TextEditingController _input = TextEditingController();
  final TransformationController _tc = TransformationController();
  Size _viewport = Size.zero;

  _Page _page = _Page.main;
  late final List<World> _worlds = List<World>.of(DemoData.worlds);
  String _worldId = DemoData.worlds.first.id;
  double _railW = 196;
  double _sideW = 300;

  /// 记忆：按世界分。每份里 key 空 = 上帝，其它 = 角色名。
  /// 现在只是孤立的数据，不接入回合流程。
  final Map<String, Map<String, MemoryBook>> _memory =
      <String, Map<String, MemoryBook>>{};

  /// 底部那个「编辑」按钮**常驻**；编辑与记忆都是弹窗，不占右栏。

  /// 推进方式的循环顺序。点一下切下一个。
  static const List<String> kRunModes = <String>['冻结', '单步', '智能', '全自动'];

  /// 顶栏那个推进按钮的 key，用来算下拉浮层的位置。
  final GlobalKey _modeKey = GlobalKey();

  /// 推进方式。**默认冻结** —— 不动它就不会自己跑。
  /// 现在只记着这个选择，真正的推进要引擎。
  String _mode = '冻结';

  /// 角色的「选择」（采样策略 / 最大输出 / 流式 / 推理档位 / JSON）。
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

  /// 聚焦展开的动画：卡片、表头、底层连线都用同一份插值列宽。
  String? _animId;
  late final AnimationController _focusAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

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

  SeqEvent? get _selectedEvent {
    final SeqLane? lane = _focusedLane;
    if (lane == null || _selected == null) return null;
    if (_selected! < 0 || _selected! >= lane.events.length) return null;
    return lane.events[_selected!];
  }

  /// 排版：每条序列的事件各占一行。
  /// **换地点线要经过的格子必须留空**：不够就把后面的事件整列下移（插空行）。
  Map<String, List<int>> get _rows {
    final Map<String, List<int>> rows = <String, List<int>>{};
    for (final SeqLane l in _world.lanes) {
      rows[l.id] = <int>[for (int i = 0; i < l.events.length; i++) i];
    }
    for (int iter = 0; iter < 64; iter++) {
      bool changed = false;
      for (final MoveLink m in _world.moves) {
        final List<int>? src = rows[m.fromLane];
        final List<int>? dst = rows[m.toLane];
        if (src == null || dst == null) continue;
        if (m.fromStep >= src.length || m.toStep >= dst.length) continue;
        // 竖段从源卡底走到目标行上方那条空隙；源列中间不能有卡
        if (dst[m.toStep] > src[m.fromStep] + 1 &&
            m.fromStep + 1 < src.length &&
            src[m.fromStep + 1] < dst[m.toStep]) {
          for (int k = m.fromStep + 1; k < src.length; k++) {
            src[k] += 1;
          }
          changed = true;
        }
      }
      if (!changed) break;
    }
    return rows;
  }

  int get _maxRows {
    int max = 1;
    for (final SeqLane l in _world.lanes) {
      final List<int> r = _rows[l.id]!;
      if (r.isNotEmpty && r.last + 1 > max) max = r.last + 1;
    }
    return max;
  }

  double get _rowH => _cardH + _cardGap;

  /// 列宽。聚焦过渡中，卡片、表头、**底层连线**都是用这个值算的，
  /// 所以它们会一起动，不会错位。
  /// 列宽。聚焦过渡中，卡片、表头、底层连线都用这个值算，
  /// 所以它们会一起动，不会错位。
  double _colW(String id) {
    if (_animId == null) return _wCompact;
    final double t = Curves.easeOutCubic.transform(_focusAnim.value);
    final double target = id == _animId ? _wFocus : _wShrunk;
    return _wCompact + (target - _wCompact) * t;
  }

  Map<String, double> get _colX {
    final Map<String, double> map = <String, double>{};
    double x = _rulerW + _padX;
    for (final SeqLane l in _world.lanes) {
      map[l.id] = x;
      x += _colW(l.id) + _gap;
    }
    return map;
  }

  double get _totalW {
    double x = _rulerW + _padX;
    for (final SeqLane l in _world.lanes) {
      x += _colW(l.id) + _gap;
    }
    return x;
  }

  double get _totalH => _headerH + _maxRows * _rowH + _padBottom;

  double _rowTop(int i) => _headerH + i * _rowH;

  void _pickWorld(String id) {
    setState(() {
      _worldId = id;
      _focused = null;
      _selected = null;
    });
  }

  Future<void> _newWorld() async {
    final World? w = await showWorldDialog(context);
    if (w == null || !mounted) return;
    setState(() {
      _worlds.add(w);
      _worldId = w.id;
      _focused = null;
      _selected = null;
    });
  }

  /// 卡片上的「编辑」：跟右栏底部那个是**同一个入口** —— 打开编辑弹窗。
  /// 之前它开的是「创建向导」那个合体弹窗，那才是要修的。
  Future<void> _editWorld(World w) async {
    if (w.id != _worldId) setState(() => _worldId = w.id);
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
      owners: <String>[
        for (final CharCard c in _world.characters) c.name,
      ],
      characters: _world.characters,
      charModels:
          _charModel[_world.id] ?? const <String, ModelPlan>{},
      isLastWorld: _worlds.length <= 1,
    );
    if (r == null || !mounted) return;
    final String id = _world.id;
    setState(() {
      if (r.delete) {
        _worlds.removeWhere((World w) => w.id == id);
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
      }
    });
  }

  void _focusLane(String id, {int? index}) {
    final bool closing = _focused == id && index == null;
    setState(() {
      if (closing) {
        _focused = null;
        _selected = null;
        _focusAnim.reverse().whenComplete(() {
          if (mounted && _focused == null) setState(() => _animId = null);
        });
      } else {
        _focused = id;
        _selected = index;
        _animId = id;
        _focusAnim.forward();
      }
    });
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
      out.add((
        providerId: pv.id,
        providerName: pv.name,
        models: ids,
      ));
    }
    return out;
  }

  /// 发言框那张牌上写什么：这个世界默认用的模型。
  /// 世界默认没设就留空，交给全局默认（全局默认在设置里）。
  String get _worldModelLabel {
    final ModelPick? pick =
        ModelPick.of(_plans[_world.id]?.defaultRef ?? '');
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
      characters: <String>[
        for (final CharCard c in _world.characters) c.name,
      ],
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
    _focusAnim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
            onKeysChanged: (Map<String, String> next) =>
                widget.onKeysChanged?.call(next),
            onBack: () => setState(() => _page = _Page.main),
          )
        : _mainPage();
    // 页面切换：160ms 淡入淡出（克制，不做位移 / 缩放）
    // layoutBuilder 给紧约束：里面有 Row + Expanded，默认那个松散 Stack 撑不起来。
    // 快捷键。全局这几条**从设置里读**，不再写死；「发送」不在这里，
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
        children: <Widget>[
          ...previous,
          ?current,
        ],
      ),
      transitionBuilder: (Widget child, Animation<double> a) =>
          FadeTransition(opacity: a, child: child),
      child: body,
        ),
      ),
    );
  }

  /// 全局那几条绑定。键位**从设置里读**，不再写死。
  /// 「发送」不在其中 —— 它落在输入框上。
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

  Widget _mainPage() {
    final JoPalette p = JoTheme.of(context);

    return Container(
      color: p.bg,
      child: Row(
        children: <Widget>[
          SizedBox(
            width: _railW,
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
          _VDrag(
            palette: p,
            onDrag: (double d) =>
                setState(() => _railW = (_railW + d).clamp(160.0, 360.0)),
          ),
          Expanded(
            child: Column(
              // stretch：不然子项拿松约束，顶栏只按内容宽度居中排，
              // 右边那两个按钮就贴不到右边界。
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _TopBar(
                  palette: p,
                  worldName: _world.name,
                  mode: _mode,
                  onMode: (String v) => setState(() => _mode = v),
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
                    sendKey: widget.keys[JoKey.send] ?? 'Enter',
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
          _VDrag(
            palette: p,
            onDrag: (double d) =>
                setState(() => _sideW = (_sideW - d).clamp(200.0, 520.0)),
          ),
          SizedBox(
            width: _sideW,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(
                  child: _SidePanel(
                    palette: p,
                    settings: widget.settings,
                    world: _world,
                    focusedLane: _focusedLane,
                    selectedEvent: _selectedEvent,
                    selectedIndex: _selected,
                    onClear: () => setState(() {
                      _focused = null;
                      _selected = null;
                    }),
                  ),
                ),
                // 常驻按钮；编辑与记忆都走弹窗。
                WorldEditButton(
                  palette: p,
                  onTap: _openEdit,
                ),
              ],
            ),
          ),
        ],
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
              boundaryMargin:
                  const EdgeInsets.only(right: 480, bottom: 480),
              // 聚焦展开的动画：卡片 / 表头 / 底层连线都在这里重建，
              // 用的是同一份插值后的列宽，所以不会错位。
              child: AnimatedBuilder(
                animation: _focusAnim,
                builder: (BuildContext context, Widget? _) {
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
                              headerH: _headerH,
                              cardH: _cardH,
                              rowH: _rowH,
                              gap: _gap,
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
          height: _headerH - 14,
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
                          fontWeight:
                              lane.here ? FontWeight.w700 : FontWeight.w400,
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
        out.add(
          Positioned(
            left: colX[lane.id]!,
            top: _rowTop(r[i]),
            width: _colW(lane.id),
            height: _cardH,
            child: _StepCard(
              palette: p,
              settings: widget.settings,
              event: lane.events[i],
              focused: _focused == lane.id,
              selected: _focused == lane.id && _selected == i,
              onTap: () => _focusLane(lane.id, index: i),
            ),
          ),
        );
      }
    }
    return out;
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
                  style: JoFonts.meta
                      .copyWith(color: p.secondary, letterSpacing: 2),
                ),
                const Spacer(),
                JoButton(
                  text: '＋ 新建世界',
                  onTap: onNew,
                  color: p.accent,
                ),
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        world.name,
                        overflow: TextOverflow.ellipsis,
                        style: JoFonts.ui.copyWith(
                          fontSize: 13,
                          color: on ? p.accent : p.text,
                          fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                        ),
                      ),
                    ),
                    const SizedBox(width: JoSpace.s2),
                    GestureDetector(
                      onTap: onEdit,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: Text(
                          '编辑',
                          style: JoFonts.meta.copyWith(
                            color: on ? p.accent : p.secondary,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  world.note,
                  overflow: TextOverflow.ellipsis,
                  style: JoFonts.meta.copyWith(color: p.secondary, fontSize: 10),
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
  });

  final JoPalette palette;
  final JoSettings settings;
  final World world;
  final SeqLane? focusedLane;
  final SeqEvent? selectedEvent;
  final int? selectedIndex;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = palette;
    final SeqEvent? e = selectedEvent;
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
                    style: JoFonts.meta
                        .copyWith(color: p.secondary, letterSpacing: 2),
                  ),
                ),
                if (e != null || lane != null)
                  Padding(
                    padding: const EdgeInsets.only(left: JoSpace.s3),
                    child: GestureDetector(
                      onTap: onClear,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: Text('×', style: JoFonts.meta.copyWith(color: p.secondary)),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                JoSpace.s4,
                0,
                JoSpace.s4,
                JoSpace.s4,
              ),
              children: <Widget>[
                if (e != null) ..._stepDetail(p, lane!, e)
                else if (lane != null) ..._laneDetail(p, lane)
                else ..._worldDetail(p),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _stepDetail(JoPalette p, SeqLane lane, SeqEvent e) {
    return <Widget>[
      _kv(p, '谁', e.who),
      _kv(p, '时间标签', e.time),
      _kv(p, '地点', lane.place),
      _kv(p, '步序', '第 ${(selectedIndex ?? 0) + 1} 步'),
      const SizedBox(height: JoSpace.s4),
      Text('正文', style: JoFonts.meta.copyWith(color: p.secondary)),
      const SizedBox(height: JoSpace.s2),
      Text(e.text, style: settings.bodyStyle(p.text)),
    ];
  }

  List<Widget> _laneDetail(JoPalette p, SeqLane lane) {
    final List<String> who = <String>[];
    for (final SeqEvent e in lane.events) {
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
                    style: JoFonts.meta
                        .copyWith(color: p.secondary, height: 1.5),
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
              style: JoFonts.ui.copyWith(color: p.text, fontSize: 12, height: 1.5),
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

// ————————————————————————————— 侧栏拖动条

/// 竖拖动条：按住左右拖，改两侧栏宽。
class _VDrag extends StatefulWidget {
  const _VDrag({required this.palette, required this.onDrag});

  final JoPalette palette;
  final ValueChanged<double> onDrag;

  @override
  State<_VDrag> createState() => _VDragState();
}

class _VDragState extends State<_VDrag> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = widget.palette;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (DragUpdateDetails d) => widget.onDrag(d.delta.dx),
        child: SizedBox(
          width: 6,
          child: Center(
            // 平时就是一条普通分隔线；hover 才亮起来变粗，提示“这里能拖”
            child: AnimatedContainer(
              duration: kJoTapMs,
              curve: Curves.easeOut,
              width: _hover ? 2 : 1,
              color: _hover ? p.accent : p.border,
            ),
          ),
        ),
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
    required this.onTap,
  });

  final JoPalette palette;
  final JoSettings settings;
  final SeqEvent event;
  final bool focused;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = palette;
    final bool compact = !focused && !selected;
    final Color whoColor = event.isNarration ? p.accent : p.text;
    return JoTap(
      onTap: onTap,
      builder: (BuildContext context, bool hover, bool down) {
        return AnimatedContainer(
          duration: kJoTapMs,
          curve: Curves.easeOut,
          padding: EdgeInsets.all(compact ? JoSpace.s3 : JoSpace.s4),
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
                  style: settings.bodyStyle(p.text).copyWith(
                        fontSize:
                            compact ? settings.bodySize - 3 : settings.bodySize,
                      ),
                  maxLines: compact ? 2 : null,
                  overflow: compact ? TextOverflow.ellipsis : null,
                ),
              ),
            ],
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

  /// 打开「选择」面板（跟着角色走的那一套）。
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
          const Spacer(),
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
  });

  final JoPalette palette;
  final JoSettings settings;
  final TextEditingController controller;
  final VoidCallback onSubmit;

  /// 「发送」用哪个键（从设置里读）。
  final String sendKey;

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
  });

  final TextEditingController controller;
  final JoSettings settings;
  final VoidCallback onSubmit;
  final String sendKey;

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

  @override
  Widget build(BuildContext context) {
    final JoSettings s = JoTheme.settingsOf(context);
    // 不用 s.palette —— 那个 getter 已被删除（它算不出跟随系统）。
    final JoPalette p = JoTheme.of(context);
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: widget.controller,
      builder: (BuildContext context, TextEditingValue value, _) {
        // 「发送」键**从设置里读**。
        //
        // Enter 走 EditableText 自己的 onSubmitted —— 输入框里的按键
        // 先被输入法吃掉，外面的全局绑定根本看不见它。所以别的组合键
        // 在这儿绑；发送键正好是 Enter 时**不重复绑**，免得送两次。
        final ShortcutActivator? a = joActivator(widget.sendKey);
        final bool bareEnter =
            widget.sendKey.trim().toLowerCase() == 'enter';
        return CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            if (a != null && !bareEnter) a: widget.onSubmit,
          },
          child: Stack(
            alignment: Alignment.centerLeft,
            children: <Widget>[
              if (value.text.isEmpty)
                Text(
                  '你要做什么……',
                  style: s.bodyStyle(p.secondary).copyWith(fontSize: 15),
                ),
              EditableText(
                controller: widget.controller,
                focusNode: _focus,
                autofocus: true,
                maxLines: 1,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => widget.onSubmit(),
                style: s.bodyStyle(p.text).copyWith(fontSize: 15),
                cursorColor: p.accent,
                cursorWidth: 1.5,
                backgroundCursorColor: p.border,
                selectionColor: p.accent.withValues(alpha: 0.3),
              ),
            ],
          ),
        );
      },
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
  final double gap;
  final int maxRows;
  final Map<String, List<int>> rows;
  final double rulerW;
  final double totalW;
  final List<SeqLane> lanes;
  final List<MoveLink> moves;

  @override
  void paint(Canvas canvas, Size size) {
    double rowTop(int i) => headerH + i * rowH;
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
        final double y0 = rowTop(r[i]) + cardH;
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
      if (!colX.containsKey(m.fromLane) || !colX.containsKey(m.toLane)) continue;
      final List<int>? sr = rows[m.fromLane];
      final List<int>? dr = rows[m.toLane];
      if (sr == null || dr == null) continue;
      if (m.fromStep >= sr.length || m.toStep >= dr.length) continue;

      final double srcCx = colCenter(m.fromLane);
      final double dstCx = colCenter(m.toLane);
      final double srcBottom = rowTop(sr[m.fromStep]) + cardH;
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

      final TextPainter tp = TextPainter(
        text: TextSpan(
          text: '换地点',
          style: JoFonts.meta.copyWith(color: palette.accent, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset((srcCx + dstCx) / 2 - tp.width / 2, yH - tp.height - 2),
      );
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
      old.maxRows != maxRows ||
      old.totalW != totalW ||
      old.colX.toString() != colX.toString() ||
      old.rows.toString() != rows.toString();
}
