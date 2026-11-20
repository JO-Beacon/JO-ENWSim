import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/engine/character_memory.dart';
import 'package:joenws/engine/engine_state.dart';
import 'package:joenws/engine/perception.dart';
import 'package:joenws/engine/state_delta.dart';
import 'package:joenws/engine/turn_session.dart';

void main() {
  test('TurnState 事件日志和 memory 能往返', () {
    const WorldEvent event = WorldEvent(
      id: 'E5',
      kind: WorldEventKind.speech,
      content: '别小瞧任何你不了解的文明。',
      actor: 'char:信标',
      target: 'char:艾琳',
      delivery: Delivery(
        channel: DeliveryChannel.voice,
        form: 'spoken',
        audience: Audience.scene,
      ),
      linkMembers: <String>['char:信标', 'char:艾琳'],
      deliveryNote: '声音小了一些',
      distanceNote: '因为距离近',
      attachmentIds: <String>['a_blue_apple'],
    );
    const CharacterMemory memory = CharacterMemory(
      id: 'm1',
      characterId: 'char:灵梦',
      text: '那个黑铁壳子对那个受伤的联邦女人说……',
      kind: MemoryKind.episodic,
      origin: MemoryOrigin.model,
      sourceEvents: <String>['E5'],
    );
    final TurnState state = const TurnState(
      events: <WorldEvent>[event],
      pendingEvents: <WorldEvent>[event],
      memory: <CharacterMemory>[memory],
      locations: <String, String>{
        'char:灵梦': '东门内侧',
        'char:艾琳': '仓房',
      },
      states: <String, String>{'char:灵梦': '右臂缠着白布条'},
      inventories: <String, List<String>>{
        'char:信标': <String>['item:first_aid_kit_01'],
      },
      injuries: <InjuryFact>[
        InjuryFact(
          who: 'char:魔理沙',
          part: 'left_shoulder',
          kind: 'cut',
          cause: '刀伤',
          treatment: '已包扎',
          note: '还在渗血',
        ),
      ],
      constraints: <FunctionalConstraint>[
        FunctionalConstraint(
          who: 'char:魔理沙',
          capability: 'use_left_arm',
          state: ConstraintState.cannot,
          reason: '左肩刀伤',
        ),
      ],
      playerAnswers: <PlayerAnswer>[
        PlayerAnswer(
          step: 'GM_ENV_UPDATE',
          question: '门锁了吗？',
          answer: '锁了。',
          kind: 'fact',
          createdAt: '2026-11-17T12:00:00+08:00',
        ),
      ],
      stopPoint: StopPoint(
        reason: 'player_action',
        question: '轮到你行动了。',
        options: <String>['观察', '开口'],
        nextActor: '信标',
      ),
    );
    final TurnState decoded = TurnState.decode(state.encode());

    expect(decoded.events.length, 1);
    expect(decoded.events.single.id, 'E5');
    expect(decoded.pendingEvents.single.id, 'E5');
    expect(decoded.events.single.delivery.channel, DeliveryChannel.voice);
    expect(decoded.events.single.delivery.audience, Audience.scene);
    expect(decoded.events.single.deliveryNote, '声音小了一些');
    expect(decoded.events.single.distanceNote, '因为距离近');
    expect(decoded.events.single.linkMembers, <String>['char:信标', 'char:艾琳']);
    expect(decoded.events.single.attachmentIds, <String>['a_blue_apple']);
    expect(decoded.memory.length, 1);
    expect(decoded.memory.single.characterId, 'char:灵梦');
    expect(decoded.memory.single.sourceEvents, <String>['E5']);
    expect(decoded.locations['char:灵梦'], '东门内侧');
    expect(decoded.locations['char:艾琳'], '仓房');
    expect(decoded.states['char:灵梦'], '右臂缠着白布条');
    expect(decoded.inventories['char:信标'], <String>['item:first_aid_kit_01']);
    expect(decoded.injuries.single.part, 'left_shoulder');
    expect(decoded.injuries.single.kind, 'cut');
    expect(decoded.constraints.single.capability, 'use_left_arm');
    expect(decoded.playerAnswers.single.step, 'GM_ENV_UPDATE');
    expect(decoded.playerAnswers.single.answer, '锁了。');
    expect(decoded.playerAnswers.single.kind, 'fact');
    expect(decoded.stopPoint?.reason, 'player_action');
    expect(decoded.stopPoint?.options, <String>['观察', '开口']);
    expect(decoded.stopPoint?.nextActor, '信标');
    expect(decoded.constraints.single.state, ConstraintState.cannot);
  });

  test('空字符串解成空状态', () {
    final TurnState state = TurnState.decode('');
    expect(state.events, isEmpty);
    expect(state.memory, isEmpty);
  });
}
