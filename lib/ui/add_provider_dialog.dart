import 'package:flutter/material.dart';

import '../model/provider.dart';
import '../theme/tokens.dart';
import 'common.dart';

/// “添加服务商”：**只做选择**，点一张卡就直接加进去。
///
/// 参数不在这里填。添加完右侧详情页会立刻显示这个服务商，那里本来就有
/// 掩码 / 显示 / 测试、DeepSeek 参数区、模型列表，比弹窗里几个裸输入框好用。
/// 换句话说：**添加是“选一个”，配置是“改它”**，两件事不挤在一个地方。
Future<Provider?> showAddProviderDialog(
  BuildContext context, {
  List<ProviderPreset> presets = kProviderPresets,
}) {
  return showDialog<Provider>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (BuildContext c) => _AddProviderDialog(presets: presets),
  );
}

class _AddProviderDialog extends StatelessWidget {
  const _AddProviderDialog({required this.presets});

  final List<ProviderPreset> presets;

  void _pop(
    BuildContext context, {
    required String name,
    required Protocol protocol,
    String baseUrl = '',
    String apiPath = '',
    List<ModelRef> models = const <ModelRef>[],
    CustomShape? custom,
    bool responses = false,
  }) {
    Navigator.of(context).pop(
      Provider(
        id: newProviderId(),
        protocol: protocol,
        name: name,
        baseUrl: baseUrl,
        apiPath: apiPath,
        models: models,
        custom: custom,
        useResponsesApi: responses,
      ),
    );
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
            Expanded(child: _list(context, p)),
            _footer(p),
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
            '添加服务商',
            style: JoFonts.ui.copyWith(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: p.text,
            ),
          ),
          const Spacer(),
          JoButton(
            text: '×',
            onTap: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _footer(JoPalette p) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: JoSpace.s4,
        vertical: JoSpace.s2,
      ),
      decoration: BoxDecoration(border: Border(top: JoShape.side(p.border))),
      child: Text(
        '点一下就添加。名称、Key、地址这些都添加完在右边改。',
        style: JoFonts.meta.copyWith(color: p.secondary),
      ),
    );
  }

  Widget _list(BuildContext context, JoPalette p) {
    return ListView(
      padding: const EdgeInsets.all(JoSpace.s4),
      children: <Widget>[
        _section(p, '厂商预设'),
        for (final ProviderPreset ps in presets)
          _card(
            context,
            p,
            title: ps.name,
            subtitle: ps.baseUrl,
            badge: ps.models.isEmpty ? null : '${ps.models.length} 个模型',
            onTap: () => _pop(
              context,
              name: ps.name,
              protocol: ps.protocol,
              baseUrl: ps.baseUrl,
              apiPath: ps.apiPath,
              models: ps.models,
            ),
          ),
        const SizedBox(height: JoSpace.s5),
        _section(p, '自定义'),
        for (final CustomShape c in CustomShape.values)
          _card(
            context,
            p,
            title: '自定义 · ${c.label}',
            subtitle: '地址留空，添加后在详情页填',
            onTap: () => _pop(
              context,
              name: '自定义 · ${c.label}',
              protocol: c.protocol,
              custom: c,
              responses: c.responses,
            ),
          ),
      ],
    );
  }

  Widget _section(JoPalette p, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 0, 0, JoSpace.s2),
        child: Text(text, style: JoFonts.meta.copyWith(color: p.secondary)),
      );

  Widget _card(
    BuildContext context,
    JoPalette p, {
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    String? badge,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: JoSpace.s2),
      child: JoTap(
        onTap: onTap,
        opaque: false,
        cursor: SystemMouseCursors.click,
        builder: (BuildContext context, bool hover, bool down) {
          return AnimatedContainer(
            duration: kJoTapMs,
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(
              horizontal: JoSpace.s4,
              vertical: JoSpace.s3,
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
                        style: JoFonts.ui.copyWith(
                          fontSize: 13,
                          color: hover ? p.accent : p.text,
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
                if (badge != null) ...<Widget>[
                  Text(
                    badge,
                    style: JoFonts.meta.copyWith(
                      color: p.secondary,
                      fontSize: 10,
                    ),
                  ),
                  const SizedBox(width: JoSpace.s3),
                ],
                Text('›', style: JoFonts.meta.copyWith(color: p.secondary)),
              ],
            ),
          );
        },
      ),
    );
  }
}
