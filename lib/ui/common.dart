import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';
import 'icons.dart';

/// 可点区域的动效基元：hover / 按下。builder 拿到状态自己画。
/// 极简风格用得很克制：120ms、只改底色和描边。
class JoTap extends StatefulWidget {
  const JoTap({
    super.key,
    required this.onTap,
    required this.builder,
    this.cursor = SystemMouseCursors.click,
    this.opaque = true,
  });

  final VoidCallback onTap;
  final Widget Function(BuildContext context, bool hover, bool down) builder;
  final MouseCursor cursor;
  final bool opaque;

  @override
  State<JoTap> createState() => _JoTapState();
}

class _JoTapState extends State<JoTap> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.cursor,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _down = false;
      }),
      child: GestureDetector(
        behavior: widget.opaque
            ? HitTestBehavior.opaque
            : HitTestBehavior.deferToChild,
        onTapDown: (_) => setState(() => _down = true),
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        onTap: widget.onTap,
        child: widget.builder(context, _hover, _down),
      ),
    );
  }
}

/// 动效时长（统一一处，好调）。
const Duration kJoTapMs = Duration(milliseconds: 120);

/// 可点文字（细线边框可选）。
/// 一个只有图标的动作（工具栏、返回键）。
///
/// 悬停 / 按下：底色浮起（文字色 9% / 20%），图标从次要色亮到正文色。
/// 不做描边——那是“每个图标一个小盒子”，界面里别的工具栏不是那样。
///
/// [inverted] 是实底强调色 + 底色图标，给主行动用（比如发送）。
class JoIconAction extends StatelessWidget {
  const JoIconAction({
    super.key,
    required this.icon,
    required this.onTap,
    this.tip,
    this.size = 16,
    this.inverted = false,
  });

  final IconData icon;

  /// 名字。现在只给代码看（还没做悬停提示），将来要用就在这儿。
  final String? tip;

  final VoidCallback onTap;
  final double size;

  /// 反色：实底强调色 + 底色图标。主行动用。
  final bool inverted;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = JoTheme.of(context);
    return JoTap(
      onTap: onTap,
      opaque: false,
      builder: (BuildContext c, bool hover, bool down) {
        final double a = down ? 0.20 : (hover ? 0.09 : 0.0);
        // 反色的底色：往正文色那一侧混，所以暗主题会变亮、亮主题会变深 ——
        // 两边都是“更醒目”。直接混背景色会反掉。
        final Color bgColor = inverted
            ? Color.alphaBlend(
                p.text.withValues(alpha: hover || down ? 0.28 : 0.0),
                p.accent,
              )
            : p.icon.withValues(alpha: a);
        final Color fgColor = inverted
            ? p.bg
            : ((hover || down) ? p.text : p.icon);
        return AnimatedContainer(
          duration: kJoTapMs,
          curve: Curves.easeOut,
          // 内边距**四边一样**。写成一宽一窄，图标在框里就是偏的。
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(color: bgColor),
          child: Icon(icon, size: size, color: fgColor),
        );
      },
    );
  }
}

class JoButton extends StatelessWidget {
  const JoButton({
    super.key,
    required this.text,
    required this.onTap,
    this.color,
    this.bordered = false,
  });

  final String text;
  final VoidCallback onTap;
  final Color? color;
  final bool bordered;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = JoTheme.of(context);
    final Color base = color ?? p.secondary;
    return JoTap(
      onTap: onTap,
      opaque: false,
      builder: (BuildContext context, bool hover, bool down) {
        final double a = down ? 0.20 : (hover ? 0.09 : 0.0);
        return AnimatedContainer(
          duration: kJoTapMs,
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(
            horizontal: JoSpace.s3,
            vertical: JoSpace.s1 + 2,
          ),
          decoration: BoxDecoration(
            color: a == 0 ? Colors.transparent : base.withValues(alpha: a),
            border: bordered
                ? JoShape.border(hover || down ? base : p.border)
                : null,
            borderRadius: JoShape.br,
          ),
          child: AnimatedDefaultTextStyle(
            duration: kJoTapMs,
            curve: Curves.easeOut,
            style: JoFonts.meta.copyWith(
              color: hover || down ? (color ?? p.text) : base,
            ),
            child: Text(text),
          ),
        );
      },
    );
  }
}

