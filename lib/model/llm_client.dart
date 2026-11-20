// LLM 调用层：**按服务商分发**。
//
// 按 `AGENTS/服务商适配方针.md`：这里只做认领，不做转换。
// 认出是 DeepSeek 就整个交给 `llm_deepseek.dart`（它的请求体、鉴权头、
// 响应解析、错误码、流式都在那边）；这里不放任何 DeepSeek 的规矩。
//
// 共用类型在 `llm_types.dart`（结果类型允许共用）。这里 export 出去，
// 原来 `import 'llm_client.dart'` 拿 LlmReply 的地方不用改。
//
// 还没搬的（下一步做，**一次一家**）：
//   · Claude / Anthropic 兼容：body 与解析仍在本文件按 wire 分支处理；
//   · Google：`Wire.google` 仍然直接报“还没接”。

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'llm_deepseek.dart';
import 'llm_types.dart';
import 'network.dart';

import 'provider.dart';

export 'llm_types.dart';

/// 调用层。
class LlmClient {
  LlmClient._();

  /// 只重试这些码。400 / 401 / 402 / 422 重试没有意义，直接报给人。
  static const Set<int> _retryable = <int>{429, 500, 503};

  /// 发一次（非流式）。
  ///
  /// **DeepSeek 整个交给 `llm_deepseek.dart`**（它有自己的一份重试与错误码表）。
  /// 其余协议暂时仍走本文件的分支；认不出的协议返回一句“还没接”，
  /// **不假装能发**。
  static Future<LlmReply> send(
    Provider provider,
    String apiKey,
    LlmRequest req, {
    http.Client? client,
  }) async {
    if (provider.protocol.isDeepSeek) {
      return DeepSeekLlm.send(provider, apiKey, req, client: client);
    }
    final Wire wire = provider.protocol.wire;
    if (wire != Wire.chatCompletions && wire != Wire.anthropic) {
      return LlmReply(error: '这个协议还没接：${provider.protocol.label}');
    }
    // 内置搜索的形状得跟协议对得上，否则发了也是无效参数。
    if (req.webSearch != BuiltinSearch.none) {
      if (req.webSearch == BuiltinSearch.anthropic && wire != Wire.anthropic) {
        return const LlmReply(error: 'Anthropic 的内置搜索只能用在 Anthropic 格式的服务商上');
      }
      if (req.webSearch == BuiltinSearch.mimo && wire != Wire.chatCompletions) {
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
        res = await (client ?? NetworkRuntime.newClient())
            .post(uri, headers: headers, body: payload)
            .timeout(const Duration(minutes: 5));
      } on TimeoutException {
        netError = '超时（5 分钟没有响应）';
      } catch (e) {
        netError = '连接失败：$e';
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

  /// 把成功返回解析出来。字段名照 Chat Completions 形状。
  ///
  /// 这是**还没搬走**的通用路径（MiMo 等 OpenAI 兼容服务商用）。
  /// DeepSeek 有自己的解析，在 `llm_deepseek.dart`。
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
      // 内置搜索的引用放在 `message.annotations`（url_citation）。
      // MiMo 是这样；DeepSeek 的联网工具也返回 annotations，但那边走
      // `llm_deepseek.dart` 自己的解析。
      return LlmReply(
        text: text,
        reasoning: rc is String && rc.isNotEmpty ? rc : null,
        usage: _usageOf(j['usage']),
        sources: _sourcesOf(msg['annotations']),
        searches: _serverToolCallsOf(msg['server_tool_calls']),
        toolCalls: _toolCallsOf(msg['tool_calls']),
      );
    } catch (e) {
      return LlmReply(error: '解析失败：$e');
    }
  }

  /// 解析 Chat Completions 形状的 `annotations` 来源；兼容 `url_citation` 嵌套形状。
  static List<LlmSource> _sourcesOf(Object? raw) {
    if (raw is! List) return const <LlmSource>[];
    final List<LlmSource> out = <LlmSource>[];
    for (final Object? a in raw) {
      if (a is! Map) continue;
      final Object? nested = a['url_citation'];
      if (nested == null && '${a['type'] ?? ''}' != 'url_citation') continue;
      final Map<Object?, Object?> citation = nested is Map ? nested : a;
      final String url = '${citation['url'] ?? ''}';
      if (url.isEmpty) continue;
      out.add(
        LlmSource(
          title: '${citation['title'] ?? ''}',
          url: url,
        ),
      );
    }
    return out;
  }

  /// 统计 Chat Completions 形状的 `server_tool_calls` 里实际发起的调用数。
  static int _serverToolCallsOf(Object? raw) {
    if (raw is! List) return 0;
    int count = 0;
    for (final Object? group in raw) {
      if (group is! Map) continue;
      final Object? calls = group['calls'];
      if (calls is List) {
        count += calls.length;
      } else if ('${group['type'] ?? ''}'.isNotEmpty) {
        count++;
      }
    }
    return count;
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
      final List<LlmToolCall> toolCalls = <LlmToolCall>[];
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
          case 'tool_use':
            final String toolName = '${b['name'] ?? ''}';
            if (toolName.isNotEmpty) {
              toolCalls.add(
                LlmToolCall(
                  id: '${b['id'] ?? ''}',
                  name: toolName,
                  arguments: jsonEncode(b['input'] ?? const <String, Object?>{}),
                ),
              );
            }
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
        toolCalls: toolCalls,
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

  /// 客户端工具调用。Chat Completions 形状里参数是 **JSON 字符串**，原样保留。
  ///
  /// 这里照着通用路径再写一份：DeepSeek 那份在 `llm_deepseek.dart`，
  /// 按方针各写各的，不为了少几行去共用。
  static List<LlmToolCall> _toolCallsOf(Object? raw) {
    if (raw is! List) return const <LlmToolCall>[];
    final List<LlmToolCall> out = <LlmToolCall>[];
    for (final Object? t in raw) {
      if (t is! Map) continue;
      final Object? fn = t['function'];
      if (fn is! Map) continue;
      final String name = '${fn['name'] ?? ''}';
      if (name.isEmpty) continue;
      out.add(
        LlmToolCall(
          id: '${t['id'] ?? ''}',
          name: name,
          arguments: '${fn['arguments'] ?? ''}',
        ),
      );
    }
    return out;
  }

  /// 错误码 → 人话（通用路径用）。
  ///
  /// **DeepSeek 不用这张表**：它有自己那份（含 402），在 `llm_deepseek.dart`。
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

  /// 流式。
  ///
  /// **DeepSeek 整个交给 `llm_deepseek.dart`**；其余协议暂时走本文件，
  /// 且只做了 Chat Completions 形状。Anthropic 形状的流式事件形状不一样
  /// （message_start / content_block_delta…），**没做就直说**，
  /// 不拿 OpenAI 的解析器去套。
  static Stream<LlmChunk> stream(
    Provider provider,
    String apiKey,
    LlmRequest req, {
    http.Client? client,
  }) async* {
    if (provider.protocol.isDeepSeek) {
      yield* DeepSeekLlm.stream(provider, apiKey, req, client: client);
      return;
    }
    if (provider.protocol.wire != Wire.chatCompletions) {
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
    final http.Client httpClient = client ?? NetworkRuntime.newClient();
    try {
      final http.Request r = http.Request('POST', uri)
        ..headers.addAll(<String, String>{
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        })
        ..body = payload;

      final http.StreamedResponse res = await httpClient.send(r);
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
          List<LlmSource> sources = const <LlmSource>[];
          int searches = 0;
          final Object? ch = j['choices'];
          if (ch is List && ch.isNotEmpty && ch.first is Map) {
            final Object? d = (ch.first as Map)['delta'];
            if (d is Map) {
              final Object? dT = d['content'];
              final Object? dR = d['reasoning_content'];
              if (dT is String) t = dT;
              if (dR is String) rc = dR;
              sources = _sourcesOf(d['annotations']);
              searches = _serverToolCallsOf(d['server_tool_calls']);
            }
          }
          if (t.isNotEmpty || rc.isNotEmpty || u != null ||
              sources.isNotEmpty || searches > 0) {
            yield LlmChunk(
              textDelta: t,
              reasoningDelta: rc,
              usage: u,
              sources: sources,
              searches: searches,
            );
          }
        } catch (_) {
          // 某一块解析不了就跳过，不因为一块把整条流打断。
        }
      }
    } catch (e) {
      yield LlmChunk(error: '流断了：$e');
    } finally {
      httpClient.close();
    }
  }
}
