// 记忆面板：每个角色一份第一人称笔记。
//
// 放在工作台右栏，点“这个世界”时进来。
// 只做查看 / 增 / 改 / 删；写入由 workspace 统一存进 TurnState.memory。

import 'package:flutter/material.dart';

import '../engine/character_memory.dart';
import '../theme/tokens.dart';
import 'common.dart';
import 'icons.dart';
import 'memory_diff.dart';

/// 打开记忆弹窗（跟模型、编辑一样，是弹窗不是全屏）。
typedef MemoryVersionsLoader = Future<List<CharacterMemory>> Function(
  String memoryId,
);

Future<void> showMemoryDialog(
  BuildContext context, {
  required List<CharacterMemory> memories,
  required List<String> owners,
  required ValueChanged<List<CharacterMemory>> onChanged,
  MemoryVersionsLoader? loadVersions,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (BuildContext c) {
      final JoPalette p = JoTheme.of(c);
      final Size mq = MediaQuery.of(c).size;
      return Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 560,
          height: (mq.height - 96).clamp(320.0, 640.0),
          decoration: BoxDecoration(
            color: p.bg,
            border: JoShape.border(p.border),
            borderRadius: JoShape.br,
          ),
          child: MemoryPanel(
            memories: memories,
            owners: owners,
            onChanged: onChanged,
            loadVersions: loadVersions,
            onBack: () => Navigator.of(c).pop(),
          ),
        ),
      );
    },
  );
}

class MemoryPanel extends StatefulWidget {
  const MemoryPanel({
    super.key,
    required this.memories,
    required this.owners,
    required this.onChanged,
    this.loadVersions,
    this.onBack,
    this.lockedOwner,
  });

  /// 整个世界的记忆；按 characterId 分给每个角色。
  final List<CharacterMemory> memories;

  /// 角色名。
  final List<String> owners;

  final ValueChanged<List<CharacterMemory>> onChanged;

  /// 按 memory_id 读版本历史；为空时面板不显示版本入口。
  final MemoryVersionsLoader? loadVersions;
  final VoidCallback? onBack;

  /// 锁定的主人（角色名）。
  ///
  /// 从**某一步**进来时会锁定：那一步的主体是谁，就看谁的记忆。
  /// 锁定时不再给主人选择。
  final String? lockedOwner;

  @override
  State<MemoryPanel> createState() => _MemoryPanelState();
}

class _MemoryPanelState extends State<MemoryPanel> {
  /// 当前在看谁：角色名；（锁定时以锁定值为准）
  late String _owner;

  String? _historyId;
  List<CharacterMemory>? _history;
  bool _historyLoading = false;
  String? _historyError;
  final Set<int> _compareVersions = <int>{};

  @override
  void initState() {
    super.initState();
    _owner = widget.owners.isEmpty ? '' : widget.owners.first;
  }

  String get _effectiveOwner => widget.lockedOwner ?? _owner;

  String get _characterId => 'char:$_effectiveOwner';

  List<CharacterMemory> get _entries => <CharacterMemory>[
        for (final CharacterMemory m in widget.memories)
          if (m.characterId == _characterId) m,
      ];

  void _put(List<CharacterMemory> entries) {
    widget.onChanged(<CharacterMemory>[
      for (final CharacterMemory m in widget.memories)
        if (m.characterId != _characterId) m,
      ...entries,
    ]);
  }

  void _putEntry(CharacterMemory old, CharacterMemory next) {
    _put(<CharacterMemory>[
      for (final CharacterMemory m in _entries) m.id == old.id ? next : m,
    ]);
  }

  void _add() {
    if (_effectiveOwner.isEmpty) return;
    final String now = DateTime.now().toIso8601String();
    _put(<CharacterMemory>[
      ..._entries,
      CharacterMemory(
        id: newCharacterMemoryId(),
        characterId: _characterId,
        text: '',
        kind: MemoryKind.note,
        origin: MemoryOrigin.manual,
        createdAt: now,
        updatedAt: now,
      ),
    ]);
  }

