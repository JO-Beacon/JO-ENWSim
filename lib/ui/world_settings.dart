// 右栏底部的“编辑”按钮，以及它打开的**大编辑弹窗**。
//
// 弹窗里是三个标签页：世界观 / 记忆 / 模型。
// 状态集中在弹窗里，保存时一次性交回去。

import 'package:flutter/material.dart';

import '../model/demo.dart';
import '../model/memory.dart';
import '../model/model_plan.dart';
import '../theme/tokens.dart';
import 'common.dart';
import 'memory_panel.dart';
import 'model_plan_dialog.dart';

/// 底部常驻的“编辑”按钮。
class WorldEditButton extends StatelessWidget {
  const WorldEditButton({
    super.key,
    required this.palette,
    required this.onTap,
  });

  final JoPalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = palette;
    return Container(
      decoration: BoxDecoration(border: Border(top: JoShape.side(p.border))),
      padding: const EdgeInsets.symmetric(
        horizontal: JoSpace.s3,
        vertical: JoSpace.s2,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: JoButton(text: '编辑', onTap: onTap, color: p.accent),
      ),
    );
  }
}

/// 编辑弹窗保存回来的东西。
typedef WorldEditResult = ({
  String name,
  List<CharCard> characters,

  /// 每个角色一份模型配置（各自只管 B₁ / B₂）。
  /// 里面没设的，落回世界的 B₁/B₂，再落回世界默认。
  Map<String, ModelPlan> charModels,
  ModelPlan plan,
  Map<String, MemoryBook> books,
  String setting,
  String opening,

  /// 用户在“常规”里点了删除世界。
  bool delete,
});

/// 打开编辑弹窗：世界观 / 记忆 / 模型 三个标签页。
Future<WorldEditResult?> showWorldEditDialog(
  BuildContext context, {
  required String worldName,
  required String setting,
  required String opening,
  required ModelPlan plan,
  required ModelPlan globalPlan,
  required List<ModelGroup> groups,
  required Map<String, MemoryBook> books,
  required List<String> owners,
  required List<CharCard> characters,
  required Map<String, ModelPlan> charModels,
  required bool isLastWorld,
}) {
  return showDialog<WorldEditResult>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (BuildContext c) => _EditDialog(
      worldName: worldName,
      setting: setting,
      opening: opening,
      plan: plan,
      globalPlan: globalPlan,
      groups: groups,
      books: books,
      owners: owners,
      characters: characters,
      charModels: charModels,
      isLastWorld: isLastWorld,
    ),
  );
}

class _EditDialog extends StatefulWidget {
  const _EditDialog({
    required this.worldName,
    required this.setting,
    required this.opening,
    required this.plan,
    required this.globalPlan,
    required this.groups,
    required this.books,
    required this.owners,
    required this.characters,
    required this.charModels,
    required this.isLastWorld,
  });

  final String worldName;
  final String setting;
  final String opening;
  final ModelPlan plan;
  final ModelPlan globalPlan;
  final List<ModelGroup> groups;
  final Map<String, MemoryBook> books;
  final List<String> owners;
  final List<CharCard> characters;
  final Map<String, ModelPlan> charModels;
  final bool isLastWorld;

