// LLM 调用层。
//
// 现在只有 **DeepSeek** 这一条（别的协议后补）。
// 字段全部照 `AGENTS/deepseek/适配.md` 来 —— **不猜**。
//
// 还没做的：
//   · 流式（SSE）。DeepSeek 流式时先出 delta.reasoning_content、再出 delta.content，
//     必须按字段分流，不能当一坨文本拼。
//   · 别的协议（OpenAI / Claude / Google）。
//   · JSON 模式的重试（空 content）。那要等回合那层再说。

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'provider.dart';

/// 一条消息。DeepSeek 是 **OpenAI 形状**：系统提示词在这边是
/// `role: system` 的一条消息，不是顶层参数。
class LlmMessage {
  const LlmMessage(this.role, this.content);

  final String role; // 'system' / 'user' / 'assistant'
  final String content;

  Map<String, String> toJson() => <String, String>{
    'role': role,
    'content': content,
  };
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
    this.temperature,
    this.topP,
    this.maxTokens,
    this.jsonMode = false,
    this.system,
    this.webSearch = BuiltinSearch.none,
  });

  final String model;
  final List<LlmMessage> messages;

  /// 思考模式。null = 不传（DeepSeek 的默认是**开**）。
  final bool? thinking;

  /// reasoning_effort。null = 不传。
  /// DeepSeek 会把它映射到 low / high / max 三档。
  final String? effort;

  /// 注意：**思考模式下这个被忽略，而且不报错。** 界面上必须提示。
  final double? temperature;

  /// 注意：DeepSeek 只在思考模式下用 top_p，且夹到 0.95–1.0。
  final double? topP;

  final int? maxTokens;

  /// 开了要让提示词里出现 "json" 字样并给出格式示例（官方三条硬要求之二）。
  final bool jsonMode;

  /// 顶层 system。
  ///
  /// **Anthropic 形状**里 system 是顶层参数；OpenAI 形状没有这个位置，
  /// 会拼成 `messages` 里一条 `role: system`。
  final String? system;

  /// 内置搜索。**形状按服务商不同**（看 `BuiltinSearch`）：
  ///
  /// · [BuiltinSearch.anthropic]：Anthropic 的 `web_search_20250305` server tool；
  /// · [BuiltinSearch.mimo]：MiMo 的 `web_search` 工具（OpenAI 形状的 tools）。
  ///
  /// 它在**模型服务**上开关，不在搜索服务里。
  final BuiltinSearch webSearch;

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
      body['thinking'] = <String, Object?>{
        'type': think ? 'enabled' : 'disabled',
      };
    }
    if (effort != null) body['reasoning_effort'] = effort;
    if (temperature != null) body['temperature'] = temperature;
    if (topP != null) body['top_p'] = topP;
    if (maxTokens != null) body['max_tokens'] = maxTokens;
    if (jsonMode) {
      body['response_format'] = <String, Object?>{'type': 'json_object'};
    }
    // MiMo 的内置搜索走的是 **OpenAI 形状的 tools**（不是 function）。
    // 参数照 `AGENTS/docs-mimo/web-search.md`：
    //   max_keyword 控成本（一轮最多几个关键词）、force_search = 强制搜（false = 让模型判断）、
    //   limit 是每条来源的条数上限。
    if (webSearch == BuiltinSearch.mimo) {
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
            <String, Object?>{
              'role': m.role,
              'content': <Object?>[
                <String, Object?>{'type': 'text', 'text': m.content},
              ],
            },
      ],
    };
    final String sys = (system ?? '').trim();
    if (sys.isNotEmpty) body['system'] = sys;
    final bool? think = thinking;
    if (think != null) {
      body['thinking'] = <String, Object?>{
        'type': think ? 'enabled' : 'disabled',
      };
    }
    if (effort != null) {
      body['output_config'] = <String, Object?>{'effort': effort};
    }
    if (temperature != null) body['temperature'] = temperature;
    if (topP != null) body['top_p'] = topP;
    if (webSearch == BuiltinSearch.anthropic) {
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
  });

  final String text;

  /// DeepSeek 把思维链放在和 content **同级**的 reasoning_content 里。
  final String? reasoning;

  final LlmUsage? usage;

  /// 内置搜索返回的来源（只有 Anthropic 形状有；没开就是空）。
  final List<LlmSource> sources;

  /// 这次模型自己搜了几次（`server_tool_use` 的个数）。
  final int searches;

  /// 出错时给人看的一句话；没错就是 null。
  final String? error;

  /// HTTP 状态码（不是 HTTP 错就没有）。
  final int? errorCode;

  bool get ok => error == null;
}

