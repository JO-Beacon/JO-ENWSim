import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../model/languages.dart';
import '../model/model_plan.dart';
import '../model/provider.dart';
import '../model/shortcuts.dart';
import '../theme/tokens.dart';
import 'common.dart';
import 'licenses_page.dart';
import 'model_plan_dialog.dart';
import 'provider_panel.dart';

/// 设置：左边分类列表，右边内容。
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.settings,
    required this.onChanged,
    required this.providers,
    required this.onProvidersChanged,
    required this.globalPlan,
    required this.onGlobalPlanChanged,
    this.servicesNote,
    this.globalPlanNote,
    required this.keys,
    required this.onKeysChanged,
    required this.onBack,
  });

  final JoSettings settings;
  final ValueChanged<JoSettings> onChanged;

  /// 全局模型默认：总默认 + 每种步骤的全局默认。
  final ModelPlan globalPlan;
  final ValueChanged<ModelPlan> onGlobalPlanChanged;

  /// 存档读不出来时的提示语（如实说，不藏）。
  final String? servicesNote;
  final String? globalPlanNote;

  /// 快捷键：动作 id → 键位字符串。
  final Map<String, String> keys;
  final ValueChanged<Map<String, String>> onKeysChanged;
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
    '行为',
    '快捷键',
    '模型服务',
    '搜索服务',
    '语音服务',
    '引擎',
    '数据',
    '关于',
  ];

  /// 流程图里各步决策用的提示词。
  ///
  /// 步骤清单与“每世界模型配置”共用 model_plan.dart 里的 kSteps，
  /// 免得以后改步骤要改两处。
  static const List<StepKind> _prompts = kSteps;

  /// 三类服务共用同一块面板：模型 / 搜索 / 语音只是清单与预设不同。
  Widget _servicePanel(ServiceKind kind) {
    return ProviderPanel(
      providers: <Provider>[
        for (final Provider x in widget.providers)
          if (x.kind == kind) x,
      ],
      note: widget.servicesNote,
      presets: switch (kind) {
        ServiceKind.model => kProviderPresets,
        ServiceKind.search => kSearchPresets,
        ServiceKind.voice => kVoicePresets,
      },
      onChanged: (List<Provider> next) {
        // 只换这一类，别动其它类。
        widget.onProvidersChanged(<Provider>[
          for (final Provider x in widget.providers)
            if (x.kind != kind) x,
          ...next,
        ]);
      },
    );
  }

  Future<void> _pickGlobalModel(String stepId) async {
    final ModelPick? pick = await showModelPicker(
      context,
      groups: modelGroupsOf(widget.providers),
      current: stepId.isEmpty
          ? widget.globalPlan.defaultRef
          : widget.globalPlan.stepKey(stepId),
      clearLabel: stepId.isEmpty ? '不设（未设置）' : '不设（跟随全局默认）',
    );
    if (!mounted) return;
    widget.onGlobalPlanChanged(
      stepId.isEmpty
          ? widget.globalPlan.copyWith(defaultRef: pick?.key ?? '')
          : widget.globalPlan.withStep(stepId, pick?.key ?? ''),
    );
  }

  /// 全局那两级：总默认 + 每种步骤的全局默认。
  List<Widget> _globalModels(JoPalette p) {
    return <Widget>[
      _modelRow(
        p,
        title: '全局默认',
        hint: '所有步骤最后都落到它',
        stepId: '',
        follow: '未设置',
      ),
      for (final StepKind s in kSteps)
        _modelRow(
          p,
          title: s.title,
          hint: s.hint,
          stepId: s.id,
          follow: '跟随全局默认',
        ),
    ];
  }

  Widget _modelRow(
    JoPalette p, {
    required String title,
    required String hint,
    required String stepId,
    required String follow,
  }) {
    final String key = stepId.isEmpty
        ? widget.globalPlan.defaultRef
        : widget.globalPlan.stepKey(stepId);
    final String value =
        modelKeyLabel(modelGroupsOf(widget.providers), key);
    return _modelRowBox(
      p,
      title: title,
      hint: hint,
      value: value.isEmpty ? follow : value,
      set: value.isNotEmpty,
      onTap: () => _pickGlobalModel(stepId),
    );
  }

  Widget _modelRowBox(
    JoPalette p, {
    required String title,
    required String hint,
    required String value,
    required bool set,
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
                    Text(title,
                        style:
                            JoFonts.ui.copyWith(fontSize: 13, color: p.text)),
                    const SizedBox(height: 2),
                    Text(
                      hint,
                      overflow: TextOverflow.ellipsis,
                      style: JoFonts.meta
                          .copyWith(color: p.secondary, fontSize: 10),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: JoSpace.s3),
              Text(
                value,
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
    );
  }

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
                      child: _tab >= 4 && _tab <= 6
                          ? _servicePanel(ServiceKind.values[_tab - 4])
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

  /// 界面语言。只有这一个语言设置，没别的。
  String _lang = kJoLangDefault;

  /// 页签下标：0 语言 / 1 外观 / 2 行为（先留空）/ 3 快捷键
  ///           / 4–6 三类服务（外面板接管）/ 7 引擎 / 8 数据 / 9 关于
  List<Widget> _content(JoPalette p) {
    switch (_tab) {
      case 0: // 语言
        return <Widget>[
          JoSection(
            title: '界面语言',
            children: <Widget>[
              for (final JoLanguage l in kJoLanguages)
                JoTap(
                  onTap: () => setState(() => _lang = l.tag),
                  builder: (BuildContext c, bool hover, bool down) => Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: JoSpace.s2),
                    child: Row(
                      children: <Widget>[
                        SizedBox(
                          width: 22,
                          child: _lang == l.tag
                              ? Text(
                                  '✓',
                                  style: JoFonts.meta.copyWith(color: p.accent),
                                )
                              : null,
                        ),
                        Expanded(
                          child: Text(
                            l.label,
                            style: JoFonts.ui.copyWith(
                              fontSize: 13,
                              color: _lang == l.tag ? p.text : p.secondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: JoSpace.s3),
          Text(
            '列表按国际标准写：BCP 47 标签（zh-Hans-CN 这种）+ 语言自己的名字。'
            '目前只有中文（中国）做好了 —— 选别的不会换掉界面文字，也不存。',
            style: JoFonts.meta.copyWith(color: p.secondary, fontSize: 10),
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
                child: JoSegment<String>(
                  options: const <({String label, String value})>[
                    (label: '跟随系统', value: 'system'),
                    (label: '暗 · 机器', value: 'dark'),
                    (label: '明 · 纸', value: 'light'),
                  ],
                  value: widget.settings.followSystem
                      ? 'system'
                      : (widget.settings.isDark ? 'dark' : 'light'),
                  // 选「跟随系统」时**保留** isDark —— 那是上次选的那套，
                  // 以后关掉跟随时要回到它。
                  onChanged: (String v) => widget.onChanged(
                    widget.settings.copyWith(
                      followSystem: v == 'system',
                      isDark: v == 'dark'
                          ? true
                          : (v == 'light' ? false : widget.settings.isDark),
                    ),
                  ),
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
      case 3: // 快捷键
        return <Widget>[
          Text(
            '点一下那块，然后按你要的组合键，就记下了。\n'
            '想退出捕获就点别处；按 Esc 则清除这一条（变成未设置）。'
            '认不出来的键会当场标出来。',
            style: JoFonts.meta.copyWith(color: p.secondary, height: 1.7),
          ),
          const SizedBox(height: JoSpace.s5),
          JoSection(
            title: '快捷键',
            children: <Widget>[
              for (final JoKeyItem k in kJoKeys) ...<Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      flex: 2,
                      child: Text(
                        k.label,
                        style: JoFonts.ui.copyWith(fontSize: 13, color: p.text),
                      ),
                    ),
                    const SizedBox(width: JoSpace.s3),
                    Expanded(
                      flex: 3,
                      child: JoKeyField(
                        spec: widget.keys[k.id] ?? k.fallback,
                        onChanged: (String v) => widget.onKeysChanged(
                          <String, String>{...widget.keys, k.id: v},
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 18,
                      // 空 = 没设，不是“认不出”
                      child: (widget.keys[k.id] ?? '').trim().isNotEmpty &&
                              joActivator(widget.keys[k.id] ?? '') == null
                          ? Text(
                              '认不出',
                              style: JoFonts.meta.copyWith(color: p.accent),
                            )
                          : null,
                    ),
                  ],
                ),
                const SizedBox(height: JoSpace.s3),
              ],
            ],
          ),
          const SizedBox(height: JoSpace.s4),
          Align(
            alignment: Alignment.centerLeft,
            child: JoButton(
              text: '还原回默认',
              bordered: true,
              onTap: () => widget.onKeysChanged(joDefaultKeys()),
            ),
          ),
          const SizedBox(height: JoSpace.s4),
          Text(
            '「发送」这条落在输入框上，其余几条是全局的。'
            '改完立刻生效，也存在本地。',
            style: JoFonts.meta.copyWith(color: p.secondary, fontSize: 10),
          ),
        ];
      case 2: // 行为（先留空）
        return <Widget>[];
      case 7: // 引擎
        return <Widget>[
          Text(
            '引擎还没接入：这里填的提示词暂时不会被用到。',
            style: JoFonts.meta.copyWith(color: p.secondary, height: 1.7),
          ),
          if (widget.globalPlanNote != null) ...<Widget>[
            const SizedBox(height: JoSpace.s3),
            Text(
              widget.globalPlanNote!,
              style: JoFonts.meta.copyWith(color: p.secondary, height: 1.7),
            ),
          ],
          const SizedBox(height: JoSpace.s5),
          JoSection(
            title: '全局默认模型',
            children: _globalModels(p),
          ),
          const SizedBox(height: JoSpace.s5),
          for (final ({String id, String title, String hint}) pr in _prompts)
            _prompt(p, pr.title, pr.hint, _promptC[pr.id]!),
        ];
      case 8: // 数据
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
          _kv(p, '图标', 'Remix Icon（Remix Icon License v1.0）'),
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

  /// 开源许可。**自己写的一页** —— 自带那个会把框架的许可按库文件重复几百遍。
  ///
  /// 转场也用我们自己的：160ms 淡入淡出，不做位移（跟页面切换一致）。
  /// 所以这里不用 MaterialPageRoute（它带系统的滑动转场）。
  void _openLicenses() {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 160),
        reverseTransitionDuration: const Duration(milliseconds: 160),
        pageBuilder: (
          BuildContext c,
          Animation<double> primary,
          Animation<double> secondary,
        ) =>
            const LicensesPage(),
        transitionsBuilder: (
          BuildContext c,
          Animation<double> a,
          Animation<double> secondary,
          Widget child,
        ) =>
            FadeTransition(opacity: a, child: child),
      ),
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
