import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/engine/perception.dart';
import 'package:joenws/engine/player_input.dart';

NarrativeScene buildScene() {
  return NarrativeScene(
    place: '东门内侧',
    names: <String, String>{
      'char:信标': '信标',
      'char:灵梦': '灵梦',
      'char:艾琳': '艾琳',
    },
    cast: <CharacterSnapshot>[
      CharacterSnapshot(
        id: 'char:信标',
        name: '信标',
        nearby: true,
        aliases: <String, String>{
          'char:灵梦': '巫女',
          'char:艾琳': '联邦女人',
        },
      ),
      CharacterSnapshot(
        id: 'char:灵梦',
        name: '灵梦',
        nearby: true,
        aliases: <String, String>{
          'char:信标': '那个黑铁壳子',
          'char:艾琳': '那个受伤的联邦女人',
        },
      ),
      CharacterSnapshot(
        id: 'char:艾琳',
        name: '艾琳',
        nearby: true,
        aliases: <String, String>{
          'char:信标': '探险家',
          'char:灵梦': '巫女',
        },
      ),
    ],
  );
}

PlayerParseResult buildResult() {
  return const PlayerParseResult(
    raw: '我看向艾琳，因为距离近，所以声音小了一些，“你没事吧？”',
    segments: <PlayerSegment>[
      PlayerSegment(
        id: 's1',
        kind: PlayerSegmentKind.action,
        text: '看向艾琳',
        target: '艾琳',
        delivery: Delivery(
          channel: DeliveryChannel.visual,
          form: 'gesture',
          audience: Audience.scene,
        ),
      ),
      PlayerSegment(
        id: 's2',
        kind: PlayerSegmentKind.speech,
        text: '“你没事吧？”',
        target: '艾琳',
        delivery: Delivery(
          channel: DeliveryChannel.voice,
          form: 'spoken',
          audience: Audience.unknown,
        ),
        deliveryNote: '声音小了一些',
        distanceNote: '因为距离近',
      ),
      PlayerSegment(
        id: 's3',
        kind: PlayerSegmentKind.inner,
        text: '我想',
        delivery: Delivery(
          channel: DeliveryChannel.mental,
          form: 'telepathic',
          audience: Audience.hidden,
        ),
      ),
    ],
    unresolved: <PlayerUnresolved>[
      PlayerUnresolved(
        segmentIds: <String>['s2'],
        field: 'delivery.audience',
        question: '是只让艾琳听见，还是附近/全场也能听见？',
        why: '原文只说声音小了一些。',
        options: <String>['target', 'nearby', 'scene'],
      ),
    ],
    warnings: <String>[],
  );
}

