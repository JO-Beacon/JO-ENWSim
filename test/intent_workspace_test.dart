import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/data/world_store.dart';
import 'package:joenws/engine/turn_session.dart';
import 'package:joenws/model/demo.dart';
import 'package:joenws/model/llm_client.dart';
import 'package:joenws/model/model_plan.dart';
import 'package:joenws/model/provider.dart';
import 'package:joenws/model/turn.dart';
import 'package:joenws/theme/tokens.dart';
import 'package:joenws/ui/common.dart';
import 'package:joenws/ui/workspace.dart';

const World _world = World(
  id: 'intent-world',
  name: '意图回合',
  note: '',
  setting: '',
  opening: '',
  playerName: '',
  characters: <CharCard>[
    CharCard(name: '灵梦', persona: '测试角色', location: '东门内侧'),
  ],
  parallelPlaces: <ParallelPlace>[
    ParallelPlace(id: 'gate', place: '东门内侧', here: true, events: <TurnStep>[]),
  ],
  moves: <MoveLink>[],
);

const Provider _provider = Provider(
  id: 'p',
  protocol: Protocol.deepseek,
  name: 'test',
  apiKey: 'unused',
  models: <ModelRef>[ModelRef(id: 'test')],
);

LlmReply _reply(LlmRequest request) {
  final String system = request.system ?? '';
  if (system.contains('GM_OPEN_PLACE')) {
    return const LlmReply(text: '{"places":[]}');
  }
  if (system.contains('GM_ROUTE')) {
    return const LlmReply(text: '{"next":"turn"}');
  }
  if (system.contains('你负责当前角色本次行动前的记忆召回')) {
    return const LlmReply(
      text: '{"action":"finish","memory_ids":[],"archived_ids":[]}',
    );
  }
  if (system.contains('直接写出你想做什么')) {
    return const LlmReply(
      text: '{"intent_id":"i1","actor":"char:灵梦",'
          '"text":"我想看看门外","desired":"看看门外"}',
    );
  }
  if (system.contains('你是立案官')) {
    return const LlmReply(
      text: '{"intent_id":"i1","actor":"char:灵梦","kind":"action",'
          '"text":"灵梦想要看看门外",'
          '"delivery":{"channel":"visual","form":"gesture","audience":"scene"}}',
    );
  }
  if (system.contains('你是裁决上帝')) {
    return const LlmReply(
      text: '{"settlements":[{"intent_id":"i1","actor":"char:灵梦",'
          '"result":"success","result_text":"灵梦看了看门外",'
          '"self_text":"你看了看门外"}]}',
    );
  }
  if (system.contains('把一条已经裁定的客观结果')) {
    return const LlmReply(text: '{"text":""}');
  }
  if (system.contains('第一人称记忆')) {
    return const LlmReply(text: '{"operations":[]}');
  }
  if (system.contains('GM_REVIEW_NARRATION')) {
    return const LlmReply(text: '{"violations":[]}');
  }
  if (system.contains('给玩家看的正文')) {
    return const LlmReply(text: '{"public_text":"灵梦看了看门外。","god_note":""}');
  }
  throw StateError('意外的模型步骤：$system');
}

