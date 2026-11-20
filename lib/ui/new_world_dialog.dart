import 'package:flutter/material.dart';

import '../model/demo.dart';
import '../theme/tokens.dart';
import 'common.dart';
import 'tooltip.dart';

/// 新建世界：两步向导。
///
/// 第一步：世界观设定 + 开场（可选手写角色）。
/// 第二步：AI 分析世界设定与开场，请玩家补全角色；
///         没有需要补的角色，就直接创建完成。
Future<World?> showWorldDialog(BuildContext context, {World? initial}) {
  return showDialog<World>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (BuildContext c) => _WorldDialog(initial: initial),
  );
}

class _WorldDialog extends StatefulWidget {
  const _WorldDialog({this.initial});

  /// 非空 = 编辑已有世界；空 = 新建。
  final World? initial;

  @override
  State<_WorldDialog> createState() => _WorldDialogState();
}

class _Draft {
  _Draft({String name = '', String persona = ''})
    : nameC = TextEditingController(text: name),
      personaC = TextEditingController(text: persona);

  final TextEditingController nameC;
  final TextEditingController personaC;

  void dispose() {
    nameC.dispose();
    personaC.dispose();
  }
}

class _WorldDialogState extends State<_WorldDialog> {
  final TextEditingController _nameC = TextEditingController();
  final TextEditingController _placeC = TextEditingController();
  final TextEditingController _settingC = TextEditingController();
  final TextEditingController _openingC = TextEditingController();
  final List<_Draft> _chars = <_Draft>[];

  int _step = 1;
  bool _analyzing = false;

