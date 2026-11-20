// Responses API（`/responses`）的请求与解析。
//
// 它跟 Chat Completions 不是同一套字段：
//   · 输入叫 `input`（item 列表），系统提示词走 `instructions`；
//   · 输出上限叫 `max_output_tokens`；
//   · 思考在 `reasoning.effort`，JSON 模式在 `text.format`；
//   · function 工具的 name/parameters 在**工具对象顶层**，不包在 `function` 里。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:joenws/model/llm_client.dart';
import 'package:joenws/model/provider.dart';

http.Response json(String body) => http.Response(
  body,
  200,
  headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
);

const Provider _responses = Provider(
  id: 'd',
  protocol: Protocol.deepseekResponses,
  name: 'DeepSeek · Responses',
  apiKey: 'sk',
);

const LlmRequest _req = LlmRequest(
  model: 'deepseek-flash',
  system: '你是旁白',
  messages: <LlmMessage>[LlmMessage('user', 'hi')],
  maxTokens: 100,
  effort: 'high',
  jsonMode: true,
);

void main() {
  test('Responses 是并列协议：选它才走 /responses', () {
    expect(_responses.endpoint, 'https://api.deepseek.com/responses');
    expect(_responses.usesResponses, isTrue);
    // 没选它还是 chat/completions。
    const Provider chat = Provider(
      id: 'p',
      protocol: Protocol.deepseek,
      name: 'DeepSeek',
      apiKey: 'sk',
    );
    expect(chat.endpoint, 'https://api.deepseek.com/chat/completions');
    expect(chat.usesResponses, isFalse);
  });

  test('别家的协议不会走这条路', () {
    const Provider claude = Provider(
      id: 'c',
      protocol: Protocol.claude,
      name: 'Claude',
    );
    expect(claude.usesResponses, isFalse);
    expect(claude.endpoint, 'https://api.anthropic.com/v1/messages');
  });

  test('请求体按 Responses 的字段名', () {
    final Map<String, Object?> body = _req.toResponsesJson();
    expect(body['instructions'], '你是旁白');
    expect(body['max_output_tokens'], 100);
    expect(body['reasoning'], <String, Object?>{'effort': 'high'});
    expect(body['text'], <String, Object?>{
      'format': <String, Object?>{'type': 'json_object'},
    });
    final List<Object?> input = body['input']! as List<Object?>;
    expect(input, hasLength(1));
    final Map<Object?, Object?> first = input.first! as Map<Object?, Object?>;
    expect(first['role'], 'user');
    expect(first['content'], 'hi');
  });

  test('显式关思考：用 reasoning.effort = none', () {
    const LlmRequest req = LlmRequest(
      model: 'deepseek-flash',
      messages: <LlmMessage>[LlmMessage('user', 'hi')],
      thinking: false,
    );
    expect(req.toResponsesJson()['reasoning'], <String, Object?>{
      'effort': 'none',
    });
  });

  test('function 工具的字段在顶层', () {
    const LlmTool t = LlmTool.function(
      name: 'get_weather',
      description: '查天气',
      parameters: <String, Object?>{'type': 'object'},
    );
    expect(t.toResponsesJson(), <String, Object?>{
      'type': 'function',
      'name': 'get_weather',
      'description': '查天气',
      'parameters': <String, Object?>{'type': 'object'},
    });
  });

  test('服务端工具只写 type', () {
    expect(
      const LlmTool.webSearch().toResponsesJson(),
      <String, Object?>{'type': 'deepseek_web_search'},
    );
  });

  test('解析 output 数组：正文、思维链、工具调用、搜索来源、用量', () async {
    final MockClient c = MockClient(
      (http.Request r) async => json(r'''
{"status":"completed","output":[
 {"type":"reasoning","content":[{"type":"reasoning_text","text":"先想"}]},
 {"type":"message","content":[{"type":"output_text","text":"结论"}]},
 {"type":"function_call","call_id":"call_1","name":"get_weather",
  "arguments":"{\"city\":\"武汉\"}"},
 {"type":"web_search_call","action":{"type":"search",
  "sources":[{"url":"https://a.example/1","title":"来源"}]}}
],
"usage":{"input_tokens":7,"input_tokens_details":{"cached_tokens":3},
 "output_tokens":11}}
'''),
    );

    final LlmReply r = await LlmClient.send(
      _responses,
      'sk-test',
      _req,
      client: c,
    );

    expect(r.ok, isTrue, reason: r.error);
    expect(r.text, '结论');
    expect(r.reasoning, '先想');
    expect(r.toolCalls, hasLength(1));
    expect(r.toolCalls.first.id, 'call_1');
    expect(r.toolCalls.first.name, 'get_weather');
    expect(jsonDecode(r.toolCalls.first.arguments)['city'], '武汉');
    expect(r.sources, hasLength(1));
    expect(r.searches, 1);
    expect(r.usage!.input, 7);
    expect(r.usage!.cacheHit, 3);
    expect(r.usage!.cacheMiss, 4);
  });

  test('status=failed 时把错误捞出来', () async {
    final MockClient c = MockClient(
      (http.Request r) async => json(
        '{"status":"failed","error":{"code":"server_error","message":"挂了"}}',
      ),
    );
    final LlmReply r = await LlmClient.send(
      _responses,
      'sk-test',
      _req,
      client: c,
    );
    expect(r.ok, isFalse);
    expect(r.error, '挂了');
  });

  test('流式：正文增量、思考、工具调用、搜索来源、用量都收到', () async {
    final MockClient c = MockClient(
      (http.Request r) async => http.Response(
        'event: response.created\n'
        'data: {"type":"response.created","sequence_number":0}\n\n'
        'event: response.output_text.delta\n'
        'data: {"type":"response.output_text.delta","delta":"结论"}\n\n'
        'event: response.output_item.done\n'
        'data: {"type":"response.output_item.done","item":'
        '{"type":"reasoning","content":[{"type":"reasoning_text","text":"先想"}]}}\n\n'
        'event: response.output_item.done\n'
        'data: {"type":"response.output_item.done","item":'
        '{"type":"function_call","call_id":"call_1","name":"get_weather",'
        '"arguments":"{\\"city\\":\\"武汉\\"}"}}\n\n'
        'event: response.output_item.done\n'
        'data: {"type":"response.output_item.done","item":'
        '{"type":"web_search_call","action":{"type":"search",'
        '"sources":[{"url":"https://a.example/1","title":"来源"}]}}}\n\n'
        'event: response.completed\n'
        'data: {"type":"response.completed","response":{"output":[],'
        '"usage":{"input_tokens":7,"input_tokens_details":{"cached_tokens":3},'
        '"output_tokens":11}}}\n\n',
        200,
        headers: <String, String>{
          'content-type': 'text/event-stream; charset=utf-8',
        },
      ),
    );

    final List<LlmChunk> chunks = await LlmClient.stream(
      _responses,
      'sk-test',
      _req,
      client: c,
    ).toList();

    expect(chunks.map((LlmChunk c) => c.textDelta).join(), '结论');
    expect(chunks.map((LlmChunk c) => c.reasoningDelta).join(), '先想');
    final List<LlmToolCall> calls = <LlmToolCall>[
      for (final LlmChunk c in chunks) ...c.toolCalls,
    ];
    expect(calls, hasLength(1));
    expect(calls.first.name, 'get_weather');
    expect(jsonDecode(calls.first.arguments)['city'], '武汉');
    final List<LlmSource> sources = <LlmSource>[
      for (final LlmChunk c in chunks) ...c.sources,
    ];
    expect(sources, hasLength(1));
    expect(chunks.fold<int>(0, (int n, LlmChunk c) => n + c.searches), 1);
    final LlmUsage usage =
        chunks.lastWhere((LlmChunk c) => c.usage != null).usage!;
    expect(usage.input, 7);
    expect(usage.cacheHit, 3);
  });

  test('流式失败：把 error 报出来', () async {
    final MockClient c = MockClient(
      (http.Request r) async => http.Response(
        'event: response.failed\n'
        'data: {"type":"response.failed","response":{"error":{"message":"挂了"}}}\n\n',
        200,
        headers: <String, String>{
          'content-type': 'text/event-stream; charset=utf-8',
        },
      ),
    );
    final List<LlmChunk> chunks = await LlmClient.stream(
      _responses,
      'sk-test',
      _req,
      client: c,
    ).toList();
    expect(chunks.first.error, '挂了');
  });
}