  @override
  State<_EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends State<_EditDialog> {
  /// 五个标签：常规 / 世界观 / 角色 / 记忆 / 模型
  static const List<String> _tabs = <String>['常规', '世界观', '角色', '记忆', '模型'];

  /// 角色身上只有这两步：他被谁感知、他由谁决定行动。
  static const List<StepKind> _charSteps = <StepKind>[
    (id: 'B1', title: '角色感知', hint: '该角色感知到了什么'),
    (id: 'B2', title: '角色行为', hint: '该角色如何行动'),
  ];

  int _tab = 0;
  late ModelPlan _plan = widget.plan;
  late List<CharCard> _chars = List<CharCard>.of(widget.characters);
  late Map<String, ModelPlan> _charModels = <String, ModelPlan>{
    ...widget.charModels,
  };
  late final List<TextEditingController> _personaC = <TextEditingController>[
    for (final CharCard c in widget.characters)
      TextEditingController(text: c.persona),
  ];
  late Map<String, MemoryBook> _books = widget.books;
  late final TextEditingController _name = TextEditingController(
    text: widget.worldName,
  );
  late final TextEditingController _setting = TextEditingController(
    text: widget.setting,
  );
  late final TextEditingController _opening = TextEditingController(
    text: widget.opening,
  );

  @override
  void dispose() {
    for (final TextEditingController c in _personaC) {
      c.dispose();
    }
    _name.dispose();
    _setting.dispose();
    _opening.dispose();
    super.dispose();
  }

  void _save() => Navigator.of(context).pop((
    name: _name.text.trim().isEmpty ? widget.worldName : _name.text.trim(),
    characters: _chars,
    charModels: _charModels,
    plan: _plan,
    books: _books,
    setting: _setting.text,
    opening: _opening.text,
    delete: false,
  ));

  /// 删除世界。最后一个不给删——不然工作台就没有世界可看了。
  Future<void> _askDelete() async {
    if (widget.isLastWorld) return;
    final JoPalette p = JoTheme.of(context);
    final bool? ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (BuildContext c) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 420,
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
                '删除世界',
                style: JoFonts.ui.copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: p.text,
                ),
              ),
              const SizedBox(height: JoSpace.s3),
              Text(
                '“${widget.worldName}” 以及它下面的序列、回合、记忆一起删掉，不能撤销。',
                style: JoFonts.meta.copyWith(color: p.secondary, height: 1.7),
              ),
              const SizedBox(height: JoSpace.s4),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  JoButton(text: '取消', onTap: () => Navigator.of(c).pop(false)),
                  const SizedBox(width: JoSpace.s2),
                  JoButton(
                    text: '删除',
                    color: p.accent,
                    onTap: () => Navigator.of(c).pop(true),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    Navigator.of(context).pop((
      name: widget.worldName,
      characters: _chars,
      charModels: _charModels,
      plan: _plan,
      books: _books,
      setting: _setting.text,
      opening: _opening.text,
      delete: true,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final JoPalette p = JoTheme.of(context);
    final Size mq = MediaQuery.of(context).size;
    final double w = (mq.width - 64).clamp(560.0, 960.0);
    final double h = (mq.height - 64).clamp(420.0, 760.0);

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
            _header(context, p),
            Expanded(
              child: switch (_tab) {
                0 => _general(p),
                1 => _worldBook(p),
                2 => _characters(p),
                3 => MemoryPanel(
                  books: _books,
                  owners: widget.owners,
                  onChanged: (Map<String, MemoryBook> next) =>
                      setState(() => _books = next),
                ),
                _ => _models(p),
              },
            ),
            _footer(context, p),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, JoPalette p) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        JoSpace.s4,
        JoSpace.s3,
        JoSpace.s4,
        JoSpace.s2,
      ),
      decoration: BoxDecoration(border: Border(bottom: JoShape.side(p.border))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                '编辑',
                style: JoFonts.ui.copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: p.text,
                ),
              ),
              const SizedBox(width: JoSpace.s3),
              Expanded(
                child: Text(
                  widget.worldName,
                  overflow: TextOverflow.ellipsis,
                  style: JoFonts.meta.copyWith(color: p.secondary),
                ),
              ),
              JoButton(text: '×', onTap: () => Navigator.of(context).pop()),
            ],
          ),
          const SizedBox(height: JoSpace.s3),
          Align(
            alignment: Alignment.centerLeft,
            child: JoSegment<int>(
              options: <({String label, int value})>[
                for (int i = 0; i < _tabs.length; i++)
                  (label: _tabs[i], value: i),
              ],
              value: _tab,
              onChanged: (int v) => setState(() => _tab = v),
            ),
          ),
        ],
      ),
    );
  }

  // ——— 常规 ———

  Widget _general(JoPalette p) {
    return ListView(
      padding: const EdgeInsets.all(JoSpace.s4),
      children: <Widget>[
        _label(p, '世界名'),
        JoInput(
          initial: _name.text,
          hint: '比如：旧宅 · 雨夜',
          onChanged: (String v) => _name.text = v,
        ),
        const SizedBox(height: JoSpace.s6),
        _label(p, '删除世界'),
        Text(
          widget.isLastWorld
              ? '这是最后一个世界，不能删——不然工作台就没有世界可看了。'
              : '连同它的序列、回合、记忆一起删掉，不能撤销。',
          style: JoFonts.meta.copyWith(
            color: p.secondary,
            fontSize: 10,
            height: 1.7,
          ),
        ),
        const SizedBox(height: JoSpace.s3),
        Align(
          alignment: Alignment.centerLeft,
          child: JoButton(
            text: '删除这个世界',
            color: p.secondary,
            onTap: widget.isLastWorld ? () {} : _askDelete,
          ),
        ),
      ],
    );
  }

  // ——— 世界观 ———

  Widget _worldBook(JoPalette p) {
    return ListView(
      padding: const EdgeInsets.all(JoSpace.s4),
      children: <Widget>[
        _label(p, '世界观设定'),
        _Area(controller: _setting, hint: '时代、地点、规则、眼下的大事……'),
        const SizedBox(height: JoSpace.s5),
        _label(p, '开场'),
        _Area(controller: _opening, hint: '故事开始时，玩家角色在哪里、看见什么……'),
      ],
    );
  }

  // ——— 角色 ———

  void _addChar() => setState(() {
    _chars = <CharCard>[..._chars, const CharCard(name: '', persona: '')];
    _personaC.add(TextEditingController());
  });

  void _putChar(int i, CharCard c) => setState(() {
    final List<CharCard> next = List<CharCard>.of(_chars);
    next[i] = c;
    _chars = next;
  });

  void _removeChar(int i) => setState(() {
    final List<CharCard> next = List<CharCard>.of(_chars)..removeAt(i);
    _chars = next;
    _personaC.removeAt(i).dispose();
  });

  /// 用模型读世界观、列出一批角色。
  ///
  /// **引擎还没接入**，所以这里只如实说明，不假装能跑。
  Future<void> _askGenerate() {
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
                '根据世界观生成角色',
                style: JoFonts.ui.copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: p.text,
                ),
              ),
              const SizedBox(height: JoSpace.s3),
              Text(
                '要把世界观交给模型、让它列出一批角色——这得先接引擎。'
                '引擎还没接入，所以现在还不能用。',
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

  Widget _characters(JoPalette p) {
    return ListView(
      padding: const EdgeInsets.all(JoSpace.s4),
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              '一共有 ${_chars.length} 名角色',
              style: JoFonts.meta.copyWith(
                color: p.secondary,
                letterSpacing: 1.5,
              ),
            ),
            const Spacer(),
            JoButton(
              text: '根据世界观生成角色',
              color: p.secondary,
              onTap: _askGenerate,
            ),
            const SizedBox(width: JoSpace.s2),
            JoButton(text: '＋ 添加角色', color: p.accent, onTap: _addChar),
          ],
        ),
        const SizedBox(height: JoSpace.s3),
        if (_chars.isEmpty)
          Text(
            '还没有角色。',
            style: JoFonts.meta.copyWith(color: p.secondary, height: 1.7),
          ),
        for (int i = 0; i < _chars.length; i++) _charBox(p, i),
      ],
    );
  }

  Widget _charBox(JoPalette p, int i) {
    final CharCard c = _chars[i];
    return Container(
      margin: const EdgeInsets.only(bottom: JoSpace.s3),
      padding: const EdgeInsets.all(JoSpace.s3),
      decoration: BoxDecoration(
        border: JoShape.border(p.border),
        borderRadius: JoShape.br,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: JoInput(
                  initial: c.name,
                  hint: '角色名',
                  onChanged: (String v) =>
                      _putChar(i, CharCard(name: v, persona: c.persona)),
                ),
              ),
              const SizedBox(width: JoSpace.s2),
              JoTap(
                onTap: () => _removeChar(i),
                opaque: false,
                builder: (BuildContext context, bool hover, bool down) {
                  return AnimatedDefaultTextStyle(
                    duration: kJoTapMs,
                    curve: Curves.easeOut,
                    style: JoFonts.meta.copyWith(
                      color: hover ? p.accent : p.secondary,
                    ),
                    child: const Text('×'),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: JoSpace.s2),
          _Area(controller: _personaC[i], hint: '人设', lines: 4),
        ],
      ),
    );
  }

  // ——— 模型 ———

  Widget _models(JoPalette p) {
    return ListView(
      padding: const EdgeInsets.all(JoSpace.s4),
      children: <Widget>[
        // 链上最高的一级：每个角色各有一对 B₁ / B₂。
        if (widget.characters.isNotEmpty) ...<Widget>[
          for (final CharCard c in widget.characters) ...<Widget>[
            _label(p, c.name),
            for (final StepKind step in _charSteps)
              _modelRow(
                p,
                title: step.title,
                hint: step.hint,
                key: _charModels[c.name]?.stepKey(step.id) ?? '',
                follow: '跟随世界默认',
                onTap: () => _pickCharModel(c.name, step.id),
              ),
            const SizedBox(height: JoSpace.s4),
          ],
          const SizedBox(height: JoSpace.s1),
        ],
        _label(p, '世界'),
        _modelRow(
          p,
          title: '世界默认',
          hint: '这一步之后才轮到全局默认',
          key: _plan.defaultRef,
          follow: '不设（交给全局默认）',
          onTap: () => _pickModel(''),
        ),
        const SizedBox(height: JoSpace.s3),
        for (final StepKind s in kSteps)
          _modelRow(
            p,
            title: s.title,
            hint: s.hint,
            key: _plan.stepKey(s.id),
            follow: '跟随世界默认',
            onTap: () => _pickModel(s.id),
          ),
      ],
    );
  }

  Future<void> _pickCharModel(String name, String stepId) async {
    final ModelPlan plan = _charModels[name] ?? const ModelPlan();
    final ModelPick? pick = await showModelPicker(
      context,
      groups: widget.groups,
      current: plan.stepKey(stepId),
      clearLabel: '不设（跟随世界默认）',
    );
    if (!mounted) return;
    setState(() {
      _charModels = <String, ModelPlan>{
        ..._charModels,
        name: plan.withStep(stepId, pick?.key ?? ''),
      };
    });
  }

  Future<void> _pickModel(String stepId) async {
    final ModelPick? pick = await showModelPicker(
      context,
      groups: widget.groups,
      current: stepId.isEmpty ? _plan.defaultRef : _plan.stepKey(stepId),
      clearLabel: stepId.isEmpty ? '不设（交给全局默认）' : '不设（跟随世界默认）',
    );
    if (!mounted) return;
    setState(() {
      _plan = stepId.isEmpty
          ? _plan.copyWith(defaultRef: pick?.key ?? '')
          : _plan.withStep(stepId, pick?.key ?? '');
    });
  }

  Widget _modelRow(
    JoPalette p, {
    required String title,
    required String hint,
    required String key,
    required String follow,
    required VoidCallback onTap,
  }) {
    final String value = modelKeyLabel(widget.groups, key);
    final bool set = value.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: JoSpace.s2),
      child: JoTap(
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
                  set ? value : follow,
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
      ),
    );
  }

  Widget _footer(BuildContext context, JoPalette p) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: JoSpace.s4,
        vertical: JoSpace.s3,
      ),
      decoration: BoxDecoration(border: Border(top: JoShape.side(p.border))),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '常规里改世界名；角色在“角色”里。',
              style: JoFonts.meta.copyWith(color: p.secondary, fontSize: 10),
            ),
          ),
          const SizedBox(width: JoSpace.s3),
          JoButton(text: '取消', onTap: () => Navigator.of(context).pop()),
          const SizedBox(width: JoSpace.s2),
          JoButton(text: '保存', color: p.accent, onTap: _save),
        ],
      ),
    );
  }

  Widget _label(JoPalette p, String text) => Padding(
    padding: const EdgeInsets.only(bottom: JoSpace.s2),
    child: Text(
      text,
      style: JoFonts.meta.copyWith(color: p.secondary, letterSpacing: 1.5),
    ),
  );
}

/// 多行输入（编辑弹窗里自己用的，跟创建向导那个同款）。
class _Area extends StatelessWidget {
  const _Area({required this.controller, this.hint, this.lines = 9});

  final TextEditingController controller;
  final String? hint;
  final int lines;

  @override
  Widget build(BuildContext context) {
    final JoSettings s = JoTheme.settingsOf(context);
    // 不用 s.palette —— 那个 getter 已经被删了（它算不出跟随系统）。
    // 实际用哪一套只有 main 知道，要就拿 JoTheme 里那份。
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