/// 调用层。
class LlmClient {
  LlmClient._();

  /// 只重试这些码。400 / 401 / 402 / 422 重试没有意义，直接报给人。
  static const Set<int> _retryable = <int>{429, 500, 503};

  /// 发一次（非流式）。
  ///
  /// 现在只认 [Protocol.deepseek]。别的协议返回一句“还没接”，
  /// **不假装能发**。
  static Future<LlmReply> send(
    Provider provider,
    String apiKey,
    LlmRequest req, {
    http.Client? client,
  }) async {
    final Wire wire = provider.protocol.wire;
    if (wire != Wire.openai && wire != Wire.anthropic) {
      return LlmReply(error: '这个协议还没接：${provider.protocol.label}');
    }
    // 内置搜索的形状得跟协议对得上，否则发了也是无效参数。
    if (req.webSearch != BuiltinSearch.none) {
      if (req.webSearch == BuiltinSearch.anthropic && wire != Wire.anthropic) {
        return const LlmReply(error: 'Anthropic 的内置搜索只能用在 Anthropic 格式的服务商上');
      }
      if (req.webSearch == BuiltinSearch.mimo && wire != Wire.openai) {
        return const LlmReply(
          error: 'MiMo 的内置搜索只在 OpenAI 格式（chat/completions）下支持',
        );
      }
    }
    if (apiKey.trim().isEmpty) {
      return const LlmReply(error: '这个服务商还没填 API Key');
    }

    // **用服务商自己的地址**（baseUrl / apiPath 可以覆盖协议默认值）。
    // 早先这里拼的是 protocol 的默认值，结果任何“预设带自定义地址”的服务商
    // 都发不到自己的地址上。
    final Uri uri = Uri.parse(provider.endpoint);
    final String payload = jsonEncode(
      wire == Wire.anthropic ? req.toAnthropicJson() : req.toJson(),
    );
    final Map<String, String> headers = <String, String>{
      // **必须带 charset**：http 包不写时按 latin1 编码请求体，中文会抛。
      'Content-Type': 'application/json; charset=utf-8',
      if (wire == Wire.anthropic)
        'x-api-key': apiKey
      else
        'Authorization': 'Bearer $apiKey',
    };

    // 退避：0.5s → 1s → 2s。总共 4 次尝试。
    int waitMs = 500;
    for (int attempt = 0; attempt < 4; attempt++) {
      http.Response? res;
      String? netError;
      try {
        res = await (client ?? http.Client())
            .post(uri, headers: headers, body: payload)
            .timeout(const Duration(minutes: 5));
      } on TimeoutException {
        netError = '超时（5 分钟没有响应）';
      } catch (e) {
        netError = '连不上：$e';
      }

      if (res == null) {
        if (attempt < 3) {
          await Future<void>.delayed(Duration(milliseconds: waitMs));
          waitMs *= 2;
          continue;
        }
        return LlmReply(error: netError);
      }

      if (res.statusCode == 200) {
        return wire == Wire.anthropic
            ? _parseAnthropic(res.body)
            : _parseOk(res.body);
      }

      if (_retryable.contains(res.statusCode) && attempt < 3) {
        await Future<void>.delayed(Duration(milliseconds: waitMs));
        waitMs *= 2;
        continue;
      }

      return LlmReply(
        error: _messageFor(res.statusCode, res.body),
        errorCode: res.statusCode,
      );
    }

    return const LlmReply(error: '重试了几次都不行');
  }

