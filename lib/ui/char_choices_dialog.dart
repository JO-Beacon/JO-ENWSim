// 聊天栏里的「选择」面板。
//
// 采样策略、最大输出、流式、推理档位、要不要 JSON —— 这些**跟着角色走**，
// 每个角色各有一整套。这个面板一次编辑一个角色。
//
// 跟「模型详情」分工：那边是**能力声明**（客观事实），这边是**选择**。

import 'package:flutter/material.dart';

import '../model/char_choices.dart';
import '../model/provider.dart';
import '../theme/tokens.dart';
import 'common.dart';

/// 打开选择面板。返回改动后的一整套（取消则返回 null）。
/// 一个角色当前的模型情况。
typedef CharModelInfo = ({
  /// 显示成什么样（“服务商 · 模型”，或“未选模型”）
  String label,

  /// 那个模型的能力声明。null = 我们不知道（用户自己加的模型）
  ModelCaps? caps,

  /// 那个协议下“思考”长什么样。isEmpty = 我们不知道
  ThinkingSpec spec,
});

/// 打开选择面板。
///
/// **顺序是「先模型、后选择」**：面板先显示这个角色用哪个模型（点开可改），
/// 再按那个模型的能力与本协议的形状，长出它能做的选择。
Future<Map<String, CharChoices>?> showCharChoicesDialog(
  BuildContext context, {
  required List<String> characters,
  required Map<String, CharChoices> values,
  required CharModelInfo Function(String name) infoOf,
  required Future<void> Function(String name) onPickModel,
}) {
  return showDialog<Map<String, CharChoices>>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (BuildContext c) => _ChoicesDialog(
      characters: characters,
      initial: values,
      infoOf: infoOf,
      onPickModel: onPickModel,
    ),
  );
}

class _ChoicesDialog extends StatefulWidget {
  const _ChoicesDialog({
    required this.characters,
    required this.initial,
    required this.infoOf,
    required this.onPickModel,
  });

  final List<String> characters;
  final Map<String, CharChoices> initial;
  final CharModelInfo Function(String name) infoOf;
  final Future<void> Function(String name) onPickModel;

  @override
  State<_ChoicesDialog> createState() => _ChoicesDialogState();
}

class _ChoicesDialogState extends State<_ChoicesDialog> {
  late Map<String, CharChoices> _all = <String, CharChoices>{...widget.initial};
  late String _who = widget.characters.isEmpty ? '' : widget.characters.first;

  CharChoices get _cur => _all[_who] ?? const CharChoices();

  void _put(CharChoices next) =>
      setState(() => _all = <String, CharChoices>{..._all, _who: next});

