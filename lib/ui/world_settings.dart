// 右栏底部的“编辑”图标（铅笔），以及它打开的**大编辑弹窗**。
//
// 弹窗里是三个标签页：世界观 / 记忆 / 模型。
// 状态集中在弹窗里，保存时一次性交回去。

import 'package:flutter/material.dart';

import '../engine/character_memory.dart';
import '../model/demo.dart';
import '../model/model_plan.dart';
import '../model/provider.dart';
import '../model/tts_types.dart';
import '../model/world_search.dart';
import '../theme/tokens.dart';
import '../tts/kokoro_voices.dart';
import 'common.dart';
import 'icons.dart';
import 'memory_panel.dart';
import 'model_plan_dialog.dart';
import 'tooltip.dart';
import 'tts_picker.dart';

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
      // 先前是“编辑”两个字；换成铅笔图标，悬停浮底色、图标亮一档 ——
      // 跟左下角那个设置齿轮、行动输入框旁那几个工具按钮一个做法。
      child: Row(
        children: <Widget>[
          JoIconAction(icon: JoIcons.pencil, tip: '编辑这个世界', onTap: onTap),
        ],
      ),
    );
  }
}

/// 编辑弹窗保存回来的东西。
typedef WorldEditResult = ({
  String name,
  List<CharCard> characters,

  /// 每个角色一份模型配置（各自只管“角色感知”和“角色行为”两步）。
  /// 里面没设的，落回世界这两步的设置，再落回世界默认。
  Map<String, ModelPlan> charModels,
  Map<String, String> charTts,
  ModelPlan plan,
  String worldTts,
  String narratorTts,
  WorldSearchSource searchSource,
  List<CharacterMemory> memory,
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
  required String worldTts,
  required String narratorTts,
  required WorldSearchSource searchSource,
  required ModelPlan plan,
  required ModelPlan globalPlan,
  required List<ModelGroup> groups,
  required List<CharacterMemory> memory,
  required List<String> owners,
  required List<CharCard> characters,
  required Map<String, ModelPlan> charModels,
  required Map<String, String> charTts,
  required List<Provider> ttsProviders,
  required TtsPick globalTts,
  String? modelRoot,
  required bool isLastWorld,
  MemoryVersionsLoader? loadMemoryVersions,
}) {
  return showDialog<WorldEditResult>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (BuildContext c) => _EditDialog(
      worldName: worldName,
      setting: setting,
      opening: opening,
      worldTts: worldTts,
      narratorTts: narratorTts,
      searchSource: searchSource,
      plan: plan,
      globalPlan: globalPlan,
      groups: groups,
      memory: memory,
      owners: owners,
      characters: characters,
      charModels: charModels,
      charTts: charTts,
      ttsProviders: ttsProviders,
      globalTts: globalTts,
      modelRoot: modelRoot,
      isLastWorld: isLastWorld,
      loadMemoryVersions: loadMemoryVersions,
    ),
  );
}

class _EditDialog extends StatefulWidget {
  const _EditDialog({
    required this.worldName,
    required this.setting,
    required this.opening,
    required this.worldTts,
    required this.narratorTts,
    required this.searchSource,
    required this.plan,
    required this.globalPlan,
    required this.groups,
    required this.memory,
    required this.owners,
    required this.characters,
    required this.charModels,
    required this.charTts,
    required this.ttsProviders,
    required this.globalTts,
    this.modelRoot,
    required this.isLastWorld,
    this.loadMemoryVersions,
  });

  final String worldName;
  final String setting;
  final String opening;
  final String worldTts;
  final String narratorTts;
  final WorldSearchSource searchSource;
  final ModelPlan plan;
  final ModelPlan globalPlan;
  final List<ModelGroup> groups;
  final List<CharacterMemory> memory;
  final List<String> owners;
  final List<CharCard> characters;
  final Map<String, ModelPlan> charModels;
  final Map<String, String> charTts;
  final List<Provider> ttsProviders;
  final TtsPick globalTts;
  final String? modelRoot;
  final bool isLastWorld;
  final MemoryVersionsLoader? loadMemoryVersions;

