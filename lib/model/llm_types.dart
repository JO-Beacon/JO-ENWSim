// LLM 调用的共用类型：请求、消息、结果。
//
// **这里只放“向上交出什么”的约定**，不放“怎么跟某家说话”。
// 按 `AGENTS/服务商适配方针.md`：结果类型允许共用；请求体怎么拼、响应怎么解析、
// 鉴权头、错误码，一律沉到各家自己的文件（如 `llm_deepseek.dart`）。
//
// 已知欠账：`LlmRequest.toJson()` / `toAnthropicJson()` 现在还在这儿共用，
// 严格说属于“请求体怎么拼”，应该下沉到各家。暂时留着是因为
// MiMo 与 DeepSeek 都在用，拆它要连 MiMo 一起动，不放在第一步里做。

import 'dart:convert';

import 'provider.dart';

/// 一个工具声明。
///
/// 两类，**执行方不同**：
/// · [LlmToolKind.function] —— 客户端工具：模型发起调用，我们自己执行，
///   再把结果回传；
/// · [LlmToolKind.webSearch] / [LlmToolKind.readUrl] —— DeepSeek 的**服务端工具**：
///   服务端执行，客户端什么都不用做，结果随响应回来。
///
/// 两种工具在请求里都放在 `tools` 数组，但写法按协议不同，见两个 toXxxJson。
enum LlmToolKind { function, webSearch, readUrl }

class LlmTool {
  const LlmTool.function({
    required this.name,
    this.description = '',
    this.parameters = const <String, Object?>{},
  }) : kind = LlmToolKind.function;

  /// 联网搜索。就是这个名字，官方不接受改名。
  const LlmTool.webSearch()
    : kind = LlmToolKind.webSearch,
      name = 'deepseek_web_search',
      description = '',
      parameters = const <String, Object?>{};

  /// 阅读链接。同上。
  const LlmTool.readUrl()
    : kind = LlmToolKind.readUrl,
      name = 'deepseek_read_url',
      description = '',
      parameters = const <String, Object?>{};

  final LlmToolKind kind;
  final String name;
  final String description;

  /// function 的入参 JSON Schema；服务端工具没有这个。
  final Map<String, Object?> parameters;

  /// 服务端工具 = 不用我们执行。
  bool get isServerTool => kind != LlmToolKind.function;

  /// Chat Completions 形状（chat/completions、responses）。
  ///
  /// 服务端工具**不带 name** —— 官方 Chat Completions 的写法就是
  /// `{"type":"deepseek_web_search"}`。
  Map<String, Object?> toOpenAiJson() {
    if (isServerTool) return <String, Object?>{'type': name};
    return <String, Object?>{
      'type': 'function',
      'function': <String, Object?>{
        'name': name,
        'description': description,
        'parameters': parameters,
      },
    };
  }

  /// Responses 形状（`/responses`）。
  ///
  /// 跟 Chat Completions 有一处**容易写错**：function 工具的 `name` /
  /// `description` / `parameters` 在**工具对象顶层**，不包在 `function` 里。
  /// 服务端工具则同样只写 `type`。
  Map<String, Object?> toResponsesJson() {
    if (isServerTool) return <String, Object?>{'type': name};
    return <String, Object?>{
      'type': 'function',
      'name': name,
      'description': description,
      'parameters': parameters,
    };
  }

  /// Anthropic 形状（`/messages`）。
  ///
  /// 服务端工具**要带 name** —— 官方 Messages 的写法是
  /// `{"type":"deepseek_web_search","name":"deepseek_web_search"}`。
  /// 客户端工具反过来：**不传 type**（传了会被当成服务端工具解析）。
  Map<String, Object?> toAnthropicJson() {
    if (isServerTool) {
      return <String, Object?>{'type': name, 'name': name};
    }
    return <String, Object?>{
      'name': name,
      'description': description,
      'input_schema': parameters,
    };
  }
}

/// 模型发起的一次**客户端工具**调用。
///
/// 服务端工具（联网搜索、阅读链接）不产生这个，那些由服务端执行完直接给结果。
class LlmToolCall {
  const LlmToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  final String id;
  final String name;

  /// 调用参数。两家给的形式不一样（OpenAI 是 JSON 字符串，Anthropic 是对象），
  /// 这里统一成 **JSON 字符串**，调用方自己决定怎么解。
  final String arguments;
}

/// 一张随消息发出的图片。
class LlmImage {
  const LlmImage({required this.bytes, required this.mime, this.id = ''});

