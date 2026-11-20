// 工具声明与工具调用。
//
// 两种工具的写法按协议不同，这是官方文档明确分开的：
//   · Chat Completions 形状（chat/completions、responses）：服务端工具 `{"type":"deepseek_web_search"}`
//   · Anthropic 形状（/messages）：服务端工具 `{"type":"deepseek_web_search","name":"deepseek_web_search"}`
// 客户端工具反过来：OpenAI 要包在 function 里，Anthropic 不传 type、用 input_schema。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:joenws/engine/agents/llm_agent_runner.dart';
import 'package:joenws/engine/perception.dart';
import 'package:joenws/model/llm_client.dart';
import 'package:joenws/model/provider.dart';

http.Response json(String body, int code) => http.Response(
  body,
  code,
  headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
);

const Provider _deepseek = Provider(
  id: 'd',
  protocol: Protocol.deepseek,
  name: 'DeepSeek',
  apiKey: 'sk',
);

const Provider _deepseekAnthropic = Provider(
  id: 'da',
  protocol: Protocol.deepseekAnthropic,
  name: 'DeepSeek · Anthropic',
  apiKey: 'sk',
);

void main() {
  group('工具声明', () {
    test('OpenAI：function 工具包在 function 里', () {
      const LlmRequest req = LlmRequest(
        model: 'deepseek-flash',
        messages: <LlmMessage>[LlmMessage('user', 'hi')],
        tools: <LlmTool>[
          LlmTool.function(
            name: 'get_weather',
            description: '查天气',
            parameters: <String, Object?>{'type': 'object'},
          ),
        ],
      );
      final List<Object?> tools = req.toJson()['tools']! as List<Object?>;
      final Map<Object?, Object?> t = tools.first! as Map<Object?, Object?>;
      expect(t['type'], 'function');
      final Map<Object?, Object?> fn = t['function']! as Map<Object?, Object?>;
      expect(fn['name'], 'get_weather');
      expect(fn['description'], '查天气');
      expect(fn['parameters'], <String, Object?>{'type': 'object'});
    });

    test('OpenAI：服务端工具只写 type，不带 name', () {
      const LlmRequest req = LlmRequest(
        model: 'deepseek-flash',
        messages: <LlmMessage>[LlmMessage('user', 'hi')],
        tools: <LlmTool>[LlmTool.webSearch(), LlmTool.readUrl()],
      );
      final List<Object?> tools = req.toJson()['tools']! as List<Object?>;
      expect(tools, hasLength(2));
      expect(tools[0], <String, Object?>{'type': 'deepseek_web_search'});
      expect(tools[1], <String, Object?>{'type': 'deepseek_read_url'});
    });

    test('Anthropic：服务端工具要带 name', () {
      const LlmRequest req = LlmRequest(
        model: 'deepseek-flash',
        messages: <LlmMessage>[LlmMessage('user', 'hi')],
        tools: <LlmTool>[LlmTool.webSearch()],
      );
      final List<Object?> tools =
          req.toAnthropicJson()['tools']! as List<Object?>;
      expect(tools.first, <String, Object?>{
        'type': 'deepseek_web_search',
        'name': 'deepseek_web_search',
      });
    });

    test('Anthropic：function 工具不传 type，用 input_schema', () {
      const LlmRequest req = LlmRequest(
        model: 'deepseek-flash',
        messages: <LlmMessage>[LlmMessage('user', 'hi')],
        tools: <LlmTool>[
          LlmTool.function(
            name: 'get_weather',
            description: '查天气',
            parameters: <String, Object?>{'type': 'object'},
          ),
        ],
      );
      final List<Object?> tools =
          req.toAnthropicJson()['tools']! as List<Object?>;
      final Map<Object?, Object?> t = tools.first! as Map<Object?, Object?>;
      expect(t.containsKey('type'), isFalse);
      expect(t['name'], 'get_weather');
      expect(t['input_schema'], <String, Object?>{'type': 'object'});
    });

    test('显式传了 tools 就压过旧的内置搜索开关', () {
      const LlmRequest req = LlmRequest(
        model: 'deepseek-flash',
        messages: <LlmMessage>[LlmMessage('user', 'hi')],
        webSearch: BuiltinSearch.anthropic,
        tools: <LlmTool>[LlmTool.readUrl()],
      );
      final List<Object?> tools =
          req.toAnthropicJson()['tools']! as List<Object?>;
      expect(tools, hasLength(1));
      expect(
        (tools.first! as Map<Object?, Object?>)['type'],
        'deepseek_read_url',
      );
    });
  });

  group('工具调用解析', () {
    test('OpenAI：tool_calls 解析出 id / name / 参数字符串', () async {
      final MockClient c = MockClient(
        (http.Request r) async => json(r'''
{"choices":[{"message":{"role":"assistant","content":null,
 "tool_calls":[{"id":"call_1","type":"function",
   "function":{"name":"get_weather","arguments":"{\"city\":\"武汉\"}"}}]}}]}
''', 200),
      );

      final LlmReply r = await LlmClient.send(
        _deepseek,
        'sk-test',
        const LlmRequest(
          model: 'deepseek-flash',
          messages: <LlmMessage>[LlmMessage('user', 'hi')],
          tools: <LlmTool>[LlmTool.function(name: 'get_weather')],
        ),
        client: c,
      );

      expect(r.ok, isTrue, reason: r.error);
      expect(r.toolCalls, hasLength(1));
      expect(r.toolCalls.first.id, 'call_1');
      expect(r.toolCalls.first.name, 'get_weather');
      expect(jsonDecode(r.toolCalls.first.arguments)['city'], '武汉');
    });

    test('Anthropic：tool_use 的 input 对象转成 JSON 字符串', () async {
      final MockClient c = MockClient(
        (http.Request r) async => json(r'''
{"content":[
 {"type":"tool_use","id":"toolu_1","name":"get_weather","input":{"city":"武汉"}},
 {"type":"text","text":"我去查一下"}]}
''', 200),
      );

      final LlmReply r = await LlmClient.send(
        _deepseekAnthropic,
        'sk-test',
        const LlmRequest(
          model: 'deepseek-flash',
          messages: <LlmMessage>[LlmMessage('user', 'hi')],
          tools: <LlmTool>[LlmTool.function(name: 'get_weather')],
        ),
        client: c,
      );

      expect(r.ok, isTrue, reason: r.error);
      expect(r.toolCalls, hasLength(1));
      expect(r.toolCalls.first.name, 'get_weather');
      expect(jsonDecode(r.toolCalls.first.arguments)['city'], '武汉');
      expect(r.text, '我去查一下');
    });

    test('没有工具调用时列表是空的，不影响老行为', () async {
      final MockClient c = MockClient(
        (http.Request r) async =>
            json('{"choices":[{"message":{"content":"好"}}]}', 200),
      );
      final LlmReply r = await LlmClient.send(
        _deepseek,
        'sk-test',
        const LlmRequest(
          model: 'deepseek-flash',
          messages: <LlmMessage>[LlmMessage('user', 'hi')],
        ),
        client: c,
      );
      expect(r.toolCalls, isEmpty);
      expect(r.text, '好');
    });
  });

  group('DeepSeek 内置搜索', () {
    test('开着内置搜索时，请求里声明联网搜索与阅读链接', () async {
      LlmRequest? seen;
      final LlmAgentRunner runner = LlmAgentRunner(
        provider: _deepseek,
        apiKey: 'sk-test',
        model: 'deepseek-flash',
        builtinSearch: BuiltinSearch.deepseek,
        sender: (LlmRequest r) async {
          seen = r;
          return const LlmReply(text: '{"events":[]}');
        },
      );
      await runner.environmentEvents(
        scene: NarrativeScene(
          place: '红魔馆',
          cast: <CharacterSnapshot>[
            CharacterSnapshot(id: 'char:魔理沙', name: '魔理沙', nearby: true),
          ],
          names: const <String, String>{},
        ),
        events: const <WorldEvent>[],
      );

      expect(seen!.tools, hasLength(2));
      expect(seen!.tools.first.kind, LlmToolKind.webSearch);
      expect(seen!.tools.last.kind, LlmToolKind.readUrl);
      // 走新机制之后，旧的内置搜索开关不再参与。
      expect(seen!.webSearch, BuiltinSearch.none);
    });

    test('没开内置搜索就不声明任何工具', () async {
      LlmRequest? seen;
      final LlmAgentRunner runner = LlmAgentRunner(
        provider: _deepseek,
        apiKey: 'sk-test',
        model: 'deepseek-flash',
        sender: (LlmRequest r) async {
          seen = r;
          return const LlmReply(text: '{"events":[]}');
        },
      );
      await runner.environmentEvents(
        scene: NarrativeScene(
          place: '红魔馆',
          cast: const <CharacterSnapshot>[],
          names: const <String, String>{},
        ),
        events: const <WorldEvent>[],
      );
      expect(seen!.tools, isEmpty);
    });
  });
}
