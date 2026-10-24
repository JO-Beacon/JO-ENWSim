import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../model/model_plan.dart';
import '../model/provider.dart';
import '../model/shortcuts.dart';
import 'tokens.dart';

/// 读存档的结果：读到了什么 + 有多少读不出来。
///
/// 做法：**逐条解析**。坏的那条跳过，其余照常读出来。
/// **不静默丢弃、不备份**——读不出来的就如实报出来，让界面能说清楚。
class LoadResult<T> {
  const LoadResult({
    required this.value,
    this.unreadable = 0,
    this.broken = false,
  });

  final T value;

  /// 有多少条读不出来。
  final int unreadable;

  /// 整份都读不出来（不是 JSON / 形状不对）。
  final bool broken;

  bool get clean => !broken && unreadable == 0;
}

/// 给界面用的一句话；没什么可说的就返回 null。
String? loadNoteOf(LoadResult<Object?> r, String what) {
  if (r.broken) return '$what存档读不出来（文件坏了），下面显示不出来。';
  if (r.unreadable > 0) return '还有 ${r.unreadable} 条$what读不出来。';
  return null;
}

/// 设置的持久化（存到本地）。
class SettingsStore {
  const SettingsStore(this._prefs);

  final SharedPreferences _prefs;

  static const String _kDark = 'appearance.dark';
  static const String _kBodySize = 'narrative.bodySize';
  static const String _kSerif = 'narrative.serifBody';
  static const String _kProviders = 'provider.list';
  static const String _kGlobalPlan = 'model.global';
  static const String _kWorldPlans = 'model.worlds';
  static const String _kKeys = 'input.keys';
  static const String _kPrompts = 'engine.prompts';
  static const String _kFollow = 'ui.followSystem';
  static const String _kRailW = 'layout.railW';
  static const String _kSideW = 'layout.sideW';

  static Future<SettingsStore> open() async =>
      SettingsStore(await SharedPreferences.getInstance());

  JoSettings load() {
    return JoSettings(
      isDark: _prefs.getBool(_kDark) ?? true,
      followSystem: _prefs.getBool(_kFollow) ?? false,
      bodySize: _prefs.getDouble(_kBodySize) ?? 16,
      serifBody: _prefs.getBool(_kSerif) ?? true,
    );
  }

  Future<void> save(JoSettings s) async {
    await _prefs.setBool(_kDark, s.isDark);
    await _prefs.setBool(_kFollow, s.followSystem);
    await _prefs.setDouble(_kBodySize, s.bodySize);
    await _prefs.setBool(_kSerif, s.serifBody);
  }

  /// 两侧栏的宽度（拖动条拖出来的）。没存过就是 null，由界面用默认值。
  ///
  /// 存的是**人想要的宽度**：窗口变小画的时候再收一道，拉回去能恢复。
  double? loadRailW() => _prefs.getDouble(_kRailW);

  double? loadSideW() => _prefs.getDouble(_kSideW);

  Future<void> saveWidths({
    required double railW,
    required double sideW,
  }) async {
    await _prefs.setDouble(_kRailW, railW);
    await _prefs.setDouble(_kSideW, sideW);
  }

  /// 服务商列表。逐条解析，坏条跳过。
  LoadResult<List<Provider>> loadProviders() {
    final String? raw = _prefs.getString(_kProviders);
    if (raw == null || raw.isEmpty) {
      return const LoadResult<List<Provider>>(value: <Provider>[]);
    }
    Object? j;
    try {
      j = jsonDecode(raw);
    } catch (_) {
      // 整份不是 JSON —— 读不出来就是读不出来，如实报。
      return const LoadResult<List<Provider>>(
        value: <Provider>[],
        broken: true,
      );
    }
    if (j is! List) {
      return const LoadResult<List<Provider>>(
        value: <Provider>[],
        broken: true,
      );
    }
    final List<Provider> out = <Provider>[];
    int bad = 0;
    for (final Object? e in j) {
      if (e is! Map) {
        bad++;
        continue;
      }
      try {
        out.add(Provider.fromJson(e.cast<String, Object?>()));
      } catch (_) {
        // 这一条坏了，只跳过这一条，**不连累其它条**。
        bad++;
      }
    }
    return LoadResult<List<Provider>>(value: out, unreadable: bad);
  }