  final List<int> bytes;
  final String mime;

  /// 这张图对应的附件 id（能对上就说明可以按它缓存转述）。空 = 不知道来源。
  final String id;
}

/// 一条消息。DeepSeek 是 **Chat Completions 形状**：系统提示词在这边是
/// `role: system` 的一条消息，不是顶层参数。
class LlmMessage {
  const LlmMessage(this.role, this.content, {this.images = const <LlmImage>[]});

  final String role; // 'system' / 'user' / 'assistant'
  final String content;

  /// 图片只跟 user 消息走；文字为空时可以只发图。
  final List<LlmImage> images;

  Map<String, Object?> toJson() {
    if (images.isEmpty) {
      return <String, Object?>{'role': role, 'content': content};
    }
    return <String, Object?>{
      'role': role,
      'content': <Object?>[
        if (content.trim().isNotEmpty)
          <String, Object?>{'type': 'text', 'text': content},
        for (final LlmImage img in images)
          <String, Object?>{
            'type': 'image_url',
            'image_url': <String, Object?>{
              'url': 'data:${img.mime};base64,${base64Encode(img.bytes)}',
            },
          },
      ],
    };
  }

  List<Object?> toAnthropicContent() => <Object?>[
    if (content.trim().isNotEmpty)
      <String, Object?>{'type': 'text', 'text': content},
    for (final LlmImage img in images)
      <String, Object?>{
        'type': 'image',
        'source': <String, Object?>{
          'type': 'base64',
          'media_type': img.mime,
          'data': base64Encode(img.bytes),
        },
      },
  ];

  /// Responses 形状的消息内容。
  ///
  /// 纯文字直接给字符串；带图片才用内容块（`input_text` / `input_image`）。
  Object? toResponsesContent() {
    if (images.isEmpty) return content;
    return <Object?>[
      if (content.trim().isNotEmpty)
        <String, Object?>{'type': 'input_text', 'text': content},
      for (final LlmImage img in images)
        <String, Object?>{
          'type': 'input_image',
          'image_url': 'data:${img.mime};base64,${base64Encode(img.bytes)}',
        },
    ];
  }
}

/// 一次调用的输入。
///
/// 凡是“用户的选择”，为 null 就**不传**，让服务端用它自己的默认
/// —— 我们不在代码里写死档位。
class LlmRequest {
  const LlmRequest({
    required this.model,
    this.messages = const <LlmMessage>[],
    this.thinking,
    this.effort,
    this.budgetTokens,
    this.temperature,
    this.topP,
    this.maxTokens,
    this.jsonMode = false,
    this.system,
    this.webSearch = BuiltinSearch.none,
    this.tools = const <LlmTool>[],
  });

  final String model;
  final List<LlmMessage> messages;

  /// 思考模式。null = 不传（DeepSeek 的默认是**开**）。
  final bool? thinking;

  /// reasoning_effort。null = 不传。
  /// DeepSeek 会把它映射到 low / high / max 三档。
  final String? effort;

  /// 思考预算（token 数）。null = 不传。
  ///
  /// 只有 **Anthropic 形状**用它（`thinking.budget_tokens`）；DeepSeek 文档
  /// 明说这个字段会被忽略、不会设置思考预算，而 Responses / chat 那边没有这个东西。
  final int? budgetTokens;

  /// 注意：**思考模式下这个被忽略，而且不报错。** 界面上必须提示。
  final double? temperature;

  /// 注意：DeepSeek 只在思考模式下用 top_p，且夹到 0.95–1.0。
  final double? topP;

  final int? maxTokens;

  /// 开了要让提示词里出现“json”字样并给出格式示例（官方三条硬要求之二）。
  final bool jsonMode;

  /// 顶层 system。
  ///
  /// **Anthropic 形状**里 system 是顶层参数；Chat Completions 形状没有这个位置，
  /// 会拼成 `messages` 里一条 `role: system`。
  final String? system;

  /// 内置搜索。**形状按服务商不同**（看 `BuiltinSearch`）：
  ///
  /// · [BuiltinSearch.anthropic]：Anthropic 的 `web_search_20250305` server tool；
  /// · [BuiltinSearch.mimo]：MiMo 的 `web_search` 工具（Chat Completions 形状的 tools）。
  ///
  /// 它在**模型服务**上开关，不在搜索服务里。
  final BuiltinSearch webSearch;

  /// 工具声明。**非空时取代 [webSearch]** ——
  /// [webSearch] 是旧的内置搜索开关（MiMo / Anthropic 形状），
  /// [tools] 是通用写法，客户端工具与 DeepSeek 的联网工具都走这里。
  final List<LlmTool> tools;