  @override
  Widget build(BuildContext context) {
    final JoPalette p = JoTheme.of(context);
    final Size mq = MediaQuery.of(context).size;
    final double w = (mq.width - 64).clamp(420.0, 720.0);
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
            _header(context, p),
            if (widget.characters.isEmpty)
              Expanded(
                child: Center(
                  child: Text(
                    '这个世界还没有角色',
                    style: JoFonts.meta.copyWith(color: p.secondary),
                  ),
                ),
              )
            else ...<Widget>[
              _whoRow(p),
              Container(height: 1, color: p.border),
              Expanded(child: _fields(p)),
            ],
            _footer(context, p),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, JoPalette p) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: JoSpace.s4,
        vertical: JoSpace.s3,
      ),
      decoration: BoxDecoration(border: Border(bottom: JoShape.side(p.border))),
      child: Row(
        children: <Widget>[
          Text(
            '选择',
            style: JoFonts.ui.copyWith(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: p.text,
            ),
          ),
          const SizedBox(width: JoSpace.s3),
          Expanded(
            child: Text(
              '每个角色各有一套',
              overflow: TextOverflow.ellipsis,
              style: JoFonts.meta.copyWith(color: p.secondary),
            ),
          ),
          JoButton(text: '×', onTap: () => Navigator.of(context).pop()),
        ],
      ),
    );
  }

  Widget _whoRow(JoPalette p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        JoSpace.s4,
        JoSpace.s3,
        JoSpace.s4,
        JoSpace.s3,
      ),
      child: Wrap(
        spacing: JoSpace.s2,
        runSpacing: JoSpace.s2,
        children: <Widget>[
          for (final String name in widget.characters)
            JoTap(
              onTap: () => setState(() => _who = name),
              opaque: false,
              builder: (BuildContext context, bool hover, bool down) {
                final bool on = name == _who;
                return AnimatedContainer(
                  duration: kJoTapMs,
                  curve: Curves.easeOut,
                  padding: const EdgeInsets.symmetric(
                    horizontal: JoSpace.s3,
                    vertical: JoSpace.s2,
                  ),
                  decoration: BoxDecoration(
                    color: on ? p.surface : Colors.transparent,
                    border: JoShape.border(on || hover ? p.accent : p.border),
                    borderRadius: JoShape.br,
                  ),
                  child: AnimatedDefaultTextStyle(
                    duration: kJoTapMs,
                    curve: Curves.easeOut,
                    style: JoFonts.meta.copyWith(
                      color: on ? p.accent : p.secondary,
                      fontSize: 10,
                    ),
                    child: Text(name),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _fields(JoPalette p) {
    final CharChoices c = _cur;
    final CharModelInfo info = widget.infoOf(_who);
    final ModelCaps? caps = info.caps;
    final ThinkingSpec spec = info.spec;
    final bool known = caps != null && !spec.isEmpty;
    return ListView(
      padding: const EdgeInsets.all(JoSpace.s4),
      children: <Widget>[
        // ——— 先模型 ———
        _label(p, '这个角色用的模型'),
        JoTap(
          onTap: () async {
            await widget.onPickModel(_who);
            if (mounted) setState(() {});
          },
          opaque: false,
          builder: (BuildContext context, bool hover, bool down) {
            return AnimatedContainer(
              duration: kJoTapMs,
              curve: Curves.easeOut,
              padding: const EdgeInsets.symmetric(
                horizontal: JoSpace.s3,
                vertical: JoSpace.s3,
              ),
              decoration: BoxDecoration(
                border: JoShape.border(hover ? p.accent : p.border),
                borderRadius: JoShape.br,
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      info.label,
                      overflow: TextOverflow.ellipsis,
                      style: JoFonts.meta.copyWith(
                        color: info.label == '未选模型' ? p.secondary : p.text,
                      ),
                    ),
                  ),
                  Text('改', style: JoFonts.meta.copyWith(color: p.accent)),
                ],
              ),
            );
          },
        ),
        if (caps == null)
          _note(p, '这个模型没有能力声明（大概是用户自己加的），所以下面只摆通用的几样。')
        else
          _note(
            p,
            '它声明：上下文 ${caps.contextWindow.isEmpty ? '—' : caps.contextWindow}'
            ' · 输出上限 ${caps.maxOutput.isEmpty ? '—' : caps.maxOutput}'
            ' · 输入 ${caps.inputModalities.join('/')}'
            '${caps.vision ? ' · 能看图' : ''}'
            '${caps.tools ? ' · 工具' : ''}'
            '${caps.reasoning ? ' · 推理' : ''}'
            '${caps.stream == true ? ' · 流式' : ''}',
          ),
        const SizedBox(height: JoSpace.s5),

        // ——— 再选择 ———
        _label(p, '温度'),
        JoInput(
          initial: c.temperature,
          hint: '留空 = 不传',
          onChanged: (String v) => _put(c.copyWith(temperature: v)),
        ),
        const SizedBox(height: JoSpace.s4),
        _label(p, '核采样 top_p'),
        JoInput(
          initial: c.topP,
          hint: '留空 = 不传',
          onChanged: (String v) => _put(c.copyWith(topP: v)),
        ),
        const SizedBox(height: JoSpace.s4),
        _label(p, '最大输出'),
        JoInput(
          initial: c.maxOutput,
          hint: caps != null && caps.maxOutput.isNotEmpty
              ? '留空 = 不传（这个模型的上限是 ${caps.maxOutput}）'
              : '留空 = 不传（跟模型那边的“上限”不是一回事）',
          onChanged: (String v) => _put(c.copyWith(maxOutput: v)),
        ),
        const SizedBox(height: JoSpace.s4),
        _label(p, '流式输出'),
        JoSegment<bool>(
          options: const <({String label, bool value})>[
            (label: '否', value: false),
            (label: '是', value: true),
          ],
          value: c.stream,
          onChanged: (bool v) => _put(c.copyWith(stream: v)),
        ),
        // 模型声明不支持流式时：这条选择**不生效**，但数据留着 ——
        // 换回支持流式的模型就自动再生效，不用重新勾。
        // 只对“声明了不支持”的模型这么说；没声明（不知道）的不拦。
        if (caps != null && caps.stream == false) ...<Widget>[
          const SizedBox(height: JoSpace.s2),
          Text(
            '不生效 —— 这个模型声明它不支持流式。'
            '你的选择留着，换回支持的模型就再生效。',
            style: JoFonts.meta.copyWith(color: p.accent, fontSize: 10),
          ),
        ],
        if (spec.levels.isNotEmpty) ...<Widget>[
          const SizedBox(height: JoSpace.s4),
          _label(p, '推理等级'),
          Wrap(
            spacing: JoSpace.s2,
            runSpacing: JoSpace.s2,
            children: <Widget>[
              _chip(
                p,
                '不设',
                '',
                c.effortLevel,
                (String v) => _put(c.copyWith(effortLevel: v)),
              ),
              for (final String v in spec.levels)
                _chip(
                  p,
                  v,
                  v,
                  c.effortLevel,
                  (String x) => _put(c.copyWith(effortLevel: x)),
                ),
            ],
          ),
        ],
        if (spec.hasBudget) ...<Widget>[
          const SizedBox(height: JoSpace.s4),
          _label(p, '推理预算（tokens）'),
          JoInput(
            initial: c.effortBudget,
            hint: '留空 = 不传（这个厂商用预算而不是等级）',
            onChanged: (String v) => _put(c.copyWith(effortBudget: v)),
          ),
        ],
        if (!known)
          _note(
            p,
            caps == null
                ? '这个模型支不支持推理、用等级还是预算，我们不知道，所以推理这两项不摆。'
                : '这个模型没有声明支持推理，所以推理这两项不摆。',
          ),
        const SizedBox(height: JoSpace.s4),
        _label(p, '请求 JSON 输出'),
        JoSegment<bool>(
          options: const <({String label, bool value})>[
            (label: '否', value: false),
            (label: '是', value: true),
          ],
          value: c.jsonOutput,
          onChanged: (bool v) => _put(c.copyWith(jsonOutput: v)),
        ),
      ],
    );
  }

  Widget _chip(
    JoPalette p,
    String label,
    String value,
    String current,
    ValueChanged<String> onTap,
  ) {
    final bool on = value == current;
    return JoTap(
      onTap: () => onTap(value),
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
            border: JoShape.border(on || hover ? p.accent : p.border),
            borderRadius: JoShape.br,
          ),
          child: AnimatedDefaultTextStyle(
            duration: kJoTapMs,
            curve: Curves.easeOut,
            style: JoFonts.meta.copyWith(
              color: on ? p.accent : p.secondary,
              fontSize: 10,
            ),
            child: Text(label),
          ),
        );
      },
    );
  }

  Widget _note(JoPalette p, String text) => Padding(
    padding: const EdgeInsets.only(top: JoSpace.s2),
    child: Text(
      text,
      style: JoFonts.meta.copyWith(
        color: p.secondary,
        fontSize: 10,
        height: 1.7,
      ),
    ),
  );

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
              '等级与预算两个都留着：到底发哪个，由引擎看当前模型决定。',
              style: JoFonts.meta.copyWith(color: p.secondary, fontSize: 10),
            ),
          ),
          const SizedBox(width: JoSpace.s3),
          JoButton(text: '取消', onTap: () => Navigator.of(context).pop()),
          const SizedBox(width: JoSpace.s2),
          JoButton(
            text: '保存',
            color: p.accent,
            onTap: () => Navigator.of(context).pop(_all),
          ),
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
