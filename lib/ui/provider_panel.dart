import 'package:flutter/material.dart';

import '../model/provider.dart';
import '../model/provider_api.dart';
import '../theme/tokens.dart';
import 'add_provider_dialog.dart';
import 'common.dart';

/// “服务商”：左列表（分组可折叠）+ 右详情（Key / 地址 / 模型）。
class ProviderPanel extends StatefulWidget {
  const ProviderPanel({
    super.key,
    required this.providers,
    required this.onChanged,
  });

  final List<Provider> providers;
  final ValueChanged<List<Provider>> onChanged;

  @override
  State<ProviderPanel> createState() => _ProviderPanelState();
}

class _ProviderPanelState extends State<ProviderPanel> {
  final TextEditingController _search = TextEditingController();
  final Set<String> _collapsed = <String>{};
  String? _selectedId;

  /// 行内展开了参数的模型（按对象身份记；替换时会跟着换）。
  final Set<ModelRef> _openModels = <ModelRef>{};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Provider? get _selected {
    for (final Provider p in widget.providers) {
      if (p.id == _selectedId) return p;
    }
    return widget.providers.isEmpty ? null : widget.providers.first;
  }

  List<({String name, List<Provider> items})> get _groups {
    final String q = _search.text.trim().toLowerCase();
    final List<Provider> list = q.isEmpty
        ? widget.providers
        : widget.providers
            .where(
              (Provider p) =>
                  p.name.toLowerCase().contains(q) ||
                  p.groupName.toLowerCase().contains(q),
            )
            .toList();
    final List<({String name, List<Provider> items})> out =
        <({String name, List<Provider> items})>[];
    for (final Provider p in list) {
      final String g = p.groupName;
      final int i = out.indexWhere((({String name, List<Provider> items}) e) => e.name == g);
      if (i >= 0) {
        out[i].items.add(p);
      } else {
        out.add((name: g, items: <Provider>[p]));
      }
    }
    return out;
  }

  void _replace(Provider p) {
    widget.onChanged(<Provider>[
      for (final Provider x in widget.providers) x.id == p.id ? p : x,
    ]);
  }

  void _remove(String id) {
    widget.onChanged(
      widget.providers.where((Provider p) => p.id != id).toList(),
    );
    setState(() => _selectedId = null);
  }

  Future<void> _add() async {
    final Provider? p = await showAddProviderDialog(context);
    if (p == null || !mounted) return;
    // 重名就自动加序号：第二个 DeepSeek 叫 “DeepSeek 2”。
    final Set<String> names = <String>{
      for (final Provider x in widget.providers) x.name,
    };
    String name = p.name;
    if (names.contains(name)) {
      int i = 2;
      while (names.contains('${p.name} $i')) {
        i++;
      }
      name = '${p.name} $i';
    }
    widget.onChanged(<Provider>[
      ...widget.providers,
      p.copyWith(name: name),
    ]);
    setState(() => _selectedId = p.id);
  }

