// 可下载的 TTS 模型清单。
//
// 只放能从 sherpa-onnx 官方 release 直接拿到、并且许可清楚的模型：
//   · Melo：MIT；Kokoro：Apache-2.0；两者内置引擎可直接合成
//   · icefall 模型：Apache-2.0（AISHELL-3 / LJSpeech）
//   · 归档里必须带 model.onnx、tokens.txt
//
// 地址是官方 GitHub release；下载后按 SHA-256 校验，不通过不安装。

enum DownloadableTtsKind { vits, kokoro }

class DownloadableTtsModel {
  const DownloadableTtsModel({
    required this.id,
    required this.label,
    required this.language,
    required this.description,
    required this.license,
    required this.licenseUrl,
    required this.url,
    required this.sha256,
    required this.archiveBytes,
    required this.kind,
    this.speakerCount = 1,
  });

  final String id;
  final String label;
  final String language;
  final String description;
  final String license;
  final String licenseUrl;
  final String url;
  final String sha256;
  final int archiveBytes;
  final DownloadableTtsKind kind;
  final int speakerCount;
}

const List<DownloadableTtsModel> kDownloadableTtsModels = <DownloadableTtsModel>[
  // 前两个是内置引擎（lib/tts/builtin_tts.dart）能直接用的模型；
  // id 必须与 BuiltinModel.folder 一致，安装后落在 models/<id>。
  DownloadableTtsModel(
    id: 'melo',
    label: 'MeloTTS 中文',
    language: '中文',
    description: '普通话女声，单说话人；内置引擎的默认模型。',
    license: 'MIT',
    licenseUrl: 'https://github.com/myshell-ai/MeloTTS',
    url:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-melo-tts-zh_en.tar.bz2',
    sha256: 'e58351ed7149f290a54534538badd4077cdbe6fddc964b24d0bee870415d1514',
    archiveBytes: 167006755,
    kind: DownloadableTtsKind.vits,
  ),
  DownloadableTtsModel(
    id: 'kokoro',
    label: 'Kokoro 多语言',
    language: '中文 / 英文',
    description: '103 个声线，中英多语言；适合多角色。',
    license: 'Apache-2.0',
    licenseUrl: 'https://huggingface.co/hexgrad/Kokoro-82M',
    url:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-multi-lang-v1_1.tar.bz2',
    sha256: 'b78e1ac42b852e839cceaafbe88f66806bf5860992d1d7b9a3f2ad1198427aed',
    archiveBytes: 364855331,
    kind: DownloadableTtsKind.kokoro,
    speakerCount: 103,
  ),
  DownloadableTtsModel(
    id: 'icefall-zh-aishell3',
    label: 'AISHELL-3 中文',
    language: '中文',
    description: '174 个说话人，普通话；适合中文旁白和多角色。',
    license: 'Apache-2.0',
    licenseUrl: 'https://www.openslr.org/93/',
    url:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-icefall-zh-aishell3.tar.bz2',
    sha256: 'ab468db3a3308cdd861495e0db2f25d79418a0c00639f74944c7cdf5dd8c6ec1',
    archiveBytes: 31559701,
    kind: DownloadableTtsKind.vits,
    speakerCount: 174,
  ),
  DownloadableTtsModel(
    id: 'icefall-en-ljspeech-medium',
    label: 'LJSpeech 英文（标准）',
    language: '英文',
    description: 'LJSpeech 单说话人女声；英文旁白的常用基线模型。',
    license: 'Public Domain',
    licenseUrl: 'https://keithito.com/LJ-Speech-Dataset/',
    url:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-icefall-en_US-ljspeech-medium.tar.bz2',
    sha256: '93efae74fe0c72199c51b11ca7acb20b4966c2dc8b728109910266784f39f720',
    archiveBytes: 73546070,
    kind: DownloadableTtsKind.vits,
  ),
  DownloadableTtsModel(
    id: 'icefall-en-ljspeech-low',
    label: 'LJSpeech 英文（轻量）',
    language: '英文',
    description: '同上，低配版；模型更小，适合先试听。',
    license: 'Public Domain',
    licenseUrl: 'https://keithito.com/LJ-Speech-Dataset/',
    url:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-icefall-en_US-ljspeech-low.tar.bz2',
    sha256: 'e5ae18c97b566099a2a748f243d4d44ea7cd188acc34e3533a2adc2565c9f845',
    archiveBytes: 31746179,
    kind: DownloadableTtsKind.vits,
  ),
];
