/// 内置 TTS 引擎支持的两个模型。
///
/// 名字固定：MeloTTS 中文负责普通话；Kokoro 多语言负责其他语言。
/// 模型文件不随安装包，按需下载到应用数据目录的 `models/<folder>`；
/// 下载地址与校验值在 `downloadable_models.dart` 里。
enum BuiltinModel {
  melo('MeloTTS 中文', 'melo'),
  kokoro('Kokoro 多语言', 'kokoro');

  const BuiltinModel(this.label, this.folder);

  final String label;

  /// 模型目录名，也是可下载模型清单里的 id。
  final String folder;
}