/// 分段选择（一排细线小格）。
class JoSegment<T> extends StatelessWidget {
  const JoSegment({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final List<({String label, T value})> options;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = JoTheme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < options.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: JoSpace.s2),
          _cell(context, p, options[i]),
        ],
      ],
    );
  }

  Widget _cell(BuildContext context, JoPalette p, ({String label, T value}) o) {
    final bool on = o.value == value;
    return JoTap(
      onTap: () => onChanged(o.value),
      opaque: false,
      builder: (BuildContext context, bool hover, bool down) {
        return AnimatedContainer(
          duration: kJoTapMs,
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(
            horizontal: JoSpace.s3,
            vertical: JoSpace.s1 + 2,
          ),
          decoration: BoxDecoration(
            color: on ? p.surface : (hover ? p.surface.withValues(alpha: 0.6) : Colors.transparent),
            border: JoShape.border(on || hover ? p.accent : p.border),
            borderRadius: JoShape.br,
          ),
          child: AnimatedDefaultTextStyle(
            duration: kJoTapMs,
            curve: Curves.easeOut,
            style: JoFonts.meta.copyWith(color: on ? p.accent : p.secondary),
            child: Text(o.label),
          ),
        );
      },
    );
  }
}

/// 设置分区：小标题 + 内容。
class JoSection extends StatelessWidget {
  const JoSection({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = JoTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: JoSpace.s2),
          child: Text(
            title,
            style: JoFonts.meta.copyWith(color: p.secondary, letterSpacing: 1.2),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: p.surface,
            border: JoShape.border(p.border),
            borderRadius: JoShape.br,
          ),
          child: Column(
            children: <Widget>[
              for (int i = 0; i < children.length; i++) ...<Widget>[
                if (i > 0)
                  Divider(height: 1, thickness: 1, color: p.border),
                children[i],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 设置行：左标签，右控件。
class JoField extends StatelessWidget {
  const JoField({
    super.key,
    required this.label,
    this.hint,
    required this.child,
  });

  final String label;
  final String? hint;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = JoTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: JoSpace.s4,
        vertical: JoSpace.s3,
      ),
      child: Row(
        children: <Widget>[
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                label,
                style: JoFonts.ui.copyWith(fontSize: 14, color: p.text),
              ),
              if (hint != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    hint!,
                    style: JoFonts.meta.copyWith(color: p.secondary),
                  ),
                ),
            ],
          ),
          const Spacer(),
          child,
        ],
      ),
    );
  }
}

/// 页面头：标题 + 返回。
class JoPageHeader extends StatelessWidget {
  const JoPageHeader({
    super.key,
    required this.title,
    required this.onBack,
    this.trailing,
  });