  @override
  Widget build(BuildContext context) {
    final JoPalette p = JoTheme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(width: 280, child: _left(p)),
        Container(width: 1, color: p.border),
        Expanded(child: _selected == null ? _empty(p) : _right(p, _selected!)),
      ],
    );
  }

  Widget _empty(JoPalette p) => Center(
        child: Text(
          '还没有服务商，点左下角“＋ 添加”',
          style: JoFonts.meta.copyWith(color: p.secondary),
        ),
      );

  // —— 左：列表 ——

  Widget _left(JoPalette p) {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            JoSpace.s3,
            JoSpace.s3,
            JoSpace.s3,
            JoSpace.s2,
          ),
          child: _SearchBox(
            controller: _search,
            onChanged: () => setState(() {}),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: JoSpace.s2),
            children: <Widget>[
              for (final ({String name, List<Provider> items}) g in _groups)
                ..._group(p, g),
            ],
          ),
        ),
        Container(
          decoration: BoxDecoration(
            border: Border(top: JoShape.side(p.border)),
          ),
          padding: const EdgeInsets.all(JoSpace.s2),
          child: GestureDetector(
            onTap: _add,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: JoSpace.s3),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: JoShape.border(p.border),
                  borderRadius: JoShape.br,
                ),
                child: Text(
                  '＋ 添加',
                  style: JoFonts.ui.copyWith(fontSize: 13, color: p.accent),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _group(
    JoPalette p,
    ({String name, List<Provider> items}) g,
  ) {
    final bool open = !_collapsed.contains(g.name);
    return <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(
          JoSpace.s3,
          JoSpace.s3,
          JoSpace.s3,
          JoSpace.s2,
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: GestureDetector(
                onTap: () => setState(() {
                  if (open) {
                    _collapsed.add(g.name);
                  } else {
                    _collapsed.remove(g.name);
                  }
                }),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Row(
                    children: <Widget>[
                      Text(
                        open ? '▾' : '▸',
                        style: JoFonts.meta.copyWith(color: p.secondary),
                      ),
                      const SizedBox(width: JoSpace.s2),
                      Flexible(
                        child: Text(
                          g.name,
                          overflow: TextOverflow.ellipsis,
                          style: JoFonts.ui.copyWith(
                            fontSize: 13,
                            color: p.text,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Text(
              '${g.items.length}',
              style: JoFonts.meta.copyWith(color: p.secondary),
            ),
            const SizedBox(width: JoSpace.s3),
            JoTap(
              onTap: () => _renameGroupDialog(g.name),
              opaque: false,
              builder: (BuildContext context, bool hover, bool down) {
                return AnimatedDefaultTextStyle(
                  duration: kJoTapMs,
                  curve: Curves.easeOut,
                  style: JoFonts.meta.copyWith(
                    color: hover ? p.accent : p.secondary,
                    fontSize: 10,
                  ),
                  child: const Text('改名'),
                );
              },
            ),
          ],
        ),
      ),
      if (open)
        for (final Provider x in g.items) _row(p, x),
    ];
  }

  Widget _row(JoPalette p, Provider x) {
    final bool on = _selected?.id == x.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: JoSpace.s1),
      child: JoTap(
        onTap: () => setState(() => _selectedId = x.id),
        opaque: false,
        builder: (BuildContext context, bool hover, bool down) {
          return AnimatedContainer(
            duration: kJoTapMs,
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(
              horizontal: JoSpace.s2,
              vertical: JoSpace.s3,
            ),
            decoration: BoxDecoration(
              color: on
                  ? p.surface
                  : (hover ? p.surface.withValues(alpha: 0.55) : Colors.transparent),
              border: JoShape.border(
                on ? p.accent : (hover ? p.border : Colors.transparent),
              ),
              borderRadius: JoShape.br,
            ),
            child: Row(
              children: <Widget>[
                _Avatar(palette: p, name: x.name, on: on),
                const SizedBox(width: JoSpace.s3),
                Expanded(
                  child: Text(
                    x.name,
                    overflow: TextOverflow.ellipsis,
                    style: JoFonts.ui.copyWith(
                      fontSize: 13,
                      color: on ? p.accent : p.text,
                      fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                    ),
                  ),
                ),
                Text(
                  x.enabled ? '启用' : '禁用',
                  style: JoFonts.meta.copyWith(
                    color: x.enabled ? p.accent : p.secondary,
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

  // —— 右：详情 ——

  Widget _right(JoPalette p, Provider x) {
    return Column(
      key: ValueKey<String>(x.id),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _detailHeader(p, x),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              JoSpace.s5,
              JoSpace.s3,
              JoSpace.s5,
              JoSpace.s5,
            ),
            children: <Widget>[
              _label(p, '名称'),
              JoInput(
                initial: x.name,
                hint: '服务商名字',
                onChanged: (String v) => _replace(x.copyWith(name: v)),
              ),
              const SizedBox(height: JoSpace.s5),
              _label(p, '分组'),
              JoInput(
                initial: x.group,
                hint: '留空 = 未分组',
                onChanged: (String v) => _replace(x.copyWith(group: v)),
              ),
              if (_otherGroups.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: JoSpace.s2),
                  child: Wrap(
                    spacing: JoSpace.s2,
                    runSpacing: JoSpace.s2,
                    children: <Widget>[
                      for (final String g in _otherGroups)
                        GestureDetector(
                          onTap: () => _replace(x.copyWith(group: g)),
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: JoSpace.s3,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                border: JoShape.border(p.border),
                                borderRadius: JoShape.br,
                              ),
                              child: Text(
                                g,
                                style: JoFonts.meta.copyWith(
                                  color: p.secondary,
                                  fontSize: 10,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: JoSpace.s5),
              _label(p, 'API Key'),
              _KeyField(
                initial: x.apiKey,
                provider: x,
                onEdit: (String v) => _replace(x.copyWith(apiKey: v)),
              ),
              const SizedBox(height: JoSpace.s5),
              _label(p, '接口'),
              if (x.custom == null)
                // 预设来的：端点是死的事实，只读。
                Text(
                  x.endpoint,
                  style: JoFonts.meta.copyWith(color: p.text),
                )
              else ...<Widget>[
                JoInput(
                  initial: x.baseUrl,
                  hint: x.protocol.baseUrl,
                  onChanged: (String v) => _replace(x.copyWith(baseUrl: v)),
                ),
                const SizedBox(height: JoSpace.s3),
                JoInput(
                  initial: x.apiPath,
                  hint: x.protocol.apiPath,
                  onChanged: (String v) => _replace(x.copyWith(apiPath: v)),
                ),
              ],
              if (x.protocol.wire == Wire.openai && x.custom == null)
                ...<Widget>[
                const SizedBox(height: JoSpace.s4),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        'Use Responses API',
                        style: JoFonts.ui.copyWith(
                          fontSize: 13,
                          color: p.text,
                        ),
                      ),
                    ),
                    JoToggle(
                      on: x.useResponsesApi,
                      onChanged: (bool v) =>
                          _replace(x.copyWith(useResponsesApi: v)),
                    ),
                  ],
                ),
                _note(
                  p,
                  '改用 Responses 接口而不是 chat/completions；'
                  '服务商不支持时保持关闭',
                ),
              ],
              if (x.protocol.isDeepSeek) ...<Widget>[
                const SizedBox(height: JoSpace.s6),
                ..._deepseek(p, x),
              ],
              const SizedBox(height: JoSpace.s6),
              _models(p, x),
              const SizedBox(height: JoSpace.s6),
              Align(
                alignment: Alignment.centerLeft,
                child: JoButton(
                  text: '删除这个服务商',
                  onTap: () => _confirmDelete(x),
                  color: p.secondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// DeepSeek 专属开关。
  ///
  /// 只把规则摊开，不给默认档位：要不要开思考、投入多高，都是用户自己定。
  List<Widget> _deepseek(JoPalette p, Provider x) => <Widget>[
        _label(p, '端点格式'),
        JoSegment<String>(
          options: const <({String label, String value})>[
            (label: 'OpenAI 格式', value: 'openai'),
            (label: 'Anthropic 格式', value: 'anthropic'),
          ],
          value: x.protocol == Protocol.deepseekAnthropic
              ? 'anthropic'
              : 'openai',
          onChanged: (String v) {
            final Protocol next = v == 'anthropic'
                ? Protocol.deepseekAnthropic
                : Protocol.deepseek;
            _replace(x.copyWith(
              protocol: next,
              baseUrl: next.baseUrl,
              apiPath: next.apiPath,
            ));
          },
        ),
        const SizedBox(height: JoSpace.s5),
        _note(
          p,
          '输入按缓存命中与未命中分别计价，命中便宜约 50 倍；'
          '前缀越稳定越容易命中，所以稳定的内容放前面、每回合变的放最后',
        ),
        _note(p, '峰时（北京时间 09:00–12:00、14:00–18:00 的工作日）是谷时的两倍'),
      ];

  /// 模型行点开后展开的参数。
  ///
  /// 这些是**模型级**的：同一个服务商下面，不同模型能力不一样。
  Widget _modelParams(JoPalette p, Provider x, ModelRef m) {
    final bool ds = x.protocol.isDeepSeek;
    return Container(
      margin: const EdgeInsets.only(top: JoSpace.s1),
      padding: const EdgeInsets.all(JoSpace.s3),
      decoration: BoxDecoration(
        color: p.surface,
        border: JoShape.border(p.border),
        borderRadius: JoShape.br,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (ds) ...<Widget>[
            _label(p, '思考模式'),
            JoSegment<ThinkingMode>(
              options: <({String label, ThinkingMode value})>[
                for (final ThinkingMode v in ThinkingMode.values)
                  (label: v.label, value: v),
              ],
              value: m.thinking,
              onChanged: (ThinkingMode v) =>
                  _replaceModel(x, m, m.copyWith(thinking: v)),
            ),
            const SizedBox(height: JoSpace.s4),
            _label(p, '思考投入'),
            _chips<ReasoningEffort>(
              p,
              <({String label, ReasoningEffort value})>[
                for (final ReasoningEffort v in ReasoningEffort.values)
                  (label: v.label, value: v),
              ],
              m.effort,
              (ReasoningEffort v) =>
                  _replaceModel(x, m, m.copyWith(effort: v)),
            ),
            const SizedBox(height: JoSpace.s4),
          ],
          _label(p, '最大输出 tokens'),
          JoInput(
            initial: m.maxTokens,
            hint: '留空 = 用服务端默认',
            onChanged: (String v) =>
                _replaceModel(x, m, m.copyWith(maxTokens: v)),
          ),
          const SizedBox(height: JoSpace.s4),
          _label(p, '请求 JSON 输出'),
          JoSegment<bool>(
            options: const <({String label, bool value})>[
              (label: '否', value: false),
              (label: '是', value: true),
            ],
            value: m.jsonOutput,
            onChanged: (bool v) =>
                _replaceModel(x, m, m.copyWith(jsonOutput: v)),
          ),
          if (m.jsonOutput)
            _note(p, '要求提示词里出现 json 这个词并给出格式示例；官方说明该模式偶发返回空内容'),
          if (ds)
            _note(
              p,
              '思考模式下 temperature / presence_penalty / frequency_penalty 会被忽略，'
              '不报错但无效；top_p 只在思考模式生效，低于 0.95 按 0.95 算，'
              '非思考模式固定为 1.0',
            ),
        ],
      ),
    );
  }

  /// 一排挤不下时的可换行选项。
  Widget _chips<T>(
    JoPalette p,
    List<({String label, T value})> options,
    T value,
    ValueChanged<T> onChanged,
  ) {
    return Wrap(
      spacing: JoSpace.s2,
      runSpacing: JoSpace.s2,
      children: <Widget>[
        for (final ({String label, T value}) o in options)
          JoTap(
            onTap: () => onChanged(o.value),
            opaque: false,
            builder: (BuildContext context, bool hover, bool down) {
              final bool on = o.value == value;
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
                  child: Text(o.label),
                ),
              );
            },
          ),
      ],
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

  /// 删除服务商前问一句。它下面的模型和 Key 会一起没。
  Future<void> _confirmDelete(Provider x) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (BuildContext c) => _ConfirmDeleteDialog(name: x.name),
    );
    if (ok != true || !mounted) return;
    _remove(x.id);
  }

  /// 重命名整个分组：组里所有服务商一起改。
  void _renameGroup(String from, String to) {
    final String t = to.trim();
    widget.onChanged(<Provider>[
      for (final Provider x in widget.providers)
        x.groupName == from ? x.copyWith(group: t) : x,
    ]);
    setState(() {
      if (_collapsed.remove(from) && t.isNotEmpty) _collapsed.add(t);
    });
  }

  Future<void> _renameGroupDialog(String from) async {
    final String? to = await showDialog<String>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (BuildContext c) => _RenameGroupDialog(initial: from),
    );
    if (to == null || !mounted) return;
    _renameGroup(from, to);
  }

  /// 已经用过的分组名（用于快速归类）。
  List<String> get _otherGroups {
    final List<String> out = <String>[];
    for (final Provider x in widget.providers) {
      final String g = x.group.trim();
      if (g.isEmpty || out.contains(g)) continue;
      out.add(g);
    }
    return out;
  }

  Widget _detailHeader(JoPalette p, Provider x) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: JoSpace.s5,
        vertical: JoSpace.s3,
      ),
      decoration: BoxDecoration(border: Border(bottom: JoShape.side(p.border))),
      child: Row(
        children: <Widget>[
          _Avatar(palette: p, name: x.name, on: true),
          const SizedBox(width: JoSpace.s3),
          Expanded(
            child: Text(
              x.name,
              overflow: TextOverflow.ellipsis,
              style: JoFonts.ui.copyWith(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: p.text,
              ),
            ),
          ),
          Text(
            x.protocol.label,
            style: JoFonts.meta.copyWith(color: p.secondary),
          ),
          const SizedBox(width: JoSpace.s4),
          JoToggle(
            on: x.enabled,
            onChanged: (bool v) => _replace(x.copyWith(enabled: v)),
          ),
        ],
      ),
    );
  }

  Widget _models(JoPalette p, Provider x) {
    final List<({String name, List<ModelRef> items})> groups =
        <({String name, List<ModelRef> items})>[];
    for (final ModelRef m in x.models) {
      final int i = groups.indexWhere(
        (({String name, List<ModelRef> items}) e) => e.name == m.groupName,
      );
      if (i >= 0) {
        groups[i].items.add(m);
      } else {
        groups.add((name: m.groupName, items: <ModelRef>[m]));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            _label(p, '模型 ${x.models.length}'),
            const Spacer(),
            JoButton(
              text: '＋ 添加模型',
              color: p.accent,
              onTap: () => _replace(
                x.copyWith(
                  models: <ModelRef>[
                    ...x.models,
                    ModelRef(id: '', group: x.name),
                  ],
                ),
              ),
            ),
            const SizedBox(width: JoSpace.s3),
            _ProbeButton(
              palette: p,
              provider: x,
              onModels: (List<String> ids) {
                final List<ModelRef> next = <ModelRef>[...x.models];
                for (final String id in ids) {
                  if (next.any((ModelRef m) => m.id == id)) continue;
                  next.add(ModelRef(id: id, group: x.name));
                }
                _replace(x.copyWith(models: next));
              },
            ),
          ],
        ),
        const SizedBox(height: JoSpace.s2),
        if (x.models.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: JoSpace.s2),
            child: Text(
              '还没有模型。点“获取”从接口拉一份，或者手动加。',
              style: JoFonts.meta.copyWith(color: p.secondary),
            ),
          ),
        for (final ({String name, List<ModelRef> items}) g in groups)
          ..._modelGroup(p, x, g),
      ],
    );
  }

  List<Widget> _modelGroup(
    JoPalette p,
    Provider x,
    ({String name, List<ModelRef> items}) g,
  ) {
    return <Widget>[
      Padding(
        padding: const EdgeInsets.only(top: JoSpace.s3, bottom: JoSpace.s1),
        child: Text(
          '▾ ${g.name}',
          style: JoFonts.meta.copyWith(color: p.secondary),
        ),
      ),
      for (final ModelRef m in g.items)
        Padding(
          padding: const EdgeInsets.only(bottom: JoSpace.s1),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              JoTap(
                onTap: () => setState(() {
                  if (!_openModels.remove(m)) _openModels.add(m);
                }),
                opaque: false,
                builder: (BuildContext context, bool hover, bool down) {
                  final bool open = _openModels.contains(m);
                  return AnimatedContainer(
                    duration: kJoTapMs,
                    curve: Curves.easeOut,
                    padding: const EdgeInsets.symmetric(
                      horizontal: JoSpace.s3,
                      vertical: JoSpace.s2,
                    ),
                    decoration: BoxDecoration(
                      color: open ? p.surface : Colors.transparent,
                      border: JoShape.border(
                        open || hover ? p.accent : p.border,
                      ),
                      borderRadius: JoShape.br,
                    ),
                    child: Row(
                      children: <Widget>[
                        Text(
                          open ? '▾' : '▸',
                          style: JoFonts.meta.copyWith(
                            color: p.secondary,
                            fontSize: 10,
                          ),
                        ),
                        const SizedBox(width: JoSpace.s2),
                        Expanded(
                          child: m.id.trim().isEmpty
                              ? JoInput(
                                  initial: m.id,
                                  hint: '模型 id，比如 deepseek-chat',
                                  compact: true,
                                  onChanged: (String v) =>
                                      _replaceModel(x, m, m.copyWith(id: v)),
                                )
                              : Text(
                                  m.display,
                                  overflow: TextOverflow.ellipsis,
                                  style: JoFonts.meta.copyWith(
                                    color: m.enabled ? p.text : p.secondary,
                                  ),
                                ),
                        ),
                        const SizedBox(width: JoSpace.s2),
                        if (m.id.trim().isNotEmpty)
                          GestureDetector(
                            onTap: () => _replaceModel(
                              x,
                              m,
                              m.copyWith(enabled: !m.enabled),
                            ),
                            child: MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: Text(
                                m.enabled ? '启用' : '禁用',
                                style: JoFonts.meta.copyWith(
                                  color: m.enabled ? p.accent : p.secondary,
                                  fontSize: 10,
                                ),
                              ),
                            ),
                          ),
                        const SizedBox(width: JoSpace.s3),
                        GestureDetector(
                          onTap: () {
                            _openModels.remove(m);
                            _replace(
                              x.copyWith(
                                models: x.models
                                    .where((ModelRef y) => !identical(y, m))
                                    .toList(),
                              ),
                            );
                          },
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: Text(
                              '×',
                              style: JoFonts.meta.copyWith(color: p.secondary),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              if (_openModels.contains(m)) _modelParams(p, x, m),
            ],
          ),
        ),
    ];
  }

  void _replaceModel(Provider x, ModelRef old, ModelRef next) {
    // 展开状态跟着走，不然一改参数就折回去了。
    if (_openModels.remove(old)) _openModels.add(next);
    _replace(
      x.copyWith(
        models: <ModelRef>[
          for (final ModelRef m in x.models) identical(m, old) ? next : m,
        ],
      ),
    );
  }

  Widget _label(JoPalette p, String text) => Padding(
        padding: const EdgeInsets.only(bottom: JoSpace.s2),
        child: Text(
          text,
          style: JoFonts.meta.copyWith(color: p.secondary, letterSpacing: 1),
        ),
      );
}

/// 占位头像（还没有各家图标，先用首字母方块）。
/// 删除服务商的二次确认。
class _ConfirmDeleteDialog extends StatelessWidget {
  const _ConfirmDeleteDialog({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = JoTheme.of(context);
    return Dialog(
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
              '删除服务商',
              style: JoFonts.ui.copyWith(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: p.text,
              ),
            ),
            const SizedBox(height: JoSpace.s3),
            Text(
              '“$name” 连同它下面的模型与 API Key 一起删掉，不能撤销。',
              style: JoFonts.meta.copyWith(color: p.secondary, height: 1.7),
            ),
            const SizedBox(height: JoSpace.s4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                JoButton(
                  text: '取消',
                  onTap: () => Navigator.of(context).pop(false),
                ),
                const SizedBox(width: JoSpace.s2),
                JoButton(
                  text: '删除',
                  color: p.accent,
                  onTap: () => Navigator.of(context).pop(true),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.palette, required this.name, required this.on});

  final JoPalette palette;
  final String name;
  final bool on;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = palette;
    final String c = name.trim().isEmpty ? '?' : name.trim().substring(0, 1);
    return Container(
      width: 20,
      height: 20,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: p.surface,
        border: JoShape.border(on ? p.accent : p.border),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        c,
        style: JoFonts.meta.copyWith(
          color: on ? p.accent : p.secondary,
          fontSize: 10,
        ),
      ),
    );
  }
}

/// 搜索框。
class _SearchBox extends StatelessWidget {
  const _SearchBox({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = JoTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: JoSpace.s3),
      decoration: BoxDecoration(
        color: p.surface,
        border: JoShape.border(p.border),
        borderRadius: JoShape.br,
      ),
      child: TextField(
        controller: controller,
        onChanged: (_) => onChanged(),
        style: JoFonts.ui.copyWith(fontSize: 13, color: p.text),
        cursorColor: p.accent,
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          hintText: '搜索服务商或分组',
          hintStyle: JoFonts.ui.copyWith(fontSize: 13, color: p.secondary),
        ),
      ),
    );
  }
}

/// API Key：掩码 + 眼睛 + 测试。
class _KeyField extends StatefulWidget {
  const _KeyField({
    required this.initial,
    required this.provider,
    required this.onEdit,
  });

  final String initial;
  final Provider provider;
  final ValueChanged<String> onEdit;

  @override
  State<_KeyField> createState() => _KeyFieldState();
}

class _KeyFieldState extends State<_KeyField> {
  late final TextEditingController _c = TextEditingController(
    text: widget.initial,
  );
  bool _show = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final JoPalette p = JoTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: JoSpace.s3,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: p.surface,
                  border: JoShape.border(p.border),
                  borderRadius: JoShape.br,
                ),
                child: TextField(
                  controller: _c,
                  obscureText: !_show,
                  onChanged: widget.onEdit,
                  style: JoFonts.ui.copyWith(fontSize: 13, color: p.text),
                  cursorColor: p.accent,
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: 'sk-…',
                    hintStyle:
                        JoFonts.ui.copyWith(fontSize: 13, color: p.secondary),
                  ),
                ),
              ),
            ),
            const SizedBox(width: JoSpace.s3),
            GestureDetector(
              onTap: () => setState(() => _show = !_show),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Text(
                  _show ? '隐藏' : '显示',
                  style: JoFonts.meta.copyWith(color: p.secondary),
                ),
              ),
            ),
            const SizedBox(width: JoSpace.s3),
            _ProbeButton(palette: p, provider: widget.provider, label: '测试'),
          ],
        ),
      ],
    );
  }
}

