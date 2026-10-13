import 'package:shared_preferences/shared_preferences.dart';

import 'tokens.dart';

/// 设置的持久化（存到本地）。
class SettingsStore {
  const SettingsStore(this._prefs);

  final SharedPreferences _prefs;

  static const String _kDark = 'appearance.dark';
  static const String _kBodySize = 'narrative.bodySize';
  static const String _kSerif = 'narrative.serifBody';

  static Future<SettingsStore> open() async =>
      SettingsStore(await SharedPreferences.getInstance());

  JoSettings load() {
    return JoSettings(
      isDark: _prefs.getBool(_kDark) ?? true,
      bodySize: _prefs.getDouble(_kBodySize) ?? 16,
      serifBody: _prefs.getBool(_kSerif) ?? true,
    );
  }

  Future<void> save(JoSettings s) async {
    await _prefs.setBool(_kDark, s.isDark);
    await _prefs.setDouble(_kBodySize, s.bodySize);
    await _prefs.setBool(_kSerif, s.serifBody);
  }
}