void main() {
  group('PlayerParseResult', () {
    test('audience 未定时要求确认，不能直接 toEvents', () {
      final PlayerParseResult r = buildResult();
      expect(r.needsConfirmation, isTrue);
      expect(r.audienceQuestions.length, 1);
      expect(
        () => r.toEvents(
          playerName: '信标',
          startSeq: 5,
          scene: buildScene(),
        ),
        throwsStateError,
      );
    });

    test('确认 audience 后生成事件，inner 不进事件', () {
      final PlayerParseResult r = buildResult().resolveAudience(
        Audience.scene,
        segmentIds: <String>{'s2'},
      );
      expect(r.needsConfirmation, isFalse);
      final List<WorldEvent> events = r.toEvents(
        playerName: '信标',
        startSeq: 5,
        scene: buildScene(),
      );
      expect(events.length, 2);
      expect(events[0].id, 'E5');
      expect(events[0].summary, '信标看向艾琳');
      expect(events[1].id, 'E6');
      expect(events[1].summary, '信标对艾琳说：“你没事吧？”');
      expect(events[1].delivery.audience, Audience.scene);
      expect(events[1].deliveryNote, '声音小了一些');
      expect(events[1].distanceNote, '因为距离近');
    });

    test('确认后的玩家输入能转成 CH_ACT 行动记录', () {
      final PlayerParseResult r = buildResult().resolveAudience(
        Audience.scene,
        segmentIds: <String>{'s2'},
      );
      final Map<String, Object?> action = r.toActionRecord(
        actorName: '信标',
        scene: buildScene(),
      );
      final List<Object?> segments = action['segments']! as List<Object?>;
      expect(segments, hasLength(2));
      final Map<String, Object?> speech =
          (segments[1]! as Map).cast<String, Object?>();
      expect(speech['kind'], 'speech');
      expect(speech['requires'], <String>['speak']);
      expect(speech['perceivable_by'], hasLength(3));
      expect(action['state_delta'], isEmpty);
    });

    test('玩家行动的状态变化提案能进 CH_ACT 行动记录', () {
      const PlayerParseResult r = PlayerParseResult(
        raw: '我走到门口',
        segments: <PlayerSegment>[
          PlayerSegment(
            id: 's1',
            kind: PlayerSegmentKind.action,
            text: '走到门口',
            delivery: Delivery(
              channel: DeliveryChannel.visual,
              form: 'gesture',
              audience: Audience.scene,
            ),
          ),
        ],
        unresolved: <PlayerUnresolved>[],
        warnings: <String>[],
        stateDelta: <String, Object?>{
          'move': <String, String>{'信标': '门口'},
        },
        stateDeltaEvidence: <String, String>{'move.信标': '走到门口'},
      );
      final Map<String, Object?> action = r.toActionRecord(
        actorName: '信标',
        scene: buildScene(),
      );
      expect(action['state_delta'], <String, Object?>{
        'move': <String, String>{'信标': '门口'},
      });
    });

    test('玩家动作的 requires 会进入 CH_ACT，不再固定为空', () {
      const PlayerParseResult r = PlayerParseResult(
        raw: '我用左手推开箱子',
        segments: <PlayerSegment>[
          PlayerSegment(
            id: 's1',
            kind: PlayerSegmentKind.action,
            text: '用左手推开箱子',
            requires: <String>['use_left_arm', 'act'],
            delivery: Delivery(
              channel: DeliveryChannel.visual,
              form: 'gesture',
              audience: Audience.scene,
            ),
          ),
        ],
        unresolved: <PlayerUnresolved>[],
        warnings: <String>[],
      );
      final Map<String, Object?> action = r.toActionRecord(
        actorName: '信标',
        scene: buildScene(),
      );
      final List<Object?> segments = action['segments']! as List<Object?>;
      expect(
        (segments.single! as Map)['requires'],
        <String>['use_left_arm', 'act'],
      );
    });

    test('对抗动作会带 action_kind，普通行动不带', () {
      const PlayerParseResult r = PlayerParseResult(
        raw: '我扑向艾琳',
        segments: <PlayerSegment>[
          PlayerSegment(
            id: 's1',
            kind: PlayerSegmentKind.action,
            text: '扑向艾琳',
            target: '艾琳',
            actionKind: 'grapple',
            delivery: Delivery(
              channel: DeliveryChannel.visual,
              form: 'gesture',
              audience: Audience.scene,
            ),
          ),
        ],
        unresolved: <PlayerUnresolved>[],
        warnings: <String>[],
      );
      final Map<String, Object?> action = r.toActionRecord(
        actorName: '信标',
        scene: buildScene(),
      );
      final List<Object?> segments = action['segments']! as List<Object?>;
      expect(
        (segments.single! as Map)['action_kind'],
        'grapple',
      );
    });

    test('target 可以用玩家自己的称呼解析回规范名', () {
      const PlayerParseResult r = PlayerParseResult(
        raw: '我看向联邦女人',
        segments: <PlayerSegment>[
          PlayerSegment(
            id: 's1',
            kind: PlayerSegmentKind.action,
            text: '看向联邦女人',
            target: '联邦女人',
            delivery: Delivery(
              channel: DeliveryChannel.visual,
              form: 'gesture',
              audience: Audience.scene,
            ),
          ),
        ],
        unresolved: <PlayerUnresolved>[],
        warnings: <String>[],
      );
      final List<WorldEvent> events = r.toEvents(
        playerName: '信标',
        startSeq: 1,
        scene: buildScene(),
      );
      expect(events.single.target, 'char:艾琳');
    });
  });
}