  void _archive(CharacterMemory e) {
    _putEntry(
      e,
      e.copyWith(
        state: MemoryState.archived,
        archiveRecallable: false,
        updatedAt: DateTime.now().toIso8601String(),
      ),
    );
  }

  Future<void> _openHistory(CharacterMemory e) async {
    final MemoryVersionsLoader? loader = widget.loadVersions;
    if (loader == null) return;
    setState(() {
      _historyId = e.id;
      _history = null;
      _historyError = null;
      _compareVersions.clear();
      _historyLoading = true;
    });
    try {
      final List<CharacterMemory> versions = await loader(e.id);
      if (!mounted) return;
      setState(() {
        _history = versions;
        _compareVersions
          ..clear()
          ..addAll(<int>[
            if (versions.isNotEmpty) versions.first.version,
            if (versions.length > 1) versions[1].version,
          ]);
        _historyLoading = false;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _historyError = '版本历史读取失败：$err';
        _historyLoading = false;
      });
    }
  }

  void _toggleCompare(int version) {
    setState(() {
      if (_compareVersions.remove(version)) return;
      if (_compareVersions.length >= 2) {
        _compareVersions.remove(_compareVersions.first);
      }
      _compareVersions.add(version);
    });
  }

  void _selectOwner(String value) {
    setState(() {
      _owner = value;
      _historyId = null;
      _history = null;
      _historyError = null;
      _compareVersions.clear();
    });
  }

  void _restoreVersion(CharacterMemory current, CharacterMemory old) {
    _putEntry(
      current,
      old.copyWith(
        state: MemoryState.fresh,
        origin: MemoryOrigin.manual,
        updatedAt: DateTime.now().toIso8601String(),
      ),
    );
    _openHistory(current);
  }

