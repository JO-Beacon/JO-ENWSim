import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/engine/engine_state.dart';
import 'package:joenws/engine/local_turn_scope.dart';
import 'package:joenws/engine/perception.dart';
import 'package:joenws/engine/state_delta.dart';
import 'package:joenws/engine/world_schedule.dart';
import 'package:joenws/model/demo.dart';

const Delivery _delivery = Delivery(
  channel: DeliveryChannel.visual, form: 'gesture', audience: Audience.scene,
);

const World _world = World(
  id: 'schedule', name: '调度', note: '', setting: '', opening: '',
  characters: <CharCard>[
    CharCard(name: '慧音', persona: '', location: '酒馆'),
    CharCard(name: '灵梦', persona: '', location: '仓房'),
  ],
  parallelPlaces: <ParallelPlace>[
    ParallelPlace(id: 'a', place: '酒馆', here: false, events: []),
    ParallelPlace(id: 'b', place: '仓房', here: false, events: []),
  ],
  moves: [],
);

const TurnState _contestBase = TurnState(
  events: [],
  entities: <String, EntityRecord>{
    'place:酒馆': EntityRecord(id: 'place:酒馆', kind: 'place', name: '酒馆'),
    'place:仓房': EntityRecord(id: 'place:仓房', kind: 'place', name: '仓房'),
    'char:慧音': EntityRecord(id: 'char:慧音', kind: 'character', name: '慧音', location: '酒馆'),
    'char:灵梦': EntityRecord(id: 'char:灵梦', kind: 'character', name: '灵梦', location: '仓房'),
    'key': EntityRecord(id: 'key', kind: 'item', name: '钥匙', location: '酒馆'),
  },
  locations: <String, String>{'慧音': '酒馆', '灵梦': '仓房'},
  facts: <FactRecord>[
    FactRecord(id: 'hatch', subject: 'key', predicate: 'shared_access', object: '仓房'),
  ],
);

