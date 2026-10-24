import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';
import 'icons.dart';
import 'tooltip.dart';

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
/// **tip 是必填的**：界面上的图标一律要能悬停看出名字。
///
/// [inverted] 是实底强调色 + 底色图标，给主行动用（比如发送）。
class JoIconAction extends StatelessWidget {
  const JoIconAction({
    super.key,
    required this.icon,
    required this.tip,
    required this.onTap,
    this.size = 16,
    this.inverted = false,
  });

  final IconData icon;

  /// 悬停时浮出来的名字。必填，不许留空。
  final String tip;

  final VoidCallback onTap;
  final double size;

  /// 反色：实底强调色 + 底色图标。主行动用。
  final bool inverted;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = JoTheme.of(context);
    return JoTooltip(
      text: tip,
      child: JoTap(
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
      ),
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
    this.tip,
  });

  final String text;
  final VoidCallback onTap;
  final Color? color;
  final bool bordered;

  /// 悬停文字提示。给“×”、“↺”这类只有个符号的按钮用。
  final String? tip;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = JoTheme.of(context);
    final Color base = color ?? p.secondary;
    final Widget button = JoTap(
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
    return tip == null ? button : JoTooltip(text: tip!, child: button);
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
            color: on
                ? p.surface
                : (hover
                      ? p.surface.withValues(alpha: 0.6)
                      : Colors.transparent),
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
            style: JoFonts.meta.copyWith(
              color: p.secondary,
              letterSpacing: 1.2,
            ),
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
                if (i > 0) Divider(height: 1, thickness: 1, color: p.border),
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
/// 不做“手打 Ctrl+E”这种反人类的事。
/// Esc 取消本次捕获（不是记下 Esc）。
class JoKeyField extends StatefulWidget {
  const JoKeyField({super.key, required this.spec, required this.onChanged});

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
              border: Border.all(color: _capturing ? p.accent : p.border),
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
      child: JoTextField(
        controller: _c,
        onChanged: _onChanged,
        style: JoFonts.ui.copyWith(fontSize: size, color: p.text),
        hint: widget.hint,
        hintStyle: JoFonts.ui.copyWith(fontSize: size, color: p.secondary),
      ),
    );
  }
}

/// 输入框：`EditableText` + 提示文字，**不挂 Material**。
///
/// 为什么不用自带那个 `TextField`：它要求外面有 `Material` 祖先。而这套界面
/// 是自绘的、树里没有 `Material`，于是 debug 构建直接抛红屏（release 里那句
/// 检查被编译掉，看着没事，但 ink / 焦点高亮 / 默认文字样式全取不到）。
/// 所以输入框一律走这里，边框、底色、左右内边距由外面那个 Container 给。
///
/// **光有 `EditableText` 是不能选字的**：拖选、双击选词、三击选行、Shift+点
/// 扩选、右键菜单，都是 `TextField` 自己额外垫的那层手势。这里用
/// [TextSelectionGestureDetectorBuilder] 把那层补回来（它已经是公开 API）。
///
/// 高度对齐原来的 `TextField(isDense: true, border: InputBorder.none)`：
/// 它比纯文字高 8，所以这里上下各留 4（可用 [verticalPadding] 改）。
class JoTextField extends StatefulWidget {
  const JoTextField({
    super.key,
    required this.controller,
    required this.style,
    this.hint,
    this.hintStyle,
    this.obscureText = false,
    this.autofocus = false,
    this.onChanged,
    this.onSubmitted,
    this.maxLines = 1,
    this.minLines,
    this.focusNode,
    this.verticalPadding = 4,
  });

  final TextEditingController controller;
  final TextStyle style;
  final String? hint;
  final TextStyle? hintStyle;
  final bool obscureText;
  final bool autofocus;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  /// `null` = 不限行数（多行）。[obscureText] 为真时必须是 1。
  final int? maxLines;

  /// 最少占几行的高度（为空就跟内容走）。多行框用它撑住初始高度。
  final int? minLines;

  /// 外面要自己管焦点（比如失焦时提交）就传一个进来，不传就内部建一个。
  final FocusNode? focusNode;

  final double verticalPadding;

  @override
  State<JoTextField> createState() => _JoTextFieldState();
}

