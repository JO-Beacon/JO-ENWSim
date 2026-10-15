// 每世界的模型配置界面。
//
// 从发言框上那个模型按钮进来：先看/改“世界默认”，再逐项看/改七步。
// 全局默认不在这里——在设置里。

import 'package:flutter/material.dart';

import '../model/model_plan.dart';
import '../model/provider.dart';
import '../theme/tokens.dart';
import 'common.dart';

/// 可选的一组模型：一个服务商 + 它下面启用着的模型。
typedef ModelGroup = ({
  String providerId,
  String providerName,
  List<String> models,
});

/// 挑一个模型。返回 null = 取消或清除（看 [allowClear]）。
Future<ModelPick?> showModelPicker(
  BuildContext context, {
  required List<ModelGroup> groups,
  String? current,
  bool allowClear = true,
  String clearLabel = '不设（跟随上层）',
}) {
  return showDialog<ModelPick>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (BuildContext c) => _PickerDialog(
      groups: groups,
      current: current,
      allowClear: allowClear,
      clearLabel: clearLabel,
    ),
  );
}

/// 每世界的模型配置：世界默认 + 七步。
Future<ModelPlan?> showModelPlanDialog(
  BuildContext context, {
  required ModelPlan plan,
  required ModelPlan globalPlan,
  required List<ModelGroup> groups,
  required String worldName,
}) {
  return showDialog<ModelPlan>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (BuildContext c) => _PlanDialog(
      initial: plan,
      globalPlan: globalPlan,
      groups: groups,
      worldName: worldName,
    ),
  );
}

