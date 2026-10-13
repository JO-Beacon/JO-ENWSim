import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// 可点文字（细线边框可选）。
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
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: JoSpace.s3,
            vertical: JoSpace.s1 + 2,
          ),
          decoration: bordered
              ? BoxDecoration(
                  border: JoShape.border(p.border),
                  borderRadius: JoShape.br,
                )
              : null,
          child: Text(text, style: JoFonts.meta.copyWith(color: color ?? p.secondary)),
        ),
      ),
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
    return GestureDetector(
      onTap: () => onChanged(o.value),
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
            o.label,
            style: JoFonts.meta.copyWith(color: on ? p.accent : p.secondary),
          ),
        ),
      ),
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
          JoButton(text: '← 返回', onTap: onBack, color: p.accent),
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