  /// 把成功返回解析出来。字段名照 DeepSeek 的文档。
  static LlmReply _parseOk(String body) {
    try {
      final Object? j = jsonDecode(body);
      if (j is! Map) return const LlmReply(error: '返回的不是 JSON 对象');
      final Object? choices = j['choices'];
      if (choices is! List || choices.isEmpty) {
        return const LlmReply(error: '返回里没有 choices');
      }
      final Object? first = choices.first;
      final Object? msg = (first is Map) ? first['message'] : null;
      if (msg is! Map) return const LlmReply(error: '返回里没有 message');

      final String text = '${msg['content'] ?? ''}';
      final Object? rc = msg['reasoning_content'];
      // 内置搜索的来源：MiMo 把引用放在 `message.annotations`（url_citation）。
      final List<LlmSource> sources = <LlmSource>[];
      final Object? ann = msg['annotations'];
      if (ann is List) {
        for (final Object? a in ann) {
          if (a is! Map) continue;
          if ('${a['type']}' != 'url_citation') continue;
          sources.add(
            LlmSource(title: '${a['title'] ?? ''}', url: '${a['url'] ?? ''}'),
          );
        }
      }
      return LlmReply(
        text: text,
        reasoning: rc is String && rc.isNotEmpty ? rc : null,
        usage: _usageOf(j['usage']),
        sources: sources,
      );
    } catch (e) {
      return LlmReply(error: '解析失败：$e');
    }
  }

  /// Anthropic 形状的响应。
  ///
  /// `content` 是一组块，不是一个字符串：
  /// · `text` → 正文；`thinking` → 思维链；
  /// · `server_tool_use` → 模型发起了一次内置搜索（计数用）；
  /// · `web_search_tool_result` → 该次搜索的来源（title/url）。
  ///
  /// 字段名照 Anthropic 消息格式；DeepSeek 文档写的是“这个块类型支持”，
  /// 具体字段就按 Anthropic 官方的来。
  static LlmReply _parseAnthropic(String body) {
    try {
      final Object? j = jsonDecode(body);
      if (j is! Map) return const LlmReply(error: '返回的不是 JSON 对象');
      final Object? content = j['content'];
      if (content is! List) return const LlmReply(error: '返回里没有 content');

      final StringBuffer text = StringBuffer();
      final StringBuffer think = StringBuffer();
      final List<LlmSource> sources = <LlmSource>[];
      int searches = 0;

      for (final Object? b in content) {
        if (b is! Map) continue;
        switch ('${b['type']}') {
          case 'text':
            text.write('${b['text'] ?? ''}');
          case 'thinking':
            think.write('${b['thinking'] ?? ''}');
          case 'server_tool_use':
            searches++;
          case 'web_search_tool_result':
            final Object? inner = b['content'];
            if (inner is List) {
              for (final Object? r in inner) {
                if (r is! Map) continue;
                sources.add(
                  LlmSource(
                    title: '${r['title'] ?? ''}',
                    url: '${r['url'] ?? ''}',
                  ),
                );
              }
            }
        }
      }

      return LlmReply(
        text: text.toString(),
        reasoning: think.isEmpty ? null : think.toString(),
        usage: _anthropicUsage(j['usage']),
        sources: sources,
        searches: searches,
      );
    } catch (e) {
      return LlmReply(error: '解析失败：$e');
    }
  }

  static LlmUsage? _anthropicUsage(Object? u) {
    if (u is! Map) return null;
    int n(Object? v) => v is num ? v.toInt() : 0;
    return LlmUsage(
      input: n(u['input_tokens']),
      output: n(u['output_tokens']),
      // Anthropic 把缓存读写分开报；命中 ≈ cache_read。
      cacheHit: n(u['cache_read_input_tokens']),
      cacheMiss: n(u['cache_creation_input_tokens']),
    );
  }

  static LlmUsage? _usageOf(Object? u) {
    if (u is! Map) return null;
    int n(Object? v) => v is num ? v.toInt() : 0;
    return LlmUsage(
      input: n(u['prompt_tokens']),
      output: n(u['completion_tokens']),
      cacheHit: n(u['prompt_cache_hit_tokens']),
      cacheMiss: n(u['prompt_cache_miss_tokens']),
    );
  }