  Map<String, Object?> toJson() {
    final Map<String, Object?> body = <String, Object?>{
      'model': model,
      'messages': <Object?>[
        if ((system ?? '').trim().isNotEmpty)
          LlmMessage('system', system!.trim()).toJson(),
        ...messages.map((LlmMessage m) => m.toJson()),
      ],
    };
    final bool? think = thinking;
    if (think != null) {
      body['thinking'] = <String, Object?>{'type': think ? 'enabled' : 'disabled'};
    }
    if (effort != null) body['reasoning_effort'] = effort;
    if (temperature != null) body['temperature'] = temperature;
    if (topP != null) body['top_p'] = topP;
    if (maxTokens != null) body['max_tokens'] = maxTokens;
    if (jsonMode) {
      body['response_format'] = <String, Object?>{'type': 'json_object'};
    }
    // 工具声明。**显式传入的 tools 优先**；没传才回落到旧的内置搜索开关。
    if (tools.isNotEmpty) {
      body['tools'] = tools.map((LlmTool t) => t.toOpenAiJson()).toList();
      body['tool_choice'] = 'auto';
    } else if (webSearch == BuiltinSearch.mimo) {
      // MiMo 的内置搜索走的是 **Chat Completions 形状的 tools**（不是 function）。
      // 参数照 `AGENTS/docs-mimo/web-search.md`：
      //   max_keyword 控成本（一轮最多几个关键词）、force_search = 强制搜（false = 让模型判断）、
      //   limit 是每条来源的条数上限。
      body['tools'] = <Object?>[
        <String, Object?>{
          'type': 'web_search',
          'max_keyword': 3,
          'force_search': false,
          'limit': 1,
        },
      ];
      body['tool_choice'] = 'auto';
    }
    return body;
  }

  /// Anthropic 形状（`/anthropic/messages`）。
  ///
  /// 差异（照 `AGENTS/docs-deepseek/guide-anthropic.md`）：
  /// · `system` 是**顶层参数**，不放在 messages 里；
  /// · `max_tokens` 必填（这里给个上限，调用方传了就用自己的）；
  /// · 思考开关还是 `thinking`，但“力度”在 `output_config.effort`；
  /// · 内置搜索是 `tools` 里一个 **server tool**（不是我们定义的 function）。
  Map<String, Object?> toAnthropicJson() {
    final Map<String, Object?> body = <String, Object?>{
      'model': model,
      'max_tokens': maxTokens ?? 4096,
      'messages': <Object?>[
        for (final LlmMessage m in messages)
          if (m.role != 'system')
            <String, Object?>{'role': m.role, 'content': m.toAnthropicContent()},
      ],
    };
    final String sys = (system ?? '').trim();
    if (sys.isNotEmpty) body['system'] = sys;
    final bool? think = thinking;
    if (think != null) {
      body['thinking'] = <String, Object?>{
        'type': think ? 'enabled' : 'disabled',
        // 预算只在开启思考时才有意义（Anthropic 的规矩）。
        if (think && budgetTokens != null) 'budget_tokens': budgetTokens,
      };
    }
    if (effort != null) {
      body['output_config'] = <String, Object?>{'effort': effort};
    }
    if (temperature != null) body['temperature'] = temperature;
    if (topP != null) body['top_p'] = topP;
    // 工具声明。显式 tools 优先；没传才回落到旧的内置搜索开关。
    if (tools.isNotEmpty) {
      body['tools'] = tools.map((LlmTool t) => t.toAnthropicJson()).toList();
    } else if (webSearch == BuiltinSearch.anthropic) {
      body['tools'] = <Object?>[
        <String, Object?>{
          // Anthropic 的 server tool 写法。DeepSeek 文档只写了
          // “`server_tool_use` / `web_search_tool_result` 支持”，
          // 没写声明长什么样，所以先按 Anthropic 官方那种声明。
          'type': 'web_search_20250305',
          'name': 'web_search',
          'max_uses': 5,
        },
      ];
    }
    return body;
  }

