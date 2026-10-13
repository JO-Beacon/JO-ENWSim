import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/demo.dart';
import '../theme/tokens.dart';
import 'common.dart';
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
  });

  final JoSettings settings;
  final ValueChanged<JoSettings> onSettingsChanged;

  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace> {
  final TextEditingController _input = TextEditingController();
  final TransformationController _tc = TransformationController();
  Size _viewport = Size.zero;

  _Page _page = _Page.main;
  late final List<World> _worlds = List<World>.of(DemoData.worlds);
  String _worldId = DemoData.worlds.first.id;
  double _railW = 196;
  double _sideW = 300;
  String? _focused;
  int? _selected;

  World get _world =>
      _worlds.firstWhere((World w) => w.id == _worldId);

  SeqLane? get _focusedLane {
    if (_focused == null) return null;
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

  double _colW(String id) {
    if (_focused == null) return _wCompact;
    return id == _focused ? _wFocus : _wShrunk;
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

  Future<void> _editWorld(World w) async {
    final World? next = await showWorldDialog(context, initial: w);
    if (next == null || !mounted) return;
    setState(() {
      final int i = _worlds.indexWhere((World x) => x.id == w.id);
      if (i >= 0) _worlds[i] = next;
    });
  }

  void _focusLane(String id, {int? index}) {
    setState(() {
      if (_focused == id && index == null) {
        _focused = null;
        _selected = null;
      } else {
        _focused = id;
        _selected = index;
      }
    });
  }

  void _submit() {
    final String t = _input.text.trim();
    if (t.isEmpty) return;
    setState(() {
      _selected = null;
    });
    _input.clear();
  }

  @override
  void dispose() {
    _input.dispose();
    _tc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_page == _Page.settings) {
      return SettingsPage(
        settings: widget.settings,
        onChanged: widget.onSettingsChanged,
        onBack: () => setState(() => _page = _Page.main),
      );
    }

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
              children: <Widget>[
                _TopBar(palette: p, worldName: _world.name),
                Expanded(
                  child: _world.lanes.isEmpty
                      ? _EmptyWorld(palette: p)
                      : _canvas(p),
                ),
                _InputBar(
                  palette: p,
                  settings: widget.settings,
                  controller: _input,
                  onSubmit: _submit,
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
    final Map<String, double> colX = _colX;
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
              child: SizedBox(
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
          child: GestureDetector(
            onTap: () => _focusLane(lane.id),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: JoSpace.s3),
                decoration: BoxDecoration(
                  color: on ? p.surface : p.bg,
                  border: JoShape.border(on ? p.accent : p.border),
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
              ),
            ),
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
  const _TopBar({required this.palette, required this.worldName});

  final JoPalette palette;
  final String worldName;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = palette;
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: JoSpace.s4),
      decoration: BoxDecoration(border: Border(bottom: JoShape.side(p.border))),
      child: Row(
        children: <Widget>[
          Flexible(
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
        ],
      ),
    );
  }
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
                JoButton(text: '设置', onTap: onSettings),
                const Spacer(),
                JoButton(
                  text: isDark ? '暗' : '明',
                  onTap: onTheme,
                  color: p.accent,
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
      child: GestureDetector(
        onTap: onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: JoSpace.s3,
              vertical: JoSpace.s3,
            ),
            decoration: BoxDecoration(
              color: on ? p.surface : p.bg,
              border: JoShape.border(on ? p.accent : p.border),
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
          ),
        ),
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
                  GestureDetector(
                    onTap: onClear,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Text('×', style: JoFonts.meta.copyWith(color: p.secondary)),
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
class _VDrag extends StatelessWidget {
  const _VDrag({required this.palette, required this.onDrag});

  final JoPalette palette;
  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (DragUpdateDetails d) => onDrag(d.delta.dx),
        child: SizedBox(
          width: 6,
          child: Center(
            child: Container(width: 1, color: palette.border),
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
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: EdgeInsets.all(compact ? JoSpace.s3 : JoSpace.s4),
          decoration: BoxDecoration(
            color: event.isNarration
                ? p.accent.withValues(alpha: 0.06)
                : p.surface,
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
  });

  final JoPalette palette;
  final JoSettings settings;
  final TextEditingController controller;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = palette;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: JoSpace.s4,
        vertical: JoSpace.s3,
      ),
      decoration: BoxDecoration(border: Border(top: JoShape.side(p.border))),
      child: Row(
        children: <Widget>[
          Text('>', style: JoFonts.meta.copyWith(color: p.accent)),
          const SizedBox(width: JoSpace.s3),
          Expanded(
            child: _JoInput(
              controller: controller,
              settings: settings,
              onSubmit: onSubmit,
            ),
          ),
          const SizedBox(width: JoSpace.s3),
          GestureDetector(
            onTap: onSubmit,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Text('↵', style: JoFonts.meta.copyWith(color: p.accent)),
            ),
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
  });

  final TextEditingController controller;
  final JoSettings settings;
  final VoidCallback onSubmit;

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
    final JoPalette p = s.palette;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: widget.controller,
      builder: (BuildContext context, TextEditingValue value, _) {
        return Stack(
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
