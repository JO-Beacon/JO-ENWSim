// 已安装的 TTS 模型：应用数据目录下的 models/<id>。
//
// 只存“装在哪、是什么类型、多少个说话人”；模型文件本身不放设置里。

import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'downloadable_models.dart';

class InstalledTtsModel {
  const InstalledTtsModel({
    required this.id,
    required this.label,
    required this.path,
    required this.kind,
    required this.speakerCount,
    required this.license,
  });

  final String id;
  final String label;
  final String path;
  final DownloadableTtsKind kind;
  final int speakerCount;
  final String license;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'label': label,
    'path': path,
    'kind': kind.name,
    'speakerCount': speakerCount,
    'license': license,
  };

  static InstalledTtsModel? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final String id = '${raw['id'] ?? ''}'.trim();
    final String path = '${raw['path'] ?? ''}'.trim();
    if (id.isEmpty || path.isEmpty) return null;
    DownloadableTtsKind kind = DownloadableTtsKind.vits;
    final String kindName = '${raw['kind'] ?? ''}';
    for (final DownloadableTtsKind k in DownloadableTtsKind.values) {
      if (k.name == kindName) kind = k;
    }
    return InstalledTtsModel(
      id: id,
      label: '${raw['label'] ?? id}',
      path: path,
      kind: kind,
      speakerCount: (raw['speakerCount'] as num?)?.toInt() ?? 1,
      license: '${raw['license'] ?? ''}',
    );
  }
}

class TtsModelStore {
  TtsModelStore._();

  static const String _key = 'tts.installedModels';

  static Future<List<InstalledTtsModel>> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_key);
    if (raw == null || raw.trim().isEmpty) return <InstalledTtsModel>[];
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return <InstalledTtsModel>[];
      final List<InstalledTtsModel> out = decoded
          .map(InstalledTtsModel.fromJson)
          .whereType<InstalledTtsModel>()
          .where((InstalledTtsModel m) => Directory(m.path).existsSync())
          .toList();
      return out;
    } catch (_) {
      return <InstalledTtsModel>[];
    }
  }

  static Future<void> save(List<InstalledTtsModel> models) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(models.map((InstalledTtsModel m) => m.toJson()).toList()),
    );
  }
}