/// “测试”/“获取”：拉模型列表。
class _ProbeButton extends StatefulWidget {
  const _ProbeButton({
    required this.palette,
    required this.provider,
    this.label = '获取',
    this.onModels,
  });

  final JoPalette palette;
  final Provider provider;
  final String label;
  final ValueChanged<List<String>>? onModels;

  @override
  State<_ProbeButton> createState() => _ProbeButtonState();
}

class _ProbeButtonState extends State<_ProbeButton> {
  bool _busy = false;
  String? _msg;

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _msg = null;
    });
    final ProbeResult r = await ProviderApi.fetchModels(widget.provider);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _msg = r.message;
    });
    if (r.ok) widget.onModels?.call(r.models);
  }

  @override
  Widget build(BuildContext context) {
    final JoPalette p = widget.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        JoButton(
          text: _busy ? '连接中…' : widget.label,
          color: p.accent,
          onTap: _busy ? () {} : _run,
        ),
        if (_msg != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: SizedBox(
              width: 420,
              child: Text(
                _msg!,
                style: JoFonts.meta.copyWith(
                  color: p.secondary,
                  height: 1.5,
                  fontSize: 10,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 重命名分组。
class _RenameGroupDialog extends StatefulWidget {
  const _RenameGroupDialog({required this.initial});

  final String initial;

  @override
  State<_RenameGroupDialog> createState() => _RenameGroupDialogState();
}

class _RenameGroupDialogState extends State<_RenameGroupDialog> {
  late final TextEditingController _c = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _ok() => Navigator.of(context).pop(_c.text.trim());

  @override
  Widget build(BuildContext context) {
    final JoPalette p = JoTheme.of(context);
    return Dialog(
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
              '重命名分组',
              style: JoFonts.ui.copyWith(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: p.text,
              ),
            ),
            const SizedBox(height: JoSpace.s2),
            Text(
              '组里的服务商一起改名。留空 = 拆成未分组。',
              style: JoFonts.meta.copyWith(color: p.secondary),
            ),
            const SizedBox(height: JoSpace.s4),
            JoInput(
              initial: widget.initial,
              hint: '分组名',
              onChanged: (String v) => _c.text = v,
            ),
            const SizedBox(height: JoSpace.s4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                JoButton(
                  text: '取消',
                  onTap: () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: JoSpace.s3),
                JoButton(text: '确定', onTap: _ok, color: p.accent),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
