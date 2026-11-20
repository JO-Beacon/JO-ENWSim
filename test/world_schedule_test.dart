import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/engine/causal_context.dart';
import 'package:joenws/engine/engine_state.dart';
import 'package:joenws/engine/local_turn_scope.dart';
import 'package:joenws/engine/perception.dart';
import 'package:joenws/engine/sequence.dart';
import 'package:joenws/engine/state_delta.dart';
import 'package:joenws/engine/turn_loop.dart';
import 'package:joenws/engine/world_schedule.dart';
import 'package:joenws/model/demo.dart';

import 'engine_turn_loop_test.dart' show FakeAgents;

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

NarrativeScene _scene(String place) {
  final String actor = place == '酒馆' ? '慧音' : '灵梦';
  return NarrativeScene(
    place: place,
    names: <String, String>{'char:$actor': actor, 'key': '钥匙'},
    cast: <CharacterSnapshot>[CharacterSnapshot(id: 'char:$actor', name: actor, nearby: true)],
  );
}

Map<String, Object?> _take(String actor) => <String, Object?>{
  'segments': <Object?>[
    <String, Object?>{
      'kind': 'action', 'action_kind': 'take', 'text': '伸手取钥匙。', 'target': null,
      'delivery': <String, Object?>{'channel': 'visual', 'form': 'gesture', 'audience': 'scene'},
      'requires': <String>[], 'perceivable_by': <String>[],
    },
  ],
  'state_delta': <String, Object?>{
    'items': <Object?>[
      <String, Object?>{'kind': 'take', 'item_id': 'key', 'from': '酒馆', 'to': actor},
    ],
  },
};

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

  test('有共享通路的两地争同一件物品，只结算一个归属', () async {
    final FakeAgents agents = FakeAgents(
      choices: <String>['慧音'], actions: <Map<String, Object?>>[_take('慧音'), _take('灵梦')],
    );
    final TurnTrace result = await TurnLoop(
      scene: _scene('酒馆'), agents: agents, deferPresentation: true,
      causalContext: const CausalContext(state: _contestBase),
      otherParallelPlaces: const <ParallelPlaceInfo>[
        ParallelPlaceInfo(id: 'b', place: '仓房', members: <String>['灵梦']),
      ],
      sceneForPlace: _scene,
      contestDecider: (item, attempts, errors) async {
        expect(item, 'key');
        expect(attempts.map((attempt) => attempt['place']), ['酒馆', '仓房']);
        return <String, Object?>{'winner': '灵梦', 'outcome': 'resolved', 'reason': '仓房一侧先够到。'};
      },
    ).run(newEvents: [], actorNames: ['慧音']);
    expect(result.arbitration?['winner'], '灵梦');
    expect(result.events.map((event) => event.outcome), ['failure', 'success']);
    expect(result.events.map((event) => event.turnIndex).toSet(), hasLength(1));
    expect(result.events.last.witnesses.map((witness) => witness.characterId), isNot(contains('char:慧音')));
    final TurnState settled = _contestBase.applyDelta(result.stateDelta!);
    expect(settled.entities['key']!.location, '灵梦');
    expect(settled.inventories, <String, List<String>>{'灵梦': ['key']});
  });

  test('远处争用轮到人控角色时，在提交任何结果前等待玩家', () async {
    final TurnTrace result = await TurnLoop(
      scene: _scene('酒馆'),
      agents: FakeAgents(choices: ['慧音'], action: _take('慧音')),
      causalContext: const CausalContext(state: _contestBase),
      controlledCharacter: '灵梦',
      otherParallelPlaces: const <ParallelPlaceInfo>[
        ParallelPlaceInfo(id: 'b', place: '仓房', members: <String>['灵梦']),
      ],
      sceneForPlace: _scene,
      contestDecider: (_, _, _) async => throw StateError('玩家还没回应，不应裁定。'),
    ).run(newEvents: [], actorNames: ['慧音']);
    expect(result.stop?.code, 'player_action');
    expect(result.events, isEmpty);
  });

  for (final bool ordered in <bool>[false, true]) {
  test(ordered ? '多项依赖按已知时序结算并逐项检查前提' : '对同一扇门的互斥尝试只提交一种结果', () async {
    final NarrativeScene scene = NarrativeScene(place: '仓房', cast: <CharacterSnapshot>[
      CharacterSnapshot(id: 'char:甲', name: '甲', nearby: true),
      CharacterSnapshot(id: 'char:乙', name: '乙', nearby: true),
    ], names: <String, String>{'char:甲': '甲', 'char:乙': '乙', 'door': '仓门'});
    final TurnState base = TurnState(events: const [], entities: const <String, EntityRecord>{
      'door': EntityRecord(id: 'door', kind: 'other', name: '仓门', location: '仓房'),
    }, facts: <FactRecord>[
      const FactRecord(id: 'door-position', subject: 'door', predicate: 'open_state', object: 'ajar'),
      if (ordered) ...const <FactRecord>[
        FactRecord(id: 'door-bar', subject: 'door', predicate: 'latched', object: 'true'),
        FactRecord(id: 'first', subject: 'door', predicate: 'time_boundary', object: '解闩', evidence: '先检查门闩。'),
        FactRecord(id: 'second', subject: 'door', predicate: 'time_boundary', object: '验门', evidence: '检查完后再试门。'),
        FactRecord(id: 'order', subject: 'first', predicate: 'time_before', object: 'second'),
      ],
    ]);
    Map<String, Object?> attempt(String state, String text, {bool earlier = false}) => <String, Object?>{
      if (ordered) 'time_boundary_id': earlier ? 'first' : 'second',
      if (ordered && !earlier) 'preconditions': <Object?>[
        <String, Object?>{'subject': 'door', 'predicate': 'latched', 'object': 'false'},
      ],
      'segments': <Object?>[
        <String, Object?>{
          'kind': 'action', 'action_kind': 'gesture', 'text': text,
          'delivery': <String, Object?>{'channel': 'visual', 'form': 'gesture', 'audience': 'scene'},
          'requires': <String>[], 'perceivable_by': <String>[],
        },
      ],
      'state_delta': <String, Object?>{
        'facts': <Object?>[
          StateFactDelta(subject: 'door', predicate: 'open_state', object: state,
              evidence: text, visibility: 'public').toJson(),
          if (ordered && earlier) const StateFactDelta(subject: 'door', predicate: 'latched',
              object: 'false', evidence: '拨开门闩。', visibility: 'public').toJson(),
        ],
      },
    };
    final TurnTrace result = await TurnLoop(
      scene: scene,
      agents: FakeAgents(choices: [ordered ? '乙' : '甲'], actions: ordered
          ? [attempt('closed', '关上仓门。'), attempt('open', '拨开门闩并推开仓门。', earlier: true)]
          : [attempt('open', '推开仓门。'), attempt('closed', '关上仓门。')]),
      causalContext: CausalContext(state: base), deferPresentation: true,
      contestDecider: (subject, attempts, errors) async {
        expect(ordered, isFalse, reason: '现有时间关系和可验证前提足以确定顺序。');
        expect(subject, 'door');
        expect(attempts.map((a) => a['contested_property']), ['open_state', 'open_state']);
        return <String, Object?>{'winner': '乙', 'outcome': 'resolved'};
      },
    ).run(newEvents: [], actorNames: ['甲', '乙']);
    expect(result.events.map((event) => event.actor), <String>['char:甲', 'char:乙']);
    expect(result.events.map((event) => event.outcome), [ordered ? 'success' : 'failure', 'success']);
    TurnState settled = base;
    for (final StateDelta delta in result.orderedDeltas) {
      settled = settled.applyDelta(delta);
    }
    expect(settled.facts.singleWhere((fact) => fact.predicate == 'open_state').object, 'closed');
    if (ordered) expect(settled.facts.singleWhere((fact) => fact.predicate == 'latched').object, 'false');
  });
  }
}
