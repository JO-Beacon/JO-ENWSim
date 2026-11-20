import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/data/world_store.dart';
import 'package:joenws/engine/character_memory.dart';
import 'package:joenws/engine/engine_state.dart';
import 'package:joenws/engine/perception.dart';
import 'package:joenws/model/demo.dart';
import 'package:joenws/model/turn.dart';

void main() {
  test('commitTurn 一次写世界、快照、主步和额外步', () {
    final WorldStore store = WorldStore.memory()..seedDemo();
    addTearDown(store.close);

    final World world = store.loadWorlds().worlds.first;
    final String parallelPlaceId = world.parallelPlaces.first.id;
    const TurnStep mainStep = TurnStep(
      kind: 'CH_ACT',
      who: '灵梦',
      time: '现在',
      text: '主步正文',
    );
    const TurnStep extraStep = TurnStep(
      kind: 'GM_OPEN_PLACE',
      who: '旁白',
      time: '现在',
      text: '并行地点记录',
    );

    store.commitTurn(
      worldId: world.id,
      stateJson: '{"events":[]}',
      parallelPlaceId: parallelPlaceId,
      mainStep: mainStep,
      extraSteps: <({String parallelPlaceId, TurnStep step})>[
        (parallelPlaceId: parallelPlaceId, step: extraStep),
      ],
      world: world,
    );

    expect(store.loadLatestWorldState(world.id), '{"events":[]}');
    final List<TurnStep> steps = store.loadSteps(world.id, parallelPlaceId);
    expect(steps.map((TurnStep s) => s.text), containsAll(<String>['主步正文', '并行地点记录']));
  });

  test('commitTurn 新格式把事件和记忆拆表，再组装回来', () {
    final WorldStore store = WorldStore.memory()..seedDemo();
    addTearDown(store.close);
    final World world = store.loadWorlds().worlds.first;
    final String parallelPlaceId = world.parallelPlaces.first.id;
    const WorldEvent event = WorldEvent(
      id: 'E1',
      uid: 'evt-1',
      kind: WorldEventKind.action,
      content: '推门。',
      actor: 'char:灵梦',
      delivery: Delivery(
        channel: DeliveryChannel.other,
        form: 'other',
        audience: Audience.scene,
      ),
    );
    const CharacterMemory memory = CharacterMemory(
      id: 'cm-1',
      characterId: 'char:灵梦',
      text: '我推过门。',
      sourceEvents: <String>['evt-1'],
    );
    final TurnState state = TurnState(
      events: const <WorldEvent>[event],
      pendingEvents: const <WorldEvent>[event],
      memory: const <CharacterMemory>[memory],
    );
    store.commitTurn(
      worldId: world.id,
      stateJson: state.encodeCheckpoint(),
      parallelPlaceId: parallelPlaceId,
      mainStep: const TurnStep(kind: 'CH_ACT', text: '门开了。'),
      events: const <WorldEvent>[event],
      memory: const <CharacterMemory>[memory],
      world: world,
    );
    final TurnState? loaded = store.loadTurnState(world.id);
    expect(loaded, isNotNull);
    expect(loaded!.events.single.uid, 'evt-1');
    expect(loaded.pendingEvents.single.uid, 'evt-1');
    expect(loaded.memory.single.text, '我推过门。');

    store.saveWorldMemory(world.id, <CharacterMemory>[
      memory.copyWith(text: '我后来又推了一次门。'),
    ]);
    final TurnState? edited = store.loadTurnState(world.id);
    expect(edited, isNotNull);
    expect(edited!.events.single.uid, 'evt-1');
    expect(edited.memory.single.text, '我后来又推了一次门。');
  });
}
