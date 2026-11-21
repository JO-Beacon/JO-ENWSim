import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/engine/turn_session.dart';
import 'package:joenws/model/model_plan.dart';
import 'package:joenws/theme/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('全部 AI 步骤都有身份前缀、唯一语义名、中文名称和默认提示词', () {
    final Set<String> ids = kSteps.map((step) => step.id).toSet();
    expect(ids.length, kSteps.length);
    expect(kDefaultPrompts.keys.toSet(), containsAll(ids));
    for (final step in kSteps) {
      expect(step.id, matches(RegExp(r'^(GM|CH)_[A-Z]+(?:_[A-Z]+)*$')));
      expect(step.title, isNotEmpty);
      expect(StepId.label(step.id), '${step.id} · ${step.title}');
      expect(kDefaultPromptOf(step.id), isNotEmpty);
    }
    expect(StepId.gmParseInput, 'GM_PARSE_INPUT');
    expect(StepId.title('${StepId.chPerceive}:慧音'), '角色感知');
  });

  test('正式标识在模型配置、提示词和恢复点中原样往返', () async {
    SharedPreferences.setMockInitialValues({});
    final SettingsStore settings = await SettingsStore.open();
    await settings.savePrompts({StepId.chIntent: 'intent', StepId.gmFileClaim: 'claim'});
    expect(settings.loadPrompts()[StepId.chIntent], 'intent');
    expect(settings.loadPrompts()[StepId.gmFileClaim], 'claim');
    final ModelPlan plan = const ModelPlan()
        .withStep(StepId.chIntent, 'intent-model').withStep(StepId.gmFileClaim, 'claim-model');
    final ModelPlan loaded = ModelPlan.fromJson(jsonDecode(jsonEncode(plan.toJson())));
    expect(loaded.stepKey(StepId.chIntent), 'intent-model');
    expect(loaded.stepKey(StepId.gmFileClaim), 'claim-model');
    final TurnSession session = TurnSession(worldId: 'world', parallelPlaceId: 'place', rawInput: '',
        journal: TurnJournal(responses: {'${StepId.chIntent}#1': '{"intent_id":"i1"}'}))
        .withCheckpoint(StepId.chIntent, {'intent_id': 'i1'})
        .withCheckpoint(StepId.gmFileClaim, {'intent_id': 'i1'});
    final TurnSession restored = TurnSession.fromJson(jsonDecode(jsonEncode(session.toJson())));
    expect(restored.checkpoints.keys, [StepId.chIntent, StepId.gmFileClaim]);
    expect(restored.stage, StepId.gmFileClaim);
    expect(restored.journal.responses.keys.single, '${StepId.chIntent}#1');
  });
}