  bool get _editing => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final World? w = widget.initial;
    if (w != null) {
      _nameC.text = w.name;
      _placeC.text = w.parallelPlaces.isEmpty
          ? ''
          : w.parallelPlaces.first.place;
      _settingC.text = w.setting;
      _openingC.text = w.opening;
      for (final CharCard c in w.characters) {
        _chars.add(_Draft(name: c.name, persona: c.persona));
      }
    }
    _settingC.addListener(_onText);
    _openingC.addListener(_onText);
  }

  void _onText() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _settingC.removeListener(_onText);
    _openingC.removeListener(_onText);
    _nameC.dispose();
    _placeC.dispose();
    _settingC.dispose();
    _openingC.dispose();
    for (final _Draft d in _chars) {
      d.dispose();
    }
    super.dispose();
  }

  /// 玩家扮演谁。空 = 没选。
  String _player = '';

  /// 走到第三步时能选的名字：跟 _finish 的过滤规则一致。
  List<String> get _playerNames => <String>[
    for (final _Draft d in _chars)
      if (d.nameC.text.trim().isNotEmpty || d.personaC.text.trim().isNotEmpty)
        (d.nameC.text.trim().isEmpty ? '（未命名）' : d.nameC.text.trim()),
  ];

  bool get _canNext =>
      _settingC.text.trim().isNotEmpty && _openingC.text.trim().isNotEmpty;

  void _goStep(int s) {
    setState(() {
      _step = s;
      _analyzing = s == 2;
    });
    if (s == 2) {
      Future<void>.delayed(const Duration(milliseconds: 900), () {
        if (!mounted) return;
        setState(() => _analyzing = false);
      });
    }
  }

  void _addChar() {
    setState(() => _chars.add(_Draft()));
  }

  void _removeChar(int i) {
    setState(() {
      final _Draft d = _chars.removeAt(i);
      d.dispose();
    });
  }

  void _finish() {
    final List<CharCard> cards = <CharCard>[];
    for (final _Draft d in _chars) {
      final String n = d.nameC.text.trim();
      final String ps = d.personaC.text.trim();
      if (n.isEmpty && ps.isEmpty) continue;
      cards.add(CharCard(name: n.isEmpty ? '（未命名）' : n, persona: ps));
    }
    final World? base = widget.initial;
    final String name = _nameC.text.trim();
    final World w = World(
      id: base?.id ?? 'w${DateTime.now().microsecondsSinceEpoch}',
      name: name.isEmpty ? '未命名世界' : name,
      note: base?.note ?? '刚创建 · 尚未开始',
      setting: _settingC.text.trim(),
      opening: _openingC.text.trim(),
      characters: cards,
      parallelPlaces: base?.parallelPlaces ?? const <ParallelPlace>[],
      moves: base?.moves ?? const <MoveLink>[],
      playerName: _player,
    );
    // 新世界不靠用户点“加地点”：第一条线在这里自动建。
    Navigator.of(context).pop(w.withInitialParallelPlace(place: _placeC.text));
  }

  @override
  Widget build(BuildContext context) {
    final JoPalette p = JoTheme.of(context);
    final Size mq = MediaQuery.of(context).size;
    final double w = (mq.width - 64).clamp(420.0, 780.0);
    final double h = (mq.height - 64).clamp(360.0, 640.0);

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: Container(
        width: w,
        height: h,
        decoration: BoxDecoration(
          color: p.bg,
          border: JoShape.border(p.border),
          borderRadius: JoShape.br,
        ),
        child: Column(
          children: <Widget>[
            _header(p),
            Expanded(
              child: _step == 1
                  ? _body1(p)
                  : (_step == 2 ? _body2(p) : _body3(p)),
            ),
            _footer(p),
          ],
        ),
      ),
    );
  }

  Widget _header(JoPalette p) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: JoSpace.s4,
        vertical: JoSpace.s3,
      ),
      decoration: BoxDecoration(border: Border(bottom: JoShape.side(p.border))),
      child: Row(
        children: <Widget>[
          Text(
            _editing ? '编辑世界' : '新建世界',
            style: JoFonts.ui.copyWith(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: p.text,
            ),
          ),
          const SizedBox(width: JoSpace.s5),
          _stepChip(p, 1, '① 世界观与开场'),
          const SizedBox(width: JoSpace.s2),
          _stepChip(p, 2, '② 补全角色'),
          const SizedBox(width: JoSpace.s2),
          _stepChip(p, 3, '③ 操控角色'),
          const Spacer(),
          JoTooltip(
            text: '关闭',
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Text(
                  '×',
                  style: JoFonts.meta.copyWith(color: p.secondary),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepChip(JoPalette p, int n, String label) {
    final bool on = _step == n;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: JoSpace.s3,
        vertical: JoSpace.s1 + 2,
      ),
      decoration: BoxDecoration(
        color: on ? p.surface : Colors.transparent,
        border: JoShape.border(on ? p.accent : p.border),
        borderRadius: JoShape.br,
      ),
      child: Text(
        label,
        style: JoFonts.meta.copyWith(color: on ? p.accent : p.secondary),
      ),
    );
  }

  Widget _footer(JoPalette p) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: JoSpace.s4,
        vertical: JoSpace.s3,
      ),
      decoration: BoxDecoration(border: Border(top: JoShape.side(p.border))),
      child: Row(
        children: <Widget>[
          if (_step == 1)
            JoButton(text: '取消', onTap: () => Navigator.of(context).pop())
          else
            JoButton(text: '← 上一步', onTap: () => _goStep(_step - 1)),
          const Spacer(),
          if (_step == 1)
            JoButton(
              text: '下一步 →',
              onTap: _canNext ? () => _goStep(2) : () {},
              color: _canNext ? p.accent : p.secondary,
            )
          else if (_step == 2)
            JoButton(
              // 一个角色都没有就跳过第三步，直接完成。
              text: _playerNames.isEmpty ? '完成' : '下一步 →',
              onTap: _playerNames.isEmpty ? _finish : () => _goStep(3),
              color: p.accent,
            )
          else
            JoButton(
              text: _editing ? '保存' : '完成',
              onTap: _finish,
              color: p.accent,
            ),
        ],
      ),
    );
  }

  // —— 第三步：扮演谁 ——

  Widget _body3(JoPalette p) {
    final List<String> names = _playerNames;
    return ListView(
      padding: const EdgeInsets.all(JoSpace.s4),
      children: <Widget>[
        Text(
          '开局由你操控哪个角色？',
          style: JoFonts.ui.copyWith(fontSize: 14, color: p.text),
        ),
        const SizedBox(height: JoSpace.s2),
        Text(
          '选中的角色即当前操控角色，其行动由你决定，不由 AI 决定。',
          style: JoFonts.meta.copyWith(color: p.secondary, height: 1.7),
        ),
        const SizedBox(height: JoSpace.s4),
        Wrap(
          spacing: JoSpace.s2,
          runSpacing: JoSpace.s2,
          children: <Widget>[
            for (final String n in names)
              GestureDetector(
                // 再点一下取消选中。
                onTap: () => setState(() => _player = n == _player ? '' : n),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: JoSpace.s3,
                      vertical: JoSpace.s2,
                    ),
                    decoration: BoxDecoration(
                      color: n == _player ? p.surface : Colors.transparent,
                      border: JoShape.border(
                        n == _player ? p.accent : p.border,
                      ),
                      borderRadius: JoShape.br,
                    ),
                    child: Text(
                      n,
                      style: JoFonts.meta.copyWith(
                        color: n == _player ? p.accent : p.secondary,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: JoSpace.s4),
        Text(
          _player.isEmpty
              ? '尚未选择。也可以不选，此时所有角色由 AI 接管。'
              : '当前操控角色：$_player（再次点击该名字可取消）',
          style: JoFonts.meta.copyWith(color: p.secondary, height: 1.7),
        ),
      ],
    );
  }

  // —— 第一步 ——

  Widget _body1(JoPalette p) {
    return ListView(
      padding: const EdgeInsets.all(JoSpace.s4),
      children: <Widget>[
        _label(p, '世界名'),
        _Input(controller: _nameC, hint: '例如：旧宅 · 雨夜'),
        const SizedBox(height: JoSpace.s5),
        _label(p, '起始地点'),
        _Input(controller: _placeC, hint: '开场时玩家所在的地点；留空则为“开场”'),
        const SizedBox(height: JoSpace.s5),
        _label(p, '世界观设定'),
        _Input(controller: _settingC, hint: '时代、地点、规则、当前要事……', lines: 5),
        const SizedBox(height: JoSpace.s5),
        _label(p, '开场'),
        _Input(controller: _openingC, hint: '故事开始时，当前操控角色身处何处、看见什么……', lines: 6),
        const SizedBox(height: JoSpace.s5),
        Row(
          children: <Widget>[
            _label(p, '手写角色（可选）'),
            const Spacer(),
            JoButton(text: '＋ 添加角色', onTap: _addChar, color: p.accent),
          ],
        ),
        if (_chars.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: JoSpace.s2),
            child: Text(
              '也可以不手写角色；下一步会列出当前可用的角色。',
              style: JoFonts.meta.copyWith(color: p.secondary),
            ),
          ),
        for (int i = 0; i < _chars.length; i++) _charBox(p, i),
      ],
    );
  }

  Widget _charBox(JoPalette p, int i) {
    final _Draft d = _chars[i];
    return Container(
      margin: const EdgeInsets.only(top: JoSpace.s3),
      padding: const EdgeInsets.all(JoSpace.s3),
      decoration: BoxDecoration(
        color: p.surface,
        border: JoShape.border(p.border),
        borderRadius: JoShape.br,
      ),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: _Input(controller: d.nameC, hint: '角色名'),
              ),
              const SizedBox(width: JoSpace.s2),
              JoTooltip(
                text: '移除这个角色',
                child: GestureDetector(
                  onTap: () => _removeChar(i),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Text(
                      '×',
                      style: JoFonts.meta.copyWith(color: p.secondary),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: JoSpace.s2),
          _Input(controller: d.personaC, hint: '人设：身份、目标与人物关系', lines: 3),
        ],
      ),
    );
  }

  // —— 第二步 ——

  Widget _body2(JoPalette p) {
    if (_analyzing) {
      return Center(
        child: Text(
          '正在分析世界观设定与开场……',
          style: JoFonts.meta.copyWith(color: p.secondary),
        ),
      );
    }

    final List<int> missing = <int>[];
    for (int i = 0; i < _chars.length; i++) {
      if (_chars[i].personaC.text.trim().isEmpty) missing.add(i);
    }

    final String note;
    if (_chars.isEmpty) {
      note = '尚未添加角色，可直接完成。';
    } else if (missing.isEmpty) {
      note = '所有角色均已填写人设，无需补全。';
    } else {
      note = '以下角色尚未填写人设，补充后即可继续。';
    }

    return ListView(
      padding: const EdgeInsets.all(JoSpace.s4),
      children: <Widget>[
        Text(note, style: JoFonts.ui.copyWith(fontSize: 13, color: p.text)),
        const SizedBox(height: JoSpace.s2),
        Text(
          '当前版本仅列出你手写的角色，自动生成角色暂未开放。',
          style: JoFonts.meta.copyWith(color: p.secondary),
        ),
        const SizedBox(height: JoSpace.s4),
        Row(
          children: <Widget>[
            _label(p, '角色'),
            const Spacer(),
            JoButton(text: '＋ 添加角色', onTap: _addChar, color: p.accent),
          ],
        ),
        if (_chars.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: JoSpace.s2),
            child: Text(
              '也可以不添加角色，直接完成。',
              style: JoFonts.meta.copyWith(color: p.secondary),
            ),
          ),
        for (int i = 0; i < _chars.length; i++) _charBox(p, i),
      ],
    );
  }

  Widget _label(JoPalette p, String text) {
    return Text(
      text,
      style: JoFonts.meta.copyWith(color: p.secondary, letterSpacing: 1),
    );
  }
}

