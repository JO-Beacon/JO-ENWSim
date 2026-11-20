// 内置引擎的模型是否已经下载到应用数据目录。
//
// 模型不再随安装包；来源是“可下载模型”清单，安装逻辑见
// model_downloader.dart。这里只做目录检查，不触发下载。

import 'dart:io';

import 'builtin_models.dart';

/// `root` 是模型根目录（应用数据目录下的 models/）。
/// 有 `models/<folder>/model.onnx` 就认为装好了；文件完整性由下载器负责。
bool isBuiltinModelInstalled(BuiltinModel model, String root) {
  final String base = root.trim();
  if (base.isEmpty) return false;
  return File('$base/${model.folder}/model.onnx').existsSync();
}

String builtinModelMissingMessage(BuiltinModel model) =>
    '尚未下载 ${model.label}：请前往“设置 → TTS 服务 → 模型 → 可下载模型”下载后使用。';