  @override
  State<_EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends State<_EditDialog> {
  /// 五个标签：常规 / 世界观 / 角色 / 记忆 / 模型
  static const List<String> _tabs = <String>['常规', '世界观', '角色', '记忆', '模型'];

  /// 角色身上只有这两步：他被谁感知、他由谁决定行动。
  static const List<StepKind> _charSteps = <StepKind>[
    (id: 'CH_PERCEIVE', title: '角色感知', hint: '该角色感知到了什么'),
    (id: 'CH_ACT', title: '角色行为', hint: '该角色如何行动'),
  ];

  int _tab = 0;
  late ModelPlan _plan = widget.plan;
  late List<CharCard> _chars = List<CharCard>.of(widget.characters);
  late Map<String, ModelPlan> _charModels = <String, ModelPlan>{
    ...widget.charModels,
  };
  late Map<String, String> _charTts = <String, String>{...widget.charTts};
  late String _worldTts = widget.worldTts;
  late String _narratorTts = widget.narratorTts;
  late final List<TextEditingController> _personaC = <TextEditingController>[
    for (final CharCard c in widget.characters)
      TextEditingController(text: c.persona),
  ];
  late final List<TextEditingController> _aliasC = <TextEditingController>[
    for (final CharCard c in widget.characters)
      TextEditingController(text: _aliasesText(c.aliases)),
  ];
  late List<CharacterMemory> _memory = widget.memory;
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
    for (final TextEditingController c in _aliasC) {
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
    charTts: _charTts,
    plan: _plan,
    worldTts: _worldTts,
    narratorTts: _narratorTts,
    searchSource: widget.searchSource,
    memory: _memory,
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
                '“${widget.worldName}”的序列、回合与记忆将一并删除，且无法恢复。',
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
      charTts: _charTts,
      plan: _plan,
      worldTts: _worldTts,
      narratorTts: _narratorTts,
      memory: _memory,
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
                  memories: _memory,
                  owners: widget.owners,
                  onChanged: (List<CharacterMemory> next) =>
                      setState(() => _memory = next),
                  loadVersions: widget.loadMemoryVersions,
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
              JoButton(
                text: '×',
                tip: '关闭',
                onTap: () => Navigator.of(context).pop(),
              ),
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
          widget.isLastWorld ? '这是最后一个世界，至少需要保留一个世界。' : '该世界的序列、回合与记忆将一并删除，且无法恢复。',
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
        _Area(controller: _setting, hint: '时代、地点、规则、当前要事……'),
        const SizedBox(height: JoSpace.s5),
        _label(p, '开场'),
        _Area(controller: _opening, hint: '故事开始时，当前操控角色身处何处、看见什么……'),
      ],
    );
  }

  // ——— 角色 ———

  void _addChar() => setState(() {
    _chars = <CharCard>[..._chars, const CharCard(name: '', persona: '')];
    _personaC.add(TextEditingController());
    _aliasC.add(TextEditingController());
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
    _aliasC.removeAt(i).dispose();
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
                '根据世界观生成角色需要模型支持，当前版本暂未开放。',
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
              '共 ${_chars.length} 名角色',
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
            '当前还没有角色。',
            style: JoFonts.meta.copyWith(color: p.secondary, height: 1.7),
          ),
        for (int i = 0; i < _chars.length; i++) _charBox(p, i),
      ],
    );
  }

  String _aliasesText(Map<String, String> m) => m.entries
      .map((MapEntry<String, String> e) => '${e.key}=${e.value}')
      .join('\n');

  Map<String, String> _parseAliases(String s) {
    final Map<String, String> out = <String, String>{};
    for (final String line in s.split(RegExp(r'\r?\n'))) {
      final String t = line.trim();
      if (t.isEmpty) continue;
      final int i = t.indexOf('=');
      if (i <= 0) continue;
      final String k = t.substring(0, i).trim();
      final String v = t.substring(i + 1).trim();
      if (k.isNotEmpty && v.isNotEmpty) out[k] = v;
    }
    return out;
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
                  onChanged: (String v) => _putChar(
                    i,
                    CharCard(
                      name: v,
                      persona: c.persona,
                      location: c.location,
                      state: c.state,
                      aliases: c.aliases,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: JoSpace.s2),
              JoTooltip(
                text: '移除这个角色',
                child: JoTap(
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
              ),
            ],
          ),
          const SizedBox(height: JoSpace.s2),
          JoInput(
            initial: c.location,
            hint: '所在地点（留空则由最近步骤推断）',
            onChanged: (String v) => _putChar(
              i,
              CharCard(
                name: c.name,
                persona: c.persona,
                location: v,
                state: c.state,
                aliases: c.aliases,
              ),
            ),
          ),
          const SizedBox(height: JoSpace.s2),
          JoInput(
            initial: c.state,
            hint: '状态（伤势、装备、情绪，供裁定参考）',
            onChanged: (String v) => _putChar(
              i,
              CharCard(
                name: c.name,
                persona: c.persona,
                location: c.location,
                state: v,
                aliases: c.aliases,
              ),
            ),
          ),
          const SizedBox(height: JoSpace.s2),
          _Area(
            controller: _aliasC[i],
            hint: '别名（每行“目标名=称呼”；留空则使用规范名）',
            lines: 2,
            onChanged: (String v) => _putChar(
              i,
              CharCard(
                name: c.name,
                persona: c.persona,
                location: c.location,
                state: c.state,
                aliases: _parseAliases(v),
              ),
            ),
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
        // 链上最高的一级：每个角色各有一对“角色感知 / 角色行为”。
        if (widget.characters.isNotEmpty) ...<Widget>[
          for (final CharCard c in widget.characters) ...<Widget>[
            _label(p, c.name),
            for (final StepKind step in _charSteps)
              _modelRow(
                p,
                title: StepId.label(step.id),
                hint: step.hint,
                key: _charModels[c.name]?.stepKey(step.id) ?? '',
                follow: '跟随世界默认',
                onTap: () => _pickCharModel(c.name, step.id),
              ),
            _ttsRow(
              p,
              title: 'TTS',
              hint: '该角色朗读时使用的声音；留空则跟随世界设置',
              pick: TtsPick.of(_charTts[c.name] ?? ''),
              onTap: () => _pickCharTts(c.name),
            ),
            const SizedBox(height: JoSpace.s4),
          ],
          const SizedBox(height: JoSpace.s1),
        ],
        _label(p, '世界'),
        _ttsRow(
          p,
          title: '旁白 TTS',
          hint: '旁白专用；留空则跟随世界默认',
          pick: TtsPick.of(_narratorTts),
          onTap: _pickNarratorTts,
        ),
        _ttsRow(
          p,
          title: '世界默认 TTS',
          hint: '角色未单独设置时使用；留空则跟随全局设置',
          pick: TtsPick.of(_worldTts),
          onTap: _pickWorldTts,
        ),
        const SizedBox(height: JoSpace.s2),
        _modelRow(
          p,
          title: '世界默认',
          hint: '各步骤未单独设置时使用，其后才使用全局默认',
          key: _plan.defaultRef,
          follow: '不设（跟随全局默认）',
          onTap: () => _pickModel(''),
        ),
        const SizedBox(height: JoSpace.s3),
        for (final StepKind s in kSteps)
          _modelRow(
            p,
            title: StepId.label(s.id),
            hint: s.hint,
            key: _plan.stepKey(s.id),
            follow: '跟随世界默认',
            onTap: () => _pickModel(s.id),
          ),
      ],
    );
  }

  Future<void> _pickCharTts(String name) async {
    final TtsPickChoice? choice = await showTtsPicker(
      context,
      providers: widget.ttsProviders,
      current: TtsPick.of(_charTts[name] ?? ''),
      clearLabel: '不设（跟随世界 TTS）',
      modelRoot: widget.modelRoot,
    );
    if (choice == null || !mounted) return;
    setState(() {
      _charTts = <String, String>{
        ..._charTts,
        name: choice.cleared ? '' : (choice.pick?.key ?? ''),
      };
    });
  }

  Future<void> _pickWorldTts() async {
    final TtsPickChoice? choice = await showTtsPicker(
      context,
      providers: widget.ttsProviders,
      current: TtsPick.of(_worldTts),
      clearLabel: '不设（跟随全局 TTS）',
      modelRoot: widget.modelRoot,
    );
    if (choice == null || !mounted) return;
    setState(() {
      _worldTts = choice.cleared ? '' : (choice.pick?.key ?? '');
    });
  }

  Future<void> _pickNarratorTts() async {
    final TtsPickChoice? choice = await showTtsPicker(
      context,
      providers: widget.ttsProviders,
      current: TtsPick.of(_narratorTts),
      clearLabel: '不设（跟随世界默认）',
      modelRoot: widget.modelRoot,
    );
    if (choice == null || !mounted) return;
    setState(() {
      _narratorTts = choice.cleared ? '' : (choice.pick?.key ?? '');
    });
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

  String _ttsLabel(TtsPick? pick) {
    if (pick == null) return '不设';
    switch (pick.source) {
      case TtsSource.builtin:
        if (pick.modelId == 'kokoro') {
          final KokoroVoice? v = kokoroVoiceOf(int.tryParse(pick.voiceId) ?? 0);
          if (v != null) return 'Kokoro · ${v.displayName}';
        }
        return pick.modelId == 'kokoro' ? 'Kokoro 多语言' : 'MeloTTS 中文';
      case TtsSource.system:
        return '系统 TTS${pick.voiceId.isEmpty ? '' : '：${pick.voiceId}'}';
      case TtsSource.api:
        String name = pick.providerId;
        for (final Provider x in widget.ttsProviders) {
          if (x.id == pick.providerId) {
            name = x.name;
            break;
          }
        }
        return '$name · ${pick.voiceId}';
    }
  }

  Widget _ttsRow(
    JoPalette p, {
    required String title,
    required String hint,
    required TtsPick? pick,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: JoSpace.s2),
      child: JoTap(
        onTap: onTap,
        opaque: false,
        builder: (BuildContext context, bool hover, bool down) => Container(
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
                _ttsLabel(pick),
                style: JoFonts.meta.copyWith(
                  color: pick == null ? p.secondary : p.accent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
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
              '世界名在“常规”中修改，角色设置见“角色”标签页。',
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
  const _Area({
    required this.controller,
    this.hint,
    this.lines = 9,
    this.onChanged,
  });

  final TextEditingController controller;
  final String? hint;
  final int lines;
  final ValueChanged<String>? onChanged;

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
          onChanged: onChanged,
        ),
      ),
    );
  }
}