  @override
  Widget build(BuildContext context) {
    final JoPalette p = JoTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _header(p),
        _owners(p),
        Container(height: 1, color: p.border),
        Expanded(child: _list(p)),
      ],
    );
  }

  Widget _header(JoPalette p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        JoSpace.s4,
        JoSpace.s3,
        JoSpace.s4,
        JoSpace.s2,
      ),
      child: Row(
        children: <Widget>[
          if (widget.onBack != null)
            JoIconAction(
              icon: JoIcons.arrowLeft,
              tip: '返回',
              onTap: widget.onBack!,
            ),
          const SizedBox(width: JoSpace.s3),
          Text(
            _effectiveOwner.isEmpty ? '记忆' : '$_effectiveOwner 的记忆',
            style: JoFonts.ui.copyWith(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: p.text,
            ),
          ),
          const Spacer(),
          Text(
            '共 ${_entries.length} 条',
            style: JoFonts.meta.copyWith(color: p.secondary),
          ),
        ],
      ),
    );
  }

  /// 谁：各角色。
  Widget _owners(JoPalette p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(JoSpace.s4, 0, JoSpace.s4, JoSpace.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (widget.lockedOwner == null)
            Wrap(
              spacing: JoSpace.s2,
              runSpacing: JoSpace.s2,
              children: <Widget>[
                for (final String name in widget.owners) _chip(p, name, name),
              ],
            ),
          const SizedBox(height: JoSpace.s2),
          Text(
            _effectiveOwner.isEmpty
                ? '还没有角色。'
                : '$_effectiveOwner 的记忆（受信息隔离限制，仅供该角色使用）',
            style: JoFonts.meta.copyWith(
              color: p.secondary,
              fontSize: 10,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(JoPalette p, String label, String value) {
    final bool on = value == _owner;
    return JoTap(
      onTap: () => _selectOwner(value),
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

  Widget _list(JoPalette p) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        JoSpace.s4,
        JoSpace.s3,
        JoSpace.s4,
        JoSpace.s5,
      ),
      children: <Widget>[
        if (_entries.isEmpty)
          Text(
            '还没有记忆。记忆是角色自己的主观笔记。',
            style: JoFonts.meta.copyWith(color: p.secondary, height: 1.7),
          )
        else
          for (final CharacterMemory e in _entries) _entry(p, e),
        const SizedBox(height: JoSpace.s3),
        Align(
          alignment: Alignment.centerLeft,
          child: JoButton(
            text: '＋ 添加一条',
            onTap: _add,
            color: p.accent,
          ),
        ),
      ],
    );
  }

  Widget _entry(JoPalette p, CharacterMemory e) {
    final String meta = <String>[
      'v${e.version}',
      e.kind.name,
      e.state.name,
      e.origin.name,
      if (e.state == MemoryState.archived)
        e.archiveRecallable ? '可按需召回' : '已停用，不参与模型召回',
      if (e.sourceEvents.isNotEmpty) '来源 ${e.sourceEvents.length} 个事件',
      _when(e.updatedAt),
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          margin: const EdgeInsets.only(bottom: JoSpace.s2),
          padding: const EdgeInsets.all(JoSpace.s3),
          decoration: BoxDecoration(
            border: JoShape.border(p.border),
            borderRadius: JoShape.br,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              JoInput(
                initial: e.text,
                hint: '一条第一人称笔记',
                onChanged: (String v) => _putEntry(
                  e,
                  e.copyWith(
                    text: v,
                    updatedAt: DateTime.now().toIso8601String(),
                  ),
                ),
              ),
              const SizedBox(height: JoSpace.s2),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      meta,
                      style: JoFonts.meta.copyWith(
                        color: p.secondary,
                        fontSize: 10,
                      ),
                    ),
                  ),
                  if (widget.loadVersions != null) ...<Widget>[
                    _action(
                      p,
                      _historyId == e.id ? '收起版本' : '版本',
                      () {
                        if (_historyId == e.id) {
                          setState(() => _historyId = null);
                        } else {
                          _openHistory(e);
                        }
                      },
                    ),
                    const SizedBox(width: JoSpace.s2),
                  ],
                  if (e.state == MemoryState.archived && !e.archiveRecallable)
                    _action(p, '允许召回', () => _putEntry(e, e.copyWith(
                      archiveRecallable: true,
                      updatedAt: DateTime.now().toIso8601String(),
                    )))
                  else
                    _action(p, '停用', () => _archive(e)),
                ],
              ),
            ],
          ),
        ),
        if (_historyId == e.id) _historyPanel(p, e),
      ],
    );
  }

  Widget _action(JoPalette p, String label, VoidCallback onTap) {
    return JoTap(
      onTap: onTap,
      opaque: false,
      builder: (BuildContext context, bool hover, bool down) {
        return AnimatedDefaultTextStyle(
          duration: kJoTapMs,
          curve: Curves.easeOut,
          style: JoFonts.meta.copyWith(
            color: hover ? p.accent : p.secondary,
          ),
          child: Text(label),
        );
      },
    );
  }

  Widget _historyPanel(JoPalette p, CharacterMemory current) {
    final List<CharacterMemory> versions =
        _history ?? const <CharacterMemory>[];
    return Container(
      margin: const EdgeInsets.only(bottom: JoSpace.s3),
      padding: const EdgeInsets.all(JoSpace.s3),
      decoration: BoxDecoration(
        color: p.surface,
        border: JoShape.border(p.border),
        borderRadius: JoShape.br,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            '版本历史',
            style: JoFonts.ui.copyWith(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: p.text,
            ),
          ),
          const SizedBox(height: JoSpace.s2),
          if (_historyLoading)
            Text(
              '正在读取…',
              style: JoFonts.meta.copyWith(color: p.secondary),
            )
          else if (_historyError != null)
            Text(
              _historyError!,
              style: JoFonts.meta.copyWith(color: p.accent),
            )
          else if (versions.isEmpty)
            Text(
              '还没有历史版本。',
              style: JoFonts.meta.copyWith(color: p.secondary),
            )
          else
            for (final CharacterMemory v in versions)
              _historyRow(p, current, v),
          if (!_historyLoading &&
              _historyError == null &&
              versions.length > 1) ...<Widget>[
            const SizedBox(height: JoSpace.s2),
            Text(
              '选择两个版本进行对比；默认选中最新两个版本。',
              style: JoFonts.meta.copyWith(
                color: p.secondary,
                fontSize: 10,
              ),
            ),
            if (_compareVersions.length == 2) _diffPanel(p, versions),
          ],
        ],
      ),
    );
  }

  Widget _diffPanel(JoPalette p, List<CharacterMemory> versions) {
    final List<CharacterMemory> selected = <CharacterMemory>[
      for (final CharacterMemory v in versions)
        if (_compareVersions.contains(v.version)) v,
    ]..sort(
        (CharacterMemory a, CharacterMemory b) =>
            a.version.compareTo(b.version),
      );
    if (selected.length != 2) return const SizedBox.shrink();
    final CharacterMemory old = selected.first;
    final CharacterMemory next = selected.last;
    final List<MemoryDiffLine> lines = memoryLineDiff(old.text, next.text);
    final int adds = lines
        .where((MemoryDiffLine l) => l.kind == MemoryDiffKind.add)
        .length;
    final int removes = lines
        .where((MemoryDiffLine l) => l.kind == MemoryDiffKind.remove)
        .length;
    return Container(
      margin: const EdgeInsets.only(top: JoSpace.s2),
      padding: const EdgeInsets.all(JoSpace.s2),
      decoration: BoxDecoration(
        color: p.bg,
        border: JoShape.border(p.border),
        borderRadius: JoShape.br,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            '对比 v${old.version} → v${next.version}'
            ' · +$adds / -$removes',
            style: JoFonts.meta.copyWith(
              color: p.secondary,
              fontSize: 10,
            ),
          ),
          const SizedBox(height: JoSpace.s1),
          for (final MemoryDiffLine line in lines)
            Container(
              color: line.kind == MemoryDiffKind.add
                  ? p.accent.withValues(alpha: 0.08)
                  : line.kind == MemoryDiffKind.remove
                      ? p.secondary.withValues(alpha: 0.08)
                      : null,
              padding: const EdgeInsets.symmetric(
                horizontal: JoSpace.s1,
                vertical: 1,
              ),
              child: Text(
                '${line.kind == MemoryDiffKind.add
                    ? '+'
                    : line.kind == MemoryDiffKind.remove
                        ? '-'
                        : ' '} ${line.text}',
                style: JoFonts.body.copyWith(
                  fontFamily: JoFonts.mono,
                  fontSize: 10,
                  height: 1.45,
                  color: line.kind == MemoryDiffKind.remove
                      ? p.secondary
                      : p.text,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _historyRow(
    JoPalette p,
    CharacterMemory current,
    CharacterMemory version,
  ) {
    final bool isCurrent = version.version == current.version;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: JoSpace.s2),
      decoration: BoxDecoration(
        border: Border(top: JoShape.side(p.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            version.text,
            style: JoFonts.body.copyWith(
              fontSize: 12,
              color: p.text,
              height: 1.5,
            ),
          ),
          const SizedBox(height: JoSpace.s1),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'v${version.version} · ${version.state.name} · '
                  '${version.origin.name} · ${_when(version.updatedAt)}',
                  style: JoFonts.meta.copyWith(
                    color: p.secondary,
                    fontSize: 10,
                  ),
                ),
              ),
              _action(
                p,
                _compareVersions.contains(version.version)
                    ? '取消对比'
                    : '对比',
                () => _toggleCompare(version.version),
              ),
              const SizedBox(width: JoSpace.s2),
              if (isCurrent)
                Text(
                  '当前',
                  style: JoFonts.meta.copyWith(
                    color: p.accent,
                    fontSize: 10,
                  ),
                )
              else
                _action(
                  p,
                  '恢复此版本',
                  () => _restoreVersion(current, version),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static String _when(String raw) {
    final DateTime? t = DateTime.tryParse(raw);
    if (t == null) return '';
    String two(int v) => v < 10 ? '0$v' : '$v';
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }
}
