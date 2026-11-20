import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/model/demo.dart';
import 'package:joenws/model/turn.dart';

World buildWorld({List<ParallelPlace>? parallelPlaces}) => World(
      id: 'w',
      name: '测试',
      note: '',
      setting: '',
      opening: '',
      playerName: '信标',
      characters: const <CharCard>[
        CharCard(name: '信标', persona: '玩家。', location: '正厅'),
        CharCard(name: '灵梦', persona: '巫女。', location: '正厅'),
      ],
      parallelPlaces: parallelPlaces ??
          const <ParallelPlace>[
            ParallelPlace(id: 'l1', place: '正厅', here: true, events: <TurnStep>[]),
          ],
      moves: const <MoveLink>[],
    );

void main() {
  test('没有序列时自动建第一条；已有序列不重复建', () {
    final World empty = buildWorld(parallelPlaces: const <ParallelPlace>[]);
    final World first = empty.withInitialParallelPlace();
    expect(first.parallelPlaces.length, 1);
    expect(first.parallelPlaces.single.id, 'l1');
    expect(first.parallelPlaces.single.place, '开场');
    expect(first.parallelPlaces.single.here, isTrue);

    final World custom = empty.withInitialParallelPlace(place: '旧宅门廊');
    expect(custom.parallelPlaces.single.place, '旧宅门廊');

    expect(identical(first.withInitialParallelPlace(), first), isTrue);
  });

  test('在空地点开新线：编号往后排，同地点不重复', () {
    final World w = buildWorld().addParallelPlaceAt('仓房', parentId: 'l1');
    expect(w.parallelPlaces.length, 2);
    expect(w.parallelPlaces.last.id, 'l2');
    expect(w.parallelPlaces.last.place, '仓房');
    expect(w.parallelPlaces.last.parentId, 'l1');
    expect(w.parallelPlaces.last.isActive, isTrue);

    final World again = w.addParallelPlaceAt('仓房', parentId: 'l1');
    expect(identical(again, w), isTrue);
    expect(again.parallelPlaces.length, 2);
  });

  test('合并：源线标 merged、目标必须是 active、不能并自己', () {
    final World w = buildWorld()
        .addParallelPlaceAt('仓房')
        .addParallelPlaceAt('后巷');
    final World merged = w.mergeParallelPlace('l1', 'l2');
    expect(merged.parallelPlaces.first.status, 'merged');
    expect(merged.parallelPlaces.first.mergeInto, 'l2');
    expect(merged.parallelPlaces.first.isActive, isFalse);

    expect(identical(w.mergeParallelPlace('l1', 'l1'), w), isTrue);
    expect(identical(w.mergeParallelPlace('l1', 'l9'), w), isTrue);
    expect(identical(w.mergeParallelPlace('l9', 'l2'), w), isTrue);
    // 已经合并的源线不能再当目标。
    expect(identical(merged.mergeParallelPlace('l3', 'l1'), merged), isTrue);
  });

  test('当前操控角色可以切换，角色数据不跟着搬', () {
    final World w = buildWorld();
    final World switched = w.withControlledCharacter('灵梦');
    expect(switched.controlledCharacterName, '灵梦');
    expect(switched.characters.length, w.characters.length);
    expect(switched.characters.first.name, '信标');

    final World ai = switched.withControlledCharacter('');
    expect(ai.controlledCharacterName, isEmpty);
  });

  test('玩家地点变化时刷新“在此”标记', () {
    final World w = buildWorld().addParallelPlaceAt('仓房');
    final World moved = w.withPlayerAt('仓房');
    expect(moved.parallelPlaces.first.here, isFalse);
    expect(moved.parallelPlaces.last.here, isTrue);
    expect(w.withPlayerAt('').parallelPlaces.every((ParallelPlace l) => !l.here), isTrue);
  });

  test('下一序列编号不复用已删除的中间号', () {
    final World w = buildWorld(
      parallelPlaces: const <ParallelPlace>[
        ParallelPlace(id: 'l1', place: '正厅', here: true, events: <TurnStep>[]),
        ParallelPlace(id: 'l5', place: '仓房', here: false, events: <TurnStep>[]),
      ],
    );
    expect(w.nextParallelPlaceId(), 'l6');
  });
}
