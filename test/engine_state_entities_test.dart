import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/engine/engine_state.dart';
import 'package:joenws/engine/perception.dart';
import 'package:joenws/engine/player_input.dart';

void main() {
  test('实体 / 事实 / 内心能往返', () {
    const TurnState state = TurnState(
      events: <WorldEvent>[],
      entities: <String, EntityRecord>{
        'char:灵梦': EntityRecord(
          id: 'char:灵梦',
          kind: 'character',
          name: '灵梦',
          location: '东门内侧',
          state: <String, Object?>{'pose': '站着'},
          relations: <String, String>{'char:信标': '警惕'},
        ),
        'cont:kit': EntityRecord(
          id: 'cont:kit',
          kind: 'container',
          name: '急救箱',
          location: '仓房',
          contains: <String>['item:first_aid_kit_01'],
        ),
      },
      facts: <FactRecord>[
        FactRecord(
          id: 'fact:1',
          subject: 'char:灵梦',
          predicate: 'location',
          object: '东门内侧',
          sinceEvent: 'E1',
          sourceEvent: 'E1',
        ),
      ],
      inner: <InnerEntry>[
        InnerEntry(
          id: 'inner:s1',
          characterId: 'char:灵梦',
          text: '这个黑铁壳子不对劲。',
          sourceEvent: 'E1',
        ),
      ],
    );
    final TurnState decoded = TurnState.decode(state.encode());
    expect(decoded.entities['char:灵梦']!.state['pose'], '站着');
    expect(decoded.entities['char:灵梦']!.relations['char:信标'], '警惕');
    expect(decoded.entities['cont:kit']!.contains.single,
        'item:first_aid_kit_01');
    expect(decoded.facts.single.predicate, 'location');
    expect(decoded.facts.single.object, '东门内侧');
    expect(decoded.inner.single.text, '这个黑铁壳子不对劲。');
    expect(decoded.inner.single.visibility, 'self+god');
  });

  test('P 的 inner 段进 inner 表，不进事件', () {
    const PlayerParseResult result = PlayerParseResult(
      raw: '我看向她，心里想：她不对劲。',
      segments: <PlayerSegment>[
        PlayerSegment(
          id: 's1',
          kind: PlayerSegmentKind.action,
          text: '看向她',
          delivery: Delivery(
            channel: DeliveryChannel.visual,
            form: 'gesture',
            audience: Audience.scene,
          ),
        ),
        PlayerSegment(
          id: 's2',
          kind: PlayerSegmentKind.inner,
          text: '她不对劲',
          delivery: Delivery(
            channel: DeliveryChannel.mental,
            form: 'telepathic',
            audience: Audience.hidden,
          ),
        ),
      ],
      unresolved: <PlayerUnresolved>[],
      warnings: <String>[],
    );
    final List<InnerEntry> inner = result.innerEntries('信标');
    expect(inner.length, 1);
    expect(inner.single.characterId, 'char:信标');
    expect(inner.single.text, '她不对劲');
  });
}
