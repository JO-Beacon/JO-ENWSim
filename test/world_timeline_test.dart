import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/data/world_store.dart';
import 'package:joenws/engine/character_memory.dart';
import 'package:joenws/engine/engine_state.dart';
import 'package:joenws/engine/perception.dart';
import 'package:joenws/model/demo.dart';
import 'package:joenws/model/turn.dart';

void main() {
  test('分支共享已完成回合，后续版本和回执各自保存', () async {
    final Directory dir = await Directory.systemTemp.createTemp('jo-timeline-');
    addTearDown(() => dir.delete(recursive: true));
    final String path = '${dir.path}${Platform.pathSeparator}world.db';
    late String worldId;
    late String branchId;
    late int firstId;
    late int siblingHeadId;
    late int mainHeadId;

    final WorldStore store = await WorldStore.open(path: path);
    try {
      final World initial = store.loadWorlds().worlds.first;
      worldId = initial.id;
      final String placeId = initial.parallelPlaces.first.id;
      final int openingId =
          store.loadTimelineBranch(worldId, mainTimelineId)!.headVersionId;
      expect(store.loadTimelineSnapshot(worldId, openingId).version.round, isNull);
      expect(
        () => store.createTimelineBranch(
          worldId: worldId,
          sourceBranchId: mainTimelineId,
          versionId: openingId,
          requestId: 'opening',
        ),
        throwsStateError,
      );

      const WorldEvent event = WorldEvent(
        id: 'E1',
        uid: 'evt-key',
        kind: WorldEventKind.action,
        content: '钥匙仍在桌上。',
        actor: 'char:甲',
        delivery: Delivery(
          channel: DeliveryChannel.other,
          form: 'other',
          audience: Audience.scene,
        ),
        receivedBy: <String>['char:甲'],
      );
      const CharacterMemory memory = CharacterMemory(
        id: 'mem-key',
        characterId: 'char:甲',
        text: '钥匙在桌上。',
        sourceEvents: <String>['evt-key'],
      );
      final TurnState firstState = TurnState(
        events: const <WorldEvent>[event],
        memory: const <CharacterMemory>[memory],
        locations: const <String, String>{'甲': '酒馆'},
      );

      void saveMain(String taskId, World world, TurnState state) {
        store.commitTurn(
          worldId: worldId,
          world: world,
          sessionId: taskId,
          stateJson: state.encodeCheckpoint(),
          parallelPlaceId: placeId,
          mainStep: TurnStep(kind: 'CH_ACT', text: taskId),
          events: state.events,
          memory: state.memory,
        );
      }

      saveMain('main-1', initial, firstState);
      firstId = store.loadTimelineBranch(worldId, mainTimelineId)!.headVersionId;
      final TimelineBranch branch = store.createTimelineBranch(
        worldId: worldId,
        sourceBranchId: mainTimelineId,
        versionId: firstId,
        requestId: 'fork',
      );
      branchId = branch.id;
      expect(branch.headVersionId, firstId);

      final World mainWorld = initial.addParallelPlaceAt('仓库');
      final TurnState mainState = firstState.withHistory(
        events: <WorldEvent>[event.copyWith(receivedBy: <String>['char:甲', 'char:乙'])],
        memory: <CharacterMemory>[memory.copyWith(version: 2, text: '钥匙已经交出。')],
      );
      saveMain('main-2', mainWorld, mainState);
      saveMain('main-2', mainWorld, mainState);
      mainHeadId = store.loadTimelineBranch(worldId, mainTimelineId)!.headVersionId;
      expect(store.timelineHistory(worldId, mainTimelineId).length, 3);
      final String warehouseId = mainWorld.parallelPlaces.singleWhere((p) => p.place == '仓库').id;
      store.saveTimelinePlace(worldId, mainTimelineId, warehouseId);
      store.saveTimelinePlace(worldId, branchId, placeId);

      int saveSibling(String taskId) => store.commitTimelineTurn(
        worldId: worldId,
        branchId: branchId,
        baseVersionId: firstId,
        taskId: taskId,
        world: initial.copyWith(setting: '支线设定'),
        state: firstState.withMemory(<CharacterMemory>[
          memory.copyWith(version: 2, text: '我把钥匙收起来了。'),
        ]),
        newSteps: <({String placeId, TurnStep step})>[
          (placeId: placeId, step: const TurnStep(kind: 'CH_ACT', text: '收起钥匙。')),
        ],
      );
      siblingHeadId = saveSibling('branch-2');
      expect(saveSibling('branch-2'), siblingHeadId);
      store.saveTimelineWork(worldId, mainTimelineId, mainHeadId, <String, Object?>{placeId: 'evaluated'});
      store.saveTimelineWork(worldId, mainTimelineId, firstId, <String, Object?>{placeId: 'stale'});
      expect(() => saveSibling('stale'), throwsStateError);
      expect(
        () => store.createTimelineBranch(
          worldId: worldId,
          sourceBranchId: mainTimelineId,
          versionId: siblingHeadId,
          requestId: 'not-an-ancestor',
        ),
        throwsStateError,
      );
    } finally {
      store.close();
    }

    final WorldStore reopened = await WorldStore.open(path: path);
    addTearDown(reopened.close);
    final TimelineSnapshot first = reopened.loadTimelineSnapshot(worldId, firstId);
    final TimelineSnapshot main = reopened.loadTimelineSnapshot(worldId, mainHeadId);
    final TimelineSnapshot sibling = reopened.loadTimelineSnapshot(worldId, siblingHeadId);
    expect(reopened.loadTimelineBranch(worldId, branchId)!.headVersionId, siblingHeadId);
    expect(reopened.loadTimelinePlace(worldId, mainTimelineId),
        main.world.parallelPlaces.singleWhere((p) => p.place == '仓库').id);
    expect(reopened.loadTimelinePlace(worldId, branchId), sibling.world.parallelPlaces.first.id);
    expect(reopened.loadTimelineWork(worldId, mainTimelineId),
        <String, Object?>{sibling.world.parallelPlaces.first.id: 'evaluated'});
    expect(reopened.loadTimelineWork(worldId, branchId), isNull);
    expect(first.state.events.single.receivedBy, <String>['char:甲']);
    expect(main.state.events.single.receivedBy, <String>['char:甲', 'char:乙']);
    expect(sibling.state.events.single.receivedBy, <String>['char:甲']);
    expect(main.state.memory.single.text, '钥匙已经交出。');
    expect(sibling.state.memory.single.text, '我把钥匙收起来了。');
    expect(main.world.parallelPlaces.map((ParallelPlace p) => p.place), contains('仓库'));
    expect(sibling.world.parallelPlaces.map((ParallelPlace p) => p.place), isNot(contains('仓库')));
    expect(sibling.world.parallelPlaces.first.events.last.text, '收起钥匙。');
    expect(sibling.world.setting, '支线设定');
    expect(
      reopened.timelineHistory(worldId, branchId).map((TimelineVersion v) => v.id),
      <int>[first.version.parentId!, firstId, siblingHeadId],
    );
  });
}