void main() {
  testWidgets('工作台默认走意图回合：一轮一条意图，裁决后出正文', (WidgetTester tester) async {
    final WorldStore store = WorldStore.memory()..saveWorld(_world);
    final List<String> seen = <String>[];
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      JoTheme(
        settings: const JoSettings(backgroundRunMode: BackgroundRunMode.round),
        palette: JoPalette.dark,
        child: MaterialApp(
          home: Workspace(
            settings: const JoSettings(backgroundRunMode: BackgroundRunMode.round),
            onSettingsChanged: (_) {},
            providers: const <Provider>[_provider],
            onProvidersChanged: (_) {},
            globalPlan: const ModelPlan(defaultRef: 'p\u0000test'),
            onGlobalPlanChanged: (_) {},
            store: store,
            worlds: store.loadWorlds().worlds,
            engineSender: (LlmRequest request) async {
              seen.add((request.system ?? '').split('\n').first);
              return _reply(request);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (int i = 0; i < 12; i++) {
      if (store.timelineHistory(_world.id, mainTimelineId).length > 1) break;
      final Finder send = find.byWidgetPredicate(
        (Widget w) => w is JoIconAction && w.tip == '发送',
      );
      if (send.evaluate().isEmpty) break;
      await tester.tap(send.first);
      await tester.pumpAndSettle();
    }

    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();

    expect(store.timelineHistory(_world.id, mainTimelineId).length, greaterThan(1));
    expect(store.loadTurnState(_world.id)?.events, hasLength(1));

    final Finder send = find.byWidgetPredicate(
      (Widget w) => w is JoIconAction && w.tip == '发送',
    );
    if (send.evaluate().isNotEmpty) {
      await tester.tap(send.first);
      await tester.pumpAndSettle();
    }
    expect(seen.any((String s) => s.contains('给玩家看的正文')), isTrue);

    expect(seen.any((String s) => s.contains('扮演指定角色')), isTrue);
    expect(seen.any((String s) => s.contains('你是立案官')), isTrue);
    expect(seen.any((String s) => s.contains('你是裁决上帝')), isTrue);
    expect(seen.any((String s) => s.contains('第一人称记忆')), isTrue);
  });

  testWidgets('工作台单步在 CH_INTENT 暂停，继续不重复调意图', (WidgetTester tester) async {
    final WorldStore store = WorldStore.memory()..saveWorld(_world);
    final List<String> seen = <String>[];
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      JoTheme(
        settings: const JoSettings(),
        palette: JoPalette.dark,
        child: MaterialApp(
          home: Workspace(
            settings: const JoSettings(),
            onSettingsChanged: (_) {},
            providers: const <Provider>[_provider],
            onProvidersChanged: (_) {},
            globalPlan: const ModelPlan(defaultRef: 'p\u0000test'),
            onGlobalPlanChanged: (_) {},
            store: store,
            worlds: store.loadWorlds().worlds,
            engineSender: (LlmRequest request) async {
              seen.add((request.system ?? '').split('\n').first);
              return _reply(request);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('单回合 ▾'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('单步').last);
    await tester.pumpAndSettle();

    Future<void> tapSend() async {
      final Finder send = find.byWidgetPredicate(
        (Widget w) => w is JoIconAction && w.tip == '发送',
      );
      if (send.evaluate().isEmpty) return;
      await tester.tap(send.first, warnIfMissed: false);
      await tester.pumpAndSettle();
      while (find.text('知道了').evaluate().isNotEmpty) {
        await tester.tap(find.text('知道了').last);
        await tester.pumpAndSettle();
      }
    }

    for (int i = 0; i < 12; i++) {
      final TurnSession? session =
          store.loadTimelineSession(_world.id, mainTimelineId);
      if (session?.checkpoints.containsKey('CH_INTENT:灵梦') ?? false) break;
      await tapSend();
    }
    final TurnSession? paused =
        store.loadTimelineSession(_world.id, mainTimelineId);
    expect(paused?.checkpoints.containsKey('CH_INTENT:灵梦'), isTrue,
        reason: '暂停后应有 CH_INTENT 存档，实际：${paused?.checkpoints.keys}');
    final int intentCalls =
        seen.where((String s) => s.contains('扮演指定角色')).length;

    for (int i = 0; i < 12; i++) {
      final TurnSession? session =
          store.loadTimelineSession(_world.id, mainTimelineId);
      if (session?.checkpoints.containsKey('GM_FILE_CLAIM') ?? false) break;
      await tapSend();
    }
    final TurnSession? continued =
        store.loadTimelineSession(_world.id, mainTimelineId);
    expect(continued?.checkpoints.containsKey('GM_FILE_CLAIM'), isTrue);
    expect(seen.where((String s) => s.contains('扮演指定角色')).length,
        intentCalls);
  });
}