/// 从已启用的服务商里整理出可选模型（两个层级共用）。
List<ModelGroup> modelGroupsOf(List<Provider> providers) {
  final List<ModelGroup> out = <ModelGroup>[];
  for (final Provider pv in providers) {
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

/// 把一个模型键变成能读的一行。服务商被删了也不会崩。
String modelKeyLabel(List<ModelGroup> groups, String key) {
  final ModelPick? pick = ModelPick.of(key);
  if (pick == null) return '';
  for (final ModelGroup g in groups) {
    if (g.providerId == pick.providerId) {
      return '${g.providerName} · ${pick.modelId}';
    }
  }
  return pick.modelId;
}

// ————————————————————————————— 挑一个模型

class _PickerDialog extends StatelessWidget {
  const _PickerDialog({
    required this.groups,
    required this.current,
    required this.allowClear,
    required this.clearLabel,
  });

  final List<ModelGroup> groups;
  final String? current;
  final bool allowClear;
  final String clearLabel;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = JoTheme.of(context);
    final Size mq = MediaQuery.of(context).size;
    final double h = (mq.height - 120).clamp(220.0, 520.0);

    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 460,
        height: h,
        decoration: BoxDecoration(
          color: p.bg,
          border: JoShape.border(p.border),
          borderRadius: JoShape.br,
        ),
        child: Column(
          children: <Widget>[
            _header(context, p),
            if (allowClear)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  JoSpace.s3,
                  JoSpace.s3,
                  JoSpace.s3,
                  0,
                ),
                child: _row(
                  context,
                  p,
                  label: clearLabel,
                  on: (current ?? '').isEmpty,
                  onTap: () => Navigator.of(context).pop(),
                ),
              ),
            Expanded(
              child: groups.isEmpty
                  ? Center(
                      child: Text(
                        '还没有可用的模型\n先去 设置 → 服务商 配一个',
                        textAlign: TextAlign.center,
                        style: JoFonts.meta
                            .copyWith(color: p.secondary, height: 1.8),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.all(JoSpace.s3),
                      children: <Widget>[
                        for (final ModelGroup g in groups) ...<Widget>[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(
                              JoSpace.s3,
                              JoSpace.s2,
                              JoSpace.s3,
                              JoSpace.s1,
                            ),
                            child: Text(
                              '▾ ${g.providerName}',
                              style: JoFonts.meta.copyWith(color: p.secondary),
                            ),
                          ),
                          for (final String id in g.models)
                            _row(
                              context,
                              p,
                              label: id,
                              on: current ==
                                  ModelPick(
                                    providerId: g.providerId,
                                    modelId: id,
                                  ).key,
                              onTap: () => Navigator.of(context).pop(
                                ModelPick(
                                  providerId: g.providerId,
                                  modelId: id,
                                ),
                              ),
                            ),
                        ],
                      ],
                    ),
            ),
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
            '选择模型',
            style: JoFonts.ui.copyWith(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: p.text,
            ),
          ),
          const Spacer(),
          JoButton(text: '×', onTap: () => Navigator.of(context).pop()),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context,
    JoPalette p, {
    required String label,
    required bool on,
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
            color: on
                ? p.surface
                : (hover
                    ? p.surface.withValues(alpha: 0.5)
                    : Colors.transparent),
            border: JoShape.border(on || hover ? p.accent : Colors.transparent),
            borderRadius: JoShape.br,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: JoFonts.meta.copyWith(color: on ? p.accent : p.text),
                ),
              ),
              if (on)
                Text(
                  '当前',
                  style: JoFonts.meta.copyWith(color: p.accent, fontSize: 10),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ————————————————————————————— 每世界的模型配置

class _PlanDialog extends StatefulWidget {
  const _PlanDialog({
    required this.initial,
    required this.globalPlan,
    required this.groups,
    required this.worldName,
  });

  final ModelPlan initial;

  /// 全局那一层（设置 → 引擎）。用来算每一步最终落在哪。
  final ModelPlan globalPlan;
  final List<ModelGroup> groups;
  final String worldName;

  @override
  State<_PlanDialog> createState() => _PlanDialogState();
}

class _PlanDialogState extends State<_PlanDialog> {
  late ModelPlan _plan = widget.initial;

  Future<void> _pickWorldDefault() async {
    final ModelPick? pick = await showModelPicker(
      context,
      groups: widget.groups,
      current: _plan.defaultRef,
      clearLabel: '不设（交给全局默认）',
    );
    if (!mounted) return;
    setState(() {
      _plan = _plan.copyWith(
        defaultRef: pick?.key ?? '',
      );
    });
  }

  Future<void> _pickStep(StepKind step) async {
    final ModelPick? pick = await showModelPicker(
      context,
      groups: widget.groups,
      current: _plan.stepKey(step.id),
      clearLabel: '不设（跟随世界默认）',
    );
    if (!mounted) return;
    setState(() => _plan = _plan.withStep(step.id, pick?.key ?? ''));
  }

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
            Expanded(child: _list(p)),
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
            '模型',
            style: JoFonts.ui.copyWith(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: p.text,
            ),
          ),
          const SizedBox(width: JoSpace.s3),
          Expanded(
            child: Text(
              '${widget.worldName} · 每一步都可以单独指定',
              overflow: TextOverflow.ellipsis,
              style: JoFonts.meta.copyWith(color: p.secondary),
            ),
          ),
          JoButton(text: '×', onTap: () => Navigator.of(context).pop()),
        ],
      ),
    );
  }

  /// 这一步没单独设时，右侧显示什么。
  ///
  /// 顺着往下算：本世界默认 → 这一步的全局默认 → 全局总默认。
  String _followLabel(String stepId) {
    final String world = _plan.defaultRef;
    if (world.isNotEmpty) {
      return '跟随世界默认 → ${modelKeyLabel(widget.groups, world)}';
    }
    final String g = widget.globalPlan.stepKey(stepId);
    if (g.isNotEmpty) {
      return '跟随全局默认 → ${modelKeyLabel(widget.groups, g)}';
    }
    final String top = widget.globalPlan.defaultRef;
    if (top.isNotEmpty) {
      return '跟随全局默认 → ${modelKeyLabel(widget.groups, top)}';
    }
    return '还没设';
  }

  Widget _list(JoPalette p) {
    return ListView(
      padding: const EdgeInsets.all(JoSpace.s4),
      children: <Widget>[
        _row(
          p,
          title: '世界默认',
          hint: '这一步之后才轮到全局默认',
          value: modelKeyLabel(widget.groups, _plan.defaultRef),
          follow: '不设（交给全局默认）',
          onTap: _pickWorldDefault,
        ),
        const SizedBox(height: JoSpace.s3),
        for (final StepKind s in kSteps)
          _row(
            p,
            title: s.title,
            hint: s.hint,
            value: modelKeyLabel(widget.groups, _plan.stepKey(s.id)),
            follow: _followLabel(s.id),
            onTap: () => _pickStep(s),
          ),
      ],
    );
  }

  Widget _row(
    JoPalette p, {
    required String title,
    required String hint,
    required String value,
    required String follow,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: JoSpace.s2),
      child: JoTap(
        onTap: onTap,
        opaque: false,
        builder: (BuildContext context, bool hover, bool down) {
          final bool set = value.isNotEmpty;
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
              '没设的步骤跟随世界默认；世界默认没设就交给全局默认。',
              style: JoFonts.meta.copyWith(color: p.secondary, fontSize: 10),
            ),
          ),
          const SizedBox(width: JoSpace.s3),
          JoButton(
            text: '取消',
            onTap: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: JoSpace.s2),
          JoButton(
            text: '保存',
            color: p.accent,
            onTap: () => Navigator.of(context).pop(_plan),
          ),
        ],
      ),
    );
  }
}
