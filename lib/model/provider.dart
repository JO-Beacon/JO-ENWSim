// 模型服务商：协议 / 服务商 / 模型。

/// 接口的“形状”：鉴权方式与请求体按这个走。
///
/// 同一个厂商可能同时提供多种形状，例如 DeepSeek 就同时有
/// OpenAI 格式与 Anthropic 格式两个端点。
enum Wire { openai, anthropic, google }

/// 接口协议。
enum Protocol {
  openai('OpenAI', 'https://api.openai.com/v1', '/chat/completions',
      Wire.openai),
  google('Google', 'https://generativelanguage.googleapis.com/v1beta',
      '/models', Wire.google),
  claude('Claude', 'https://api.anthropic.com/v1', '/messages', Wire.anthropic),
  deepseek('DeepSeek', 'https://api.deepseek.com', '/chat/completions',
      Wire.openai),
  deepseekAnthropic('DeepSeek · Anthropic 格式',
      'https://api.deepseek.com/anthropic', '/messages', Wire.anthropic);

  const Protocol(this.label, this.baseUrl, this.apiPath, this.wire);

  final String label;

  /// 协议默认接口地址
  final String baseUrl;

  /// 协议默认接口路径
  final String apiPath;

  /// 请求体与鉴权按哪种形状走
  final Wire wire;

  /// 是不是 DeepSeek 自家的规矩（思考模式、缓存计费、402 余额不足等）。
  bool get isDeepSeek => this == deepseek || this == deepseekAnthropic;

  static Protocol byName(String s) => Protocol.values.firstWhere(
        (Protocol p) => p.name == s,
        orElse: () => Protocol.openai,
      );
}

/// 思考模式。
///
/// [auto] = 不传这个参数，由服务端决定。DeepSeek 目前默认是开启。
enum ThinkingMode {
  auto('跟随服务端'),
  enabled('开启'),
  disabled('关闭');

  const ThinkingMode(this.label);

  final String label;

  static ThinkingMode byName(String s) => ThinkingMode.values.firstWhere(
        (ThinkingMode m) => m.name == s,
        orElse: () => ThinkingMode.auto,
      );
}

/// 思考投入程度。
///
/// 取值只取官方文档里 “Thinking Effort Control” 明写的三个。
/// 文档另外列过 minimal / medium / xhigh / ultra，那些只是**别名**
/// （分别映射到 low / high / high / max），没有任何额外效果，故不列出。
enum ReasoningEffort {
  auto('跟随服务端'),
  low('low'),
  high('high'),
  max('max');

  const ReasoningEffort(this.label);

  final String label;

  /// 发给接口的值；跟随 = null（不传）。
  String? get wire => this == auto ? null : name;

  static ReasoningEffort byName(String s) =>
      ReasoningEffort.values.firstWhere(
        (ReasoningEffort e) => e.name == s,
        orElse: () => ReasoningEffort.auto,
      );
}

/// DeepSeek 内置模型。选了 DeepSeek 预设就直接有，不用再点“获取”。
const List<ModelRef> kDeepSeekModels = <ModelRef>[
  ModelRef(id: 'deepseek-flash', group: 'DeepSeek'),
  ModelRef(id: 'deepseek-v4-pro', group: 'DeepSeek'),
];

/// 一个模型。
///
/// 下面这几个是**模型级**设置，不是服务商级的：同一个服务商下面，
/// 不同模型的能力与默认档位就不一样。
class ModelRef {
  const ModelRef({
    required this.id,
    this.name = '',
    this.group = '',
    this.enabled = true,
    this.thinking = ThinkingMode.auto,
    this.effort = ReasoningEffort.auto,
    this.maxTokens = '',
    this.jsonOutput = false,
  });

  /// 发给接口的模型 id
  final String id;

  /// 显示名（空 = 用 id）
  final String name;

  /// 模型分组（空 = 归到“默认”）
  final String group;

  final bool enabled;

  /// 思考模式
  final ThinkingMode thinking;

  /// 思考投入
  final ReasoningEffort effort;

  /// 最大输出 tokens。空 = 不传，用服务端默认。
  final String maxTokens;

  /// 是否请求 JSON 输出
  final bool jsonOutput;

