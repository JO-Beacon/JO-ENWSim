import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../model/provider.dart';
import 'tokens.dart';

/// 设置的持久化（存到本地）。
class SettingsStore {
  const SettingsStore(this._prefs);

  final SharedPreferences _prefs;

  static const String _kDark = 'appearance.dark';
  static const String _kBodySize = 'narrative.bodySize';
  static const String _kSerif = 'narrative.serifBody';
  static const String _kProviders = 'provider.list';

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

  /// 服务商列表。
  List<Provider> loadProviders() {
    final String? raw = _prefs.getString(_kProviders);
    if (raw == null || raw.isEmpty) return <Provider>[];
    try {
      final Object? j = jsonDecode(raw);
      if (j is! List) return <Provider>[];
      return j
          .whereType<Map<String, dynamic>>()
          .map((Map<String, dynamic> m) => Provider.fromJson(m))
          .toList();
    } catch (_) {
      return <Provider>[];
    }
  }

  Future<void> saveProviders(List<Provider> list) async {
    await _prefs.setString(
      _kProviders,
      jsonEncode(list.map((Provider p) => p.toJson()).toList()),
    );
  }
}
