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
    required this.icon,
    required this.accent,
    required this.isDark,
  });

  final Color bg;
  final Color surface;
  final Color border;
  final Color text;
  final Color secondary;

  /// 图标与结构件（分隔、表头那类）专用的一档。
  /// 和 [secondary] 分开，是为了以后能单独调它而不动正文。
  /// 初值取得跟 secondary 一样，所以加它是**零视觉变化**。
  final Color icon;

  final Color accent;
  final bool isDark;

  /// 暗 · 机器
  static const JoPalette dark = JoPalette(
    bg: Color(0xFF0E0F12),
    surface: Color(0xFF16181D),
    border: Color(0xFF262A31),
    text: Color(0xFFE6E3DC),
    secondary: Color(0xFF8A8F98),
    icon: Color(0xFF8A8F98),
    accent: Color(0xFF8AA0B8),
    isDark: true,
  );

  /// 明暗过渡用：逐字段插值。
  /// isDark 不做插值，过中点时翻过来（它只当开关用）。
  static JoPalette lerp(JoPalette a, JoPalette b, double t) {
    if (t <= 0) return a;
    if (t >= 1) return b;
    return JoPalette(
      bg: Color.lerp(a.bg, b.bg, t)!,
      surface: Color.lerp(a.surface, b.surface, t)!,
      border: Color.lerp(a.border, b.border, t)!,
      text: Color.lerp(a.text, b.text, t)!,
      secondary: Color.lerp(a.secondary, b.secondary, t)!,
      icon: Color.lerp(a.icon, b.icon, t)!,
      accent: Color.lerp(a.accent, b.accent, t)!,
      isDark: t < 0.5 ? a.isDark : b.isDark,
    );
  }

  /// 明 · 纸
  static const JoPalette light = JoPalette(
    bg: Color(0xFFF5F2EC),
    surface: Color(0xFFFBFAF6),
    border: Color(0xFFE0DAD0),
    text: Color(0xFF1C1B19),
    secondary: Color(0xFF6E6A62),
    icon: Color(0xFF6E6A62),
    // 强调色：跟暗色同一色族（蓝），只是压深一档——
    // 以前是金褐 #9A7B4F，在米色底上发绿，跟暗色下的蓝根本不是一回事。
    accent: Color(0xFF4A6B8A),
    isDark: false,
  );
}

/// 字体族。
///
/// 三个：思源黑体（Noto Sans SC）、思源宋体（Noto Serif SC）、
/// 等宽（Noto Sans Mono，只给代码用）。
/// **不许再写 'monospace' 这种泛称**：它不是字体名，Windows 上找不到这个
/// 字体族，引擎就落回自带的 Roboto（就是那股“Material 味”），
/// 而中文又落回系统字体，于是同一行里两种字。
class JoFonts {
  static const String sans = 'NotoSansSC';
  static const String serif = 'NotoSerifSC';
  static const String mono = 'NotoSansMono';

  /// 数字等宽。以前靠等宽字体把编号那列对齐；换成思源后用这个特性，
  /// 数字宽度一致、列不会跳。字体不支持就忽略。
  static const List<FontFeature> tabular = <FontFeature>[
    FontFeature.tabularFigures(),
  ];

  /// 界面 / 标题（黑体）
  static const TextStyle ui = TextStyle(fontFamily: sans);

  /// 叙事正文（默认宋体；字号 / 字体由设置决定）。
  ///
  /// **正文不要那条装饰下划线**：它不是“界面装饰”，是给人读的文章。
  /// 而且以后正文要接 markdown 渲染——标题、列表、引用、代码块
  /// 都会自己带样式，底下再挂一条灰线会很乱。
  /// 这里显式写 none（不是留空）：留空就会把环境里的下划线 merge 进来。
  static const TextStyle body = TextStyle(
    fontFamily: serif,
    height: 1.75,
    fontSize: 16,
    decoration: TextDecoration.none,
  );

