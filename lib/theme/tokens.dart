import 'package:flutter/material.dart';

/// 设计令牌：颜色、字体、间距、形状。
/// 不用 Material 的观感——颜色与排版全部自己定。
@immutable
class JoPalette {
  const JoPalette({
    required this.bg,
    required this.surface,
    required this.border,
    required this.text,
    required this.secondary,
    required this.accent,
    required this.isDark,
  });

  final Color bg;
  final Color surface;
  final Color border;
  final Color text;
  final Color secondary;
  final Color accent;
  final bool isDark;

  /// 暗 · 机器
  static const JoPalette dark = JoPalette(
    bg: Color(0xFF0E0F12),
    surface: Color(0xFF16181D),
    border: Color(0xFF262A31),
    text: Color(0xFFE6E3DC),
    secondary: Color(0xFF8A8F98),
    accent: Color(0xFF8AA0B8),
    isDark: true,
  );

  /// 明 · 纸
  static const JoPalette light = JoPalette(
    bg: Color(0xFFF5F2EC),
    surface: Color(0xFFFBFAF6),
    border: Color(0xFFE0DAD0),
    text: Color(0xFF1C1B19),
    secondary: Color(0xFF6E6A62),
    accent: Color(0xFF9A7B4F),
    isDark: false,
  );
}

/// 字体族。
class JoFonts {
  static const String sans = 'SourceHanSansSC';
  static const String serif = 'NotoSerifSC';
  static const String mono = 'monospace';

  /// 界面 / 标题（黑体）
  static const TextStyle ui = TextStyle(fontFamily: sans);

  /// 叙事正文（默认宋体；字号 / 字体由设置决定）
  static const TextStyle body = TextStyle(
    fontFamily: serif,
    height: 1.75,
    fontSize: 16,
  );

  /// 元数据 / 标签（等宽）
  static const TextStyle meta = TextStyle(
    fontFamily: mono,
    height: 1.4,
    fontSize: 12,
    letterSpacing: 0.4,
  );
}

/// 间距尺度。
class JoSpace {
  static const double s1 = 4;
  static const double s2 = 8;
  static const double s3 = 12;
  static const double s4 = 16;
  static const double s5 = 24;
  static const double s6 = 32;
  static const double s7 = 48;
}

/// 形状：直角 / 极小圆角，细线，零阴影。
class JoShape {
  static const double radius = 2;
  static const BorderRadius br = BorderRadius.all(Radius.circular(radius));
  static Border border(Color color) => Border.all(color: color, width: 1);
  static BorderSide side(Color color) => BorderSide(color: color, width: 1);
}

/// 用户可配置项。
@immutable
class JoSettings {
  const JoSettings({
    this.isDark = true,
    this.bodySize = 16,
    this.serifBody = true,
  });

  final bool isDark;

  /// 叙事正文字号。
  final double bodySize;

  /// 正文用宋体（true）还是黑体（false）。
  final bool serifBody;

  JoPalette get palette => isDark ? JoPalette.dark : JoPalette.light;

  String get bodyFamily => serifBody ? JoFonts.serif : JoFonts.sans;

  /// 叙事正文样式（正文块 / 焦点栏用）。
  TextStyle bodyStyle(Color color) => JoFonts.body.copyWith(
        fontFamily: bodyFamily,
        fontSize: bodySize,
        color: color,
      );

  JoSettings copyWith({bool? isDark, double? bodySize, bool? serifBody}) {
    return JoSettings(
      isDark: isDark ?? this.isDark,
      bodySize: bodySize ?? this.bodySize,
      serifBody: serifBody ?? this.serifBody,
    );
  }
}

/// 把令牌塞进 Theme，供子组件读取。
@immutable
class JoTheme extends InheritedWidget {
  const JoTheme({super.key, required this.settings, required super.child});

  final JoSettings settings;

  JoPalette get palette => settings.palette;

  static JoTheme _scope(BuildContext context) {
    final JoTheme? t = context.dependOnInheritedWidgetOfExactType<JoTheme>();
    assert(t != null, 'JoTheme 未挂载');
    return t!;
  }

  static JoPalette of(BuildContext context) => _scope(context).palette;

  static JoSettings settingsOf(BuildContext context) => _scope(context).settings;

  @override
  bool updateShouldNotify(JoTheme oldWidget) => settings != oldWidget.settings;
}
