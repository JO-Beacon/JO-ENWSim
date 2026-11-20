import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/data/world_store.dart';
import 'package:joenws/model/demo.dart';
import 'package:joenws/model/llm_client.dart';
import 'package:joenws/model/model_plan.dart';
import 'package:joenws/model/provider.dart';
import 'package:joenws/theme/tokens.dart';
import 'package:joenws/ui/common.dart';
import 'package:joenws/ui/workspace.dart';

void main() {
  testWidgets('裁定前修订行动，下一步直接裁定修订后的行动', (tester) async {
    await _resumeWithActionEdit(tester, afterRuling: false, editCheckpoint: false);
  });
  for (final bool editCheckpoint in <bool>[false, true]) {
    final String source = editCheckpoint ? '行动检查点' : '行动模型输出';
    testWidgets('裁定后修订$source，下一步沿用裁定并用修订行动记账', (tester) async {
      await _resumeWithActionEdit(tester, afterRuling: true, editCheckpoint: editCheckpoint);
    });
  }
}

Future<void> _resumeWithActionEdit(WidgetTester tester, {
  required bool afterRuling,
  required bool editCheckpoint,
}) async {
    const world = World(
      id: 'continue-edit-probe', name: '续跑验证', note: '', setting: '', opening: '', playerName: '',
      characters: [CharCard(name: '守门人', persona: '观察者', location: '东门内侧')],
      parallelPlaces: [ParallelPlace(id: 'gate', place: '东门内侧', here: true, events: [])], moves: [],
    );
    final store = WorldStore.memory()..saveWorld(world);
    addTearDown(store.close);
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String action(String kind, String text) => jsonEncode({
      'resolution': 'adjudicate',
      'segments': [{
        'kind': 'action', 'action_kind': kind, 'text': text,
        'delivery': {'channel': 'visual', 'form': 'gesture', 'audience': 'scene'},
        'requires': [], 'perceivable_by': [],
      }],
    });
    var rulings = 0;
    var actionCalls = 0;
    const String ruledAction = '试着推门。';
    final String expectedAction = afterRuling ? '试着抢过钥匙。' : '换个姿势推门';
    await tester.pumpWidget(JoTheme(settings: const JoSettings(), palette: JoPalette.dark,
      child: MaterialApp(home: Workspace(
        settings: const JoSettings(), onSettingsChanged: (_) {},
        providers: const [Provider(id: 'p', protocol: Protocol.deepseek, name: 'test',
          apiKey: 'unused', models: [ModelRef(id: 'test')])],
        onProvidersChanged: (_) {}, globalPlan: const ModelPlan(defaultRef: 'p\u0000test'),
        onGlobalPlanChanged: (_) {}, store: store, worlds: store.loadWorlds().worlds,
        engineSender: (request) async {
          final system = request.system ?? '';
          if (system.contains('GM_ROUTE')) return const LlmReply(text: '{"next":"turn"}');
          if (system.contains('GM_OBSERVE_SCENE')) {
            return const LlmReply(text: '{"observations":{"char:守门人":""}}');
          }
          if (system.contains('只声明当前 cast')) return const LlmReply(text: '{"cast":["守门人"]}');
          if (system.contains('选出本回合有资格行动的角色')) return const LlmReply(text: '{"eligible":["守门人"]}');
          if (system.contains('选唯一一个该行动的角色')) return const LlmReply(text: '{"chosen":"守门人"}');
          if (system.contains('你负责当前角色本次行动前的记忆召回')) {
            return const LlmReply(text: '{"action":"finish","memory_ids":[],"archived_ids":[]}');
          }
          if (system.contains('只写自己这一步的行为')) {
            actionCalls++;
            return LlmReply(text: action('interact', '试着推门。'));
          }
          if (system.contains('在一个涌现叙事世界里做')) {
            rulings++;
            expect(request.messages.single.content, contains(afterRuling ? ruledAction : expectedAction));
            return const LlmReply(text: '{"outcome":"success","result":"门开了。",'
              '"observations":{"char:守门人":"门开了。"},"deltas":[],"reason":"门闩已松开。"}');
          }
          if (system.contains('GM_REVIEW_NARRATION')) return const LlmReply(text: '{"violations":[]}');
          if (system.contains('给玩家看的正文')) {
            return const LlmReply(text: '{"public_text":"门开了。","god_note":""}');
          }
          throw StateError('意外的模型步骤：$system');
        },
      )),
    ));
    await tester.pumpAndSettle();
    Future<void> pickStepMode() async {
      // 顶栏默认“单回合”，这里要的是“单步”。
      await tester.tap(find.text('单回合 ▾'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('单步').last);
      await tester.pumpAndSettle();
    }
    // 顶栏已经没有“跑”了：手动推进就是输入框的发送按钮（空着发 = 继续）。
    Future<void> stepOnce() async {
      await tester.tap(find.byWidgetPredicate(
        (Widget w) => w is JoIconAction && w.tip == '发送',
      ));
      await tester.pumpAndSettle();
      while (find.text('知道了').evaluate().isNotEmpty) {
        await tester.tap(find.text('知道了').last);
        await tester.pumpAndSettle();
      }
    }
    await pickStepMode();
    for (var step = 0; step < 15 && (afterRuling ? rulings == 0 : actionCalls == 0); step++) {
      await stepOnce();
    }
    expect(rulings, afterRuling ? 1 : 0);
    final paused = store.loadTurnSession(world.id)!;
    expect(paused.checkpoints['CH_ACT'], isNotNull);
    expect(paused.checkpoints['GM_RESOLVE_ACTION'], afterRuling ? isNotNull : isNull);
    expect(paused.checkpoints['SYS_RECORD'], isNull);
    final head = store.loadTimelineBranch(world.id, mainTimelineId)!.headVersionId;

    await tester.tap(find.text('AI 步骤'));
    await tester.pumpAndSettle();
    final String key = editCheckpoint ? 'checkpoint:CH_ACT' : 'CH_ACT#守门人#1';
    final row = find.text(key);
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();
    final String revisedAction = afterRuling
        ? action('steal', expectedAction) : action('interact', '$expectedAction。');
    final String revision = editCheckpoint
        ? jsonEncode({...paused.checkpoints['CH_ACT']!.data, 'action': jsonDecode(revisedAction)})
        : revisedAction;
    await tester.enterText(find.byType(TextFormField), revision);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await stepOnce();
    final resumed = store.loadTurnSession(world.id)!;
    expect(resumed.stage, afterRuling ? 'SYS_RECORD' : 'GM_RESOLVE_ACTION');
    expect(resumed.checkpoints['GM_RESOLVE_ACTION']!.data['action'],
        jsonDecode(afterRuling ? action('interact', ruledAction) : revisedAction));
    expect(store.loadTimelineBranch(world.id, mainTimelineId)!.headVersionId, head);
    // 换个模式再继续：单步只走一个阶段，走完全程要用单回合。
    await tester.tap(find.text('单步 ▾'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('单回合').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byWidgetPredicate(
      (Widget w) => w is JoIconAction && w.tip == '发送',
    ));
    await tester.pumpAndSettle();

    expect(store.loadTurnSession(world.id), isNull);
    expect(store.loadTimelineBranch(world.id, mainTimelineId)!.headVersionId, isNot(head));
    final event = store.loadTurnState(world.id)!.events.single;
    expect(event.content, contains(expectedAction));
    expect(event.outcome, 'success');
    expect(event.result, '门开了。');
    expect(store.timelineStepRevisions(world.id, mainTimelineId, paused.id)[key], revision);
    expect(actionCalls, 1);
    expect(rulings, 1);
    expect(tester.takeException(), isNull);
}