  String get display => name.trim().isEmpty ? id : name;
  String get groupName => group.trim().isEmpty ? '默认' : group;

  ModelRef copyWith({
    String? id,
    String? name,
    String? group,
    bool? enabled,
    ThinkingMode? thinking,
    ReasoningEffort? effort,
    String? maxTokens,
    bool? jsonOutput,
  }) =>
      ModelRef(
        id: id ?? this.id,
        name: name ?? this.name,
        group: group ?? this.group,
        enabled: enabled ?? this.enabled,
        thinking: thinking ?? this.thinking,
        effort: effort ?? this.effort,
        maxTokens: maxTokens ?? this.maxTokens,
        jsonOutput: jsonOutput ?? this.jsonOutput,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'group': group,
        'enabled': enabled,
        'thinking': thinking.name,
        'effort': effort.name,
        'maxTokens': maxTokens,
        'jsonOutput': jsonOutput,
      };

  static ModelRef fromJson(Map<String, Object?> j) => ModelRef(
        id: '${j['id'] ?? ''}',
        name: '${j['name'] ?? ''}',
        group: '${j['group'] ?? ''}',
        enabled: j['enabled'] != false,
        thinking: ThinkingMode.byName('${j['thinking'] ?? ''}'),
        effort: ReasoningEffort.byName('${j['effort'] ?? ''}'),
        maxTokens: '${j['maxTokens'] ?? ''}',
        jsonOutput: j['jsonOutput'] == true,
      );
}

/// 自定义服务商的四种起手形状。
///
/// 预设来的服务商**没有**这个标记：端点对它们是死的事实，不用用户填。
enum CustomShape {
  openaiChat('OpenAI 兼容 · chat/completions', Protocol.openai, false),
  openaiResponses('OpenAI 兼容 · Responses API', Protocol.openai, true),
  google('Google 兼容', Protocol.google, false),
  anthropic('Anthropic 兼容', Protocol.claude, false);

  const CustomShape(this.label, this.protocol, this.responses);

  final String label;
  final Protocol protocol;

  /// 是否走 Responses API
  final bool responses;
}

/// 一个服务商。
class Provider {
  const Provider({
    required this.id,
    required this.protocol,
    required this.name,
    this.group = '',
    this.enabled = true,
    this.apiKey = '',
    this.baseUrl = '',
    this.apiPath = '',
    this.useResponsesApi = false,
    this.models = const <ModelRef>[],
    this.custom,
  });

  final String id;
  final Protocol protocol;
  final String name;

  /// 服务商分组（左栏可折叠的组）
  final String group;

  final bool enabled;
  final String apiKey;
  final String baseUrl;
  final String apiPath;

  /// 只有 OpenAI 协议用得上
  final bool useResponsesApi;

  final List<ModelRef> models;

  /// 自定义起手形状。null = 从预设来的（端点不可改）。
  final CustomShape? custom;

  /// 完整接口地址（展示用）。
  String get endpoint {
    final String base =
        (baseUrl.trim().isEmpty ? protocol.baseUrl : baseUrl.trim())
            .replaceAll(RegExp(r'/+$'), '');
    final String path =
        apiPath.trim().isEmpty ? protocol.apiPath : apiPath.trim();
    return '$base$path';
  }

  String get groupName => group.trim().isEmpty ? '未分组' : group;

  Provider copyWith({
    Protocol? protocol,
    String? name,
    String? group,
    bool? enabled,
    String? apiKey,
    String? baseUrl,
    String? apiPath,
    bool? useResponsesApi,
    List<ModelRef>? models,
    CustomShape? custom,
  }) =>
      Provider(
        id: id,
        protocol: protocol ?? this.protocol,
        name: name ?? this.name,
        group: group ?? this.group,
        enabled: enabled ?? this.enabled,
        apiKey: apiKey ?? this.apiKey,
        baseUrl: baseUrl ?? this.baseUrl,
        apiPath: apiPath ?? this.apiPath,
        useResponsesApi: useResponsesApi ?? this.useResponsesApi,
        models: models ?? this.models,
        custom: custom ?? this.custom,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'protocol': protocol.name,
        'name': name,
        'group': group,
        'enabled': enabled,
        'apiKey': apiKey,
        'baseUrl': baseUrl,
        'apiPath': apiPath,
        'useResponsesApi': useResponsesApi,
        'models': models.map((ModelRef m) => m.toJson()).toList(),
        'custom': custom?.name,
      };

