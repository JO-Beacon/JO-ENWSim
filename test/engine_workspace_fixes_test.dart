import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/data/world_store.dart';
import 'package:joenws/engine/agents/llm_agent_runner.dart';
import 'package:joenws/engine/engine_state.dart';
import 'package:joenws/engine/perception.dart';
import 'package:joenws/engine/state_delta.dart';
import 'package:joenws/engine/turn_session.dart';
import 'package:joenws/model/demo.dart';
import 'package:joenws/model/llm_client.dart';
import 'package:joenws/model/model_plan.dart';
import 'package:joenws/model/provider.dart';
import 'package:joenws/model/world_search.dart';
import 'package:joenws/model/turn.dart';
import 'package:joenws/theme/tokens.dart';
import 'package:joenws/ui/common.dart';
import 'package:joenws/ui/turn_flow.dart';
import 'package:joenws/ui/workspace.dart';

const _world = World(id: 'core-entry', name: '回合入口验证', note: '', setting: '', opening: '',
  playerName: '信标', characters: [CharCard(name: '信标', persona: '观察者', location: '东门内侧')],
  parallelPlaces: [ParallelPlace(id: 'gate', place: '东门内侧', here: true, events: [])], moves: []);
const _provider = Provider(id: 'p', protocol: Protocol.deepseek, name: 'test',
  apiKey: 'unused', models: [ModelRef(id: 'test')]);

Future<void> _boot(
  WidgetTester tester, WorldStore store, LlmSender sender, {
  BackgroundRunMode background = BackgroundRunMode.step,
  int? modelRequestConcurrency,
  String? worldId,
}) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(JoTheme(settings: const JoSettings(), palette: JoPalette.dark,
    child: MaterialApp(home: Workspace(settings: JoSettings(autoRunMaxTurns: 2, backgroundRunMode: background)
      .copyWith(modelRequestConcurrency: modelRequestConcurrency), onSettingsChanged: (_) {},
      providers: const [_provider], onProvidersChanged: (_) {},
      globalPlan: const ModelPlan(defaultRef: 'p\u0000test'), onGlobalPlanChanged: (_) {},
      store: store, worlds: store.loadWorlds().worlds.where(
        (World world) => worldId == null || world.id == worldId,
      ).toList(), engineSender: sender))));
  await tester.pumpAndSettle();
}

LlmReply _environmentReply(LlmRequest request, void Function() onRoute) {
  final system = request.system ?? '';
  if (system.contains('GM_ROUTE')) { onRoute(); return const LlmReply(text: '{"next":"env"}'); }
  if (system.contains('GM_ENV_UPDATE')) {
    return const LlmReply(text: '{"events":[{"content":"雨势加大","state_delta":{}}]}');
  }
  if (system.contains('GM_OBSERVE_SCENE')) {
    return const LlmReply(text: '{"observations":{"char:信标":"雨势加大"}}');
  }
  if (system.contains('扮演')) {
    final id = RegExp(r'ENV-\d+-\d+').firstMatch(request.messages.single.content)!.group(0);
    return LlmReply(text: jsonEncode({'percepts': [{'event_id': id, 'content': '我听见雨声变大'}], 'attention': '雨声'}));
  }
  if (system.contains('第一人称记忆')) return const LlmReply(text: '{"operations":[]}');
  if (system.contains('GM_REVIEW_NARRATION')) return const LlmReply(text: '{"violations":[]}');
  if (system.contains('给玩家看的正文')) return const LlmReply(text: '{"public_text":"雨势加大。","god_note":""}');
  throw StateError('意外的模型步骤：$system');
}

Future<void> _reviseRawStep(WidgetTester tester, String key, String replacement) async {
  await tester.tap(find.text('AI 步骤'));
  await tester.pumpAndSettle();
  final Finder row = find.text(key);
  await tester.ensureVisible(row);
  await tester.tap(row);
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextFormField), replacement);
  await tester.tap(find.text('保存'));
  await tester.pumpAndSettle();
}

/// 顶栏的推进方式下拉：先点开当前那一档，再选目标档。
Future<void> _setRunMode(WidgetTester tester, String mode) async {
  Finder? open;
  for (final String label in <String>['单步 ▾', '单回合 ▾', '直到交互点 ▾', '自动 ▾']) {
    final Finder candidate = find.text(label);
    if (candidate.evaluate().isNotEmpty) {
      open = candidate;
      break;
    }
  }
  expect(open, isNotNull, reason: '顶栏找不到推进方式按钮');
  await tester.tap(open!);
  await tester.pumpAndSettle();
  // 没有玩家的世界里，“直到交互点”这一档显示成“自动”。
  final Finder item = find.text(mode).evaluate().isNotEmpty
      ? find.text(mode).last
      : find.text('自动').last;
  await tester.tap(item);
  await tester.pumpAndSettle();
}

/// 顶栏已经没有“跑”了：手动推进就是输入框右下角的发送按钮（空着发 = 继续）。
Future<void> _send(WidgetTester tester) async {
  final Finder send = find.byWidgetPredicate(
    (Widget w) => w is JoIconAction && w.tip == '发送',
  );
  expect(send, findsOneWidget, reason: '找不到输入框的发送按钮');
  await tester.tap(send);
  await tester.pumpAndSettle();
}