  /// 错误码 → 人话。照 `适配.md` 那张表。
  static String _messageFor(int code, String body) {
    String? detail;
    try {
      final Object? j = jsonDecode(body);
      if (j is Map && j['error'] is Map) {
        detail = '${(j['error'] as Map)['message'] ?? ''}';
      }
    } catch (_) {
      // 不是 JSON 就算了，下面照样给结论
    }
    final String what = switch (code) {
      400 => '请求格式不对（参数错了，重试没用）',
      401 => 'API Key 不对，去服务商那边检查',
      402 => '余额不足 —— 这是 DeepSeek 特有的码，去充值',
      422 => '参数非法，重试没用',
      429 => '请求太频繁（限流），等一会儿再来',
      500 => '服务端出错',
      503 => '服务端过载',
      _ => '没见过的错误码',
    };
    return detail == null || detail.isEmpty
        ? 'HTTP $code：$what'
        : 'HTTP $code：$what\n$detail';
  }

  /// 流式的一块。
  ///
  /// DeepSeek 先出 [reasoningDelta]（思考），再出 [textDelta]（正文）——
  /// 解析时必须按字段分流，不能当一坨文本拼。
  static Stream<LlmChunk> stream(
    Provider provider,
    String apiKey,
    LlmRequest req,
  ) async* {
    // 流式只做了 OpenAI 形状（DeepSeek 的 chat/completions）。
    // Anthropic 形状的流式事件形状不一样（message_start / content_block_delta…），
    // **没做就直说**，不拿 OpenAI 的解析器去套。
    if (provider.protocol.wire != Wire.openai) {
      yield LlmChunk(error: '${provider.protocol.label} 的流式还没接（先支持非流式）');
      return;
    }
    if (apiKey.trim().isEmpty) {
      yield const LlmChunk(error: '这个服务商还没填 API Key');
      return;
    }

    // 跟 `send()` 一样：用服务商自己的地址，不是协议默认的。
    final Uri uri = Uri.parse(provider.endpoint);
    final String payload = jsonEncode(<String, Object?>{
      ...req.toJson(),
      'stream': true,
    });

    // 流式**不做退避重试** —— 断在半路重试会把已经吐出来的字重复一遍。
    final http.Client client = http.Client();
    try {
      final http.Request r = http.Request('POST', uri)
        ..headers.addAll(<String, String>{
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        })
        ..body = payload;

      final http.StreamedResponse res = await client.send(r);
      if (res.statusCode != 200) {
        final String body = await res.stream.bytesToString();
        yield LlmChunk(error: _messageFor(res.statusCode, body));
        return;
      }

      // SSE：一行一个 `data: {...}`，最后 `data: [DONE]`。
      await for (final String line
          in res.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (!line.startsWith('data:')) continue;
        final String data = line.substring(5).trim();
        if (data.isEmpty) continue;
        if (data == '[DONE]') break;

        try {
          final Object? j = jsonDecode(data);
          if (j is! Map) continue;

          // 用量通常在最后一块里。全零就当没有（不显示一堆 0）。
          LlmUsage? u = _usageOf(j['usage']);
          if (u != null &&
              u.input == 0 &&
              u.output == 0 &&
              u.cacheHit == 0 &&
              u.cacheMiss == 0) {
            u = null;
          }

          String t = '';
          String rc = '';
          final Object? ch = j['choices'];
          if (ch is List && ch.isNotEmpty && ch.first is Map) {
            final Object? d = (ch.first as Map)['delta'];
            if (d is Map) {
              final Object? dT = d['content'];
              final Object? dR = d['reasoning_content'];
              if (dT is String) t = dT;
              if (dR is String) rc = dR;
            }
          }
          if (t.isNotEmpty || rc.isNotEmpty || u != null) {
            yield LlmChunk(textDelta: t, reasoningDelta: rc, usage: u);
          }
        } catch (_) {
          // 某一块解析不了就跳过，不因为一块把整条流打断。
        }
      }
    } catch (e) {
      yield LlmChunk(error: '流断了：$e');
    } finally {
      client.close();
    }
  }
}

/// 流式返回的一块。
class LlmChunk {
  const LlmChunk({
    this.textDelta = '',
    this.reasoningDelta = '',
    this.usage,
    this.error,
  });

  /// 正文新增的一小段。
  final String textDelta;

  /// 思考内容新增的一小段。DeepSeek 会在正文之前先吐这个。
  final String reasoningDelta;

  /// 有用量时才有（通常只有最后一块带）。
  final LlmUsage? usage;

  /// 出错时的一句话。出现这个就意味着流到此为止。
  final String? error;

  bool get ok => error == null;
}