  final String title;
  final VoidCallback onBack;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = JoTheme.of(context);
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: JoSpace.s4),
      decoration: BoxDecoration(border: Border(bottom: JoShape.side(p.border))),
      child: Row(
        children: <Widget>[
          // 返回键：从文字换成图标（左上那支左箭头）。
          JoIconAction(icon: JoIcons.arrowLeft, tip: '返回', onTap: onBack),
          const SizedBox(width: JoSpace.s4),
          Text(
            title,
            style: JoFonts.ui.copyWith(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: p.text,
            ),
          ),
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

/// 文本输入框（自带状态；父级换 key 就能重设初值）。
/// 快捷键输入框：点一下进入捕获，然后**按你要的组合键**。
///
/// 不做「手打 Ctrl+E」这种反人类的事。
/// Esc 取消本次捕获（不是记下 Esc）。
class JoKeyField extends StatefulWidget {
  const JoKeyField({
    super.key,
    required this.spec,
    required this.onChanged,
  });

  /// 当前的键位写法，如 'Ctrl+E'。空 = 没设。
  final String spec;
  final ValueChanged<String> onChanged;

  @override
  State<JoKeyField> createState() => _JoKeyFieldState();
}

class _JoKeyFieldState extends State<JoKeyField> {
  final FocusNode _focus = FocusNode();
  bool _capturing = false;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  /// 把按下的键译成 'Ctrl+E' 这种写法。只按了修饰键就返回 null（继续等）。
  String? _specOf(KeyEvent e) {
    final LogicalKeyboardKey k = e.logicalKey;
    if (k == LogicalKeyboardKey.controlLeft ||
        k == LogicalKeyboardKey.controlRight ||
        k == LogicalKeyboardKey.shiftLeft ||
        k == LogicalKeyboardKey.shiftRight ||
        k == LogicalKeyboardKey.altLeft ||
        k == LogicalKeyboardKey.altRight ||
        k == LogicalKeyboardKey.metaLeft ||
        k == LogicalKeyboardKey.metaRight) {
      return null;
    }
    final HardwareKeyboard kb = HardwareKeyboard.instance;
    final List<String> parts = <String>[];
    if (kb.isControlPressed) parts.add('Ctrl');
    if (kb.isShiftPressed) parts.add('Shift');
    if (kb.isAltPressed) parts.add('Alt');
    final String label = k.keyLabel;
    if (label.isEmpty) return null;
    parts.add(label);
    return parts.join('+');
  }

  @override
  Widget build(BuildContext context) {
    final JoPalette p = JoTheme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () {
          setState(() => _capturing = true);
          _focus.requestFocus();
        },
        child: Focus(
          focusNode: _focus,
          onFocusChange: (bool has) {
            if (!has && _capturing) setState(() => _capturing = false);
          },
          onKeyEvent: (FocusNode node, KeyEvent e) {
            // 捕获时按 Esc = **清除这一条**（变成未设置）。
            // 不在捕获时不动它，让它照常往外传（弹窗还能用它关自己）。
            if (_capturing && e.logicalKey == LogicalKeyboardKey.escape) {
              if (e is KeyDownEvent) {
                widget.onChanged('');
                setState(() => _capturing = false);
              }
              return KeyEventResult.handled;
            }
            if (!_capturing) return KeyEventResult.ignored;
            if (e is! KeyDownEvent) return KeyEventResult.handled;
            final String? spec = _specOf(e);
            if (spec == null) return KeyEventResult.handled;
            widget.onChanged(spec);
            setState(() => _capturing = false);
            return KeyEventResult.handled;
          },
          child: Container(
            height: 32,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: JoSpace.s3),
            decoration: BoxDecoration(
              color: p.surface,
              border: Border.all(
                color: _capturing ? p.accent : p.border,
              ),
            ),
            child: Text(
              _capturing
                  ? '按组合键……'
                  : (widget.spec.trim().isEmpty ? '未设置' : widget.spec),
              style: JoFonts.ui.copyWith(
                fontSize: 13,
                color: _capturing
                    ? p.accent
                    : (widget.spec.trim().isEmpty ? p.secondary : p.text),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class JoInput extends StatefulWidget {
  const JoInput({
    super.key,
    required this.initial,
    required this.onChanged,
    this.hint,
    this.compact = false,
  });

  final String initial;
  final ValueChanged<String> onChanged;
  final String? hint;
  final bool compact;

  @override
  State<JoInput> createState() => _JoInputState();
}

class _JoInputState extends State<JoInput> {
  late final TextEditingController _c;
  late String _sent;

  @override
  void initState() {
    super.initState();
    _c = TextEditingController(text: widget.initial);
    // 必须在 initState 里定死。不能用 late 懒初始化：懒初始化第一次访问
    // 发生在 didUpdateWidget 里，那时 widget.initial 已经是新值了，
    // 于是永远判不出“外部改过”。
    _sent = widget.initial;
  }

  @override
  void didUpdateWidget(JoInput old) {
    super.didUpdateWidget(old);
    // 外部把值改了（比如重命名分组）→ 跟着变；自己打的就不动，免得光标乱跳。
    if (widget.initial != _sent) {
      _sent = widget.initial;
      _c.text = widget.initial;
      _c.selection = TextSelection.collapsed(offset: _c.text.length);
    }
  }

  void _onChanged(String v) {
    _sent = v;
    widget.onChanged(v);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final JoPalette p = JoTheme.of(context);
    final double size = widget.compact ? 12 : 13;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: JoSpace.s3, vertical: 4),
      decoration: BoxDecoration(
        color: p.surface,
        border: JoShape.border(p.border),
        borderRadius: JoShape.br,
      ),
      child: TextField(
        controller: _c,
        onChanged: _onChanged,
        style: JoFonts.ui.copyWith(fontSize: size, color: p.text),
        cursorColor: p.accent,
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          hintText: widget.hint,
          hintStyle: JoFonts.ui.copyWith(fontSize: size, color: p.secondary),
        ),
      ),
    );
  }
}

/// 开关：文字样式（`启用` / `禁用`），不用圆点滑块。
class JoToggle extends StatelessWidget {
  const JoToggle({
    super.key,
    required this.on,
    required this.onChanged,
    this.onLabel = '启用',
    this.offLabel = '禁用',
  });

  final bool on;
  final ValueChanged<bool> onChanged;
  final String onLabel;
  final String offLabel;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = JoTheme.of(context);
    return GestureDetector(
      onTap: () => onChanged(!on),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: JoSpace.s3,
            vertical: JoSpace.s1 + 2,
          ),
          decoration: BoxDecoration(
            color: on ? p.surface : Colors.transparent,
            border: JoShape.border(on ? p.accent : p.border),
            borderRadius: JoShape.br,
          ),
          child: Text(
            on ? onLabel : offLabel,
            style: JoFonts.meta.copyWith(color: on ? p.accent : p.secondary),
          ),
        ),
      ),
    );
  }
}