void main() {
  test('独立地点只看自己的历史，共享物品或跨地见闻要求串行', () {
    const WorldEvent remote = WorldEvent(
      id: 'shift', kind: WorldEventKind.action, content: '仓房换班。', actor: 'char:灵梦',
      placeId: '仓房', delivery: _delivery,
    );
    final LocalTurnScope baseline = LocalTurnScope.capture(_world, TurnState.empty, 'a')!;
    final TurnState independent = TurnState(events: <WorldEvent>[remote]);
    expect(LocalTurnScope.capture(_world, independent, 'a')!.fingerprint, baseline.fingerprint);
    expect(LocalTurnScope.capture(_world, _contestBase, 'a'), isNull);
    expect(LocalTurnScope.capture(_world, _contestBase, 'b'), isNull);

    final WorldEvent message = remote.copyWith(witnesses: const <Witness>[
      Witness(characterId: 'char:慧音', modality: 'hearing', content: '听见仓房报信。'),
    ]);
    final TurnState dependent = TurnState(events: <WorldEvent>[message], pendingEvents: <WorldEvent>[message]);
    expect(LocalTurnScope.capture(_world, dependent, 'a'), isNull);
    expect(LocalTurnScope.capture(_world, dependent, 'b'), isNull);
  });

  test('优先调度有待交付见闻的地点，完成交付后恢复轮询', () {
    const WorldEvent event = WorldEvent(
      id: 'notice', kind: WorldEventKind.action, content: '门铃响了。', actor: '',
      placeId: '仓房', delivery: _delivery, witnessesResolved: true,
      witnesses: <Witness>[
        Witness(characterId: 'char:灵梦', modality: 'hearing', content: '门铃响了。'),
      ],
    );
    const WorldSchedule schedule = WorldSchedule();
    expect(schedule.readyPlaces(_world, const TurnState(events: [], pendingEvents: [event])).first.id, 'b');
    expect(schedule.readyPlaces(_world, TurnState(events: [], pendingEvents: [
      event.copyWith(receivedBy: <String>['char:灵梦']),
    ])).first.id, 'a');
  });

  test('评估结果会跳过相同输入，事实等待会跨地点变化后唤醒', () {
    const WorldSchedule schedule = WorldSchedule();
    const TurnState state = TurnState(events: [], facts: <FactRecord>[
      FactRecord(id: 'remote-condition', subject: 'place:仓房', predicate: 'power', object: 'off'),
    ]);
    final WorldWorkQueue queue = WorldWorkQueue();
    queue.checked('a', schedule.placeInput(_world, state, _world.parallelPlaces.first), state);
    queue.checked('b', schedule.placeInput(_world, state, _world.parallelPlaces.last), state,
        wait: <String, String>{'kind': 'fact_change', 'id': 'remote-condition'});
    queue.actorsServed('a', <String>['甲', '乙'], <String>{'甲'});
    final WorldWorkQueue restored = WorldWorkQueue(queue.toJson());
    expect(restored.actorsDue('a', <String>['甲', '乙']), <String>['乙']);
    restored.actorsServed('a', <String>['甲', '乙'], <String>{'乙'});
    expect(restored.actorsDue('a', <String>['甲', '乙']), <String>['甲', '乙']);
    expect(schedule.readyPlaces(_world, state, queue: restored), isEmpty);
    final TurnState changed = state.withEvents(const <WorldEvent>[
      WorldEvent(id: 'change', kind: WorldEventKind.action, content: '响了一声。',
          actor: '', placeId: '酒馆', delivery: _delivery),
    ]);
    expect(schedule.readyPlaces(_world, changed, queue: restored).map((p) => p.id), ['a']);
    expect(schedule.readyPlaces(_world, changed, queue: restored, hasPlayerInput: true).map((p) => p.id), ['a']);
    expect(schedule.readyPlaces(_world, TurnState.empty, queue: restored).map((p) => p.id), ['b']);
  });

  test('时间推进不得使用未知边界或跨过较早的过程', () {
    const TurnState state = TurnState(
      events: [],
      facts: <FactRecord>[
        FactRecord(id: 'dawn', subject: 'place:酒馆', predicate: 'time_boundary',
            object: '天亮', evidence: '门卫在天亮后换班。'),
        FactRecord(id: 'lights', subject: 'place:酒馆', predicate: 'time_boundary',
            object: '熄灯', evidence: '门卫在天亮前熄灯。'),
        FactRecord(id: 'order', subject: 'lights', predicate: 'time_before', object: 'dawn'),
      ],
      entities: <String, EntityRecord>{
        'fire': EntityRecord(id: 'fire', kind: 'process', name: '火势',
            state: <String, Object?>{'status': 'ongoing'}),
      },
    );
    const WorldSchedule schedule = WorldSchedule();
    Map<String, Object?> propose(String id, Map<String, String> order) =>
        <String, Object?>{'decision': 'advance', 'boundary_id': id, 'process_order': order, 'reason': '已有依据'};
    expect(schedule.timeAdvanceErrors(state, propose('unknown', {'fire': 'at'})), isNotEmpty);
    expect(schedule.timeAdvanceErrors(state, propose('dawn', {})), isNotEmpty);
    expect(schedule.timeAdvanceErrors(state, propose('dawn', {'fire': 'before'})), isNotEmpty);
    expect(schedule.timeAdvanceErrors(state, propose('dawn', {'fire': 'at'})), isNotEmpty);
    expect(schedule.timeAdvanceErrors(state, propose('lights', {'fire': 'at'})), isEmpty);
    expect(state.transitionErrors(const StateDelta(facts: <StateFactDelta>[
      StateFactDelta(subject: 'dawn', predicate: 'time_before', object: 'lights', evidence: '颠倒顺序'),
    ])), anyElement(contains('循环')));
  });

  test('绑定时间边界的过程不能借普通回合提前完成', () {
    final TurnState state = const TurnState(
      events: [],
      facts: <FactRecord>[
        FactRecord(id: 'dawn', subject: 'place:酒馆', predicate: 'time_boundary',
            object: '天亮', evidence: '灯火要烧到天亮。'),
      ],
      entities: <String, EntityRecord>{
        'place:酒馆': EntityRecord(id: 'place:酒馆', kind: 'place', name: '酒馆'),
        'fire': EntityRecord(id: 'fire', kind: 'process', name: '灯火', location: '酒馆',
            state: <String, Object?>{
              'status': 'ongoing', 'kind': 'environment', 'owner': '', 'destination': '',
              'completion_boundary': 'dawn', 'started_turn': 1,
            }),
      },
    );
    const StateDelta finish = StateDelta(processes: <ProcessDelta>[
      ProcessDelta(id: 'fire', place: '酒馆', description: '灯火燃尽',
          completionCondition: '到天亮', status: 'completed'),
    ]);
    expect(state.transitionErrors(finish, atTurn: 4), anyElement(contains('尚未到达')));
    final TurnState reached = state.withEvents(const <WorldEvent>[
      WorldEvent(id: 'time', kind: WorldEventKind.action, content: '天亮了', actor: '',
          source: 'world_time', target: 'dawn', delivery: _delivery, turnIndex: 3),
    ]);
    expect(reached.transitionErrors(finish, atTurn: 4), isEmpty);
  });

  test('空地点的过程保存检查条件，满足条件后重新进入调度', () {
    final World world = _world.copyWith(characters: <CharCard>[_world.characters.first]);
    const TurnState base = TurnState(events: [], facts: <FactRecord>[
      FactRecord(id: 'dawn', subject: 'place:仓房', predicate: 'time_boundary',
          object: '天亮', evidence: '天亮后才能检查仓门。'),
      FactRecord(id: 'fact:place:仓房:power', subject: 'place:仓房', predicate: 'power',
          object: 'off', evidence: '仓房已经停电。'),
    ], entities: <String, EntityRecord>{
      'place:仓房': EntityRecord(id: 'place:仓房', kind: 'place', name: '仓房'),
    });
    const StateDelta wait = StateDelta(processes: <ProcessDelta>[
      ProcessDelta(id: 'check-door', place: '仓房', description: '检查仓门',
          completionCondition: '查明仓门状态', nextCheckBoundary: 'dawn'),
    ]);
    expect(base.transitionErrors(wait), isEmpty);
    final TurnState restored = TurnState.decode(base.applyDelta(wait).encodeCheckpoint());
    const WorldSchedule schedule = WorldSchedule();
    expect(schedule.readyPlaces(world, restored).map((p) => p.id), <String>['a']);
    final TurnState reached = restored.withEvents(const <WorldEvent>[
      WorldEvent(id: 'dawn-event', kind: WorldEventKind.action, content: '天亮了。',
          actor: '', source: 'world_time', target: 'dawn', delivery: _delivery),
    ]);
    expect(schedule.readyPlaces(world, reached).map((p) => p.id), <String>['a', 'b']);

    const StateDelta waitForPower = StateDelta(processes: <ProcessDelta>[
      ProcessDelta(id: 'check-door', place: '仓房', description: '检查仓门',
          completionCondition: '查明仓门状态', nextCheckFact: 'fact:place:仓房:power'),
    ]);
    expect(base.transitionErrors(waitForPower), isEmpty);
    final TurnState unpowered = TurnState.decode(base.applyDelta(waitForPower).encodeCheckpoint());
    expect(schedule.readyPlaces(world, unpowered).map((p) => p.id), <String>['a']);
    final TurnState powered = unpowered.applyDelta(const StateDelta(facts: <StateFactDelta>[
      StateFactDelta(subject: 'place:仓房', predicate: 'power', object: 'on', evidence: '仓房已恢复供电。'),
    ]));
    expect(schedule.readyPlaces(world, powered).map((p) => p.id), <String>['a', 'b']);
  });

}