/// 顶栏没有“到末尾”了：从时间线面板点分支名 = 回到这条线的末尾。
Future<void> _toHead(WidgetTester tester, String branchName) async {
  await tester.tap(find.text('时间线'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(branchName).last);
  await tester.pumpAndSettle();
}

/// 要一直跑到交互点：先把推进方式切到“直到交互点”，再发送。
Future<void> _pushToInteraction(WidgetTester tester) async {
  await _setRunMode(tester, '直到交互点');
  await _send(tester);
}

void main() {
  testWidgets('没有玩家的世界，“直到交互点”显示成“自动”', (tester) async {
    final World noPlayer = _world.copyWith(playerName: '');
    final WorldStore store = WorldStore.memory()..saveWorld(noPlayer);
    addTearDown(store.close);
    await _boot(tester, store, (LlmRequest request) async => _environmentReply(request, () {}));
    await _setRunMode(tester, '直到交互点');
    expect(find.text('自动 ▾'), findsOneWidget);
    expect(find.text('直到交互点 ▾'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    final WorldStore store2 = WorldStore.memory()..saveWorld(_world);
    addTearDown(store2.close);
    await _boot(tester, store2, (LlmRequest request) async => _environmentReply(request, () {}));
    expect(find.text('单回合 ▾'), findsOneWidget);
    await _setRunMode(tester, '直到交互点');
    expect(find.text('直到交互点 ▾'), findsOneWidget);
    expect(find.text('自动 ▾'), findsNothing);
  });

  testWidgets('工具栏的搜索源是上拉菜单，选完就落盘', (tester) async {
    final WorldStore store = WorldStore.memory()..saveWorld(_world);
    addTearDown(store.close);
    await _boot(tester, store, (LlmRequest request) async => _environmentReply(request, () {}));
    expect(store.loadWorlds().worlds.single.searchSource, WorldSearchSource.off);
    // 世界搜索只有一个入口：工具栏最右边的地球。
    final Finder globe = find.byWidgetPredicate(
      (Widget w) => w is JoIconAction && w.tip.startsWith('世界搜索'),
    );
    expect(globe, findsOneWidget);
    await tester.tap(globe);
    await tester.pumpAndSettle();
    expect(find.text('Tavily'), findsOneWidget);
    expect(find.text('DeepSeek 搜索'), findsOneWidget);
    expect(find.text('搜索一次…'), findsOneWidget);
    await tester.tap(find.text('Tavily'));
    await tester.pumpAndSettle();
    expect(store.loadWorlds().worlds.single.searchSource, WorldSearchSource.tavily);
    expect(find.text('Tavily'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('操控角色是上拉菜单，选完就落盘', (tester) async {
    final WorldStore store = WorldStore.memory()..saveWorld(_world);
    addTearDown(store.close);
    await _boot(tester, store, (LlmRequest request) async => _environmentReply(request, () {}));
    expect(store.loadWorlds().worlds.single.controlledCharacterName, '信标');
    await tester.tap(find.text('操控'));
    await tester.pumpAndSettle();
    expect(find.text('全部交给 AI'), findsOneWidget);
    expect(find.text('信标'), findsWidgets);
    await tester.tap(find.text('全部交给 AI'));
    await tester.pumpAndSettle();
    expect(store.loadWorlds().worlds.single.controlledCharacterName, '');
    expect(find.text('AI'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('画布地点列表右侧能加地点', (tester) async {
    final WorldStore store = WorldStore.memory()..saveWorld(_world);
    addTearDown(store.close);
    await _boot(tester, store, (LlmRequest request) async => _environmentReply(request, () {}));
    expect(find.text('添加地点'), findsOneWidget);
    await tester.tap(find.text('添加地点'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '仓房');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    expect(find.text('仓房'), findsWidgets);
    expect(
      store.loadWorlds().worlds.single.parallelPlaces.map((ParallelPlace p) => p.place),
      contains('仓房'),
    );
    expect(tester.takeException(), isNull);
  });

  for (final int limit in <int>[1, 2]) {
    testWidgets('两条时间线共用模型并发上限 $limit', (tester) async {
      final store = WorldStore.memory()..saveWorld(_world);
      addTearDown(store.close);
      store.commitTurn(
        worldId: _world.id,
        stateJson: TurnState.empty.encodeCheckpoint(),
        parallelPlaceId: 'gate',
        mainStep: const TurnStep(kind: 'GM_ENV_UPDATE', text: '分岔前。'),
      );
      final int fork = store.loadTimelineBranch(_world.id, mainTimelineId)!.headVersionId;
      store.createTimelineBranch(
        worldId: _world.id, sourceBranchId: mainTimelineId,
        versionId: fork, requestId: 'concurrency', name: '并发支线',
      );
      final List<Completer<LlmReply>> firstRoutes = <Completer<LlmReply>>[
        Completer<LlmReply>(), Completer<LlmReply>(),
      ];
      int routes = 0;
      await _boot(tester, store, (LlmRequest request) async {
        if (request.system!.contains('GM_ROUTE') && routes < 2) {
          return firstRoutes[routes++].future;
        }
        return _environmentReply(request, () {});
      }, background: BackgroundRunMode.untilStop,
        modelRequestConcurrency: limit == 1 ? null : limit);
      await _send(tester);
      await tester.pumpAndSettle();
      expect(routes, 1);

      await tester.tap(find.text('时间线'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('并发支线'));
      await tester.pumpAndSettle();
      await _send(tester);
      await tester.pumpAndSettle();
      expect(routes, limit);

      const reply = LlmReply(text: '{"next":"env"}');
      firstRoutes[0].complete(reply);
      await tester.pumpAndSettle();
      expect(routes, 2);
      firstRoutes[1].complete(reply);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  for (final BackgroundRunMode background in BackgroundRunMode.values) {
    testWidgets('切线时后台推演遵守${background.label}，结果只写回原线', (tester) async {
      final store = WorldStore.memory()..saveWorld(_world);
      addTearDown(store.close);
      store.commitTurn(
        worldId: _world.id,
        stateJson: TurnState.empty.encodeCheckpoint(),
        parallelPlaceId: 'gate',
        mainStep: const TurnStep(kind: 'GM_ENV_UPDATE', text: '分岔前。'),
      );
      final int fork = store.loadTimelineBranch(_world.id, mainTimelineId)!.headVersionId;
      final TimelineBranch branch = store.createTimelineBranch(
        worldId: _world.id, sourceBranchId: mainTimelineId,
        versionId: fork, requestId: 'switch', name: '测试支线',
      );
      final Completer<LlmReply> route = Completer<LlmReply>();
      var requests = 0;
      await _boot(tester, store, (LlmRequest request) async {
        requests++;
        if (requests == 1) return route.future;
        return _environmentReply(request, () {});
      }, background: background);
      expect(requests, 0);
      await _pushToInteraction(tester);
      await tester.pumpAndSettle();
      expect(requests, 1);
      expect(find.textContaining('当前：GM_ROUTE'), findsOneWidget);
      await tester.tap(find.text('时间线'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('测试支线'));
      await tester.pumpAndSettle();
      expect(find.textContaining('当前：GM_ROUTE'), findsNothing);
      route.complete(const LlmReply(text: '{"next":"env"}'));
      await tester.pumpAndSettle();
      expect(store.loadTimelineBranch(_world.id, branch.id)!.headVersionId, fork);
      expect(store.loadTimelineSession(_world.id, branch.id), isNull);
      final int rounds = store.timelineHistory(_world.id, mainTimelineId).length - 1;
      expect(rounds, switch (background) {
        BackgroundRunMode.freeze || BackgroundRunMode.step => 1,
        BackgroundRunMode.round => 2,
        BackgroundRunMode.untilStop => 3,
      });
      if (background == BackgroundRunMode.freeze || background == BackgroundRunMode.step) {
        expect(requests, 1);
        final checkpoint = store.loadTurnSession(_world.id)?.checkpoints['GM_ROUTE'];
        expect(checkpoint, background == BackgroundRunMode.freeze ? isNull : isNotNull);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('就地切线保留分岔回合，重推本回合只推进新线', (tester) async {
    final store = WorldStore.memory()..saveWorld(_world);
    addTearDown(store.close);
    for (final String text in <String>['共同回合。', '原线正文。']) {
      store.commitTurn(
        worldId: _world.id,
        stateJson: TurnState.empty.encodeCheckpoint(),
        parallelPlaceId: 'gate',
        mainStep: TurnStep(kind: 'GM_ENV_UPDATE', text: text),
      );
    }
    final history = store.timelineHistory(_world.id, mainTimelineId);
    final branch = store.createTimelineBranch(
      worldId: _world.id,
      sourceBranchId: mainTimelineId,
      versionId: history[1].id,
      requestId: 'anchor',
      name: '就地支线',
    );
    final head = store.commitTimelineTurn(
      worldId: _world.id,
      branchId: branch.id,
      baseVersionId: history[1].id,
      taskId: 'anchor-turn',
      world: _world,
      state: TurnState.empty,
      newSteps: [
        (placeId: 'gate', step: const TurnStep(kind: 'GM_ENV_UPDATE', text: '支线正文。')),
      ],
    );
    var routes = 0;
    await _boot(tester, store, (request) async => _environmentReply(request, () => routes++));
    final Finder firstCard = find.byKey(const ValueKey<String>('card-gate-0'));
    expect(firstCard, findsOneWidget);
    await tester.longPress(firstCard);
    await tester.pumpAndSettle();
    await tester.tap(find.text('就地支线'));
    await tester.pumpAndSettle();
    expect(find.text('正在查看第 1 回合'), findsOneWidget);
    expect(find.text('最新进度为第 2 回合'), findsOneWidget);
    expect(find.text('支线正文。'), findsNothing);
    await _toHead(tester, '就地支线');
    await tester.pumpAndSettle();

    final Finder secondCard = find.byKey(const ValueKey<String>('card-gate-1'));
    await tester.longPress(secondCard);
    await tester.pumpAndSettle();
    await tester.tap(find.text('回到本次结算前'));
    await tester.pumpAndSettle();
    expect(find.text('正在查看第 1 回合'), findsOneWidget);
    expect(find.text('支线正文。'), findsNothing);
    await _toHead(tester, '就地支线');
    await tester.pumpAndSettle();

    await tester.tap(find.text('时间线'));
    await tester.pumpAndSettle();
    expect(find.text('第 1 回合'), findsOneWidget);
    expect(find.text('第 2 回合'), findsNWidgets(2));
    await tester.tap(find.text('第 2 回合').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新推演本回合'));
    await tester.pumpAndSettle();
    expect(routes, 1);
    final TimelineBranch replay = store.listTimelineBranches(_world.id).last;
    expect(replay.sourceBranchId, branch.id);
    expect(replay.forkVersionId, history[1].id);
    expect(store.loadTimelineBranch(_world.id, branch.id)!.headVersionId, head);
    expect(store.loadTimelineBranch(_world.id, mainTimelineId)!.headVersionId, history.last.id);
    expect(store.loadTimelineSnapshot(_world.id, replay.headVersionId).state.events.single.content, '雨势加大');
    expect(tester.takeException(), isNull);
  });

  testWidgets('结算先存档，正文失败后只重试呈现', (tester) async {
    final store = WorldStore.memory()..saveWorld(_world);
    addTearDown(store.close);
    var worldSteps = 0;
    var narrationAttempts = 0;
    var allowNarration = false;
    await _boot(tester, store, (LlmRequest request) async {
      if ((request.system ?? '').contains('给玩家看的正文')) {
        narrationAttempts++;
        expect(store.loadTurnState(_world.id)?.events.single.content, '雨势加大');
        expect(store.timelineHistory(_world.id, mainTimelineId), hasLength(2));
        return LlmReply(text: allowNarration
            ? '{"public_text":"雨势加大。","god_note":""}'
            : '{"public_text":"","god_note":""}');
      }
      return _environmentReply(request, () => worldSteps++);
    });
    await _pushToInteraction(tester);
    await tester.pumpAndSettle();
    expect(worldSteps, 1);
    expect(narrationAttempts, greaterThan(0));
    final blocks = tester.widget<TurnFlow>(find.byType(TurnFlow)).done.map(flowStepOf).toSet();
    expect(blocks, containsAll([FlowStep.observeScene, FlowStep.perceive, FlowStep.writeMemory]));
    expect(blocks, isNot(contains(FlowStep.recovery)));
    final int head = store.loadTimelineBranch(_world.id, mainTimelineId)!.headVersionId;
    expect(store.loadPendingNarration(_world.id, mainTimelineId)?.versionId, head);

    await tester.tap(find.text('知道了').last);
    await tester.pumpAndSettle();
    allowNarration = true;
    await _send(tester);
    expect(worldSteps, 1);
    expect(store.loadPendingNarration(_world.id, mainTimelineId), isNull);
    expect(store.loadTimelineBranch(_world.id, mainTimelineId)!.headVersionId, head);
    final World world = store.loadWorlds().worlds.single;
    expect(store.projectTimelineNarration(world, head, 'god').parallelPlaces.single.events.single.text, '雨势加大。');
    expect(store.projectTimelineNarration(world, head, 'char:信标').parallelPlaces.single.events.single.text,
        isNot(contains('雨势加大')));
    final TurnSession task = store.loadCompletedTimelineTask(_world.id, head)!;
    expect(task.checkpoints['GM_NARRATE']?.data['publicText'], '雨势加大。');
    final TimelineBranch fork = store.createTimelineBranch(
      worldId: _world.id, sourceBranchId: mainTimelineId, versionId: head,
      requestId: 'narration-edit',
    );
    expect(store.editTimelineNarration(_world.id, fork.id, head, 'god', '雨更大了。'), isTrue);
    expect(store.projectTimelineNarration(world, head, 'god', branchId: fork.id)
        .parallelPlaces.single.events.single.text, '雨更大了。');
    expect(store.projectTimelineNarration(world, head, 'god', branchId: mainTimelineId)
        .parallelPlaces.single.events.single.text, '雨势加大。');
    expect(store.loadTimelineSnapshot(_world.id, head).state.events.single.content, '雨势加大');
    expect(tester.takeException(), isNull);
  });

  testWidgets('正文生成期间切线，单步在复核前暂停并保留原结果', (tester) async {
    final store = WorldStore.memory()..saveWorld(_world);
    addTearDown(store.close);
    store.commitTurn(
      worldId: _world.id,
      stateJson: TurnState.empty.encodeCheckpoint(),
      parallelPlaceId: 'gate',
      mainStep: const TurnStep(kind: 'GM_ENV_UPDATE', text: '分岔前。'),
    );
    final int fork = store.loadTimelineBranch(_world.id, mainTimelineId)!.headVersionId;
    final TimelineBranch branch = store.createTimelineBranch(
      worldId: _world.id, sourceBranchId: mainTimelineId,
      versionId: fork, requestId: 'narration-switch', name: '正文测试支线',
    );
    final Completer<LlmReply> draft = Completer<LlmReply>();
    const LlmReply reply = LlmReply(text: '{"public_text":"雨势加大。","god_note":""}');
    var drafts = 0;
    var reviews = 0;
    await _boot(tester, store, (LlmRequest request) async {
      final String system = request.system ?? '';
      if (system.contains('GM_REVIEW_NARRATION')) {
        reviews++;
        expect(request.messages.single.content, contains('雨势更大了。'));
      } else if (system.contains('给玩家看的正文')) {
        drafts++;
        return draft.future;
      }
      return _environmentReply(request, () {});
    });
    await _pushToInteraction(tester);
    await tester.pumpAndSettle();
    expect(drafts, 1);
    final int head = store.loadTimelineBranch(_world.id, mainTimelineId)!.headVersionId;
    expect(head, isNot(fork));
    await tester.tap(find.text('时间线'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('正文测试支线'));
    await tester.pumpAndSettle();
    draft.complete(reply);
    await tester.pumpAndSettle();

    expect(reviews, 0);
    expect(store.loadPendingNarration(_world.id, mainTimelineId)?.versionId, head);
    expect(store.loadTimelineBranch(_world.id, branch.id)!.headVersionId, fork);
    await tester.tap(find.text('时间线'));
    await tester.pumpAndSettle();
    expect(find.text('正文待继续'), findsOneWidget);
    await tester.tap(find.text('主线'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AI 步骤'));
    await tester.pumpAndSettle();
    final Finder raw = find.text('GM_NARRATE#1');
    await tester.ensureVisible(raw);
    await tester.tap(raw);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '{"public_text":"雨势更大了。","god_note":""}');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await _send(tester);
    await tester.pumpAndSettle();

    expect(drafts, 1);
    expect(reviews, 1);
    expect(store.loadPendingNarration(_world.id, mainTimelineId), isNull);
    expect(store.loadCompletedTimelineTask(_world.id, head)!.journal.responses.values,
        contains(reply.text));
    expect(store.loadCompletedTimelineTask(_world.id, head)!.checkpoints['GM_NARRATE']?.data['publicText'],
        '雨势加大。');
    expect(store.projectTimelineNarration(store.loadWorlds().worlds.single, head, 'god')
        .parallelPlaces.single.events.last.text, '雨势更大了。');
  });

  testWidgets('支线正文请求只能读取当前版本和角色可见附件', (tester) async {
    final (Directory dir, WorldStore store, AssetRecord seen, AssetRecord hidden, AssetRecord other) =
        (await tester.runAsync(() async {
      final Directory dir = await Directory.systemTemp.createTemp('jo-view-');
      final WorldStore store = await WorldStore.open(path: '${dir.path}/world.db');
      store.saveWorld(_world);
      Future<AssetRecord> asset(String text) async {
        final AssetRecord saved = await store.saveAsset(
          worldId: _world.id, kind: 'text', mime: 'text/plain',
          name: '线索.txt', bytes: utf8.encode(text),
        );
        store.saveAssetText(saved.id, text);
        return saved;
      }
      return (dir, store, await asset('角色看见的线索'), await asset('角色看不到的线索'), await asset('另一线的附件'));
    }))!;
    addTearDown(() async {
      store.close();
      await dir.delete(recursive: true);
    });
    WorldEvent event(String id, String content, String assetId, List<Witness> witnesses) => WorldEvent(
      id: id, uid: id, kind: WorldEventKind.action, content: content,
      actor: 'char:信标', placeId: '东门内侧',
      delivery: const Delivery(channel: DeliveryChannel.other, form: 'observation', audience: Audience.hidden),
      witnesses: witnesses, witnessesResolved: true, attachmentIds: <String>[assetId],
    );
    const TurnStep card = TurnStep(kind: 'GM_ENV_UPDATE', text: '本回合已结算，正文待生成。');
    store.commitTurn(
      worldId: _world.id, stateJson: TurnState.empty.encodeCheckpoint(), parallelPlaceId: 'gate', mainStep: card,
    );
    final int fork = store.loadTimelineBranch(_world.id, mainTimelineId)!.headVersionId;
    final TimelineBranch branch = store.createTimelineBranch(
      worldId: _world.id, sourceBranchId: mainTimelineId, versionId: fork,
      requestId: 'scope', name: '视角支线',
    );
    final WorldEvent otherEvent = event('other', '另一线的事实', other.id, <Witness>[]);
    store.commitTurn(
      worldId: _world.id, stateJson: TurnState(events: <WorldEvent>[otherEvent]).encodeCheckpoint(),
      parallelPlaceId: 'gate', mainStep: card, events: <WorldEvent>[otherEvent],
    );
    final List<WorldEvent> branchEvents = <WorldEvent>[
      event('seen', '只有当前角色看到了路牌', seen.id, <Witness>[
        const Witness(characterId: 'char:信标', modality: 'sight', content: '路牌立在门边。'),
      ]),
      event('hidden', '同线不可见的事实', hidden.id, <Witness>[]),
    ];
    final int version = store.commitTimelineTurn(
      worldId: _world.id, branchId: branch.id, baseVersionId: fork,
      taskId: 'scope-turn', world: _world, state: TurnState(events: branchEvents),
      newSteps: [(placeId: 'gate', step: card)],
      narration: (scope: 'char:信标', placeId: 'gate', events: branchEvents),
    );
    var requests = 0;
    await _boot(tester, store, (LlmRequest request) async {
      requests++;
      final String input = request.messages.single.content;
      expect(input, isNot(contains('另一线的')));
      expect(input, isNot(contains('同线不可见')));
      expect(input, isNot(contains('角色看不到的线索')));
      if ((request.system ?? '').contains('给玩家看的正文')) {
        expect(input, contains('角色看见的线索'));
        return const LlmReply(text: '{"public_text":"路牌立在门边。","god_note":""}');
      }
      return const LlmReply(text: '{"violations":[]}');
    }, worldId: _world.id);
    await tester.tap(find.text('时间线'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('视角支线'));
    await tester.pumpAndSettle();
    expect(requests, 0);
    await _send(tester);
    await tester.pumpAndSettle();
    expect(requests, 2);
    final World work = store.loadTimelineSnapshot(_world.id, version).world;
    expect(store.projectTimelineNarration(work, version, 'char:信标').parallelPlaces.single.events.last.text, '路牌立在门边。');
    expect(store.projectTimelineNarration(work, version, 'char:别人').parallelPlaces.single.events.last.text,
        isNot(contains('路牌')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('打开应用恢复步骤，手动继续才发请求', (tester) async {
    final store = WorldStore.memory()..saveWorld(_world);
    addTearDown(store.close);
    store.saveTurnSession(TurnSession(
      id: 'interrupted',
      worldId: _world.id,
      parallelPlaceId: 'gate',
      baseVersionId: store.loadTimelineBranch(_world.id, mainTimelineId)!.headVersionId,
      rawInput: '',
      journal: TurnJournal(),
    ).withCheckpoint('GM_ROUTE', <String, Object?>{'route': 'env'}));

    var requests = 0;
    var routes = 0;
    await _boot(tester, store, (request) async {
      requests++;
      return _environmentReply(request, () => routes++);
    }, background: BackgroundRunMode.untilStop);
    expect(find.text('单回合 ▾'), findsOneWidget);
    expect(requests, 0);
    await _send(tester);
    await tester.pumpAndSettle();
    expect(requests, greaterThan(0));
    expect(routes, 0);
    expect(store.loadTurnState(_world.id)!.events.single.content, '雨势加大');
    expect(tester.takeException(), isNull);
  });

  testWidgets('主线推进后拒绝旧回合落账，续跑时保留旧步骤', (tester) async {
    final store = WorldStore.memory()..saveWorld(_world);
    addTearDown(store.close);
    final int opening = store.loadTimelineBranch(_world.id, mainTimelineId)!.headVersionId;
    final route = Completer<LlmReply>();
    var requests = 0;
    await _boot(tester, store, (request) async {
      requests++;
      if (requests == 1) return route.future;
      return _environmentReply(request, () {});
    });
    await _send(tester);
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(store.loadTurnSession(_world.id)!.baseVersionId, opening);

    store.commitTurn(
      worldId: _world.id,
      baseVersionId: opening,
      stateJson: TurnState.empty.encodeCheckpoint(),
      parallelPlaceId: 'gate',
      mainStep: const TurnStep(kind: 'GM_ENV_UPDATE', text: '另一次推进。'),
    );
    final int head = store.loadTimelineBranch(_world.id, mainTimelineId)!.headVersionId;
    route.complete(const LlmReply(text: '{"next":"env"}'));
    await tester.pumpAndSettle();
    expect(requests, greaterThan(1));
    expect(store.loadTimelineBranch(_world.id, mainTimelineId)!.headVersionId, head);
    expect(store.loadTurnState(_world.id)!.events, isEmpty);
    expect(store.loadTurnSession(_world.id)!.baseVersionId, opening);
    expect(store.loadTurnSession(_world.id)!.checkpoints['GM_ROUTE'], isNotNull);

    final int beforeResume = requests;
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    await _send(tester);
    await tester.pumpAndSettle();
    expect(find.text('旧回合无法继续'), findsOneWidget);
    await tester.tap(find.text('保留'));
    await tester.pumpAndSettle();
    expect(store.loadTurnSession(_world.id)!.baseVersionId, opening);
    await _send(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃旧回合'));
    await tester.pumpAndSettle();
    expect(store.loadTurnSession(_world.id), isNull);
    expect(requests, beforeResume);
    expect(tester.takeException(), isNull);
  });

  testWidgets('历史步骤修订保留原始结果，后续回合保持不变', (tester) async {
    final store = WorldStore.memory()..saveWorld(_world);
    addTearDown(store.close);
    final task = TurnSession(
      id: 'historical-ai',
      worldId: _world.id,
      parallelPlaceId: 'gate',
      rawInput: '',
      journal: TurnJournal(responses: <String, String>{'GM_ROUTE#1': '{"next":"env"}'}),
    );
    store.commitTurn(
      worldId: _world.id,
      stateJson: TurnState.empty.encodeCheckpoint(),
      parallelPlaceId: 'gate',
      mainStep: const TurnStep(kind: 'GM_ENV_UPDATE', text: '原回合。'),
      sessionId: task.id,
      session: task,
    );
    store.commitTurn(
      worldId: _world.id,
      stateJson: TurnState.empty.encodeCheckpoint(),
      parallelPlaceId: 'gate',
      mainStep: const TurnStep(kind: 'GM_ENV_UPDATE', text: '后续回合。'),
    );
    final history = store.timelineHistory(_world.id, mainTimelineId);
    await _boot(tester, store, (_) async => throw StateError('编辑历史不发起模型请求。'));
    await tester.longPress(find.byKey(const ValueKey<String>('card-gate-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看和编辑 AI 步骤'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('GM_ROUTE#1'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '{"next":"turn"}');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(store.loadCompletedTimelineTask(_world.id, history[1].id)!.journal.responses['GM_ROUTE#1'],
        '{"next":"env"}');
    expect(store.timelineStepRevisions(_world.id, mainTimelineId, task.id)['GM_ROUTE#1'],
        '{"next":"turn"}');
    expect(store.loadTimelineBranch(_world.id, mainTimelineId)!.headVersionId, history.last.id);
    expect(store.loadWorlds().worlds.single.parallelPlaces.single.events.last.text, '后续回合。');
    expect(tester.takeException(), isNull);
  });

  testWidgets('运行中修订等当前步骤返回，下一步读取修订', (tester) async {
    final store = WorldStore.memory()..saveWorld(_world);
    addTearDown(store.close);
    final Completer<LlmReply> observing = Completer<LlmReply>();
    var observations = 0;
    var worldCalls = 0;
    var requestsWithRevision = 0;
    await _boot(tester, store, (LlmRequest request) async {
      final String system = request.system ?? '';
      if (system.contains('GM_OBSERVE_SCENE')) {
        observations++;
        return observing.future;
      }
      if (system.contains('给玩家看的正文')) {
        expect(request.messages.single.content, contains('风势变强'));
        requestsWithRevision++;
        return const LlmReply(text: '{"public_text":"风势变强。","god_note":""}');
      }
      return _environmentReply(request, () => worldCalls++);
    });
    await _send(tester);
    await tester.pumpAndSettle();
    expect(observations, 1);
    final TurnSession task = store.loadTurnSession(_world.id)!;
    final String recorded = jsonEncode(task.checkpoints['SYS_RECORD']!.data);
    expect(recorded, contains('雨势加大'));
    await tester.tap(find.text('AI 步骤'));
    await tester.pumpAndSettle();
    final Finder checkpoint = find.text('checkpoint:SYS_RECORD');
    await tester.ensureVisible(checkpoint);
    await tester.tap(checkpoint);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), recorded.replaceAll('雨势加大', '风势变强'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(observations, 1);
    expect(store.loadTurnState(_world.id), isNull);

    observing.complete(const LlmReply(text: '{"observations":{"char:信标":"此处有风雨"}}'));
    await tester.pumpAndSettle();
    expect(worldCalls, 1);
    expect(observations, 1);
    expect(requestsWithRevision, 1);
    expect(store.loadTurnState(_world.id)!.events.single.content, '风势变强');
    expect(store.timelineStepOriginals(_world.id, mainTimelineId, task.id)['checkpoint:SYS_RECORD'],
        contains('雨势加大'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('修改已存的逐人见闻后，尚未开始感知的角色读取修订', (tester) async {
    final World world = _world.copyWith(characters: <CharCard>[
      ..._world.characters,
      const CharCard(name: '守门人', persona: '守门人', location: '东门内侧'),
    ]);
    final store = WorldStore.memory()..saveWorld(world);
    addTearDown(store.close);
    final Completer<LlmReply> firstPerception = Completer<LlmReply>();
    const String firstScene = '{"observations":{"char:信标":"雨势加大","char:守门人":"门边有水迹"}}';
    LlmReply? firstResult;
    var observationCalls = 0;
    var guardCalls = 0;
    await _boot(tester, store, (request) async {
      final String system = request.system ?? '';
      if (system.contains('GM_OBSERVE_SCENE')) {
        observationCalls++;
        return const LlmReply(text: firstScene);
      }
      final LlmReply reply = _environmentReply(request, () {});
      if (system.contains('扮演')) {
        if (request.messages.single.content.contains('门闩上挂着水珠')) {
          guardCalls++;
        } else if (firstResult == null) {
          firstResult = reply;
          return firstPerception.future;
        }
      }
      return reply;
    });
    await _send(tester);
    await tester.pumpAndSettle();
    expect(firstResult, isNotNull);
    final TurnSession task = store.loadTurnSession(world.id)!;
    final String rawKey = task.journal.responses.keys.singleWhere(
      (String key) => key.startsWith('GM_OBSERVE_SCENE#'),
    );
    await tester.tap(find.text('AI 步骤'));
    await tester.pumpAndSettle();
    final Finder raw = find.text(rawKey);
    await tester.ensureVisible(raw);
    await tester.tap(raw);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), firstScene.replaceAll('门边有水迹', '门闩上挂着水珠'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(guardCalls, 0);
    firstPerception.complete(firstResult!);
    await tester.pumpAndSettle();

    expect(observationCalls, 1);
    expect(guardCalls, 1);
    final int head = store.loadTimelineBranch(world.id, mainTimelineId)!.headVersionId;
    expect(store.loadCompletedTimelineTask(world.id, head), isNotNull);
    expect(store.timelineStepOriginals(world.id, mainTimelineId, task.id)[rawKey], firstScene);
    expect(tester.takeException(), isNull);
  });

  testWidgets('无就绪工作时可推进到已知时间边界，禁止重复推进', (tester) async {
    final WorldStore store = WorldStore.memory()..saveWorld(_world);
    addTearDown(store.close);
    store.appendWorldTurn(_world.id, const TurnState(
      events: <WorldEvent>[],
      facts: <FactRecord>[
        FactRecord(
          id: 'dawn', subject: 'place:东门内侧', predicate: 'time_boundary',
          object: '天亮', evidence: '门卫天亮换班。',
        ),
      ],
    ).encode());
    var proposals = 0;
    await _boot(tester, store, (LlmRequest request) async {
      final String system = request.system ?? '';
      if (system.contains('已知的最早将来边界')) {
        proposals++;
        expect(request.messages.single.content, contains('门卫天亮换班'));
        return const LlmReply(text: '{"decision":"advance","boundary_id":"dawn","process_order":{},"reason":"天亮是下一个已知边界"}');
      }
      if (system.contains('GM_ROUTE')) return const LlmReply(text: '{"next":"env"}');
      if (system.contains('GM_ENV_UPDATE')) return const LlmReply(text: '{"events":[]}');
      if (system.contains('GM_OBSERVE_SCENE')) {
        return const LlmReply(text: '{"observations":{"char:信标":"东门内侧"}}');
      }
      if (system.contains('扮演')) return const LlmReply(text: '{"percepts":[],"attention":"门口"}');
      if (system.contains('第一人称记忆')) return const LlmReply(text: '{"operations":[]}');
      if (system.contains('给玩家看的正文')) {
        return const LlmReply(text: '{"public_text":"天亮了。","god_note":""}');
      }
      if (system.contains('GM_REVIEW_NARRATION')) return const LlmReply(text: '{"violations":[]}');
      throw StateError('意外请求：$system');
    });
    await _pushToInteraction(tester);
    await tester.pumpAndSettle();
    final TurnState settled = store.loadTurnState(_world.id)!;
    expect(proposals, 1);
    expect(settled.events.single.source, 'world_time');
    expect(settled.events.single.target, 'dawn');
    expect(store.timelineHistory(_world.id, mainTimelineId), hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('调度等待可跨重启恢复，自动推演不重复评估相同输入', (tester) async {
    final WorldStore store = WorldStore.memory()..saveWorld(_world);
    addTearDown(store.close);
    const TurnState initial = TurnState(events: <WorldEvent>[], facts: <FactRecord>[
      FactRecord(id: 'gate-condition', subject: 'place:东门内侧', predicate: 'power', object: 'off'),
    ]);
    store.appendWorldTurn(_world.id, initial.encode());
    var evaluations = 0;
    Future<LlmReply> sender(LlmRequest request) async {
      final String system = request.system ?? '';
      if (system.contains('GM_ROUTE')) return const LlmReply(text: '{"next":"env"}');
      if (system.contains('GM_ENV_UPDATE')) {
        evaluations++;
        return const LlmReply(text: '{"events":[],"wait_for":{"kind":"fact_change","id":"gate-condition"}}');
      }
      throw StateError('意外请求：$system');
    }
    await _boot(tester, store, sender);
    await _pushToInteraction(tester);
    await tester.pumpAndSettle();
    expect(evaluations, 1);
    expect(store.loadTimelineWork(_world.id, mainTimelineId)?['gate'],
        containsPair('value', 'off'));
    expect(store.timelineHistory(_world.id, mainTimelineId), hasLength(1));

    await tester.pumpWidget(const SizedBox.shrink());
    await _boot(tester, store, sender);
    expect(evaluations, 1);
    await _pushToInteraction(tester);
    await tester.pumpAndSettle();
    expect(evaluations, 1);

    store.appendWorldTurn(_world.id, const TurnState(events: <WorldEvent>[], facts: <FactRecord>[
      FactRecord(id: 'gate-condition', subject: 'place:东门内侧', predicate: 'power', object: 'on'),
    ]).encode());
    await tester.tap(find.text('知道了').last);
    await tester.pumpAndSettle();
    await _pushToInteraction(tester);
    await tester.pumpAndSettle();
    expect(evaluations, 2);
    expect(store.loadTimelineWork(_world.id, mainTimelineId)?['gate'],
        containsPair('value', 'on'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('自动推演轮流评估有人和有持续过程的地点', (tester) async {
    final World world = _world.copyWith(
      parallelPlaces: <ParallelPlace>[
        ..._world.parallelPlaces,
        const ParallelPlace(id: 'warehouse', place: '仓库', here: false, events: []),
      ],
    );
    final store = WorldStore.memory()..saveWorld(world);
    addTearDown(store.close);
    store.appendWorldTurn(world.id, const TurnState(
      events: <WorldEvent>[],
      entities: <String, EntityRecord>{
        'process:fire': EntityRecord(
          id: 'process:fire', kind: 'process', name: '火势', location: '仓库',
          state: <String, Object?>{'kind': 'environment', 'status': 'ongoing'},
        ),
      },
    ).encode());
    final List<String> locations = <String>[];
    await _boot(tester, store, (LlmRequest request) async {
      final String input = request.messages.single.content;
      if ((request.system ?? '').contains('GM_ROUTE')) {
        locations.add(input.contains('【场景】仓库') ? '仓库' : '东门内侧');
      }
      return _environmentReply(request, () {});
    });
    await _pushToInteraction(tester);
    await tester.pumpAndSettle();
    expect(locations, <String>['东门内侧', '仓库']);
    expect(store.loadWorlds().worlds.single.parallelPlaces.map((place) => place.events.length), <int>[1, 1]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同一时间线等玩家时不调度别处', (tester) async {
    final World world = _world.copyWith(
      parallelPlaces: <ParallelPlace>[
        ..._world.parallelPlaces,
        const ParallelPlace(id: 'warehouse', place: '仓库', here: false, events: []),
      ],
    );
    final store = WorldStore.memory()..saveWorld(world);
    addTearDown(store.close);
    var routes = 0;
    await _boot(tester, store, (LlmRequest request) async {
      final String system = request.system ?? '';
      if (system.contains('GM_ROUTE')) {
        routes++;
        return const LlmReply(text: '{"next":"turn"}');
      }
      if (system.contains('GM_OBSERVE_SCENE')) {
        return const LlmReply(text: '{"observations":{"char:信标":"东门内侧"}}');
      }
      if (system.contains('【新事件】')) {
        return const LlmReply(text: '{"percepts":[],"attention":"东门"}');
      }
      if (system.contains('第一人称记忆')) {
        return const LlmReply(text: '{"operations":[]}');
      }
      if (system.contains('只声明当前 cast')) {
        return const LlmReply(text: '{"cast":["信标"]}');
      }
      if (system.contains('选出本回合有资格行动的角色')) {
        return const LlmReply(text: '{"eligible":["信标"]}');
      }
      if (system.contains('选唯一一个该行动的角色')) {
        return const LlmReply(text: '{"chosen":"信标"}');
      }
      if (system.contains('你负责当前角色本次行动前的记忆召回')) {
        return const LlmReply(text: '{"action":"finish","memory_ids":[],"archived_ids":[]}');
      }
      throw StateError('等待玩家期间出现了意外的模型步骤：$system');
    });
    await _pushToInteraction(tester);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(minutes: 2));
    expect(routes, 1);
    expect(store.loadTurnSession(world.id)!.status, 'waiting_player');
    final flow = tester.widget<TurnFlow>(find.byType(TurnFlow));
    expect(flowStepOf(flow.active), FlowStep.recovery);
    expect(flow.done.map(flowStepOf), isNot(contains(FlowStep.recovery)));
    expect(store.timelineHistory(world.id, mainTimelineId), hasLength(1));
    expect(store.loadSteps(world.id, 'warehouse'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同线两个地点并发计算，模型先回的回合不会抢先落账', (tester) async {
    final World world = _world.copyWith(
      playerName: '',
      characters: <CharCard>[
        ..._world.characters,
        const CharCard(name: '看守', persona: '仓库门卫', location: '仓库'),
      ],
      parallelPlaces: <ParallelPlace>[
        ..._world.parallelPlaces,
        const ParallelPlace(id: 'hangar', place: '仓库', here: false, events: []),
      ],
    );
    final store = WorldStore.memory()..saveWorld(world);
    addTearDown(store.close);
    final first = Completer<LlmReply>();
    final second = Completer<LlmReply>();
    bool secondObserved = false;
    await _boot(tester, store, (request) async {
      final String system = request.system ?? '';
      final String input = request.messages.single.content;
      if (system.contains('GM_ROUTE')) return const LlmReply(text: '{"next":"env"}');
      if (system.contains('GM_ENV_UPDATE')) {
        return (input.contains('【场景】仓库') ? second : first).future;
      }
      if (system.contains('GM_OBSERVE_SCENE') && input.contains('char:看守')) {
        secondObserved = true;
        return const LlmReply(text: '{"observations":{"char:看守":"看守换班"}}');
      }
      if (system.contains('给玩家看的正文') && input.contains('仓库交班')) {
        return const LlmReply(text: '{"public_text":"仓库交班。","god_note":""}');
      }
      return _environmentReply(request, () {});
    }, modelRequestConcurrency: 2);
    await _pushToInteraction(tester);
    await tester.pumpAndSettle();
    expect(store.loadTimelineSessions(world.id, mainTimelineId), hasLength(2));

    second.complete(const LlmReply(text: '{"events":[{"content":"仓库交班"}]}'));
    await tester.pumpAndSettle();
    expect(secondObserved, isTrue);
    expect(store.timelineHistory(world.id, mainTimelineId), hasLength(1));

    first.complete(const LlmReply(text: '{"events":[{"content":"雨势加大"}]}'));
    await tester.pumpAndSettle();
    final TurnState state = store.loadTurnState(world.id)!;
    expect(state.events.map((event) => event.content), <String>['雨势加大', '仓库交班']);
    expect(state.events.map((event) => event.turnIndex), <int>[1, 2]);
    expect(state.events.map((event) => event.id).toSet(), hasLength(2));
    expect(store.loadTimelineSessions(world.id, mainTimelineId), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同线等玩家时已开跑的仓库落账，第三处不启动，重启后续跑原任务', (tester) async {
    final World world = _world.copyWith(
      characters: <CharCard>[
        ..._world.characters,
        const CharCard(name: '看守', persona: '仓库门卫', location: '仓库'),
        const CharCard(name: '伙计', persona: '店员', location: '商铺'),
      ],
      parallelPlaces: <ParallelPlace>[
        ..._world.parallelPlaces,
        const ParallelPlace(id: 'shop', place: '商铺', here: false, events: []),
        const ParallelPlace(id: 'hangar', place: '仓库', here: false, events: []),
      ],
    );
    final store = WorldStore.memory()..saveWorld(world);
    addTearDown(store.close);
    final warehouse = Completer<LlmReply>();
    final List<String> routes = <String>[];
    int parses = 0;
    Future<LlmReply> send(LlmRequest request) async {
      final String system = request.system ?? '';
      final String input = request.messages.single.content;
      if (system.contains('GM_ROUTE')) {
        final String place = RegExp(r'【场景】([^\n]+)').firstMatch(input)!.group(1)!;
        routes.add(place);
        if (place == '仓库') return warehouse.future;
        return const LlmReply(text: '{"next":"turn"}');
      }
      if (system.contains('GM_ENV_UPDATE')) {
        return const LlmReply(text: '{"events":[{"content":"仓库交班","state_delta":{}}]}');
      }
      if (system.contains('GM_OBSERVE_SCENE')) {
        return input.contains('char:看守')
            ? const LlmReply(text: '{"observations":{"char:看守":"看守换班"}}')
            : const LlmReply(text: '{"observations":{"char:信标":"东门内侧"}}');
      }
      if (system.contains('【新事件】') || system.contains('扮演')) {
        final String? id = RegExp(r'ENV-\d+-\d+').firstMatch(input)?.group(0);
        return LlmReply(text: jsonEncode(<String, Object?>{
          'percepts': <Object?>[if (id != null) {'event_id': id, 'content': '看守换班'}],
          'attention': '现场',
        }));
      }
      if (system.contains('第一人称记忆')) return const LlmReply(text: '{"operations":[]}');
      if (system.contains('只声明当前 cast')) return const LlmReply(text: '{"cast":["信标"]}');
      if (system.contains('选出本回合有资格行动的角色')) return const LlmReply(text: '{"eligible":["信标"]}');
      if (system.contains('选唯一一个该行动的角色')) return const LlmReply(text: '{"chosen":"信标"}');
      if (system.contains('你负责当前角色本次行动前的记忆召回')) {
        return const LlmReply(text: '{"action":"finish","memory_ids":[],"archived_ids":[]}');
      }
      if (system.contains('GM_PARSE_INPUT')) {
        parses++;
        return const LlmReply(text: '{"segments":[{"id":"s1","kind":"speech","text":"好",'
            '"target":null,"delivery":{"channel":"voice","form":"spoken","audience":"scene"},'
            '"requires":["speak"],"evidence":{}}],"unresolved":[],"warnings":[]}');
      }
      if (system.contains('GM_REVIEW_NARRATION')) return const LlmReply(text: '{"violations":[]}');
      if (system.contains('给玩家看的正文')) {
        return input.contains('仓库交班')
            ? const LlmReply(text: '{"public_text":"仓库交班。","god_note":""}')
            : const LlmReply(text: '{"public_text":"信标说：“好”","god_note":""}');
      }
      throw StateError('意外模型步骤：$system');
    }
    await _boot(tester, store, send, modelRequestConcurrency: 2);
    await _pushToInteraction(tester);
    await tester.pumpAndSettle();
    expect(routes, unorderedEquals(<String>['东门内侧', '仓库']));
    expect(store.loadTimelineSessions(world.id, mainTimelineId), hasLength(2));
    final TurnSession playerTask = store.loadTurnSession(world.id)!;
    expect(playerTask.status, 'waiting_player');
    expect(playerTask.checkpoints['GM_SELECT_ACTOR'], isNotNull);
    expect(store.timelineHistory(world.id, mainTimelineId), hasLength(1));

    warehouse.complete(const LlmReply(text: '{"next":"env"}'));
    await tester.pumpAndSettle();
    expect(store.loadTurnState(world.id)!.events.single.content, '仓库交班');
    expect(store.loadTimelineSessions(world.id, mainTimelineId).single.id, playerTask.id);
    expect(routes, hasLength(2));

    await tester.pumpWidget(const SizedBox.shrink());
    await _boot(tester, store, send, modelRequestConcurrency: 2);
    expect(routes, hasLength(2));
    await tester.enterText(find.byType(EditableText).last, '好');
    await _send(tester);
    await tester.pumpAndSettle();
    expect(parses, 1);
    expect(routes, hasLength(2));
    expect(store.loadTurnState(world.id)!.events.map((event) => event.content), <String>['仓库交班', '好']);
    expect(store.loadTurnState(world.id)!.turnSessionId, playerTask.id);
    expect(store.loadTimelineSessions(world.id, mainTimelineId), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('所有人都不能行动时仍通过真实入口提交环境回合', (tester) async {
    final store = WorldStore.memory()..saveWorld(_world);
    addTearDown(store.close);
    store.appendWorldTurn(_world.id, const TurnState(events: [], locations: {'信标': '东门内侧'},
      constraints: [FunctionalConstraint(who: '信标', capability: 'act', state: ConstraintState.cannot)]).encode());
    var routes = 0;
    await _boot(tester, store, (request) async => _environmentReply(request, () => routes++));
    await _send(tester);
    await tester.pumpAndSettle();
    expect(routes, 1);
    expect(store.loadTurnState(_world.id)!.events.single.content, '雨势加大');
    expect(store.loadWorlds().worlds.single.parallelPlaces.single.events.single.kind, 'GM_ENV_UPDATE');
    expect(tester.takeException(), isNull);
  });

  testWidgets('自动推演连续提交两个环境回合，达到预算才停止', (tester) async {
    final store = WorldStore.memory()..saveWorld(_world);
    addTearDown(store.close);
    var routes = 0;
    await _boot(tester, store, (request) async => _environmentReply(request, () => routes++));
    await _pushToInteraction(tester);
    await tester.pumpAndSettle();
    expect(routes, 2);
    expect(store.loadWorlds().worlds.single.parallelPlaces.single.events, hasLength(2));
    expect(store.loadTurnState(_world.id)!.worldStep, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('裁定完成后修订原始裁定，从检查点继续时使用修订落账', (tester) async {
    final World world = _world.copyWith(playerName: '', characters: const <CharCard>[
      CharCard(name: '守门人', persona: '守门人', location: '东门内侧'),
    ]);
    final WorldStore store = WorldStore.memory()..saveWorld(world);
    addTearDown(store.close);
    const String original = '{"outcome":"failure","result":"门没动。",'
        '"observations":{"char:守门人":"门没动。"},"deltas":[],"reason":"门闩卡住。"}';
    const String revised = '{"outcome":"success","result":"门开了。",'
        '"observations":{"char:守门人":"门开了。"},"deltas":[],"reason":"门闩已松开。"}';
    var rulings = 0;
    await _boot(tester, store, (request) async {
      final String system = request.system ?? '';
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
        expect(system, contains('【扮演角色】守门人'));
        return const LlmReply(text: '{"resolution":"adjudicate","segments":[{"kind":"action",'
            '"action_kind":"interact","text":"试着推门。",'
            '"delivery":{"channel":"visual","form":"gesture","audience":"scene"},'
            '"requires":[],"perceivable_by":[]}]}');
      }
      if (system.contains('在一个涌现叙事世界里做')) {
        rulings++;
        return const LlmReply(text: original);
      }
      if (system.contains('给玩家看的正文')) {
        expect(request.messages.single.content, contains('门开了。'));
        return const LlmReply(text: '{"public_text":"门开了。","god_note":""}');
      }
      if (system.contains('GM_REVIEW_NARRATION')) return const LlmReply(text: '{"violations":[]}');
      throw StateError('意外步骤：$system');
    });
    await _setRunMode(tester, '单步');
    for (var step = 0; step < 15 && rulings == 0; step++) {
      await _send(tester);
      final Finder acknowledge = find.text('知道了');
      while (acknowledge.evaluate().isNotEmpty) {
        await tester.tap(acknowledge.last);
        await tester.pumpAndSettle();
      }
    }
    expect(rulings, 1);
    final TurnSession paused = store.loadTurnSession(world.id)!;
    expect(paused.checkpoints['GM_RESOLVE_ACTION'], isNotNull);
    expect(paused.checkpoints['SYS_RECORD'], isNull);
    await _reviseRawStep(tester, 'GM_RESOLVE_ACTION#1', revised);
    // 换个模式再继续：单步只走一个阶段，走完全程要用单回合。
    await tester.tap(find.text('单步 ▾'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('单回合').last);
    await tester.pumpAndSettle();
    await _send(tester);
    await tester.pumpAndSettle();
    expect(rulings, 1);
    final int head = store.loadTimelineBranch(world.id, mainTimelineId)!.headVersionId;
    expect(store.loadCompletedTimelineTask(world.id, head)!.journal.responses['GM_RESOLVE_ACTION#1'], original);
    expect(store.loadTurnState(world.id)!.events.single.outcome, 'success');
    expect(tester.takeException(), isNull);
  });

  for (final String kind in <String>['normal', 'memory', 'recall', 'wait']) {
  final bool reviseMemory = kind == 'memory';
  final bool reviseRecall = kind == 'recall';
  final bool waitInWorld = kind == 'wait';
  testWidgets(switch (kind) {
    'memory' => '记忆写入在召回完成后应用修订，保留模型原文',
    'recall' => '召回查询修订进入下一次召回请求，已完成的模型请求不重发',
    'wait' => '角色在世界中选择等待，下轮不再被要求行动',
    _ => '实际角色入口把开场现场交给角色并提交其主观印象，秘密不进入行动',
  }, (tester) async {
    final world = _world.copyWith(playerName: '', characters: const [
      CharCard(name: '慧音', persona: '观察者', location: '东门内侧')],
      opening: '门口竖着红色路牌，暗格里藏着机关秘密标记');
    final store = WorldStore.memory()..saveWorld(world);
    addTearDown(store.close);
    var projected = 0;
    var acted = 0;
    var recalled = 0;
    var wroteMemory = 0;
    final Completer<LlmReply> firstRecall = Completer<LlmReply>();
    const String search = '{"action":"search","query":"旧路牌"}';
    const String written = '{"operations":[{"op":"encode","kind":"impression","text":"我看见门口的红色路牌","source_events":[]}]}';
    await _boot(tester, store, (request) async {
      final system = request.system ?? '';
      if (system.contains('GM_ROUTE')) return const LlmReply(text: '{"next":"turn"}');
      if (system.contains('GM_OBSERVE_SCENE')) {
        projected++;
        expect(request.messages.single.content, contains('机关秘密标记'));
        return const LlmReply(text: '{"observations":{"char:慧音":"门口竖着红色路牌"}}');
      }
      if (system.contains('【新事件】')) {
        expect(request.messages.single.content, contains('红色路牌'));
        expect(request.messages.single.content, isNot(contains('机关秘密标记')));
        return const LlmReply(text: '{"percepts":[],"attention":"观察路牌"}');
      }
      if (system.contains('第一人称记忆')) {
        wroteMemory++;
        return const LlmReply(text: written);
      }
      if (system.contains('只声明当前 cast')) return const LlmReply(text: '{"cast":["慧音"]}');
      if (system.contains('选出本回合有资格行动的角色')) {
        if (waitInWorld && acted > 0) return const LlmReply(text: '{"eligible":[]}');
        return const LlmReply(text: '{"eligible":["慧音"]}');
      }
      if (system.contains('选唯一一个该行动的角色')) return const LlmReply(text: '{"chosen":"慧音"}');
      if (system.contains('你负责当前角色本次行动前的记忆召回')) {
        recalled++;
        if (reviseMemory && recalled == 1) return firstRecall.future;
        if (reviseMemory) expect(request.messages.single.content, contains('蓝色路牌'));
        if (reviseRecall && recalled == 1) return const LlmReply(text: search);
        if (reviseRecall && recalled == 2) return firstRecall.future;
        if (reviseRecall) {
          expect(request.messages.single.content, contains('新路牌'));
          expect(request.messages.single.content, isNot(contains('旧路牌')));
        }
        return const LlmReply(
          text: '{"action":"finish","memory_ids":[],"archived_ids":[]}',
        );
      }
      if (system.contains('只写自己这一步的行为')) {
        expect(system, contains('【扮演角色】慧音'));
        acted++;
        expect(request.messages.single.content, contains('红色路牌'));
        expect(request.messages.single.content, isNot(contains('机关秘密标记')));
        if (waitInWorld) {
          return const LlmReply(text: '{"resolution":"direct","segments":[{"kind":"action",'
              '"action_kind":"wait","text":"在原地等候。",'
              '"delivery":{"channel":"visual","form":"gesture","audience":"scene"},'
              '"requires":[],"perceivable_by":[]}]}');
        }
        return const LlmReply(text: '{"segments":[{"kind":"speech","text":"路牌在这里。",'
          '"delivery":{"channel":"voice","form":"spoken","audience":"scene"},"requires":["speak"],"perceivable_by":[]}]}');
      }
      if (system.contains('GM_REVIEW_NARRATION')) return const LlmReply(text: '{"violations":[]}');
      if (system.contains('给玩家看的正文')) {
        return waitInWorld
            ? const LlmReply(text: '{"public_text":"在原地等候。","god_note":""}')
            : const LlmReply(text: '{"public_text":"“路牌在这里。”","god_note":""}');
      }
      if (waitInWorld && system.contains('GM_ENV_UPDATE')) return const LlmReply(text: '{"events":[]}');
      throw StateError('意外步骤：$system');
    });
    await _send(tester);
    await tester.pumpAndSettle();
    if (waitInWorld) {
      expect(store.loadTurnState(world.id)?.worldWork['actor:慧音'], isNotNull);
      await tester.tap(find.text('知道了').last);
      await tester.pumpAndSettle();
      await _send(tester);
      await tester.pumpAndSettle();
      expect(acted, 1);
      expect(store.loadTurnState(world.id)?.worldStep, 1);
      expect(store.loadTimelineWork(world.id, mainTimelineId)?['gate'], isNotNull);
      return;
    }
    String? revisedKey;
    if (reviseMemory) {
      expect(recalled, 1);
      final TurnSession running = store.loadTurnSession(world.id)!;
      revisedKey = running.journal.responses.keys.singleWhere((key) => key.startsWith('CH_MEMORY_WRITE#'));
      await _reviseRawStep(tester, revisedKey, written.replaceAll('红色', '蓝色'));
      expect(acted, 0);
      firstRecall.complete(const LlmReply(text: '{"action":"search","query":"路牌"}'));
      await tester.pumpAndSettle();
    } else if (reviseRecall) {
      expect(recalled, 2);
      final TurnSession running = store.loadTurnSession(world.id)!;
      revisedKey = running.journal.responses.keys.singleWhere((key) => key.startsWith('CH_MEMORY_RECALL#'));
      await _reviseRawStep(tester, revisedKey, search.replaceAll('旧路牌', '新路牌'));
      expect(acted, 0);
      firstRecall.complete(const LlmReply(text: '{"action":"search","query":"门口"}'));
      await tester.pumpAndSettle();
    }
    expect(projected, 1);
    expect(acted, 1);
    final saved = store.loadTurnState(world.id)!;
    expect(saved.events.single.content, '路牌在这里。');
    expect(saved.memory.single.kind.name, 'impression');
    expect(saved.memory.single.text, contains(reviseMemory ? '蓝色路牌' : '红色路牌'));
    expect(wroteMemory, 1);
    expect(recalled, reviseMemory ? 2 : (reviseRecall ? 3 : 1));
    if (revisedKey != null) {
      final int head = store.loadTimelineBranch(world.id, mainTimelineId)!.headVersionId;
      expect(store.loadCompletedTimelineTask(world.id, head)!.journal.responses[revisedKey],
          reviseMemory ? written : search);
    }
    expect(saved.worldStep, 1);
    expect(tester.takeException(), isNull);
  });
  }
}
