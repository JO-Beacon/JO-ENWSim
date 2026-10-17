// 模型服务商：协议 / 服务商 / 模型。

/// 接口的“形状”：鉴权方式与请求体按这个走。
///
/// 同一个厂商可能同时提供多种形状，例如 DeepSeek 就同时有
/// OpenAI 格式与 Anthropic 格式两个端点。
enum Wire { openai, anthropic, google }

/// 接口协议。
enum Protocol {
  openai(
    'OpenAI',
    'https://api.openai.com/v1',
    '/chat/completions',
    Wire.openai,
    '/models',
  ),
  // Google 的列表端点形状不一样（带 ?key=），但路径仍是 /models。
  google(
    'Google',
    'https://generativelanguage.googleapis.com/v1beta',
    '/models/{model}:generateContent',
    Wire.google,
    '/models',
  ),
  // Anthropic **没有公开的模型列表端点**，所以这里是 null。
  claude(
    'Claude',
    'https://api.anthropic.com/v1',
    '/messages',
    Wire.anthropic,
    null,
  ),
  deepseek(
    'DeepSeek',
    'https://api.deepseek.com',
    '/chat/completions',
    Wire.openai,
    '/models',
  ),
  // DeepSeek 的 Anthropic 格式**不能直接把 /models 接在 /anthropic 后面**；
  // 正确做法是**剥掉 /anthropic、去主域名**拼 /models —— 也就是 provider_api
  // 里的 _accountBase 干的事。端点还是主域名那个列表接口。
  deepseekAnthropic(
    'DeepSeek · Anthropic 格式',
    'https://api.deepseek.com/anthropic',
    '/messages',
    Wire.anthropic,
    '/models',
  ),
  // 三种“兼容”只保证形状像。列模型这条按 OpenAI 的**约定**试一下是可以的，
  // 但那是约定、不是承诺——拉不到的时候要说清是“不确知”，别说人家坏了。
  openaiCompatible('OpenAI 兼容', '', '', Wire.openai, '/models'),
  anthropicCompatible('Anthropic 兼容', '', '', Wire.anthropic, null),
  googleCompatible('Google 兼容', '', '', Wire.google, null);

  const Protocol(
    this.label,
    this.baseUrl,
    this.apiPath,
    this.wire,
    this.listPath,
  );

  final String label;

  /// 协议默认接口地址
  final String baseUrl;

  /// 协议默认接口路径
  final String apiPath;

  /// 请求体与鉴权按哪种形状走
  final Wire wire;

  /// 模型列表接口的路径。**null = 这个协议没有列表接口**（别硬拼）。
  final String? listPath;

  /// 是不是 DeepSeek 自家的规矩（思考模式、缓存计费、402 余额不足等）。
  bool get isDeepSeek => this == deepseek || this == deepseekAnthropic;

  /// 是不是**真 OpenAI**（不是“OpenAI 兼容”）。
  bool get isOpenAi => this == openai;

  /// 我们**知不知道这个协议的规矩**。
  bool get rulesKnown =>
      this != openaiCompatible &&
      this != anthropicCompatible &&
      this != googleCompatible;

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

/// 一个协议下“思考”长什么样、有哪些可选值。
class ThinkingSpec {
  const ThinkingSpec({
    this.hasMode = false,
    this.levels = const <String>[],
    this.hasBudget = false,
  });

  /// 有没有开关（thinking: {type}）。
  final bool hasMode;

  /// 等级可选项。空 = 这个协议没有等级这个东西。
  final List<String> levels;

  /// 有没有 token 预算。
  final bool hasBudget;