  static Provider fromJson(Map<String, Object?> j) {
    final Protocol protocol = Protocol.byName('${j['protocol'] ?? ''}');
    final List<dynamic> raw =
        (j['models'] as List<dynamic>?) ?? const <dynamic>[];
    return Provider(
      id: '${j['id'] ?? ''}',
      protocol: protocol,
      name: '${j['name'] ?? ''}',
      group: '${j['group'] ?? ''}',
      enabled: j['enabled'] != false,
      apiKey: '${j['apiKey'] ?? ''}',
      baseUrl: '${j['baseUrl'] ?? protocol.baseUrl}',
      apiPath: '${j['apiPath'] ?? protocol.apiPath}',
      useResponsesApi: j['useResponsesApi'] == true,
      models: raw
          .whereType<Map<String, dynamic>>()
          .map(Provider._model)
          .toList(),
      custom: Provider._custom('${j['custom'] ?? ''}'),
    );
  }

  static ModelRef _model(Map<String, dynamic> j) =>
      ModelRef.fromJson(j.cast<String, Object?>());

  static CustomShape? _custom(String s) {
    for (final CustomShape c in CustomShape.values) {
      if (c.name == s) return c;
    }
    return null;
  }
}

/// “添加服务商”里的预设。
class ProviderPreset {
  const ProviderPreset({
    required this.name,
    required this.protocol,
    required this.baseUrl,
    this.apiPath = '',
    this.models = const <ModelRef>[],
  });

  final String name;
  final Protocol protocol;
  final String baseUrl;
  final String apiPath;

  /// 预设自带的模型列表（空 = 让用户自己点“获取”）。
  final List<ModelRef> models;
}

const List<ProviderPreset> kProviderPresets = <ProviderPreset>[
  ProviderPreset(
    name: 'OpenAI',
    protocol: Protocol.openai,
    baseUrl: 'https://api.openai.com/v1',
  ),
  ProviderPreset(
    name: 'Gemini',
    protocol: Protocol.google,
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
  ),
  ProviderPreset(
    name: 'Claude',
    protocol: Protocol.claude,
    baseUrl: 'https://api.anthropic.com/v1',
  ),
  ProviderPreset(
    name: 'DeepSeek',
    protocol: Protocol.deepseek,
    baseUrl: 'https://api.deepseek.com',
    models: kDeepSeekModels,
  ),
  ProviderPreset(
    name: 'DeepSeek · Anthropic 格式',
    protocol: Protocol.deepseekAnthropic,
    baseUrl: 'https://api.deepseek.com/anthropic',
    models: kDeepSeekModels,
  ),
  ProviderPreset(
    name: '硅基流动',
    protocol: Protocol.openai,
    baseUrl: 'https://api.siliconflow.cn/v1',
  ),
  ProviderPreset(
    name: 'OpenRouter',
    protocol: Protocol.openai,
    baseUrl: 'https://openrouter.ai/api/v1',
  ),
  ProviderPreset(
    name: '阿里云千问',
    protocol: Protocol.openai,
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
  ),
  ProviderPreset(
    name: '智谱',
    protocol: Protocol.openai,
    baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
  ),
  ProviderPreset(
    name: 'Grok',
    protocol: Protocol.openai,
    baseUrl: 'https://api.x.ai/v1',
  ),
  ProviderPreset(
    name: '火山引擎',
    protocol: Protocol.openai,
    baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
  ),
  ProviderPreset(
    name: '月之暗面',
    protocol: Protocol.openai,
    baseUrl: 'https://api.moonshot.cn/v1',
  ),
  ProviderPreset(
    name: 'Vercel',
    protocol: Protocol.openai,
    baseUrl: 'https://ai-gateway.vercel.sh/v1',
  ),
];

/// 新服务商的 id。
String newProviderId() => 'p${DateTime.now().microsecondsSinceEpoch}';
