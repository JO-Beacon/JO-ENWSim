// 模型选择器。
//
// 每世界的模型配置在 编辑世界 → 模型；全局默认在 设置 → 模型。
// 这里只负责“弹一个列表让人挑一个模型”。

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
                        '还没有可用模型\n可在“设置 → 模型服务”配置。',
                        textAlign: TextAlign.center,
                        style: JoFonts.meta.copyWith(
                          color: p.secondary,
                          height: 1.8,
                        ),
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
                              on:
                                  current ==
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
          JoButton(
            text: '×',
            tip: '关闭',
            onTap: () => Navigator.of(context).pop(),
          ),
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