  /// 一样都没有 = 我们不知道这个协议的规矩。
  bool get isEmpty => !hasMode && levels.isEmpty && !hasBudget;
}

/// 各家“思考”的规矩。**全部来自官方资料，不是推的**。
///
/// 这份是**程序自己的知识**，不是给用户看的设置项——
/// 界面上不摆“思考”（那是「选择」，归角色那层，进聊天栏）。
/// 以后引擎发请求时按这个决定该发哪个字段。
///
/// - OpenAI：`reasoning_effort` = none/minimal/low/medium/high/xhigh/max
///   （`openapi.yaml` 的 `components/schemas/ReasoningEffort`）
/// - DeepSeek：`thinking{type}` + `reasoning_effort` = low/high/max
///   （官方文档 “Thinking Effort Control” 明写的三个）
/// - Anthropic：`thinking{type: enabled|disabled, budget_tokens, display?}`
///   （`anthropic-sdk-python` 的 types/thinking_config_*.py）
/// - Google：`generationConfig.thinkingConfig` 里**两个字段并存**，
///   用哪个**看模型代次**（不是看 SDK、也不是看厂商）：
///     · **Gemini 2.5 系列** → `thinkingBudget`（数字；0 = 关闭，-1 = 自动）
///     · **Gemini 3 起**     → `thinkingLevel` = MINIMAL/LOW/MEDIUM/HIGH
///   （js-genai 的 `ThinkingConfig` 两个都有；python-genai 把
///   `thinking_budget` 标成“将不再支持、设了会报用户错误”——
///   那是它只盯着新代次，不是两家打架。这条是用户核实的。）
///   所以这里**两个都摆**：具体用哪个由你按自己的模型代次选。
ThinkingSpec thinkingSpecOf(Protocol p) {
  if (p.isDeepSeek) {
    return const ThinkingSpec(
      hasMode: true,
      levels: <String>['low', 'high', 'max'],
    );
  }
  if (p.isOpenAi) {
    return const ThinkingSpec(
      levels: <String>[
        'none',
        'minimal',
        'low',
        'medium',
        'high',
        'xhigh',
        'max',
      ],
    );
  }
  if (p == Protocol.claude) {
    // Anthropic 有开关和预算，**没有等级**。
    return const ThinkingSpec(hasMode: true, hasBudget: true);
  }
  if (p == Protocol.google) {
    // 等级（3 起）与预算（2.5 系列）**两个都摆**，
    // 用哪个看模型代次——这个只有用户自己知道。
    return const ThinkingSpec(
      levels: <String>['MINIMAL', 'LOW', 'MEDIUM', 'HIGH'],
      hasBudget: true,
    );
  }
  // 兼容 / 自定义：规矩未知，什么都不摆。
  return const ThinkingSpec();
}

/// DeepSeek 预设模型。选了 DeepSeek 预设就直接有，不用再点“获取”。
///
/// 能力声明抄自 DeepSeek 官方文档的模型与价格表：
/// 上下文 1M、最大输出 384K、两者都支持工具调用与思考模式、
/// **视觉只有 flash 支持**（v4-pro 那栏写的是 Not supported）。
const List<ModelRef> kDeepSeekModels = <ModelRef>[
  ModelRef(
    id: 'deepseek-flash',
    group: 'DeepSeek',
    caps: ModelCaps(
      contextWindow: '1M',
      maxOutput: '384K',
      inputModalities: <String>['文本', '图片'],
      outputModalities: <String>['文本'],
      tools: true,
      reasoning: true,
      vision: true,
      stream: true,
    ),
  ),
  ModelRef(
    id: 'deepseek-v4-pro',
    group: 'DeepSeek',
    caps: ModelCaps(
      contextWindow: '1M',
      maxOutput: '384K',
      inputModalities: <String>['文本'],
      outputModalities: <String>['文本'],
      tools: true,
      reasoning: true,
      vision: false,
      stream: true,
    ),
  ),
];

/// 模型的能力声明。**只有预设模型带这个。**
///
/// 用户自己加的模型我们不知道它是什么，所以留空（null），界面也就不显示。
/// 全是客观事实，值抄自厂商官方资料，出处写在各自的地方。
class ModelCaps {
  const ModelCaps({
    this.contextWindow = '',
    this.maxOutput = '',
    this.inputModalities = const <String>[],
    this.outputModalities = const <String>[],
    this.tools = false,
    this.reasoning = false,
    this.vision = false,
    this.stream,
  });

  /// 上下文窗口
  final String contextWindow;

  /// 最大输出上限
  final String maxOutput;

  /// 能收什么（文本 / 图片 / 音频）
  final List<String> inputModalities;

  /// 能出什么
  final List<String> outputModalities;

  final bool tools;
  final bool reasoning;
  final bool vision;

  /// 支不支持流式。
  ///
  /// **三态，不是 bool**：true 支持 / false 不支持 / **null 不知道**。
  /// 用户自加的模型没声明能力 —— 那是“不知道”，不是“不支持”。
  /// （tools / reasoning / vision 现在还是 bool，有同样的毛病，以后一起改。）
  final bool? stream;

  Map<String, Object?> toJson() => <String, Object?>{
    'contextWindow': contextWindow,
    'maxOutput': maxOutput,
    'inputModalities': inputModalities,
    'outputModalities': outputModalities,
    'tools': tools,
    'reasoning': reasoning,
    'vision': vision,
    'stream': stream,
  };

