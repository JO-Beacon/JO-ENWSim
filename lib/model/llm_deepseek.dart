// DeepSeek 自己的请求与解析。**别家的事不写在这里。**
//
// 字段全部照 `AGENTS/deepseek/适配.md` 来 —— **不猜**。
// 按 `AGENTS/服务商适配方针.md`：请求体、鉴权头、响应解析、错误码、流式事件
// 各自沉到本文件；改 DeepSeek 不该碰到别家的文件。
//
// DeepSeek 有两种形状，都由本文件负责（它们都是 DeepSeek 的事实）：
//   · Chat Completions 形状：`https://api.deepseek.com/chat/completions`
//   · Anthropic 形状：`https://api.deepseek.com/anthropic/messages`
//
// 还没做的：
//   · Anthropic 形状的**流式**（事件形状是 message_start / content_block_delta…，
//     跟 OpenAI 的 data: {...} 完全不同，**没做就直说**，不拿 OpenAI 的解析器去套）。
//   · JSON 模式的重试（空 content）。那要等回合那层再说。

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'llm_types.dart';
import 'network.dart';
import 'provider.dart';

/// DeepSeek 的调用实现。
class DeepSeekLlm {
  const DeepSeekLlm._();

  /// 只重试这些码。400 / 401 / 402 / 422 重试没有意义，直接报给人。
  static const Set<int> _retryable = <int>{429, 500, 503};

