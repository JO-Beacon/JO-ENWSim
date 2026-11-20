import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/engine/engine_state.dart';
import 'package:joenws/engine/perception.dart';
import 'package:joenws/engine/state_delta.dart';

void main() {
  test('CH_ACT state_delta 解析事实 + 功能限制 + move + items', () {
    final StateDelta d = StateDelta.fromAction(<String, Object?>{
      'move': <String, Object?>{'char:灵梦': 'place:仓房'},
      'injure': <Object?>[
        <String, Object?>{
          'who': 'char:魔理沙',
          'part': 'left_shoulder',
          'kind': 'cut',
          'cause': '刀伤',
          'treatment': '已包扎',
          'note': '还在渗血',
        },
      ],
      'constraints': <Object?>[
        <String, Object?>{
          'who': 'char:魔理沙',
          'capability': 'use_left_arm',
          'state': 'cannot',
          'reason': '左肩刀伤',
        },
      ],
      'items': <Object?>[
        <String, Object?>{
          'kind': 'take',
          'item_id': 'item:first_aid_kit_01',
          'from': 'char:信标',
          'to': 'char:灵梦',
        },
      ],
    });
    expect(d.moves['灵梦'], '仓房');
    expect(d.injuries.single.who, '魔理沙');
    expect(d.injuries.single.part, 'left_shoulder');
    expect(d.injuries.single.kind, 'cut');
    expect(d.injuries.single.cause, '刀伤');
    expect(d.injuries.single.treatment, '已包扎');
    expect(d.constraints.single.capability, 'use_left_arm');
    expect(d.constraints.single.state, ConstraintState.cannot);
    expect(d.items.single.kind, 'take');
    expect(d.items.single.from, '信标');
    expect(d.items.single.to, '灵梦');
  });

  test('GM_RESOLVE_ACTION deltas 解析 steal / move / injure / constraint', () {
    final StateDelta d = StateDelta.fromArbiter(<String, Object?>{
      'outcome': 'success',
      'deltas': <Object?>[
        <String, Object?>{
          'kind': 'steal',
          'item_id': 'item:first_aid_kit_01',
          'from': 'char:信标',
          'to': 'char:魔理沙',
        },
        <String, Object?>{
          'kind': 'move',
          'id': 'char:灵梦',
          'to': 'place:仓房',
        },
        <String, Object?>{
          'kind': 'injure',
          'who': 'char:魔理沙',
          'part': 'left_shoulder',
          'injury_kind': 'cut',
          'cause': '刀伤',
          'treatment': '已包扎',
        },
        <String, Object?>{
          'kind': 'constraint',
          'who': 'char:魔理沙',
          'capability': 'use_left_arm',
          'state': 'cannot',
          'reason': '左肩刀伤',
        },
      ],
      'reason': 'test',
    });
    expect(d.items.single.kind, 'steal');
    expect(d.moves['灵梦'], '仓房');
    expect(d.injuries.single.kind, 'cut');
    expect(d.constraints.single.capability, 'use_left_arm');
  });

  test('TurnState.applyDelta 只改 delta 里的字段，并记事实/限制', () {
    const TurnState before = TurnState(
      events: <WorldEvent>[],
      locations: <String, String>{
        '灵梦': '东门内侧',
        '魔理沙': '东门内侧',
      },
      states: <String, String>{'魔理沙': '左肩包扎'},
      inventories: <String, List<String>>{
        '信标': <String>['item:first_aid_kit_01'],
      },
    );
    final StateDelta d = StateDelta.fromArbiter(<String, Object?>{
      'deltas': <Object?>[
        <String, Object?>{
          'kind': 'move',
          'id': 'char:灵梦',
          'to': 'place:仓房',
        },
        <String, Object?>{
          'kind': 'injure',
          'who': 'char:魔理沙',
          'part': 'left_shoulder',
          'injury_kind': 'cut',
          'cause': '刀伤',
          'treatment': '已包扎',
          'note': '还在渗血',
        },
        <String, Object?>{
          'kind': 'constraint',
          'who': 'char:魔理沙',
          'capability': 'use_left_arm',
          'state': 'cannot',
          'reason': '左肩刀伤',
        },
        <String, Object?>{
          'kind': 'steal',
          'item_id': 'item:first_aid_kit_01',
          'from': 'char:信标',
          'to': 'char:魔理沙',
        },
      ],
    });
    final TurnState after = before.applyDelta(d);

    expect(after.locations['灵梦'], '仓房');
    expect(after.locations['魔理沙'], '东门内侧');
    expect(after.states['魔理沙'], '左肩包扎');
    expect(after.injuries.single.part, 'left_shoulder');
    expect(after.injuries.single.kind, 'cut');
    expect(after.constraints.single.capability, 'use_left_arm');
    expect(after.blocks('魔理沙', 'use_left_arm'), isTrue);
    expect(after.conditionText('魔理沙'), contains('伤势事实'));
    expect(after.conditionText('魔理沙'), contains('功能限制'));
    expect(after.inventories['信标'], isEmpty);
    expect(after.inventories['魔理沙'], contains('item:first_aid_kit_01'));
    expect(before.locations['灵梦'], '东门内侧');
    expect(before.injuries, isEmpty);
  });

  test('空 delta 不改变状态', () {
    const TurnState before = TurnState(
      events: <WorldEvent>[],
      locations: <String, String>{'灵梦': '东门内侧'},
    );
    final TurnState after = before.applyDelta(const StateDelta());
    expect(after.locations, before.locations);
    expect(after.injuries, isEmpty);
    expect(after.constraints, isEmpty);
  });
}