  static ModelCaps fromJson(Map<String, Object?> j) => ModelCaps(
    contextWindow: '${j['contextWindow'] ?? ''}',
    maxOutput: '${j['maxOutput'] ?? ''}',
    inputModalities: _strList(j['inputModalities']),
    outputModalities: _strList(j['outputModalities']),
    tools: j['tools'] == true,
    reasoning: j['reasoning'] == true,
    vision: j['vision'] == true,
    // 缺就是 null（不知道）；写了但不是布尔也当不知道，
    // 因为这里存的是“能不能”，没有可信的默认。
    stream: j['stream'] is bool ? j['stream'] as bool : null,
  );

  static List<String> _strList(Object? v) =>
      v is List ? v.whereType<String>().toList() : const <String>[];
}

/// 一个模型条目。
///
/// **只有能力声明，没有选择。**
/// 采样策略、思考档位这类「选择」不放在这儿（它们是跟着角色的，进聊天栏）。
class ModelRef {
  const ModelRef({
    required this.id,
    this.name = '',
    this.group = '',
    this.enabled = true,
    this.caps,
  });

  /// 发给接口的模型 id
  final String id;

  /// 显示名（空 = 用 id）
  final String name;

  /// 模型分组（空 = 归到“默认”）
  final String group;

  final bool enabled;

  /// 能力声明。**只有预设模型有**；用户模型是 null。
  final ModelCaps? caps;

  String get display => name.trim().isEmpty ? id : name;
  String get groupName => group.trim().isEmpty ? '默认' : group;

  ModelRef copyWith({
    String? id,
    String? name,
    String? group,
    bool? enabled,
    ModelCaps? caps,
  }) => ModelRef(
    id: id ?? this.id,
    name: name ?? this.name,
    group: group ?? this.group,
    enabled: enabled ?? this.enabled,
    caps: caps ?? this.caps,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'group': group,
    'enabled': enabled,
    'caps': caps?.toJson(),
  };

  static ModelRef fromJson(Map<String, Object?> j) => ModelRef(
    id: '${j['id'] ?? ''}',
    name: '${j['name'] ?? ''}',
    group: '${j['group'] ?? ''}',
    enabled: j['enabled'] != false,
    caps: j['caps'] is Map
        ? ModelCaps.fromJson((j['caps'] as Map).cast<String, Object?>())
        : null,
  );
}

/// 自定义服务商的四种起手形状。
///
/// 预设来的服务商**没有**这个标记：端点对它们是死的事实，不用用户填。
enum CustomShape {
  openaiChat('OpenAI 兼容 · chat/completions', Protocol.openaiCompatible, false),
  openaiResponses('OpenAI 兼容 · Responses API', Protocol.openaiCompatible, true),
  google('Google 兼容', Protocol.googleCompatible, false),
  anthropic('Anthropic 兼容', Protocol.anthropicCompatible, false);

  const CustomShape(this.label, this.protocol, this.responses);

  final String label;
  final Protocol protocol;

  /// 是否走 Responses API
  final bool responses;
}

/// 服务的类型。三类服务共用同一套“服务 + 清单”的结构。
enum ServiceKind {
  model('模型'),
  search('搜索'),
  voice('语音');

  const ServiceKind(this.label);

  final String label;

  static ServiceKind byName(String s) => ServiceKind.values.firstWhere(
    (ServiceKind k) => k.name == s,
    orElse: () => ServiceKind.model,
  );
}

/// 一个服务。
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
    this.kind = ServiceKind.model,
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

  /// 这是哪一类服务。
  final ServiceKind kind;

  /// 最大输出该发哪个参数名。
  ///
  /// OpenAI 现在推荐 `max_completion_tokens`，老名字 `max_tokens` 已过时；
  /// 别家没这个说法，一律用 `max_tokens`。
  String get maxTokensParam =>
      protocol.isOpenAi ? 'max_completion_tokens' : 'max_tokens';

