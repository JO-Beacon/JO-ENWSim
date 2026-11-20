import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/engine/agents/llm_agent_runner.dart';
import 'package:joenws/engine/turn_session.dart';
import 'package:joenws/model/llm_client.dart';
import 'package:joenws/model/model_plan.dart';
import 'package:joenws/model/provider.dart';
import 'package:joenws/theme/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'engine_turn_loop_test.dart' as fixtures;

void main() {
  test('全部 AI 步骤都有身份前缀、唯一语义名、中文名称和默认提示词', () {
    final Set<String> ids = kSteps.map((step) => step.id).toSet();
    expect(ids.length, kSteps.length);
    expect(ids, kDefaultPrompts.keys.toSet());
    for (final step in kSteps) {
      expect(step.id, matches(RegExp(r'^(GM|CH)_[A-Z]+(?:_[A-Z]+)*$')));
      expect(step.title, isNotEmpty);
      expect(StepId.label(step.id), '${step.id} · ${step.title}');
      expect(kDefaultPromptOf(step.id), isNotEmpty);
    }
    expect(StepId.gmParseInput, 'GM_PARSE_INPUT');
    expect(StepId.title('${StepId.chPerceive}:慧音'), '角色感知');
  });

  test('在场名单和行动资格分别读取模型与提示词，恢复日志独立', () async {
    final TurnJournal journal = TurnJournal();
    final List<String> chosenSteps = [];
    final List<LlmRequest> requests = [];
    const Provider provider = Provider(id: 'steps', name: 'steps', protocol: Protocol.deepseekAnthropic);
    final LlmAgentRunner runner = LlmAgentRunner(
      provider: provider, apiKey: 'unused', model: 'default', journal: journal,
      prompts: const {StepId.gmCast: 'CAST_INSTRUCTION', StepId.gmEligibility: 'ELIGIBILITY_INSTRUCTION'},
      modelResolver: (step, {focus = ''}) {
        chosenSteps.add(step);
        return (provider: provider, model: 'model-$step');
      },
      sender: (request) async {
        requests.add(request);
        return const LlmReply(text: '{"cast":["慧音"],"eligible":["慧音"]}');
      },
    );
    await runner.decideCast(scene: fixtures.buildScene(), knownCast: ['慧音']);
    await runner.selectEligible(baseEligible: ['慧音'], cast: ['慧音']);
    expect(chosenSteps, [StepId.gmCast, StepId.gmEligibility]);
    expect(requests[0].model, 'model-${StepId.gmCast}');
    expect(requests[1].model, 'model-${StepId.gmEligibility}');
    expect(requests[0].messages.last.content, contains('CAST_INSTRUCTION'));
    expect(requests[0].messages.last.content, isNot(contains('ELIGIBILITY_INSTRUCTION')));
    expect(requests[1].messages.last.content, contains('ELIGIBILITY_INSTRUCTION'));
    expect(journal.responses.keys, ['${StepId.gmCast}#1', '${StepId.gmEligibility}#1']);
  });

  test('正式标识在模型配置、提示词和恢复点中原样往返', () async {
    SharedPreferences.setMockInitialValues({});
    final SettingsStore settings = await SettingsStore.open();
    await settings.savePrompts({StepId.gmCast: 'cast', StepId.gmEligibility: 'eligible'});
    expect(settings.loadPrompts()[StepId.gmCast], 'cast');
    expect(settings.loadPrompts()[StepId.gmEligibility], 'eligible');
    final ModelPlan plan = const ModelPlan()
        .withStep(StepId.gmCast, 'cast-model').withStep(StepId.gmEligibility, 'eligible-model');
    final ModelPlan loaded = ModelPlan.fromJson(jsonDecode(jsonEncode(plan.toJson())));
    expect(loaded.stepKey(StepId.gmCast), 'cast-model');
    expect(loaded.stepKey(StepId.gmEligibility), 'eligible-model');
    final TurnSession session = TurnSession(worldId: 'world', parallelPlaceId: 'place', rawInput: '',
        journal: TurnJournal(responses: {'${StepId.gmCast}#1': '{"cast":[]}'}))
        .withCheckpoint(StepId.gmCast, {'cast': []})
        .withCheckpoint(StepId.gmEligibility, {'eligible': []});
    final TurnSession restored = TurnSession.fromJson(jsonDecode(jsonEncode(session.toJson())));
    expect(restored.checkpoints.keys, [StepId.gmCast, StepId.gmEligibility]);
    expect(restored.stage, StepId.gmEligibility);
    expect(restored.journal.responses.keys.single, '${StepId.gmCast}#1');
  });
}
