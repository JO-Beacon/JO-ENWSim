import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel, rootBundle;

import 'model/provider.dart';
import 'theme/settings_store.dart';
import 'theme/tokens.dart';
import 'ui/workspace.dart';

/// 把本应用自己的许可也塞进 Flutter 的许可清单。
/// 否则“查看开源许可”里只有第三方依赖，没有我们自己的 Apache-2.0 正文。
void _registerOwnLicense() {
  LicenseRegistry.addLicense(() async* {
    final String text = await rootBundle.loadString('LICENSE');
    yield LicenseEntryWithLineBreaks(<String>['JO-ENWSim'], text);
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _registerOwnLicense();
  final SettingsStore store = await SettingsStore.open();
  runApp(
    JoEnwsApp(
      store: store,
      initial: store.load(),
      providers: store.loadProviders(),
    ),
  );
}

class JoEnwsApp extends StatefulWidget {
  const JoEnwsApp({
    super.key,
    required this.store,
    required this.initial,
    this.providers = const <Provider>[],
  });

  final SettingsStore store;
  final JoSettings initial;
  final List<Provider> providers;

  @override
  State<JoEnwsApp> createState() => _JoEnwsAppState();
}

class _JoEnwsAppState extends State<JoEnwsApp>
    with SingleTickerProviderStateMixin {
  late JoSettings _settings = widget.initial;
  late List<Provider> _providers = List<Provider>.of(widget.providers);

  /// 明暗过渡：0 = 明（纸），1 = 暗（机器）。
  /// 直接在根上插色调色板，所有读 JoTheme.of 的组件就都跟着补间了。
  late final AnimationController _themeAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: _settings.isDark ? 1 : 0,
  );

  /// 原生窗口（只有 Windows 那边有；其它平台没有这条通道）。
  static const MethodChannel _windowChannel = MethodChannel('joenws/window');

  @override
  void initState() {
    super.initState();
    _pushCaption();
    _themeAnim.addListener(_pushCaption);
  }

  @override
  void dispose() {
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
    if (next.isDark != _settings.isDark) {
      if (next.isDark) {
        _themeAnim.forward();
      } else {
        _themeAnim.reverse();
      }
    }
    setState(() => _settings = next);
    widget.store.save(next);
  }

  void _updateProviders(List<Provider> next) {
    setState(() => _providers = next);
    widget.store.saveProviders(next);
  }

  @override
  Widget build(BuildContext context) {
    final JoPalette palette = _settings.palette;
    return MaterialApp(
      title: 'JO-ENWSim',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: false,
        fontFamily: JoFonts.sans,
        scaffoldBackgroundColor: palette.bg,
        colorScheme: ColorScheme.fromSeed(
          seedColor: palette.accent,
          brightness: _settings.isDark ? Brightness.dark : Brightness.light,
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
      ),
    );
  }
}