  /// 发一次（非流式）。
  static Future<LlmReply> send(
    Provider provider,
    String apiKey,
    LlmRequest req, {
    http.Client? client,
  }) async {
    // 勾了 Responses 且这个协议有这条端点：走另一套字段与解析。
    if (provider.usesResponses) {
      return _sendResponses(provider, apiKey, req, client: client);
    }
    final BuiltinSearch err = _builtinSearchError(provider, req);
    if (err != BuiltinSearch.none) {
      return LlmReply(error: _builtinSearchMessage(err));
    }
    if (apiKey.trim().isEmpty) {
      return const LlmReply(error: '这个服务商还没填 API Key');
    }

    // **用服务商自己的地址**（baseUrl / apiPath 可以覆盖协议默认值）。
    final Uri uri = Uri.parse(provider.endpoint);
    final String payload = jsonEncode(_body(provider, req));
    final Map<String, String> headers = <String, String>{
      // **必须带 charset**：http 包不写时按 latin1 编码请求体，中文会抛。
      'Content-Type': 'application/json; charset=utf-8',
      if (_isAnthropic(provider))
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
        return _isAnthropic(provider)
            ? _parseAnthropic(res.body)
            : _parseOpenAi(res.body);
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

  /// 流式。
  ///
  /// DeepSeek 先出 [LlmChunk.reasoningDelta]（思考），再出 [LlmChunk.textDelta]
  /// （正文）—— 解析时必须按字段分流，不能当一坨文本拼。
  static Stream<LlmChunk> stream(
    Provider provider,
    String apiKey,
    LlmRequest req, {
    http.Client? client,
  }) async* {
    if (_isAnthropic(provider)) {
      yield* _streamAnthropic(provider, apiKey, req, client: client);
      return;
    }
    if (provider.usesResponses) {
      yield* _streamResponses(provider, apiKey, req, client: client);
      return;
    }
    final BuiltinSearch err = _builtinSearchError(provider, req);
    if (err != BuiltinSearch.none) {
      yield LlmChunk(error: _builtinSearchMessage(err));
      return;
    }
    if (apiKey.trim().isEmpty) {
      yield const LlmChunk(error: '这个服务商还没填 API Key');
      return;
    }

    final Uri uri = Uri.parse(provider.endpoint);
    final String payload = jsonEncode(<String, Object?>{
      ..._body(provider, req),
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

      // 客户端工具调用按 `index` 分片下发，先攒着，流结束再一次性交出。
      final Map<int, Map<String, String>> pendingTools =
          <int, Map<String, String>>{};

      // SSE：一行一个 `data: {...}`，最后 `data: [DONE]`。
      await for (final String line in res.stream
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
          Map<Object?, Object?>? delta;
          final Object? ch = j['choices'];
          if (ch is List && ch.isNotEmpty && ch.first is Map) {
            final Object? d = (ch.first as Map)['delta'];
            if (d is Map) {
              delta = d;
              final Object? dT = d['content'];
              final Object? dR = d['reasoning_content'];
              if (dT is String) t = dT;
              if (dR is String) rc = dR;
              _collectToolCallDeltas(d['tool_calls'], pendingTools);
            }
          }
          // 服务端工具的结果只在带 finish_reason 的最后一块里发一次。
          // 文档说在 `delta` 里；chunk 顶层也兜一下，免得位置一变就静默丢。
          final List<LlmSource> srcs = _sourcesOf(
            delta?['annotations'] ?? j['annotations'],
          );
          final int searches = _searchCountOf(
            delta?['server_tool_calls'] ?? j['server_tool_calls'],
          );
          if (t.isNotEmpty ||
              rc.isNotEmpty ||
              u != null ||
              srcs.isNotEmpty ||
              searches > 0) {
            yield LlmChunk(
              textDelta: t,
              reasoningDelta: rc,
              usage: u,
              sources: srcs,
              searches: searches,
            );
          }
        } catch (_) {
          // 某一块解析不了就跳过，不因为一块把整条流打断。
        }
      }
      // 流结束：把攒好的工具调用一次交出去。
      if (pendingTools.isNotEmpty) {
        final List<int> order = pendingTools.keys.toList()..sort();
        yield LlmChunk(
          toolCalls: <LlmToolCall>[
            for (final int k in order)
              if ((pendingTools[k]!['name'] ?? '').isNotEmpty)
                LlmToolCall(
                  id: pendingTools[k]!['id'] ?? '',
                  name: pendingTools[k]!['name']!,
                  arguments: pendingTools[k]!['arguments'] ?? '',
                ),
          ],
        );
      }
    } catch (e) {
      yield LlmChunk(error: '流断了：$e');
    } finally {
      httpClient.close();
    }
  }

  /// Responses 形状发一次（非流式）。
  ///
  /// 字段与解析都跟 Chat Completions 不同，所以单独一条：
  /// 输入是 `input` item、系统提示词在 `instructions`、输出上限是
  /// `max_output_tokens`、思考在 `reasoning.effort`、JSON 在 `text.format`。
  static Future<LlmReply> _sendResponses(
    Provider provider,
    String apiKey,
    LlmRequest req, {
    http.Client? client,
  }) async {
    if (apiKey.trim().isEmpty) {
      return const LlmReply(error: '这个服务商还没填 API Key');
    }
    final Uri uri = Uri.parse(provider.endpoint);
    final String payload = jsonEncode(req.toResponsesJson());
    final Map<String, String> headers = <String, String>{
      'Content-Type': 'application/json; charset=utf-8',
      'Authorization': 'Bearer $apiKey',
    };

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

      if (res.statusCode == 200) return _parseResponses(res.body);

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

  /// Responses 形状的响应。
  ///
  /// 正文在 `output[]` 里按 item 分：
  /// `message` 的 `output_text` 是正文，`reasoning` 的 `reasoning_text` 是思维链，
  /// `function_call` 是客户端工具调用，`web_search_call` 是联网工具的每一次调用。
  static LlmReply _parseResponses(String body) {
    try {
      final Object? j = jsonDecode(body);
      if (j is! Map) return const LlmReply(error: '返回的不是 JSON 对象');

      if ('${j['status'] ?? ''}' == 'failed') {
        final Object? e = j['error'];
        final String msg = e is Map ? '${e['message'] ?? ''}' : '';
        return LlmReply(error: msg.isEmpty ? '生成失败' : msg);
      }

      final StringBuffer text = StringBuffer();
      final StringBuffer think = StringBuffer();
      final List<LlmSource> sources = <LlmSource>[];
      final List<LlmToolCall> toolCalls = <LlmToolCall>[];
      int searches = 0;

      final Object? output = j['output'];
      if (output is List) {
        for (final Object? item in output) {
          if (item is! Map) continue;
          switch ('${item['type'] ?? ''}') {
            case 'message':
              for (final Object? c in _listOf(item['content'])) {
                if (c is Map && '${c['type']}' == 'output_text') {
                  text.write('${c['text'] ?? ''}');
                }
              }
            case 'reasoning':
              for (final Object? c in _listOf(item['content'])) {
                if (c is Map && '${c['type']}' == 'reasoning_text') {
                  think.write('${c['text'] ?? ''}');
                }
              }
            case 'function_call':
              final String fn = '${item['name'] ?? ''}';
              if (fn.isNotEmpty) {
                toolCalls.add(
                  LlmToolCall(
                    id: '${item['call_id'] ?? ''}',
                    name: fn,
                    arguments: '${item['arguments'] ?? ''}',
                  ),
                );
              }
            case 'web_search_call':
              searches++;
              final Object? action = item['action'];
              if (action is Map) {
                for (final Object? s in _listOf(action['sources'])) {
                  if (s is! Map) continue;
                  final String url = '${s['url'] ?? ''}';
                  if (url.isEmpty) continue;
                  sources.add(
                    LlmSource(title: '${s['title'] ?? ''}', url: url),
                  );
                }
              }
          }
        }
      }

      return LlmReply(
        text: text.toString(),
        reasoning: think.isEmpty ? null : think.toString(),
        usage: _responsesUsage(j['usage']),
        sources: sources,
        searches: searches,
        toolCalls: toolCalls,
      );
    } catch (e) {
      return LlmReply(error: '解析失败：$e');
    }
  }

  static Iterable<Object?> _listOf(Object? v) =>
      v is List ? v : const <Object?>[];

  /// Responses 的用量。
  ///
  /// 它只报**命中量**（`input_tokens_details.cached_tokens`），
  /// 未命中要自己按 `input_tokens - 命中` 算。
  static LlmUsage? _responsesUsage(Object? u) {
    if (u is! Map) return null;
    int n(Object? v) => v is num ? v.toInt() : 0;
    final Object? details = u['input_tokens_details'];
    final int input = n(u['input_tokens']);
    final int hit = details is Map ? n(details['cached_tokens']) : 0;
    return LlmUsage(
      input: input,
      output: n(u['output_tokens']),
      cacheHit: hit,
      cacheMiss: input > hit ? input - hit : 0,
    );
  }

  /// Anthropic 形状（`/messages`）的流式。
  ///
  /// 事件形状跟 OpenAI 完全不同：`message_start` → 各块的
  /// `content_block_start` / `content_block_delta` / `content_block_stop`
  /// → `message_delta` → `message_stop`，**没有** `data: [DONE]`。
  ///
  /// 几条照文档来的规矩：
  /// · 服务端工具（`server_tool_use` / `web_search_tool_result` /
  ///   `web_fetch_tool_result`）的结果**一次性出现在 `content_block_start`**，不分段；
  /// · 用量以**最后的 `message_delta.usage`** 为准，**不要**跟 `message_start` 的相加；
  /// · 客户端工具（`tool_use`）的入参是 `input_json_delta` 分片，这块**暂时不接**，
  ///   声明了就如实报，不假装能收。
  static Stream<LlmChunk> _streamAnthropic(
    Provider provider,
    String apiKey,
    LlmRequest req, {
    http.Client? client,
  }) async* {
    if (apiKey.trim().isEmpty) {
      yield const LlmChunk(error: '这个服务商还没填 API Key');
      return;
    }
    final Uri uri = Uri.parse(provider.endpoint);
    final String payload = jsonEncode(<String, Object?>{
      ...req.toAnthropicJson(),
      'stream': true,
    });

    final http.Client c = client ?? NetworkRuntime.newClient();
    // 客户端工具：块开始时记下 id/name，入参从 `input_json_delta` 逐片拼。
    final Map<int, Map<String, String>> toolBlocks =
        <int, Map<String, String>>{};
    try {
      final http.Request r = http.Request('POST', uri)
        ..headers.addAll(<String, String>{
          'Content-Type': 'application/json',
          'x-api-key': apiKey,
          'anthropic-version': '2023-06-01',
        })
        ..body = payload;

      final http.StreamedResponse res = await c.send(r);
      if (res.statusCode != 200) {
        final String body = await res.stream.bytesToString();
        yield LlmChunk(error: _messageFor(res.statusCode, body));
        return;
      }

      await for (final String line in res.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (!line.startsWith('data:')) continue;
        final String data = line.substring(5).trim();
        if (data.isEmpty) continue;

        try {
          final Object? j = jsonDecode(data);
          if (j is! Map) continue;
          switch ('${j['type'] ?? ''}') {
            case 'content_block_start':
              // 服务端工具的块：内容一次性给全，不分段。
              final Object? block = j['content_block'];
              if (block is Map) {
                final String bt = '${block['type'] ?? ''}';
                if (bt == 'server_tool_use') {
                  yield const LlmChunk(searches: 1);
                } else if (bt == 'web_search_tool_result' ||
                    bt == 'web_fetch_tool_result') {
                  final List<LlmSource> srcs = _blockSourcesOf(block);
                  if (srcs.isNotEmpty) yield LlmChunk(sources: srcs);
                } else if (bt == 'tool_use') {
                  // 客户端工具：id/name 在这里给，入参稍后分段来。
                  toolBlocks[j['index'] is int ? j['index'] as int : 0] =
                      <String, String>{
                        'id': '${block['id'] ?? ''}',
                        'name': '${block['name'] ?? ''}',
                        'arguments': '',
                      };
                }
              }
            case 'content_block_delta':
              final Object? d = j['delta'];
              if (d is Map) {
                switch ('${d['type'] ?? ''}') {
                  case 'text_delta':
                    final String t = '${d['text'] ?? ''}';
                    if (t.isNotEmpty) yield LlmChunk(textDelta: t);
                  case 'thinking_delta':
                    final String t = '${d['thinking'] ?? ''}';
                    if (t.isNotEmpty) yield LlmChunk(reasoningDelta: t);
                  case 'input_json_delta':
                    final Map<String, String>? part =
                        toolBlocks[j['index'] is int ? j['index'] as int : 0];
                    if (part != null) {
                      part['arguments'] =
                          '${part['arguments']}${d['partial_json'] ?? ''}';
                    }
                }
              }
            case 'content_block_stop':
              // 参数拼完了才交出这个工具调用。
              final Map<String, String>? done = toolBlocks.remove(
                j['index'] is int ? j['index'] as int : 0,
              );
              if (done != null && (done['name'] ?? '').isNotEmpty) {
                yield LlmChunk(
                  toolCalls: <LlmToolCall>[
                    LlmToolCall(
                      id: done['id'] ?? '',
                      name: done['name']!,
                      arguments: done['arguments'] ?? '',
                    ),
                  ],
                );
              }
            case 'message_delta':
              final LlmUsage? u = _anthropicUsage(j['usage']);
              if (u != null) yield LlmChunk(usage: u);
            case 'error':
              final Object? e = j['error'];
              final String msg = e is Map ? '${e['message'] ?? ''}' : '';
              yield LlmChunk(error: msg.isEmpty ? '流式返回了错误' : msg);
              return;
            case 'message_stop':
              return;
          }
        } catch (_) {
          // 某一块解析不了就跳过，不因为一块把整条流打断。
        }
      }
    } catch (e) {
      yield LlmChunk(error: '流断了：$e');
    } finally {
      c.close();
    }
  }

  /// 服务端工具结果块里的来源。
  static List<LlmSource> _blockSourcesOf(Map<Object?, Object?> block) {
    final Object? content = block['content'];
    final List<LlmSource> out = <LlmSource>[];
    if (content is List) {
      // web_search_tool_result：content 是结果数组。
      for (final Object? r in content) {
        if (r is! Map) continue;
        final String url = '${r['url'] ?? ''}';
        if (url.isEmpty) continue;
        out.add(LlmSource(title: '${r['title'] ?? ''}', url: url));
      }
    } else if (content is Map) {
      // web_fetch_tool_result：content 是单个对象。
      final String url = '${content['url'] ?? ''}';
      if (url.isNotEmpty) {
        final Object? doc = content['content'];
        out.add(
          LlmSource(
            title: doc is Map ? '${doc['title'] ?? ''}' : '',
            url: url,
          ),
        );
      }
    }
    return out;
  }

  /// Responses 形状的流式。
  ///
  /// 事件是第三套，跟另外两家都不一样：
  /// `response.created` / `in_progress` → `output_item.added` →
  /// `output_text.delta`… → `output_text.done` → `output_item.done` →
  /// `response.completed`（**没有** `data: [DONE]`），失败收在
  /// `response.failed` / `response.incomplete`。
  ///
  /// 文档只给了正文的 delta 事件名，没说思考增量叫什么，所以**思考不按 delta 收**，
  /// 而是等 `output_item.done` 里 `reasoning` item 的完整 `reasoning_text`——不猜。
  static Stream<LlmChunk> _streamResponses(
    Provider provider,
    String apiKey,
    LlmRequest req, {
    http.Client? client,
  }) async* {
    if (apiKey.trim().isEmpty) {
      yield const LlmChunk(error: '这个服务商还没填 API Key');
      return;
    }

    final Uri uri = Uri.parse(provider.endpoint);
    final String payload = jsonEncode(<String, Object?>{
      ...req.toResponsesJson(),
      'stream': true,
    });

    final http.Client c = client ?? NetworkRuntime.newClient();
    // 正文是否已经通过 delta 收到过：没有就退回整份 result 取。
    final StringBuffer seenText = StringBuffer();
    try {
      final http.Request r = http.Request('POST', uri)
        ..headers.addAll(<String, String>{
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        })
        ..body = payload;

      final http.StreamedResponse res = await c.send(r);
      if (res.statusCode != 200) {
        final String body = await res.stream.bytesToString();
        yield LlmChunk(error: _messageFor(res.statusCode, body));
        return;
      }

      await for (final String line in res.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (!line.startsWith('data:')) continue;
        final String data = line.substring(5).trim();
        if (data.isEmpty) continue;

        Object? j;
        try {
          j = jsonDecode(data);
        } catch (_) {
          continue;
        }
        if (j is! Map) continue;

        switch ('${j['type'] ?? ''}') {
          case 'response.output_text.delta':
            final String d = '${j['delta'] ?? ''}';
            if (d.isNotEmpty) {
              seenText.write(d);
              yield LlmChunk(textDelta: d);
            }
          case 'response.output_item.done':
            for (final LlmChunk chunk in _chunksOfOutputItem(j['item'])) {
              yield chunk;
            }
          case 'response.completed':
            final Object? resp = j['response'];
            if (resp is Map) {
              final LlmUsage? u = _responsesUsage(resp['usage']);
              if (u != null) yield LlmChunk(usage: u);
              // 没收到过任何正文增量时，退回整份结果取一次。
              if (seenText.isEmpty) {
                final LlmReply parsed = _parseResponses(jsonEncode(resp));
                if (parsed.text.isNotEmpty) {
                  yield LlmChunk(textDelta: parsed.text);
                }
              }
            }
            return;
          case 'response.incomplete':
            final Object? resp = j['response'];
            if (resp is Map) {
              final LlmUsage? u = _responsesUsage(resp['usage']);
              if (u != null) yield LlmChunk(usage: u);
            }
            return;
          case 'response.failed':
            final Object? resp = j['response'];
            final Object? e = resp is Map ? resp['error'] : null;
            final String msg = e is Map ? '${e['message'] ?? ''}' : '';
            yield LlmChunk(error: msg.isEmpty ? '生成失败' : msg);
            return;
        }
      }
    } catch (e) {
      yield LlmChunk(error: '流断了：$e');
    } finally {
      c.close();
    }
  }

  /// 一个 `output_item.done` 里能交出来的东西。
  ///
  /// `reasoning` 给思维链，`function_call` 给客户端工具调用，
  /// `web_search_call` 给搜索次数与来源。
  static Iterable<LlmChunk> _chunksOfOutputItem(Object? item) sync* {
    if (item is! Map) return;
    switch ('${item['type'] ?? ''}') {
      case 'reasoning':
        for (final Object? p in _listOf(item['content'])) {
          if (p is Map && '${p['type']}' == 'reasoning_text') {
            final String t = '${p['text'] ?? ''}';
            if (t.isNotEmpty) yield LlmChunk(reasoningDelta: t);
          }
        }
      case 'function_call':
        final String fn = '${item['name'] ?? ''}';
        if (fn.isNotEmpty) {
          yield LlmChunk(
            toolCalls: <LlmToolCall>[
              LlmToolCall(
                id: '${item['call_id'] ?? ''}',
                name: fn,
                arguments: '${item['arguments'] ?? ''}',
              ),
            ],
          );
        }
      case 'web_search_call':
        final List<LlmSource> srcs = <LlmSource>[];
        final Object? action = item['action'];
        if (action is Map) {
          for (final Object? s in _listOf(action['sources'])) {
            if (s is! Map) continue;
            final String url = '${s['url'] ?? ''}';
            if (url.isEmpty) continue;
            srcs.add(LlmSource(title: '${s['title'] ?? ''}', url: url));
          }
        }
        yield LlmChunk(searches: 1, sources: srcs);
    }
  }

  /// 这个服务商走的是不是 Anthropic 形状。
  ///
  /// 只在 DeepSeek 内部用：DeepSeek 自己有两种端点。
  static bool _isAnthropic(Provider p) =>
      p.protocol.wire == Wire.anthropic;

  /// 请求体。按 DeepSeek 自己的两种形状分流。
  static Map<String, Object?> _body(Provider provider, LlmRequest req) =>
      _isAnthropic(provider) ? req.toAnthropicJson() : req.toJson();

  /// 内置搜索的形状得跟协议对得上，否则发了也是无效参数。
  ///
  /// 返回 [BuiltinSearch.none] 表示没问题；否则是要报的那个形状。
  static BuiltinSearch _builtinSearchError(Provider p, LlmRequest req) {
    if (req.webSearch == BuiltinSearch.none) return BuiltinSearch.none;
    if (req.webSearch == BuiltinSearch.anthropic && !_isAnthropic(p)) {
      return BuiltinSearch.anthropic;
    }
    if (req.webSearch == BuiltinSearch.mimo && !_isAnthropic(p)) {
      return BuiltinSearch.mimo;
    }
    return BuiltinSearch.none;
  }

  static String _builtinSearchMessage(BuiltinSearch which) {
    if (which == BuiltinSearch.anthropic) {
      return 'Anthropic 的内置搜索只能用在 Anthropic 格式的服务商上';
    }
    return 'MiMo 的内置搜索只在 OpenAI 格式（chat/completions）下支持';
  }

  /// Chat Completions 形状的响应。字段名照 DeepSeek 的文档。
  static LlmReply _parseOpenAi(String body) {
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
      // 引用来源。Chat Completions 把 url/title 包在 `url_citation` 里，
      // 平铺写法也兼容（MiMo 那种）。
      final List<LlmSource> sources = _sourcesOf(msg['annotations']);
      return LlmReply(
        text: text,
        reasoning: rc is String && rc.isNotEmpty ? rc : null,
        usage: _usageOf(j['usage']),
        sources: sources,
        toolCalls: _toolCallsOf(msg['tool_calls']),
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
            // 服务端工具（联网搜索/阅读链接）：服务端自己执行，我们只计数。
            searches++;
          case 'tool_use':
            // 客户端工具：模型在等我们执行。入参是**对象**，统一成 JSON 字符串。
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
                  LlmSource(title: '${r['title'] ?? ''}', url: '${r['url'] ?? ''}'),
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
  static List<LlmToolCall> _toolCallsOf(Object? raw) {    if (raw is! List) return const <LlmToolCall>[];
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

  /// 引用来源（`annotations` 里的 `url_citation`）。
  ///
  /// Chat Completions 的形状是把 url/title **包在** `url_citation` 里；
  /// 平铺写法（MiMo 那种）也一并认，免得换一家就解析不出来。
  static List<LlmSource> _sourcesOf(Object? ann) {
    if (ann is! List) return const <LlmSource>[];
    final List<LlmSource> out = <LlmSource>[];
    for (final Object? a in ann) {
      if (a is! Map) continue;
      if ('${a['type']}' != 'url_citation') continue;
      final Object? inner = a['url_citation'];
      final Map<Object?, Object?> m = inner is Map ? inner : a;
      final String url = '${m['url'] ?? a['url'] ?? ''}';
      if (url.isEmpty) continue;
      out.add(LlmSource(title: '${m['title'] ?? a['title'] ?? ''}', url: url));
    }
    return out;
  }

  /// `server_tool_calls` 里实际发起过几次服务端工具调用。
  ///
  /// 结构是“一步一层”：`[{index, reasoning_content, calls: [...]}]`。
  static int _searchCountOf(Object? raw) {
    if (raw is! List) return 0;
    int n = 0;
    for (final Object? step in raw) {
      if (step is! Map) continue;
      final Object? calls = step['calls'];
      if (calls is! List) continue;
      for (final Object? c in calls) {
        if (c is! Map) continue;
        final String type = '${c['type'] ?? ''}';
        if (type == 'deepseek_web_search' || type == 'deepseek_read_url') n++;
      }
    }
    return n;
  }

  /// 把流式的 `delta.tool_calls` 片段按 `index` 归并。
  ///
  /// 官方 schema 是 `ChatCompletionMessageToolCallChunk`：只有 `index` 必填，
  /// `id` 与 `function.name` 在首片给，`arguments` 逐片拼。
  static void _collectToolCallDeltas(
    Object? raw,
    Map<int, Map<String, String>> pending,
  ) {
    if (raw is! List) return;
    for (final Object? tc in raw) {
      if (tc is! Map) continue;
      final int index = tc['index'] is int ? tc['index'] as int : 0;
      final Map<String, String> part = pending.putIfAbsent(
        index,
        () => <String, String>{'id': '', 'name': '', 'arguments': ''},
      );
      if (tc['id'] is String) part['id'] = tc['id'] as String;
      final Object? fn = tc['function'];
      if (fn is Map) {
        if (fn['name'] is String) part['name'] = fn['name'] as String;
        if (fn['arguments'] is String) {
          part['arguments'] = '${part['arguments']}${fn['arguments'] as String}';
        }
      }
    }
  }

  /// 错误码 → 人话。照 `适配.md` 那张表。
  ///
  /// **402 是 DeepSeek 自己的说法**（余额不足），OpenAI 那边没这一条 ——
  /// 所以这张表写在本文件里，不进通用层。
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
}