  /// Responses 形状（`/responses`）。
  ///
  /// 字段名跟 Chat Completions 全不一样，照官方 schema 来：
  /// · 输入叫 `input`（item 列表），不是 `messages`；
  /// · 系统提示词走顶层 `instructions`；
  /// · 上限叫 `max_output_tokens`；
  /// · 思考在 `reasoning.effort`（`none` 即关闭）；
  /// · JSON 模式在 `text.format`。
  Map<String, Object?> toResponsesJson() {
    final Map<String, Object?> body = <String, Object?>{
      'model': model,
      'input': <Object?>[
        for (final LlmMessage m in messages)
          if (m.role != 'system')
            <String, Object?>{'role': m.role, 'content': m.toResponsesContent()},
      ],
    };
    final String sys = (system ?? '').trim();
    if (sys.isNotEmpty) body['instructions'] = sys;
    if (maxTokens != null) body['max_output_tokens'] = maxTokens;
    if (temperature != null) body['temperature'] = temperature;
    if (topP != null) body['top_p'] = topP;
    if (effort != null) {
      body['reasoning'] = <String, Object?>{'effort': effort};
    } else if (thinking == false) {
      // 显式关思考：这边只有 effort = none 这一种说法。
      body['reasoning'] = <String, Object?>{'effort': 'none'};
    }
    if (jsonMode) {
      body['text'] = <String, Object?>{
        'format': <String, Object?>{'type': 'json_object'},
      };
    }
    if (tools.isNotEmpty) {
      body['tools'] = tools.map((LlmTool t) => t.toResponsesJson()).toList();
      body['tool_choice'] = 'auto';
    }
    return body;
  }
}

/// 用量。DeepSeek 的缓存命中与未命中要**分开看**——命中价差 50 倍。
class LlmUsage {
  const LlmUsage({
    this.input = 0,
    this.output = 0,
    this.cacheHit = 0,
    this.cacheMiss = 0,
  });

  final int input;
  final int output;
  final int cacheHit;
  final int cacheMiss;
}

/// 内置搜索捞到的一条来源（Anthropic 形状的 `web_search_result`）。
class LlmSource {
  const LlmSource({required this.title, required this.url});

  final String title;
  final String url;
}

/// 一次调用的结果。
class LlmReply {
  const LlmReply({
    this.text = '',
    this.reasoning,
    this.usage,
    this.error,
    this.errorCode,
    this.sources = const <LlmSource>[],
    this.searches = 0,
    this.toolCalls = const <LlmToolCall>[],
  });

  final String text;

  /// DeepSeek 把思维链放在和 content **同级**的 reasoning_content 里。
  final String? reasoning;

  final LlmUsage? usage;

  /// 内置搜索返回的来源（只有 Anthropic 形状有；没开就是空）。
  final List<LlmSource> sources;

  /// 这次模型自己搜了几次（`server_tool_use` 的个数）。
  final int searches;

  /// 模型发起的**客户端工具**调用。
  ///
  /// 非空就说明模型在等这些工具的结果：调用方执行完，把结果回传，
  /// 才能拿到最终回答。服务端工具（联网搜索/阅读链接）不在这里。
  final List<LlmToolCall> toolCalls;

  /// 出错时给人看的一句话；没错就是 null。
  final String? error;

  /// HTTP 状态码（不是 HTTP 错就没有）。
  final int? errorCode;

  bool get ok => error == null;
}

/// 流式返回的一块。
class LlmChunk {
  const LlmChunk({
    this.textDelta = '',
    this.reasoningDelta = '',
    this.usage,
    this.error,
    this.sources = const <LlmSource>[],
    this.searches = 0,
    this.toolCalls = const <LlmToolCall>[],
  });

  /// 正文新增的一小段。
  final String textDelta;

  /// 思考内容新增的一小段。DeepSeek 会在正文之前先吐这个。
  final String reasoningDelta;

  /// 有用量时才有（通常只有最后一块带）。
  final LlmUsage? usage;

  /// 出错时的一句话。出现这个就意味着流到此为止。
  final String? error;

  /// 服务端工具（联网搜索/阅读链接）捞到的来源。
  ///
  /// 官方明写：完整的 `server_tool_calls` 与 `annotations` **只在带
  /// `finish_reason` 的最后一个 chunk 里发一次**，所以这里通常只有最后一块非空。
  final List<LlmSource> sources;

  /// 这次请求里服务端工具发起了几次。
  final int searches;

  /// 已经**拼好**的客户端工具调用。
  ///
  /// 两个协议都是在参数拼完之后才交出来：
  /// · OpenAI：流结束时一次性给全部（按 `index` 归并 `arguments` 片段）；
  /// · Anthropic：每个 `content_block_stop` 交一个（`input_json_delta` 拼完再解析）。
  final List<LlmToolCall> toolCalls;

  bool get ok => error == null;
}
