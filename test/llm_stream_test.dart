// 流式：两种形状各自怎么收。
//
// 重点不是“能不能流”，是**服务端工具的结果会不会丢**：
//   · Chat Completions 形状：`server_tool_calls` / `annotations` 只在带 finish_reason
//     的最后一块里发一次；
//   · Anthropic 形状：结果是 `content_block_start` 里一次性给全的，
//     用量只认最后的 `message_delta.usage`。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:joenws/model/llm_client.dart';
import 'package:joenws/model/provider.dart';

const Provider _openai = Provider(
  id: 'd',
  protocol: Protocol.deepseek,
  name: 'DeepSeek',
  apiKey: 'sk',
);

const Provider _anthropic = Provider(
  id: 'da',
  protocol: Protocol.deepseekAnthropic,
  name: 'DeepSeek · Anthropic',
  apiKey: 'sk',
);

// 必须带 charset：http 包不写时按 latin1 编码请求/响应体，中文会抛。
http.Response sse(String body) => http.Response(
  body,
  200,
  headers: <String, String>{'content-type': 'text/event-stream; charset=utf-8'},
);

const LlmRequest _req = LlmRequest(
  model: 'deepseek-flash',
  messages: <LlmMessage>[LlmMessage('user', 'hi')],
);

void main() {
  group('Chat Completions 形状', () {
    test('正文与思考按字段分流', () async {
      final MockClient c = MockClient(
        (http.Request r) async => sse(
          'data: {"choices":[{"delta":{"reasoning_content":"先想"}}]}\n\n'
          'data: {"choices":[{"delta":{"content":"结论"}}]}\n\n'
          'data: [DONE]\n\n',
        ),
      );
      final List<LlmChunk> chunks = await LlmClient.stream(
        _openai,
        'sk-test',
        _req,
        client: c,
      ).toList();

      expect(
        chunks
            .where((LlmChunk c) => c.error != null)
            .map((LlmChunk c) => c.error)
            .toList(),
        isEmpty,
      );
      expect(chunks.map((LlmChunk c) => c.reasoningDelta).join(), '先想');
      expect(chunks.map((LlmChunk c) => c.textDelta).join(), '结论');
    });

    test('最后一块里的 server_tool_calls 与 annotations 不会丢', () async {
      // SSE 是一行一个 data:，所以 JSON 必须整行写完。
      final MockClient c = MockClient(
        (http.Request r) async => sse(
          'data: {"choices":[{"delta":{"content":"答案"}}]}\n\n'
          'data: {"choices":[{"finish_reason":"stop","delta":'
          '{"annotations":[{"type":"url_citation","url_citation":'
          '{"url":"https://a.example/1","title":"来源一"}}],'
          '"server_tool_calls":['
          '{"index":0,"calls":[{"type":"deepseek_web_search","kind":"search",'
          '"action":{"type":"search","queries":["q"]}}]},'
          '{"index":1,"calls":[{"type":"deepseek_read_url","kind":"read_link",'
          '"action":{"type":"read_link","url":"https://a.example/1"}}]}]}}],'
          '"usage":{"prompt_tokens":10,"completion_tokens":5}}\n\n'
          'data: [DONE]\n\n',
        ),
      );
      final List<LlmChunk> chunks = await LlmClient.stream(
        _openai,
        'sk-test',
        _req,
        client: c,
      ).toList();

      expect(chunks.map((LlmChunk c) => c.textDelta).join(), '答案');
      final List<LlmSource> sources = <LlmSource>[
        for (final LlmChunk c in chunks) ...c.sources,
      ];
      expect(sources, hasLength(1));
      expect(sources.first.title, '来源一');
      expect(sources.first.url, 'https://a.example/1');
      // 两次服务端工具调用。
      expect(chunks.fold<int>(0, (int n, LlmChunk c) => n + c.searches), 2);
    });
  });

  group('Anthropic 形状', () {
    test('思考、正文、用量都收到', () async {
      final MockClient c = MockClient(
        (http.Request r) async => sse(r'''
event: message_start
data: {"type":"message_start","message":{"usage":{"input_tokens":1}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"先想"}}

event: content_block_start
data: {"type":"content_block_start","index":1,"content_block":{"type":"text"}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"结论"}}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"input_tokens":11,"output_tokens":22,"cache_read_input_tokens":7,"cache_creation_input_tokens":0}}

event: message_stop
data: {"type":"message_stop"}

'''),
      );
      final List<LlmChunk> chunks = await LlmClient.stream(
        _anthropic,
        'sk-test',
        _req,
        client: c,
      ).toList();

      expect(chunks.map((LlmChunk c) => c.reasoningDelta).join(), '先想');
      expect(chunks.map((LlmChunk c) => c.textDelta).join(), '结论');
      final LlmUsage usage = chunks.lastWhere((LlmChunk c) => c.usage != null).usage!;
      // 只认 message_delta 的用量，不与 message_start 相加。
      expect(usage.input, 11);
      expect(usage.output, 22);
      expect(usage.cacheHit, 7);
    });

    test('服务端工具结果块一次性给出，来源和次数都收到', () async {
      final MockClient c = MockClient(
        (http.Request r) async => sse(r'''
event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"s1","name":"deepseek_web_search","input":{"action":"search"}}}

event: content_block_start
data: {"type":"content_block_start","index":1,"content_block":{"type":"web_search_tool_result","tool_use_id":"s1","content":[{"type":"web_search_result","title":"来源一","url":"https://a.example/1"},{"type":"web_search_result","title":"来源二","url":"https://a.example/2"}]}}

event: content_block_delta
data: {"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"答"}}

event: message_stop
data: {"type":"message_stop"}

'''),
      );
      final List<LlmChunk> chunks = await LlmClient.stream(
        _anthropic,
        'sk-test',
        _req,
        client: c,
      ).toList();

      final List<LlmSource> sources = <LlmSource>[
        for (final LlmChunk c in chunks) ...c.sources,
      ];
      expect(sources, hasLength(2));
      expect(sources.last.url, 'https://a.example/2');
      expect(chunks.fold<int>(0, (int n, LlmChunk c) => n + c.searches), 1);
    });

    test('只声明服务端工具时能流式', () async {
      final MockClient c = MockClient(
        (http.Request r) async =>
            sse('data: {"type":"message_stop"}\n\n'),
      );
      final List<LlmChunk> chunks = await LlmClient.stream(
        _anthropic,
        'sk-test',
        const LlmRequest(
          model: 'deepseek-flash',
          messages: <LlmMessage>[LlmMessage('user', 'hi')],
          tools: <LlmTool>[LlmTool.webSearch()],
        ),
        client: c,
      ).toList();
      expect(chunks.every((LlmChunk c) => c.error == null), isTrue);
    });

    test('客户端工具：input_json_delta 拼完再解析', () async {
      final MockClient c = MockClient(
        (http.Request r) async => sse(
          'event: content_block_start\n'
          'data: {"type":"content_block_start","index":1,"content_block":'
          '{"type":"tool_use","id":"toolu_1","name":"get_weather","input":{}}}\n\n'
          'event: content_block_delta\n'
          'data: {"type":"content_block_delta","index":1,"delta":'
          '{"type":"input_json_delta","partial_json":"{\\"city\\":"}}\n\n'
          'event: content_block_delta\n'
          'data: {"type":"content_block_delta","index":1,"delta":'
          '{"type":"input_json_delta","partial_json":"\\"武汉\\"}"}}\n\n'
          'event: content_block_stop\n'
          'data: {"type":"content_block_stop","index":1}\n\n'
          'event: message_stop\n'
          'data: {"type":"message_stop"}\n\n',
        ),
      );
      final List<LlmChunk> chunks = await LlmClient.stream(
        _anthropic,
        'sk-test',
        const LlmRequest(
          model: 'deepseek-flash',
          messages: <LlmMessage>[LlmMessage('user', 'hi')],
          tools: <LlmTool>[LlmTool.function(name: 'get_weather')],
        ),
        client: c,
      ).toList();

      final List<LlmToolCall> calls = <LlmToolCall>[
        for (final LlmChunk c in chunks) ...c.toolCalls,
      ];
      expect(calls, hasLength(1));
      expect(calls.first.id, 'toolu_1');
      expect(calls.first.name, 'get_weather');
      expect(jsonDecode(calls.first.arguments)['city'], '武汉');
    });
  });

  group('OpenAI 客户端工具流式', () {
    test('tool_calls 分片按 index 拼成一次调用', () async {
      final MockClient c = MockClient(
        (http.Request r) async => sse(
          'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1",'
          '"type":"function","function":{"name":"get_weather",'
          '"arguments":"{\\"city\\":"}}]}}]}\n\n'
          'data: {"choices":[{"delta":{"tool_calls":[{"index":0,'
          '"function":{"arguments":"\\"武汉\\"}"}}]}}]}\n\n'
          'data: [DONE]\n\n',
        ),
      );
      final List<LlmChunk> chunks = await LlmClient.stream(
        _openai,
        'sk-test',
        const LlmRequest(
          model: 'deepseek-flash',
          messages: <LlmMessage>[LlmMessage('user', 'hi')],
          tools: <LlmTool>[LlmTool.function(name: 'get_weather')],
        ),
        client: c,
      ).toList();

      final List<LlmToolCall> calls = <LlmToolCall>[
        for (final LlmChunk c in chunks) ...c.toolCalls,
      ];
      expect(calls, hasLength(1));
      expect(calls.first.id, 'call_1');
      expect(calls.first.name, 'get_weather');
      expect(jsonDecode(calls.first.arguments)['city'], '武汉');
    });
  });
}
