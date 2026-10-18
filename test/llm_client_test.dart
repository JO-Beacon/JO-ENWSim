// 调用层的两种“形状”。
//
// DeepSeek 同时提供 OpenAI 形状（/chat/completions）和 Anthropic 形状
// （/anthropic/messages）。两者**请求体不一样**：
//   · OpenAI：system 是 messages 里一条；`tools` 只收 function。
//   · Anthropic：system 是顶层参数；max_tokens 必填；内置搜索是 `tools` 里
//     一个 server tool；响应 content 是一组块而不是一个字符串。
//
// 文档：AGENTS/docs-deepseek/chat-completion.md、guide-anthropic.md

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:joenws/model/llm_client.dart';
import 'package:joenws/model/provider.dart';

http.Response json(String body, int code) => http.Response(
  body,
  code,
  headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
);

const Provider openaiWire = Provider(
  id: 'a',
  protocol: Protocol.deepseek,
  name: 'DeepSeek',
  apiKey: 'sk-test',
);

const Provider anthropicWire = Provider(
  id: 'b',
  protocol: Protocol.deepseekAnthropic,
  name: 'DeepSeek · Anthropic',
  apiKey: 'sk-test',
);

void main() {
  test('OpenAI 形状：system 拼进 messages，不加 tools', () {
    final LlmRequest req = const LlmRequest(
      model: 'deepseek-flash',
      system: '你是旁白',
      messages: <LlmMessage>[LlmMessage('user', '开始')],
      maxTokens: 100,
    );
    final Map<String, Object?> body = req.toJson();
    final List<Object?> msgs = body['messages']! as List<Object?>;
    expect((msgs.first! as Map<Object?, Object?>)['role'], 'system');
    expect((msgs.first! as Map<Object?, Object?>)['content'], '你是旁白');
    expect(body.containsKey('tools'), isFalse);
  });

  test('Anthropic 形状：system 顶层、max_tokens 必填、内置搜索是 server tool', () {
    const LlmRequest req = LlmRequest(
      model: 'deepseek-flash',
      system: '你是旁白',
      messages: <LlmMessage>[LlmMessage('user', '开始')],
      webSearch: BuiltinSearch.anthropic,
    );
    final Map<String, Object?> body = req.toAnthropicJson();

    expect(body['system'], '你是旁白');
    expect(body['max_tokens'], isA<int>()); // 必填，没传也要有
    final List<Object?> msgs = body['messages']! as List<Object?>;
    expect(msgs, hasLength(1)); // system 不混进 messages
    final Map<Object?, Object?> m = msgs.first! as Map<Object?, Object?>;
    expect(m['role'], 'user');
    expect((m['content']! as List<Object?>).first, <String, Object?>{
      'type': 'text',
      'text': '开始',
    });

    final List<Object?> tools = body['tools']! as List<Object?>;
    expect(tools, hasLength(1));
    final Map<Object?, Object?> tool = tools.first! as Map<Object?, Object?>;
    expect(tool['name'], 'web_search');
    expect('${tool['type']}', startsWith('web_search'));
    expect(
      tool.containsKey('input_schema'),
      isFalse,
    ); // server tool 不是 function
  });

  test('Anthropic：不发内置搜索时就没有 tools', () {
    const LlmRequest req = LlmRequest(
      model: 'deepseek-flash',
      messages: <LlmMessage>[LlmMessage('user', 'hi')],
    );
    expect(req.toAnthropicJson().containsKey('tools'), isFalse);
  });

  test('Anthropic：走 x-api-key，不是 Bearer', () async {
    late http.Request seen;
    final MockClient c = MockClient((http.Request r) async {
      seen = r;
      return json('{"content":[{"type":"text","text":"好"}]}', 200);
    });

    await LlmClient.send(
      anthropicWire,
      'sk-test',
      const LlmRequest(
        model: 'deepseek-flash',
        messages: <LlmMessage>[LlmMessage('user', 'hi')],
      ),
      client: c,
    );

    expect(seen.url.toString(), 'https://api.deepseek.com/anthropic/messages');
    expect(seen.headers['x-api-key'], 'sk-test');
    expect(seen.headers.containsKey('Authorization'), isFalse);
  });

  test('Anthropic：解析 content 块 —— 正文、思维链、来源、搜索次数', () async {
    final MockClient c = MockClient(
      (http.Request r) async => json('''
{
  "content": [
    {"type": "thinking", "thinking": "先想一下"},
    {"type": "server_tool_use", "id": "srvtoolu_1", "name": "web_search",
     "input": {"query": "deepseek v4"}},
    {"type": "web_search_tool_result", "tool_use_id": "srvtoolu_1",
     "content": [
       {"type": "web_search_result", "title": "V4 发布", "url": "https://a.example/1"},
       {"type": "web_search_result", "title": "评测", "url": "https://a.example/2"}
     ]},
    {"type": "text", "text": "结论"},
    {"type": "text", "text": "。"}
  ],
  "usage": {"input_tokens": 11, "output_tokens": 22,
            "cache_read_input_tokens": 7, "cache_creation_input_tokens": 3}
}
''', 200),
    );

    final LlmReply r = await LlmClient.send(
      anthropicWire,
      'sk-test',
      const LlmRequest(
        model: 'deepseek-flash',
        messages: <LlmMessage>[LlmMessage('user', 'hi')],
        webSearch: BuiltinSearch.anthropic,
      ),
      client: c,
    );

    expect(r.ok, isTrue, reason: r.error);
    expect(r.text, '结论。');
    expect(r.reasoning, '先想一下');
    expect(r.searches, 1);
    expect(r.sources, hasLength(2));
    expect(r.sources.first.title, 'V4 发布');
    expect(r.sources.first.url, 'https://a.example/1');
    expect(r.usage!.input, 11);
    expect(r.usage!.output, 22);
    expect(r.usage!.cacheHit, 7);
    expect(r.usage!.cacheMiss, 3);
  });

  test('OpenAI 形状开内置搜索：直接拒绝，不发请求', () async {
    int calls = 0;
    final MockClient c = MockClient((http.Request r) async {
      calls++;
      return json('{}', 200);
    });

    final LlmReply r = await LlmClient.send(
      openaiWire,
      'sk-test',
      const LlmRequest(
        model: 'deepseek-flash',
        messages: <LlmMessage>[LlmMessage('user', 'hi')],
        webSearch: BuiltinSearch.anthropic,
      ),
      client: c,
    );

    expect(r.ok, isFalse);
    expect(r.error, contains('Anthropic'));
    expect(calls, 0);
  });

  test('OpenAI 形状仍按老样子解析', () async {
    final MockClient c = MockClient(
      (http.Request r) async => json(
        '{"choices":[{"message":{"content":"好","reasoning_content":"想"}}],'
        '"usage":{"prompt_tokens":5,"completion_tokens":6,'
        '"prompt_cache_hit_tokens":1,"prompt_cache_miss_tokens":4}}',
        200,
      ),
    );

    final LlmReply r = await LlmClient.send(
      openaiWire,
      'sk-test',
      const LlmRequest(
        model: 'deepseek-flash',
        messages: <LlmMessage>[LlmMessage('user', 'hi')],
      ),
      client: c,
    );
    expect(r.text, '好');
    expect(r.reasoning, '想');
    expect(r.usage!.cacheHit, 1);
    expect(r.sources, isEmpty);
  });

  // ————————————————————————————— 小米 MiMo

  const Provider mimo = Provider(
    id: 'mimo',
    protocol: Protocol.openaiCompatible,
    name: '小米 MiMo',
    apiKey: 'sk-mimo',
    baseUrl: 'https://api.xiaomimimo.com/v1',
    apiPath: '/chat/completions',
  );

  const Provider mimoAnthropic = Provider(
    id: 'mimo-a',
    protocol: Protocol.anthropicCompatible,
    name: '小米 MiMo · Anthropic',
    apiKey: 'sk-mimo',
    baseUrl: 'https://api.xiaomimimo.com/anthropic',
    apiPath: '/messages',
  );

  test('MiMo：内置搜索是 OpenAI 形状的 web_search 工具', () {
    expect(mimo.builtinSearchShape, BuiltinSearch.mimo);
    const LlmRequest req = LlmRequest(
      model: 'mimo-v2.6-pro',
      messages: <LlmMessage>[LlmMessage('user', '武汉明天天气')],
      webSearch: BuiltinSearch.mimo,
    );
    final Map<String, Object?> body = req.toJson();
    final List<Object?> tools = body['tools']! as List<Object?>;
    final Map<Object?, Object?> tool = tools.first! as Map<Object?, Object?>;
    expect(tool['type'], 'web_search');
    // 文档里用来控成本的三个参数。
    expect(tool['max_keyword'], isA<int>());
    expect(tool['force_search'], isA<bool>());
    expect(tool['limit'], isA<int>());
    // server tool，不是我们定义的 function。
    expect(tool.containsKey('input_schema'), isFalse);
    expect(body['tool_choice'], 'auto');
  });

  test('MiMo：发到自己的地址（baseUrl + apiPath，不是协议默认）', () async {
    late http.Request seen;
    final MockClient c = MockClient((http.Request r) async {
      seen = r;
      return json('{"choices":[{"message":{"content":"好"}}]}', 200);
    });

    await LlmClient.send(
      mimo,
      'sk-mimo',
      const LlmRequest(
        model: 'mimo-v2.6-pro',
        messages: <LlmMessage>[LlmMessage('user', 'hi')],
      ),
      client: c,
    );

    expect(
      seen.url.toString(),
      'https://api.xiaomimimo.com/v1/chat/completions',
    );
    expect(seen.headers['Authorization'], 'Bearer sk-mimo');
  });

  test('MiMo：搜索来源在 annotations 里，要能解析出来', () async {
    final MockClient c = MockClient(
      (http.Request r) async => json('''
{"choices":[{"message":{"role":"assistant","content":"明天阴",
  "annotations":[
    {"type":"url_citation","url":"https://a.example/1","title":"天气1",
     "summary":"摘要","site_name":"中国天气网"},
    {"type":"other","url":"https://a.example/2","title":"别的"},
    {"type":"url_citation","url":"https://a.example/3","title":"天气3"}
  ],"tool_calls":null}}],
 "usage":{"prompt_tokens":9,"completion_tokens":10}}
''', 200),
    );

    final LlmReply r = await LlmClient.send(
      mimo,
      'sk-mimo',
      const LlmRequest(
        model: 'mimo-v2.6-pro',
        messages: <LlmMessage>[LlmMessage('user', '武汉明天天气')],
        webSearch: BuiltinSearch.mimo,
      ),
      client: c,
    );

    expect(r.ok, isTrue, reason: r.error);
    expect(r.text, '明天阴');
    // 只取 url_citation，其他类型的 annotations 不当作来源。
    expect(r.sources, hasLength(2));
    expect(r.sources.first.title, '天气1');
    expect(r.sources.first.url, 'https://a.example/1');
  });

  test('MiMo 的内置搜索配 Anthropic 格式：直说用不了，不发请求', () async {
    int calls = 0;
    final MockClient c = MockClient((http.Request r) async {
      calls++;
      return json('{}', 200);
    });

    final LlmReply r = await LlmClient.send(
      mimoAnthropic,
      'sk-mimo',
      const LlmRequest(
        model: 'mimo-v2.6-pro',
        messages: <LlmMessage>[LlmMessage('user', 'hi')],
        webSearch: BuiltinSearch.mimo,
      ),
      client: c,
    );

    expect(r.ok, isFalse);
    expect(r.error, contains('MiMo'));
    expect(calls, 0);
  });

  test('形状按地址认：MiMo 是 mimo，DeepSeek 的 Anthropic 是 anthropic', () {
    expect(mimo.builtinSearchShape, BuiltinSearch.mimo);
    expect(
      const Provider(
        id: 'd',
        protocol: Protocol.deepseek,
        name: 'DeepSeek',
        baseUrl: 'https://api.deepseek.com',
      ).builtinSearchShape,
      BuiltinSearch.none,
    );
    expect(anthropicWire.builtinSearchShape, BuiltinSearch.anthropic);
  });
}