/// 输入框（单行 / 多行）。
class _Input extends StatelessWidget {
  const _Input({required this.controller, this.hint, this.lines = 1});

  final TextEditingController controller;
  final String? hint;
  final int lines;

  @override
  Widget build(BuildContext context) {
    final JoSettings s = JoTheme.settingsOf(context);
    // 不用 s.palette —— 那个 getter 已被删除（它算不出跟随系统）。
    final JoPalette p = JoTheme.of(context);
    return Container(
      margin: const EdgeInsets.only(top: JoSpace.s2),
      padding: const EdgeInsets.symmetric(
        horizontal: JoSpace.s3,
        vertical: JoSpace.s2,
      ),
      decoration: BoxDecoration(
        color: p.surface,
        border: JoShape.border(p.border),
        borderRadius: JoShape.br,
      ),
      // 原来的 `TextField` 靠 `minLines: lines` 撑高度；`JoTextField` 没这个
      // 参数，所以按行高（14 号字 × 1.75）给个最小高度。
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: lines * 14 * 1.75),
        child: JoTextField(
          controller: controller,
          maxLines: lines,
          verticalPadding: 0,
          style: s.bodyStyle(p.text).copyWith(fontSize: 14),
          hint: hint,
          hintStyle: s.bodyStyle(p.secondary).copyWith(fontSize: 14),
        ),
      ),
    );
  }
}