class _JoTextFieldState extends State<JoTextField> {
  FocusNode? _ownFocus;

  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_sanitize);
    // 先处理一遍：外面可能已经把带 \r 的字塞进来了。
    WidgetsBinding.instance.addPostFrameCallback((_) => _sanitize());
  }

  /// 把 `\r` 从输入框里清掉。
  ///
  /// 从网页 / 聊天窗口复制多行文字过来时，换行往往是 **CRLF**；
  /// `\r` 到我们这儿就变成一个“豆腐块”（☒），存进库以后还会带乱
  /// Markdown 的解析。这里在**入口**就统一成 LF，而不是到处去兼容。
  void _sanitize() {
    if (!mounted) return;
    final String t = widget.controller.text;
    if (!t.contains('\r')) return;

    final int sel = widget.controller.selection.baseOffset;
    // 光标前删掉了几个字符，光标就往前挪几位。
    final int before = sel < 0 ? 0 : sel;
    final int removedBefore = '\r'
        .allMatches(t.substring(0, before.clamp(0, t.length)))
        .length;
    final String cleaned = t.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final int caret = (sel - removedBefore).clamp(0, cleaned.length);
    widget.controller.value = TextEditingValue(
      text: cleaned,
      selection: sel < 0
          ? const TextSelection.collapsed(offset: 0)
          : TextSelection.collapsed(offset: caret),
      composing: TextRange.empty,
    );
  }

  @override
  void dispose() {
    widget.controller.removeListener(_sanitize);
    _ownFocus?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final JoPalette p = JoTheme.of(context);
    // 选中底色用界面自己的强调色：Cupertino 那套从
    // `DefaultSelectionStyle` 读它，Cupertino 默认是系统蓝，跟深色界面不搭。
    return DefaultSelectionStyle(
      selectionColor: p.accent.withValues(alpha: 0.3),
      cursorColor: p.accent,
      child: CupertinoTextField(
        controller: widget.controller,
        focusNode: _focus,
        autofocus: widget.autofocus,
        maxLines: widget.maxLines,
        minLines: widget.minLines,
        obscureText: widget.obscureText,
        style: widget.style,
        placeholder: widget.hint,
        placeholderStyle:
            widget.hintStyle ?? widget.style.copyWith(color: p.secondary),
        cursorColor: p.accent,
        // 底色、描边、圆角都由外面那个 Container 给，这里什么都不画。
        decoration: const BoxDecoration(),
        // 内边距放在框里面，这样整块框都能点（不只是文字那一行）。
        padding: EdgeInsets.symmetric(vertical: widget.verticalPadding),
        onChanged: widget.onChanged,
        onSubmitted: widget.onSubmitted,
        // 菜单外观自己给：Cupertino 自带的那个是圆角大灰底，跟这套界面不搭。
        // **布局**仍然交给 Flutter（`TextSelectionToolbar` 负责把菜单摆到选区上方，
        // 屏幕放不下就翻到下方），只有那层壳换成我们的样式。
        contextMenuBuilder: (BuildContext c, EditableTextState st) =>
            _toolbar(st, p),
      ),
    );
  }

  /// 选中文字后弹的菜单：方角、跟卡片同一种底色和描边，字用界面字体。
  ///
  /// 动作直接调 `EditableTextState` 那几个方法：它们做完会自己把菜单收掉。
  Widget _toolbar(EditableTextState st, JoPalette p) {
    final TextEditingValue v = widget.controller.value;
    final TextSelection sel = v.selection;
    final bool hasSel = sel.isValid && !sel.isCollapsed;
    final bool hasText = v.text.isNotEmpty;
    final bool allSel = hasText && sel.start == 0 && sel.end == v.text.length;
    final TextSelectionToolbarAnchors a = st.contextMenuAnchors;

    final List<({String label, VoidCallback? onTap})> items =
        <({String label, VoidCallback? onTap})>[
          if (!widget.obscureText)
            (
              label: '剪切',
              onTap: hasSel
                  ? () => st.cutSelection(SelectionChangedCause.toolbar)
                  : null,
            ),
          if (!widget.obscureText)
            (
              label: '复制',
              onTap: hasSel
                  ? () => st.copySelection(SelectionChangedCause.toolbar)
                  : null,
            ),
          (
            label: '粘贴',
            onTap: () => st.pasteText(SelectionChangedCause.toolbar),
          ),
          (
            label: '全选',
            onTap: hasText && !allSel
                ? () => st.selectAll(SelectionChangedCause.toolbar)
                : null,
          ),
        ];

    return TextSelectionToolbar(
      anchorAbove: a.primaryAnchor,
      anchorBelow: a.secondaryAnchor ?? a.primaryAnchor,
      toolbarBuilder: (BuildContext ctx, Widget child) => Container(
        decoration: BoxDecoration(
          color: p.surface,
          border: JoShape.border(p.border),
          // 方角：跟卡片一样只留 2 的小圆角，不用 Cupertino 那种大圆角。
          borderRadius: JoShape.br,
        ),
        child: child,
      ),
      children: <Widget>[
        for (final ({String label, VoidCallback? onTap}) it in items)
          _JoToolbarButton(palette: p, label: it.label, onTap: it.onTap),
      ],
    );
  }
}

/// 选中菜单上的一个文字按钮（自绘外观，不是 Material 的 `TextButton`）。
class _JoToolbarButton extends StatefulWidget {
  const _JoToolbarButton({
    required this.palette,
    required this.label,
    required this.onTap,
  });

  final JoPalette palette;
  final String label;

  /// `null` = 这一项现在用不了（灰着，点了没反应）。
  final VoidCallback? onTap;

  @override
  State<_JoToolbarButton> createState() => _JoToolbarButtonState();
}

class _JoToolbarButtonState extends State<_JoToolbarButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final JoPalette p = widget.palette;
    final bool on = widget.onTap != null;
    return MouseRegion(
      cursor: on ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: JoSpace.s3,
            vertical: 6,
          ),
          color: on && _hover ? p.border.withValues(alpha: 0.5) : null,
          child: Text(
            widget.label,
            style: JoFonts.ui.copyWith(
              fontSize: 12,
              color: on ? p.text : p.secondary,
            ),
          ),
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
