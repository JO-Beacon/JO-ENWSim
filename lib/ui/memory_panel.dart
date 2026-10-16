// 记忆面板：上帝一份 + 每个角色各一份，两者不共用。
//
// 放在工作台右栏，点“这个世界”时进来。
// 现在只做孤立的：增 / 改 / 删，不接入 A / B 的回合流程。

import 'package:flutter/material.dart';

import '../model/memory.dart';
import '../theme/tokens.dart';
import 'common.dart';
import 'icons.dart';

/// 打开记忆弹窗（跟模型、编辑一样，是弹窗不是全屏）。
Future<void> showMemoryDialog(
  BuildContext context, {
  required Map<String, MemoryBook> books,
  required List<String> owners,
  required ValueChanged<Map<String, MemoryBook>> onChanged,
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
            books: books,
            owners: owners,
            onChanged: onChanged,
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
    required this.books,
    required this.owners,
    required this.onChanged,
    this.onBack,
    this.lockedOwner,
  });

  /// 记忆簿。key 为空 = 上帝记忆，其它 = 角色名。
  final Map<String, MemoryBook> books;

  /// 角色名（不含上帝）。
  final List<String> owners;

  final ValueChanged<Map<String, MemoryBook>> onChanged;
  final VoidCallback? onBack;

  /// 锁定的主人（空串 = 上帝）。
  ///
  /// 从**某一步**进来时会锁定：那一步的主休是谁，就看谁的记忆——
  /// 旁白那一步看的就是上帝记忆。锁定时不再给主人选择。
  final String? lockedOwner;

  @override
  State<MemoryPanel> createState() => _MemoryPanelState();
}

class _MemoryPanelState extends State<MemoryPanel> {
  /// 当前在看谁：空 = 上帝；（锁定时以锁定值为准）
  String _owner = '';

  String get _effectiveOwner => widget.lockedOwner ?? _owner;

  MemoryBook get _book =>
      widget.books[_effectiveOwner] ?? MemoryBook(ownerId: _effectiveOwner);

  void _put(MemoryBook next) {
    widget.onChanged(
      <String, MemoryBook>{...widget.books, _effectiveOwner: next},
    );
  }

  void _putEntry(MemoryEntry old, MemoryEntry next) {
    _put(
      _book.copyWith(
        entries: <MemoryEntry>[
          for (final MemoryEntry e in _book.entries)
            identical(e, old) ? next : e,
        ],
      ),
    );
  }

  void _add() => _put(
        _book.copyWith(
          entries: <MemoryEntry>[..._book.entries, newMemoryEntry()],
        ),
      );

  void _remove(MemoryEntry e) => _put(
        _book.copyWith(
          entries: _book.entries
              .where((MemoryEntry x) => !identical(x, e))
              .toList(),
        ),
      );

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
            _effectiveOwner.isEmpty ? '上帝记忆' : '$_effectiveOwner 的记忆',
            style: JoFonts.ui.copyWith(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: p.text,
            ),
          ),
          const Spacer(),
          Text(
            '一共有 ${_book.entries.length} 条',
            style: JoFonts.meta.copyWith(color: p.secondary),
          ),
        ],
      ),
    );
  }

  /// 谁：上帝 + 各角色。上帝记忆不受信息隔离约束，这里如实标出来。
  Widget _owners(JoPalette p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        JoSpace.s4,
        0,
        JoSpace.s4,
        JoSpace.s3,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (widget.lockedOwner == null)
            Wrap(
              spacing: JoSpace.s2,
              runSpacing: JoSpace.s2,
              children: <Widget>[
                _chip(p, '上帝', ''),
                for (final String name in widget.owners) _chip(p, name, name),
              ],
            ),
          const SizedBox(height: JoSpace.s2),
          Text(
            _effectiveOwner.isEmpty
                ? '上帝记忆（不受信息隔离约束）'
                : '$_owner 的记忆（受信息隔离约束，只喂给这个角色自己）',
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
      onTap: () => setState(() => _owner = value),
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
        if (_book.entries.isEmpty)
          Text(
            '还没有记忆。记忆是长期事实，不接入回合流程。',
            style: JoFonts.meta.copyWith(color: p.secondary, height: 1.7),
          )
        else
          for (final MemoryEntry e in _book.entries) _entry(p, e),
        const SizedBox(height: JoSpace.s3),
        Align(
          alignment: Alignment.centerLeft,
          child: JoButton(text: '＋ 添加一条', onTap: _add, color: p.accent),
        ),
      ],
    );
  }

  Widget _entry(JoPalette p, MemoryEntry e) {
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
          JoInput(
            initial: e.content,
            hint: '一条自包含的陈述',
            onChanged: (String v) => _putEntry(e, e.copyWith(content: v)),
          ),
          const SizedBox(height: JoSpace.s2),
          Row(
            children: <Widget>[
              Expanded(
                child: JoInput(
                  initial: e.kind,
                  hint: '类型（自己写）',
                  compact: true,
                  onChanged: (String v) =>
                      _putEntry(e, e.copyWith(kind: v)),
                ),
              ),
              const SizedBox(width: JoSpace.s2),
              JoTap(
                onTap: () => _remove(e),
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
          Text(
            '${e.source.label} · ${_when(e.updatedAt)}',
            style: JoFonts.meta.copyWith(
              color: p.secondary,
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }

  static String _when(DateTime t) {
    String two(int v) => v < 10 ? '0$v' : '$v';
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }
}
