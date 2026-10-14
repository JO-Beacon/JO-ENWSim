import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../model/provider.dart';
import '../theme/tokens.dart';
import 'common.dart';
import 'provider_panel.dart';

/// 设置：左边分类列表，右边内容。
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.settings,
    required this.onChanged,
    required this.providers,
    required this.onProvidersChanged,
    required this.onBack,
  });

  final JoSettings settings;
  final ValueChanged<JoSettings> onChanged;
  final List<Provider> providers;
  final ValueChanged<List<Provider>> onProvidersChanged;
  final VoidCallback onBack;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const List<String> _tabs = <String>[
    '语言',
    '外观',
    '服务商',
    '引擎',
    '数据',
    '关于',
  ];

  /// 流程图里各步决策用的提示词。
  static const List<({String id, String title, String hint})> _prompts =
      <({String id, String title, String hint})>[
    (id: 'A0', title: 'A₀ · 是否分裂序列', hint: '判断这条序列要不要裂成两条'),
    (id: 'A1', title: 'A₁ · 环境更新', hint: '把世界自身的事件推进到当前时刻'),
    (id: 'A2', title: 'A₂ · 框选参与的 B', hint: '本回合有资格执行 B₂ 的角色'),
    (id: 'A3', title: 'A₃ · 框选唯一 B', hint: '从参与角色里挑出唯一一个执行 B₂'),
    (id: 'A4', title: 'A₄ · 是否需要合并', hint: '要不要和其他序列合并'),
    (id: 'B1', title: 'B₁ · 角色感知', hint: '该角色感知到了什么'),
    (id: 'B2', title: 'B₂ · 角色行为', hint: '该角色如何行动'),
  ];

  int _tab = 0;
  late final Future<PackageInfo> _info = PackageInfo.fromPlatform();
  final Map<String, TextEditingController> _promptC =
      <String, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    for (final ({String id, String title, String hint}) p in _prompts) {
      _promptC[p.id] = TextEditingController();
    }
  }

  @override
  void dispose() {
    for (final TextEditingController c in _promptC.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final JoPalette p = JoTheme.of(context);
    return Container(
      color: p.bg,
      child: Column(
        children: <Widget>[
          JoPageHeader(title: '设置', onBack: widget.onBack),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SizedBox(width: 200, child: _list(p)),
                Container(width: 1, color: p.border),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 160),
                    // 必须给紧约束：默认那个松散 Stack 会把短内容居中。
                    layoutBuilder:
                        (Widget? current, List<Widget> previous) => Stack(
                      fit: StackFit.expand,
                      children: <Widget>[
                        ...previous,
                        ?current,
                      ],
                    ),
                    transitionBuilder: (Widget child, Animation<double> a) =>
                        FadeTransition(opacity: a, child: child),
                    child: KeyedSubtree(
                      key: ValueKey<int>(_tab),
                      child: _tab == 2
                          ? ProviderPanel(
                              providers: widget.providers,
                              onChanged: widget.onProvidersChanged,
                            )
                          : _body(p),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _list(JoPalette p) {
    return ListView(
      padding: const EdgeInsets.symmetric(
        horizontal: JoSpace.s2,
        vertical: JoSpace.s2,
      ),
      children: <Widget>[
        for (int i = 0; i < _tabs.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: JoSpace.s1),
            child: JoTap(
              onTap: () => setState(() => _tab = i),
              opaque: false,
              builder: (BuildContext context, bool hover, bool down) {
                final bool on = _tab == i;
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
                        : (hover ? p.surface.withValues(alpha: 0.5) : Colors.transparent),
                    border: JoShape.border(on || hover ? p.accent : p.border),
                    borderRadius: JoShape.br,
                  ),
                  child: Text(
                    _tabs[i],
                    style: JoFonts.ui.copyWith(
                      fontSize: 13,
                      color: on ? p.accent : p.text,
                      fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _body(JoPalette p) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(JoSpace.s5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _content(p),
      ),
    );
  }

  /// 页签下标：0 语言 / 1 外观 / 2 服务商（外面板接管，不进这里）/ 3 引擎 / 4 数据 / 5 关于
  List<Widget> _content(JoPalette p) {
    switch (_tab) {
      case 0: // 语言
        return <Widget>[
          JoSection(
            title: '语言',
            children: <Widget>[
              _pending('界面语言', '中文 · English 还没做'),
            ],
          ),
        ];
      case 1: // 外观
        return <Widget>[
          JoSection(
            title: '界面',
            children: <Widget>[
              JoField(
                label: '主题',
                hint: '暗 = 机器，明 = 纸',
                child: JoSegment<bool>(
                  options: const <({String label, bool value})>[
                    (label: '暗 · 机器', value: true),
                    (label: '明 · 纸', value: false),
                  ],
                  value: widget.settings.isDark,
                  onChanged: (bool v) =>
                      widget.onChanged(widget.settings.copyWith(isDark: v)),
                ),
              ),
            ],
          ),
          const SizedBox(height: JoSpace.s5),
          JoSection(
            title: '叙事正文',
            children: <Widget>[
              JoField(
                label: '字号',
                child: JoSegment<double>(
                  options: const <({String label, double value})>[
                    (label: '小', value: 14),
                    (label: '中', value: 16),
                    (label: '大', value: 18),
                  ],
                  value: widget.settings.bodySize,
                  onChanged: (double v) =>
                      widget.onChanged(widget.settings.copyWith(bodySize: v)),
                ),
              ),
              JoField(
                label: '字体',
                hint: '宋体用于正文（叙事），黑体用于界面',
                child: JoSegment<bool>(
                  options: const <({String label, bool value})>[
                    (label: '宋体', value: true),
                    (label: '黑体', value: false),
                  ],
                  value: widget.settings.serifBody,
                  onChanged: (bool v) =>
                      widget.onChanged(widget.settings.copyWith(serifBody: v)),
                ),
              ),
            ],
          ),
          const SizedBox(height: JoSpace.s5),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(JoSpace.s4),
            decoration: BoxDecoration(
              border: JoShape.border(p.border),
              borderRadius: JoShape.br,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('预览', style: JoFonts.meta.copyWith(color: p.secondary)),
                const SizedBox(height: JoSpace.s2),
                Text(
                  '雨敲在瓦上。你站在旧宅的门廊下，衣角在滴水，'
                  '脚边是一小片暗色的水渍。',
                  style: widget.settings.bodyStyle(p.text),
                ),
              ],
            ),
          ),
        ];
      case 3: // 引擎
        return <Widget>[
          Text(
            '引擎还没接入：这里填的提示词暂时不会被用到。',
            style: JoFonts.meta.copyWith(color: p.secondary, height: 1.7),
          ),
          const SizedBox(height: JoSpace.s5),
          for (final ({String id, String title, String hint}) pr in _prompts)
            _prompt(p, pr.title, pr.hint, _promptC[pr.id]!),
        ];
      case 4: // 数据
        return <Widget>[
          JoSection(
            title: '存档（还没接入）',
            children: <Widget>[
              _pending('位置', '存档放哪'),
              _pending('历史', '每回合存一版，AI 只读最新，旧版不删'),
              _pending('格式', 'SQLite'),
            ],
          ),
          const SizedBox(height: JoSpace.s5),
          JoSection(
            title: '导入 / 导出',
            children: <Widget>[
              _pending('导出世界', '打包成一个文件'),
              _pending('导入世界', '从文件读回来'),
            ],
          ),
        ];
      default: // 关于
        return _about(p);
    }
  }

  List<Widget> _about(JoPalette p) {
    return <Widget>[
      _hero(p),
      const SizedBox(height: JoSpace.s6),
      FutureBuilder<PackageInfo>(
        future: _info,
        builder: (BuildContext context, AsyncSnapshot<PackageInfo> snap) {
          final PackageInfo? i = snap.data;
          final String version = i == null
              ? '读取中…'
              : '${i.version}${i.buildNumber.isEmpty ? '' : '+${i.buildNumber}'}';
          return JoSection(
            title: '信息',
            children: <Widget>[
              _kv(p, '版本', version),
              _kv(p, '发布者', 'JO-Beacon'),
              _kv(p, '标识', 'io.github.jobeacon.joenws'),
              _kv(p, '平台', i?.appName ?? 'joenws'),
            ],
          );
        },
      ),
      const SizedBox(height: JoSpace.s5),
      JoSection(
        title: '许可',
        children: <Widget>[
          _kv(p, '本应用', 'Apache-2.0 · © 2026 JO-Beacon'),
          _kv(p, '字体', '思源黑体 / 思源宋体（SIL OFL 1.1）'),
          JoField(
            label: '开源依赖',
            hint: 'Flutter / Dart 及 pub 依赖',
            child: JoButton(
              text: '查看开源许可 →',
              onTap: _openLicenses,
              color: p.accent,
            ),
          ),
        ],
      ),
      const SizedBox(height: JoSpace.s5),
      Row(
        children: <Widget>[
          JoButton(
            text: 'GitHub',
            bordered: true,
            onTap: () => _open('https://github.com/jobeacon'),
          ),
          const SizedBox(width: JoSpace.s3),
          JoButton(
            text: 'Flutter',
            bordered: true,
            onTap: () => _open('https://flutter.dev'),
          ),
        ],
      ),
      const SizedBox(height: JoSpace.s7),
      Text(
        'No plot. Just causality.',
        style: JoFonts.meta.copyWith(color: p.secondary),
      ),
    ];
  }

  Widget _hero(JoPalette p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'JO-ENWSim',
          style: JoFonts.ui.copyWith(
            fontSize: 34,
            fontWeight: FontWeight.w700,
            color: p.text,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: JoSpace.s2),
        Text(
          'Emergent Narrative World Simulator',
          style: JoFonts.ui.copyWith(fontSize: 15, color: p.secondary),
        ),
        const SizedBox(height: JoSpace.s5),
        Container(
          padding: const EdgeInsets.only(left: JoSpace.s4),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: p.accent, width: 2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '不编排剧情，只推演因果。',
                style: JoFonts.ui.copyWith(fontSize: 16, color: p.text),
              ),
              const SizedBox(height: 4),
              Text(
                '设定世界，投放开场，让它自行展开。',
                style: JoFonts.ui.copyWith(fontSize: 14, color: p.secondary),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _kv(JoPalette p, String k, String v) {
    return JoField(
      label: k,
      child: Text(v, style: JoFonts.meta.copyWith(color: p.secondary)),
    );
  }

  Future<void> _open(String url) async {
    final Uri? uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// Flutter 会把所有 pub 依赖的许可汇总进应用里，这里直接展示那份。
  void _openLicenses() {
    showLicensePage(
      context: context,
      applicationName: 'JO-ENWSim',
      applicationLegalese: 'Apache-2.0 · © 2026 JO-Beacon',
    );
  }

  Widget _prompt(
    JoPalette p,
    String title,
    String hint,
    TextEditingController c,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: JoSpace.s5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                title,
                style: JoFonts.ui.copyWith(
                  fontSize: 13,
                  color: p.text,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: JoSpace.s2),
              Expanded(
                child: Text(
                  hint,
                  overflow: TextOverflow.ellipsis,
                  style: JoFonts.meta.copyWith(color: p.secondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: JoSpace.s2),
          _Area(controller: c, hint: '系统提示词……'),
        ],
      ),
    );
  }

  Widget _pending(String label, String hint) {
    return JoField(label: label, hint: hint, child: const SizedBox.shrink());
  }
}

/// 多行输入框（提示词用）。
class _Area extends StatelessWidget {
  const _Area({required this.controller, this.hint});

  final TextEditingController controller;
  final String? hint;

  @override
  Widget build(BuildContext context) {
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
      child: TextField(
        controller: controller,
        minLines: 4,
        maxLines: null,
        style: JoFonts.meta.copyWith(color: p.text, fontSize: 12, height: 1.7),
        cursorColor: p.accent,
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          hintText: hint,
          hintStyle: JoFonts.meta.copyWith(color: p.secondary),
        ),
      ),
    );
  }
}
