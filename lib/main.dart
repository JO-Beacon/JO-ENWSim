import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel, rootBundle;

import 'data/world_store.dart';
import 'model/demo.dart';
import 'model/model_plan.dart';
import 'model/provider.dart';
import 'theme/settings_store.dart';
import 'theme/tokens.dart';
import 'ui/jo_localizations.dart';
import 'ui/workspace.dart';

/// 把本应用自己的许可也塞进 Flutter 的许可清单。
/// 否则“查看开源许可”里只有第三方依赖，没有我们自己的 Apache-2.0 正文。
void _registerOwnLicense() {
  LicenseRegistry.addLicense(() async* {
    final String text = await rootBundle.loadString('LICENSE');
    yield LicenseEntryWithLineBreaks(<String>['JO-ENWSim'], text);
  });
}

/// 把**随包发出的**那几份许可正文也塞进清单。
///
/// 这些文件本来就在 `assets/licenses/` 里、跟安装包一起出去了；
/// 注册一遍是为了在应用里也读得到（设置 → 关于 → 查看开源许可），
/// 让人不用去翻安装目录。
void _registerBundledLicenses() {
  LicenseRegistry.addLicense(() async* {
    final String text = await rootBundle.loadString(
      'assets/licenses/RemixIcon-License-1.0.txt',
    );
    yield LicenseEntryWithLineBreaks(<String>['Remix Icon'], text);
  });
  LicenseRegistry.addLicense(() async* {
    final String text = await rootBundle.loadString(
      'assets/licenses/SourceHanSans-OFL-1.1.txt',
    );
    yield LicenseEntryWithLineBreaks(<String>['Noto Sans SC'], text);
  });
  LicenseRegistry.addLicense(() async* {
    final String text = await rootBundle.loadString(
      'assets/licenses/SourceHanSans-OFL-1.1.txt',
    );
    yield LicenseEntryWithLineBreaks(<String>['Noto Serif SC'], text);
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _registerOwnLicense();
  _registerBundledLicenses();
  final SettingsStore store = await SettingsStore.open();
  final LoadResult<List<Provider>> providers = store.loadProviders();
  final LoadResult<ModelPlan> plan = store.loadGlobalPlan();
  // 世界和回合在 SQLite 里。第一次建库时自带了几个世界。
  final WorldStore worldStore = await WorldStore.open();
  final WorldsLoad worlds = worldStore.loadWorlds();
  runApp(
    JoEnwsApp(
      store: store,
      worldStore: worldStore,
      initialWorlds: worlds.worlds,
      worldsNote: worlds.note,
      initial: store.load(),
      providers: providers.value,
      servicesNote: loadNoteOf(providers, '服务商'),
      initialGlobalPlan: plan.value,
      initialPrompts: store.loadPrompts(),
      globalPlanNote: loadNoteOf(plan, '模型默认'),
    ),
  );
}

class JoEnwsApp extends StatefulWidget {
  const JoEnwsApp({
    super.key,
    required this.store,
    required this.initial,
    this.providers = const <Provider>[],
    this.initialPrompts = const <String, String>{},
    required this.worldStore,
    this.initialWorlds = const <World>[],
    this.worldsNote,
    this.servicesNote,
    this.initialGlobalPlan = const ModelPlan(),
    this.globalPlanNote,
  });

  final SettingsStore store;
  final JoSettings initial;
  final List<Provider> providers;

  /// 服务商存档读不出来时的一句话（没什么可说就是 null）。
  final String? servicesNote;

  final ModelPlan initialGlobalPlan;

  /// 设置 → 引擎 里那几步的提示词（缺的已用默认补上）。
  final Map<String, String> initialPrompts;

  /// 全局模型默认读不出来时的一句话。
  final String? globalPlanNote;

  /// 世界和回合的库。
  final WorldStore worldStore;

  /// 打开时读出来的世界。
  final List<World> initialWorlds;

  /// 世界存档读不出来时的一句话（如实说，不藏）。
  final String? worldsNote;

  @override
  State<JoEnwsApp> createState() => _JoEnwsAppState();
}

class _JoEnwsAppState extends State<JoEnwsApp>
    with SingleTickerProviderStateMixin {
  late JoSettings _settings = widget.initial;
  late List<Provider> _providers = List<Provider>.of(widget.providers);

  /// 全局模型默认（设置 → 引擎），存盘。
  late ModelPlan _globalPlan = widget.initialGlobalPlan;

  /// 快捷键：动作 id → 键位字符串。
  late Map<String, String> _keys = widget.store.loadKeys();

  /// 引擎提示词。存盘。
  late Map<String, String> _prompts = <String, String>{
    ...widget.initialPrompts,
  };

  /// 明暗过渡：0 = 明（纸），1 = 暗（机器）。
  /// 直接在根上插色调色板，所有读 JoTheme.of 的组件就都跟着补间了。
  late final AnimationController _themeAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: _settings.isDark ? 1 : 0,
  );

  /// 现在实际用哪一套：跟随系统就看系统主题，否则看用户选的。
  ///
  /// 取系统主题用 `platformBrightness`——它就是操作系统那个
  /// “深色 / 浅色”设置（Windows：个性化 → 颜色 → 选择模式）。
  bool get _effectiveDark {
    if (!_settings.followSystem) return _settings.isDark;
    return WidgetsBinding.instance.platformDispatcher.platformBrightness ==
        Brightness.dark;
  }

  /// 把动画推到当前该在的位置。关掉动画就一步到位（启动时用）。
  void _syncTheme({bool animate = true}) {
    final bool dark = _effectiveDark;
    final double target = dark ? 1 : 0;
    if (!animate) {
      _themeAnim.value = target;
      return;
    }
    if (target == _themeAnim.value) return;
    if (dark) {
      _themeAnim.forward();
    } else {
      _themeAnim.reverse();
    }
  }

  /// 原生窗口（只有 Windows 那边有；其它平台没有这条通道）。
  static const MethodChannel _windowChannel = MethodChannel('joenws/window');

  @override
  void initState() {
    super.initState();
    // 启动时先对到正确的那一套（不播动画）。
    _syncTheme(animate: false);
    _pushCaption();
    _themeAnim.addListener(_pushCaption);
    // 系统主题变了就自己跟上——不然得重启才跟。
    WidgetsBinding.instance.platformDispatcher.onPlatformBrightnessChanged =
        () {
          if (_settings.followSystem) _syncTheme();
        };
  }

  @override
  void dispose() {
    WidgetsBinding.instance.platformDispatcher.onPlatformBrightnessChanged =
        null;
    _themeAnim.removeListener(_pushCaption);
    _themeAnim.dispose();
    super.dispose();
  }

  /// 把当前背景色推给原生，让标题栏永远和背景一致、且不透明（关掉 Mica）。
  /// 过渡期间每帧都推一次，所以标题栏会跟着一起渐变。
  void _pushCaption() {
    unawaited(
      _sendCaption(
        JoPalette.lerp(JoPalette.light, JoPalette.dark, _themeAnim.value),
      ),
    );
  }

  Future<void> _sendCaption(JoPalette palette) async {
    try {
      await _windowChannel.invokeMethod<void>('setCaption', <String, Object>{
        'caption': palette.bg.toARGB32(),
        'text': palette.text.toARGB32(),
        'border': palette.border.toARGB32(),
        'dark': palette.isDark ? 1 : 0,
      });
    } catch (_) {
      // 非 Windows（安卓 / 单元测试）没这条通道，忽略。
    }
  }

  void _update(JoSettings next) {
    setState(() => _settings = next);
    _syncTheme();
    widget.store.save(next);
  }

  void _updateProviders(List<Provider> next) {
    setState(() => _providers = next);
    widget.store.saveProviders(next);
  }

  @override
  Widget build(BuildContext context) {
    // 给界面的那套，直接用动画当前的位置算——过渡期间也是平滑的。
    final JoPalette palette = JoPalette.lerp(
      JoPalette.light,
      JoPalette.dark,
      _themeAnim.value,
    );
    return MaterialApp(
      title: 'JO-ENWSim',
      debugShowCheckedModeBanner: false,
      // 输入框的选中菜单文字取自 Cupertino 本地化；不挂代理就是英文
      // （Cut / Copy / Paste / Select all）。自定义这份只改那几个词。
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        JoCupertinoLocalizationsDelegate(),
        DefaultMaterialLocalizations.delegate,
        DefaultWidgetsLocalizations.delegate,
      ],
      theme: ThemeData(
        useMaterial3: false,
        fontFamily: JoFonts.sans,
        scaffoldBackgroundColor: palette.bg,
        colorScheme: ColorScheme.fromSeed(
          seedColor: palette.accent,
          brightness: _effectiveDark ? Brightness.dark : Brightness.light,
        ),
      ),
      builder: (BuildContext context, Widget? child) {
        // JoTheme 必须在 Navigator 之上，弹窗（Overlay）才取得到。
        // 用 AnimatedBuilder 只包 JoTheme：Navigator 作为 child 传进去，
        // 不会被每帧重建（不丢页面状态）。
        return AnimatedBuilder(
          animation: _themeAnim,
          child: child ?? const SizedBox.shrink(),
          builder: (BuildContext context, Widget? inner) {
            return JoTheme(
              settings: _settings,
              palette: JoPalette.lerp(
                JoPalette.light,
                JoPalette.dark,
                _themeAnim.value,
              ),
              child: inner ?? const SizedBox.shrink(),
            );
          },
        );
      },
      home: Workspace(
        settings: _settings,
        onSettingsChanged: _update,
        providers: _providers,
        onProvidersChanged: _updateProviders,
        globalPlan: _globalPlan,
        prompts: _prompts,
        onPromptsChanged: (Map<String, String> next) {
          setState(() => _prompts = next);
          widget.store.savePrompts(next);
        },
        store: widget.worldStore,
        worlds: widget.initialWorlds,
        worldsNote: widget.worldsNote,
        keys: _keys,
        onKeysChanged: (Map<String, String> next) {
          setState(() => _keys = next);
          widget.store.saveKeys(next);
        },
        servicesNote: widget.servicesNote,
        globalPlanNote: widget.globalPlanNote,
        onGlobalPlanChanged: (ModelPlan next) {
          setState(() => _globalPlan = next);
          widget.store.saveGlobalPlan(next);
        },
      ),
    );
  }
}
