import 'package:flutter/material.dart';

import 'theme/settings_store.dart';
import 'theme/tokens.dart';
import 'ui/workspace.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final SettingsStore store = await SettingsStore.open();
  runApp(JoEnwsApp(store: store, initial: store.load()));
}

class JoEnwsApp extends StatefulWidget {
  const JoEnwsApp({super.key, required this.store, required this.initial});

  final SettingsStore store;
  final JoSettings initial;

  @override
  State<JoEnwsApp> createState() => _JoEnwsAppState();
}

class _JoEnwsAppState extends State<JoEnwsApp> {
  late JoSettings _settings = widget.initial;

  void _update(JoSettings next) {
    setState(() => _settings = next);
    widget.store.save(next);
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
        return JoTheme(
          settings: _settings,
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: Workspace(settings: _settings, onSettingsChanged: _update),
    );
  }
}