  /// 全局模型默认（总默认 + 每种步骤的全局默认）。存盘，重启还在。
  LoadResult<ModelPlan> loadGlobalPlan() {
    final String? raw = _prefs.getString(_kGlobalPlan);
    if (raw == null || raw.isEmpty) {
      return const LoadResult<ModelPlan>(value: ModelPlan());
    }
    Object? j;
    try {
      j = jsonDecode(raw);
    } catch (_) {
      return const LoadResult<ModelPlan>(value: ModelPlan(), broken: true);
    }
    if (j is! Map) {
      return const LoadResult<ModelPlan>(value: ModelPlan(), broken: true);
    }
    try {
      return LoadResult<ModelPlan>(
        value: ModelPlan.fromJson(j.cast<String, Object?>()),
      );
    } catch (_) {
      return const LoadResult<ModelPlan>(value: ModelPlan(), broken: true);
    }
  }

  /// 快捷键。缺的用默认值补上。
  Map<String, String> loadKeys() {
    final Map<String, String> out = joDefaultKeys();
    final String? raw = _prefs.getString(_kKeys);
    if (raw == null || raw.isEmpty) return out;
    try {
      final Object? j = jsonDecode(raw);
      if (j is Map) {
        j.forEach((Object? k, Object? v) {
          final String key = '$k';
          if (out.containsKey(key) && v is String) out[key] = v;
        });
      }
    } catch (_) {
      // 读不出来就用默认，界面那边会照实说
    }
    return out;
  }

  Future<void> saveKeys(Map<String, String> keys) async {
    await _prefs.setString(_kKeys, jsonEncode(keys));
  }

  /// 引擎的提示词（每一步一份）。
  ///
  /// **缺的用默认值补上** —— 设成空串不算“没设”：空串是用户主动清空的，
  /// 那意味着他不想给这一步任何额外说明。只有**没这个键**才回默认。
  Map<String, String> loadPrompts() {
    final Map<String, String> out = <String, String>{
      for (final String id in _promptIds) id: kDefaultPromptOf(id),
    };
    final String? raw = _prefs.getString(_kPrompts);
    if (raw == null || raw.isEmpty) return out;
    try {
      final Object? j = jsonDecode(raw);
      if (j is Map) {
        j.forEach((Object? k, Object? v) {
          final String key = '$k';
          if (out.containsKey(key) && v is String) out[key] = v;
        });
      }
    } catch (_) {
      // 读不出来就用默认，界面那边会照实说。
    }
    return out;
  }

  Future<void> savePrompts(Map<String, String> prompts) async {
    await _prefs.setString(_kPrompts, jsonEncode(prompts));
  }

  static final List<String> _promptIds = kSteps
      .map((StepKind s) => s.id)
      .toList();

  Future<void> saveGlobalPlan(ModelPlan plan) async {
    await _prefs.setString(_kGlobalPlan, jsonEncode(plan.toJson()));
  }

  /// 每个世界的模型配置（世界默认 + 逐步骤）。逐条解析，坏条跳过。
  ///
  /// 不存这里的话，选完模型一重启就没了 —— 发言框又会写回“未选择”。
  LoadResult<Map<String, ModelPlan>> loadWorldPlans() {
    const LoadResult<Map<String, ModelPlan>> empty =
        LoadResult<Map<String, ModelPlan>>(value: <String, ModelPlan>{});
    final String? raw = _prefs.getString(_kWorldPlans);
    if (raw == null || raw.isEmpty) return empty;
    Object? j;
    try {
      j = jsonDecode(raw);
    } catch (_) {
      return const LoadResult<Map<String, ModelPlan>>(
        value: <String, ModelPlan>{},
        broken: true,
      );
    }
    if (j is! Map) {
      return const LoadResult<Map<String, ModelPlan>>(
        value: <String, ModelPlan>{},
        broken: true,
      );
    }
    final Map<String, ModelPlan> out = <String, ModelPlan>{};
    int bad = 0;
    for (final MapEntry<Object?, Object?> e in j.entries) {
      if (e.value is! Map) {
        bad++;
        continue;
      }
      try {
        out['${e.key}'] = ModelPlan.fromJson(
          (e.value! as Map).cast<String, Object?>(),
        );
      } catch (_) {
        bad++;
      }
    }
    return LoadResult<Map<String, ModelPlan>>(value: out, unreadable: bad);
  }

  Future<void> saveWorldPlans(Map<String, ModelPlan> plans) async {
    await _prefs.setString(
      _kWorldPlans,
      jsonEncode(<String, Object?>{
        for (final MapEntry<String, ModelPlan> e in plans.entries)
          e.key: e.value.toJson(),
      }),
    );
  }

  Future<void> saveProviders(List<Provider> list) async {
    await _prefs.setString(
      _kProviders,
      jsonEncode(list.map((Provider p) => p.toJson()).toList()),
    );
  }
}
