import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/engine/agents/llm_agent_runner.dart';
import 'package:joenws/engine/perception.dart';
import 'package:joenws/engine/time_label.dart';
import 'package:joenws/model/llm_client.dart';
import 'package:joenws/model/provider.dart';

const Provider _provider = Provider(
  id: 'p-test',
  protocol: Protocol.deepseekAnthropic,
  name: 'test',
);

LlmAgentRunner _runner(Future<LlmReply> Function(LlmRequest) sender) {
  return LlmAgentRunner(
    provider: _provider,
    apiKey: 'test-key',
    model: 'test-model',
    sender: sender,
  );
}

NarrativeScene _scene() {
  return NarrativeScene(
    place: '东门内侧',
    names: <String, String>{'char:信标': '信标', 'char:艾琳': '艾琳'},
    cast: <CharacterSnapshot>[
      CharacterSnapshot(
        id: 'char:信标',
        name: '信标',
        nearby: true,
        aliases: <String, String>{'char:艾琳': '联邦女人'},
      ),
      CharacterSnapshot(
        id: 'char:艾琳',
        name: '艾琳',
        nearby: true,
        aliases: <String, String>{'char:信标': '探险家'},
      ),
    ],
  );
}

void main() {
  test('时间标签：空是缺省，不是错误', () {
    expect(normalizeTimeLabel(null), '');
    expect(normalizeTimeLabel('  入夜之后 '), '入夜之后');
    expect(timeLabelError(''), isNull);
    expect(timeLabelError('入夜之后'), isNull);
    expect(timeLabelError('雨还没停的时候'), isNull);
  });

  test('时间标签：时间戳、纯数字、换行、太长都不合格', () {
    expect(timeLabelError('2026-11-18'), contains('日期'));
    expect(timeLabelError('11月18日'), contains('日期'));
    expect(timeLabelError('午后 3:20'), contains('时刻'));
    expect(timeLabelError('15：20'), contains('时刻'));
    expect(timeLabelError('1893'), contains('纯数字'));
    expect(timeLabelError('入夜\n之后'), contains('换行'));
    expect(timeLabelError('第' * 30), contains('超过'));
  });

  test('GM_ENV_UPDATE 把 time_label 写到事件上，缺省为空', () async {
    final LlmAgentRunner runner = _runner((LlmRequest req) async {
      return const LlmReply(
        text:
            '{"events":[{"content":"雨小了。","target":null,"time_label":"入夜之后",'
            '"delivery":{"channel":"other","form":"narration","audience":"scene"}},'
            '{"content":"远处起火。","target":null,'
            '"delivery":{"channel":"other","form":"narration","audience":"scene"}}]}',
      );
    });
    final List<WorldEvent> env =
        await runner.environmentEvents(scene: _scene(), events: <WorldEvent>[]);
    expect(env, hasLength(2));
    expect(env.first.timeLabel, '入夜之后');
    expect(env.last.timeLabel, '');
  });

  test('GM_ENV_UPDATE 的 time_label 写了时间戳要报错，不静默改', () async {
    final LlmAgentRunner runner = _runner((LlmRequest req) async {
      return const LlmReply(
        text:
            '{"events":[{"content":"雨小了。","target":null,"time_label":"2026-11-18 15:20",'
            '"delivery":{"channel":"other","form":"narration","audience":"scene"}}]}',
      );
    });
    await expectLater(
      runner.environmentEvents(scene: _scene(), events: <WorldEvent>[]),
      throwsA(isA<LlmAgentException>()),
    );
  });
}