  /// 完整接口地址（展示用）。
  String get endpoint {
    final String base =
        (baseUrl.trim().isEmpty ? protocol.baseUrl : baseUrl.trim()).replaceAll(
          RegExp(r'/+$'),
          '',
        );
    final String path = apiPath.trim().isEmpty
        ? protocol.apiPath
        : apiPath.trim();
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
    ServiceKind? kind,
  }) => Provider(
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
    kind: kind ?? this.kind,
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
    'kind': kind.name,
  };

  static Provider fromJson(Map<String, Object?> j) {
    final Protocol protocol = Provider._protocolOf(j['protocol']);
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
      kind: Provider._kindOf(j['kind']),
    );
  }

  /// 缺 = 默认；在、但认不出来 = 抛（不静默降级成「模型」/「OpenAI」）。
  static ServiceKind _kindOf(Object? v) {
    if (v == null) return ServiceKind.model;
    if (v is! String) throw const FormatException('kind 不是字符串');
    for (final ServiceKind k in ServiceKind.values) {
      if (k.name == v) return k;
    }
    throw FormatException('认不出的 kind：$v');
  }

  static Protocol _protocolOf(Object? v) {
    if (v == null) return Protocol.openai;
    if (v is! String) throw const FormatException('protocol 不是字符串');
    for (final Protocol p in Protocol.values) {
      if (p.name == v) return p;
    }
    throw FormatException('认不出的 protocol：$v');
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
    protocol: Protocol.openaiCompatible,
    baseUrl: 'https://api.siliconflow.cn/v1',
  ),
  ProviderPreset(
    name: 'OpenRouter',
    protocol: Protocol.openaiCompatible,
    baseUrl: 'https://openrouter.ai/api/v1',
  ),
  ProviderPreset(
    name: '阿里云千问',
    protocol: Protocol.openaiCompatible,
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
  ),
  ProviderPreset(
    name: '智谱',
    protocol: Protocol.openaiCompatible,
    baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
  ),
  ProviderPreset(
    name: 'Grok',
    protocol: Protocol.openaiCompatible,
    baseUrl: 'https://api.x.ai/v1',
  ),
  ProviderPreset(
    name: '火山引擎',
    protocol: Protocol.openaiCompatible,
    baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
  ),
  ProviderPreset(
    name: '月之暗面',
    protocol: Protocol.openaiCompatible,
    baseUrl: 'https://api.moonshot.cn/v1',
  ),
  ProviderPreset(
    name: 'Vercel',
    protocol: Protocol.openaiCompatible,
    baseUrl: 'https://ai-gateway.vercel.sh/v1',
  ),
];

/// 搜索服务的预设。
///
/// 这份厂商列表只是起手方便，**不是定论**——名字、地址都可以随手改。
/// 接口形状暂时借用 OpenAI 那一套（只影响鉴权头与请求体形状；
/// 这两类服务现在还不真发请求）。
const List<ProviderPreset> kSearchPresets = <ProviderPreset>[
  ProviderPreset(
    name: 'Tavily',
    protocol: Protocol.openaiCompatible,
    baseUrl: 'https://api.tavily.com',
  ),
  ProviderPreset(
    name: 'Exa',
    protocol: Protocol.openaiCompatible,
    baseUrl: 'https://api.exa.ai',
  ),
  ProviderPreset(
    name: 'Brave Search',
    protocol: Protocol.openaiCompatible,
    baseUrl: 'https://api.search.brave.com/res/v1',
  ),
  ProviderPreset(
    name: 'Serper',
    protocol: Protocol.openaiCompatible,
    baseUrl: 'https://google.serper.dev',
  ),
  ProviderPreset(
    name: '博查',
    protocol: Protocol.openaiCompatible,
    baseUrl: 'https://api.bochaai.com/v1',
  ),
  ProviderPreset(
    name: 'SearXNG（自建）',
    protocol: Protocol.openaiCompatible,
    baseUrl: '',
  ),
];

/// 语音服务的预设。同样是起手用的，随便改。
const List<ProviderPreset> kVoicePresets = <ProviderPreset>[
  ProviderPreset(
    name: 'OpenAI 语音',
    protocol: Protocol.openaiCompatible,
    baseUrl: 'https://api.openai.com/v1',
  ),
  ProviderPreset(
    name: 'ElevenLabs',
    protocol: Protocol.openaiCompatible,
    baseUrl: 'https://api.elevenlabs.io/v1',
  ),
  ProviderPreset(
    name: 'MiniMax 语音',
    protocol: Protocol.openaiCompatible,
    baseUrl: 'https://api.minimax.chat/v1',
  ),
  ProviderPreset(
    name: '火山引擎语音',
    protocol: Protocol.openaiCompatible,
    baseUrl: 'https://openspeech.bytedance.com/api/v1',
  ),
  ProviderPreset(
    name: 'Azure Speech',
    protocol: Protocol.openaiCompatible,
    baseUrl: '',
  ),
  ProviderPreset(
    name: '讯飞语音',
    protocol: Protocol.openaiCompatible,
    baseUrl: '',
  ),
];

/// 新服务商的 id。
String newProviderId() => 'p${DateTime.now().microsecondsSinceEpoch}';
