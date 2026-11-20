// 角色的“选择”怎么进请求：采样、输出上限、推理档位、流式。
//
// 这些字段以前存得下、读得回，但从来没人拿去构造 LlmRequest。
// 这个测试盯的就是那条线通没通。

import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/engine/agents/llm_agent_runner.dart';
import 'package:joenws/model/char_choices.dart';
import 'package:joenws/model/llm_client.dart';
import 'package:joenws/model/provider.dart';

const Provider _provider = Provider(
  id: 'p',
  protocol: Protocol.deepseek,
  name: 'DeepSeek',
);

LlmAgentRunner _runner({
  Map<String, CharChoices> choices = const <String, CharChoices>{},
  LlmSender? sender,
  LlmStreamSender? streamSender,
}) => LlmAgentRunner(
  provider: _provider,
  apiKey: 'sk-test',
  model: 'deepseek-flash',
  choices: choices,
  sender: sender,
  streamSender: streamSender,
);

Future<Map<String, Object?>> _act(LlmAgentRunner runner) => runner.act(
  name: '魔理沙',
  context: '在场',
  perceive: '她在场',
  present: const <String>['魔理沙'],
);

void main() {
  test('角色的采样与推理选择会进请求', () async {
    LlmRequest? seen;
    await _act(
      _runner(
        choices: <String, CharChoices>{
          '魔理沙': const CharChoices(
            temperature: '0.7',
            topP: '0.9',
            maxOutput: '300',
            effortLevel: 'high',
          ),
        },
        sender: (LlmRequest r) async {
          seen = r;
          return const LlmReply(text: '{"intent":"走"}');
        },
      ),
    );

    expect(seen!.temperature, 0.7);
    expect(seen!.topP, 0.9);
    expect(seen!.maxTokens, 300);
    expect(seen!.effort, 'high');
    // 传了档位就不再传 thinking：`thinking.type` 优先于 effort，
    // 两个都发会把档位盖掉。
    expect(seen!.thinking, isNull);
  });

  test('没设选择时这些参数一律不传', () async {
    LlmRequest? seen;
    await _act(
      _runner(
        sender: (LlmRequest r) async {
          seen = r;
          return const LlmReply(text: '{"intent":"走"}');
        },
      ),
    );

    expect(seen!.temperature, isNull);
    expect(seen!.topP, isNull);
    expect(seen!.effort, isNull);
    // 没设输出上限，就用这一步自己的默认。
    expect(seen!.maxTokens, 2048);
  });

  test('空的输出上限不会把步骤默认顶掉', () async {
    LlmRequest? seen;
    await _act(
      _runner(
        choices: <String, CharChoices>{
          '魔理沙': const CharChoices(maxOutput: '  '),
        },
        sender: (LlmRequest r) async {
          seen = r;
          return const LlmReply(text: '{"intent":"走"}');
        },
      ),
    );
    expect(seen!.maxTokens, 2048);
  });

  test('勾了流式就走流式，增量攒成完整回复', () async {
    bool streamUsed = false;
    bool sendUsed = false;
    final Map<String, Object?> out = await _act(
      _runner(
        choices: <String, CharChoices>{
          '魔理沙': const CharChoices(stream: true),
        },
        sender: (LlmRequest r) async {
          sendUsed = true;
          return const LlmReply(text: '{"intent":"错"}');
        },
        streamSender: (LlmRequest r) {
          streamUsed = true;
          return Stream<LlmChunk>.fromIterable(const <LlmChunk>[
            LlmChunk(textDelta: '{"intent"'),
            LlmChunk(textDelta: ':"走"}'),
          ]);
        },
      ),
    );

    expect(streamUsed, isTrue);
    expect(sendUsed, isFalse);
    expect(out['intent'], '走');
  });

  test('流式出错就整条作废，不拿半截文本当结果', () async {
    // 半截 JSON 不会被当成结果：它照样走重试，耗尽后交给玩家本人。
    await expectLater(
      _act(
        _runner(
          choices: <String, CharChoices>{
            '魔理沙': const CharChoices(stream: true),
          },
          streamSender: (LlmRequest r) => Stream<LlmChunk>.fromIterable(
            const <LlmChunk>[
              LlmChunk(textDelta: '{"intent":"走"'),
              LlmChunk(error: '流断了：连不上'),
            ],
          ),
        ),
      ),
      throwsA(isA<Exception>()),
    );
  });

  test('别的角色勾了流式，不影响这个角色', () async {
    bool sendUsed = false;
    await _act(
      _runner(
        choices: <String, CharChoices>{
          '慧音': const CharChoices(stream: true),
        },
        sender: (LlmRequest r) async {
          sendUsed = true;
          return const LlmReply(text: '{"intent":"走"}');
        },
      ),
    );
    expect(sendUsed, isTrue);
  });

  test('角色关掉 JSON 输出就不发 response_format', () async {
    LlmRequest? seen;
    await _act(
      _runner(
        choices: <String, CharChoices>{
          '魔理沙': const CharChoices(jsonOutput: false),
        },
        sender: (LlmRequest r) async {
          seen = r;
          return const LlmReply(text: '{"intent":"走"}');
        },
      ),
    );
    expect(seen!.jsonMode, isFalse);
  });

  test('角色开着 JSON 输出就发', () async {
    LlmRequest? seen;
    await _act(
      _runner(
        choices: <String, CharChoices>{
          '魔理沙': const CharChoices(jsonOutput: true),
        },
        sender: (LlmRequest r) async {
          seen = r;
          return const LlmReply(text: '{"intent":"走"}');
        },
      ),
    );
    expect(seen!.jsonMode, isTrue);
  });

  test('GM 步骤没有角色选择，仍然要 JSON 模式', () async {
    LlmRequest? seen;
    await _runner(
      sender: (LlmRequest r) async {
        seen = r;
        return const LlmReply(text: '{"eligible":["魔理沙"]}');
      },
    ).selectEligible(
      baseEligible: const <String>['魔理沙'],
      cast: const <String>['魔理沙'],
    );
    expect(seen!.jsonMode, isTrue);
  });

  test('默认就要 JSON，动别的项不会把它关掉', () {
    expect(const CharChoices().jsonOutput, isTrue);
    // 没存过这个字段的旧数据，读回来也应当是“要 JSON”。
    expect(CharChoices.fromJson(const <String, Object?>{}).jsonOutput, isTrue);
  });

  test('推理预算进 Anthropic 的 thinking.budget_tokens', () async {
    LlmRequest? seen;
    await _act(
      _runner(
        choices: <String, CharChoices>{
          '魔理沙': const CharChoices(effortLevel: 'high', effortBudget: '2048'),
        },
        sender: (LlmRequest r) async {
          seen = r;
          return const LlmReply(text: '{"intent":"走"}');
        },
      ),
    );
    expect(seen!.budgetTokens, 2048);
    // 设了预算就显式打开思考，否则预算没地方生效。
    expect(seen!.thinking, isTrue);
    final Map<Object?, Object?> thinking =
        seen!.toAnthropicJson()['thinking']! as Map<Object?, Object?>;
    expect(thinking['type'], 'enabled');
    expect(thinking['budget_tokens'], 2048);
  });

  test('没设预算就不发 budget_tokens', () async {
    LlmRequest? seen;
    await _act(
      _runner(
        choices: <String, CharChoices>{
          '魔理沙': const CharChoices(effortLevel: 'high'),
        },
        sender: (LlmRequest r) async {
          seen = r;
          return const LlmReply(text: '{"intent":"走"}');
        },
      ),
    );
    expect(seen!.budgetTokens, isNull);
    expect(seen!.thinking, isNull);
    expect(seen!.toAnthropicJson().containsKey('thinking'), isFalse);
  });
}