  /// 元数据 / 标签（小一号的黑体 + 数字等宽）
  static const TextStyle meta = TextStyle(
    fontFamily: sans,
    fontFeatures: tabular,
    height: 1.4,
    fontSize: 12,
    letterSpacing: 0.4,
  );

  /// 代码（行内代码 / 代码块）。
  ///
  /// 真等宽字体；中文找不到字形时落回思源黑体（同一个设计家族，接缝最小）。
  static const TextStyle code = TextStyle(
    fontFamily: mono,
    fontFamilyFallback: <String>[sans],
    fontFeatures: tabular,
    height: 1.5,
  );

  /// 全局那层“装饰下划线”的**颜色**：淡灰，随明暗走。
  ///
  /// 本来根本不该有这条线：是 MaterialApp 拿 `_errorTextStyle`
  /// （红字、等宽、**淡黄双下划线**）当根默认样式，逼你把字包进 Material；
  /// 而 `Text` 会把环境样式 merge 进来 —— 于是每条没写 decoration 的字
  /// 都白赚了一条黄色双线。
  ///
  /// 既然设计上就要这条“下划线当装饰”，那就自己定一个安静的灰：
  /// 暗色给得比背景亮一点（看得见但不抢），亮色给得比背景深一点。
  static Color decorationColor(JoPalette p) =>
      p.secondary.withValues(alpha: p.isDark ? 0.45 : 0.32);

  /// 全局装饰线的样式：单线、1px、细灰。
  static TextStyle decorationOn(JoPalette p) => TextStyle(
    decoration: TextDecoration.underline,
    decorationColor: decorationColor(p),
    decorationStyle: TextDecorationStyle.solid,
    decorationThickness: 1,
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
    this.followSystem = false,
  });

  final bool isDark;

  /// 跟随系统明暗。
  ///
  /// 开了之后，实际用哪一套由平台亮度决定，[isDark] 被忽略
  /// （但保留它——关掉跟随时要回到用户上次选的那套）。
  final bool followSystem;

  /// 叙事正文字号。
  final double bodySize;

  /// 正文用宋体（true）还是黑体（false）。
  final bool serifBody;

  // 注意：这里**故意不提供** `palette` 这个便利方法。
  // “实际用哪一套”得把 followSystem 也算进去，只有 main.dart 里那个
  // `_effectiveDark` 知道——留着个只认 isDark 的 getter，就是个会说谎的陷阱。

  String get bodyFamily => serifBody ? JoFonts.serif : JoFonts.sans;

  /// 叙事正文样式（正文块 / 焦点栏用）。
  TextStyle bodyStyle(Color color) => JoFonts.body.copyWith(
    fontFamily: bodyFamily,
    fontSize: bodySize,
    color: color,
  );

  JoSettings copyWith({
    bool? isDark,
    double? bodySize,
    bool? serifBody,
    bool? followSystem,
  }) {
    return JoSettings(
      isDark: isDark ?? this.isDark,
      bodySize: bodySize ?? this.bodySize,
      serifBody: serifBody ?? this.serifBody,
      followSystem: followSystem ?? this.followSystem,
    );
  }
}

/// 把令牌塞进 Theme，供子组件读取。
@immutable
class JoTheme extends InheritedWidget {
  const JoTheme({
    super.key,
    required this.settings,
    required this.palette,
    required super.child,
  });

  final JoSettings settings;

  /// 当前**实际**用的调色板。明暗切换时这里是插值中的值，不是目标值。
  final JoPalette palette;

  static JoTheme _scope(BuildContext context) {
    final JoTheme? t = context.dependOnInheritedWidgetOfExactType<JoTheme>();
    assert(t != null, 'JoTheme 未挂载');
    return t!;
  }

  static JoPalette of(BuildContext context) => _scope(context).palette;

  static JoSettings settingsOf(BuildContext context) =>
      _scope(context).settings;

  @override
  bool updateShouldNotify(JoTheme oldWidget) =>
      settings != oldWidget.settings || palette != oldWidget.palette;
}
