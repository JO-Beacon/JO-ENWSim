// 画布排版（换地点线必须走空档）的测试。
//
// 这块原来藏在 `_WorkspaceState` 里，只能靠手点看效果；抽成纯函数之后，
// 「往上走的换地点」「竖段被卡挡住」这两条路径可以钉住。

import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/model/demo.dart';
import 'package:joenws/model/pack_rows.dart';
import 'package:joenws/model/turn.dart';

SeqLane lane(String id, int steps) => SeqLane(
  id: id,
  place: id,
  here: false,
  events: <TurnStep>[
    for (int i = 0; i < steps; i++) TurnStep(kind: 'A1', text: '$id#$i'),
  ],
);

/// 每条换地点线都得满足：①线是往下走的；②起点列里，源卡和目标行之间没有卡。
void expectChannelsClear(
  List<SeqLane> lanes,
  List<MoveLink> moves,
  Map<String, List<int>> rows,
) {
  for (final MoveLink m in moves) {
    final List<int> src = rows[m.fromLane]!;
    final int sr = src[m.fromStep];
    final int dr = rows[m.toLane]![m.toStep];

    expect(dr, greaterThan(sr), reason: '换地点线不能往上穿过起点列里更早的卡');

    for (int k = 0; k < src.length; k++) {
      if (k == m.fromStep) continue;
      expect(
        src[k] > sr && src[k] < dr,
        isFalse,
        reason: '起点列第 ${k + 1} 步（行 ${src[k]}）卡在竖线中间（$sr → $dr）',
      );
    }
  }
}

void main() {
  test('demo 世界：默认错行，只有后巷被推下一格', () {
    final World w = DemoData.worlds.first;
    final Map<String, List<int>> rows = packRows(w.lanes, w.moves);

    expect(rows['l1'], <int>[0, 1, 2, 3, 4]);
    expect(rows['l2'], <int>[0, 1, 2]);
    // 人物3 从仓房绕到后巷、再回正厅：后巷第 2 步要让出竖段，所以推到第 3 行。
    expect(rows['l3'], <int>[0, 1, 3]);
    expectChannelsClear(w.lanes, w.moves, rows);
  });

  test('竖段被起点列后面的卡挡住：该列整体下移', () {
    final List<SeqLane> lanes = <SeqLane>[lane('A', 3), lane('B', 3)];
    final List<MoveLink> moves = <MoveLink>[
      const MoveLink(fromLane: 'A', fromStep: 0, toLane: 'B', toStep: 2),
    ];

    final Map<String, List<int>> rows = packRows(lanes, moves);

    // A 的第 1 步原本在行 1，正好卡在 0 → 2 的竖线中间，只能让路。
    expect(rows['A'], <int>[0, 2, 3]);
    expect(rows['B'], <int>[0, 1, 2]);
    expectChannelsClear(lanes, moves, rows);
  });

  test('往上走的换地点：目标行被压到起点行下面', () {
    final List<SeqLane> lanes = <SeqLane>[lane('A', 3), lane('B', 3)];
    final List<MoveLink> moves = <MoveLink>[
      const MoveLink(fromLane: 'A', fromStep: 2, toLane: 'B', toStep: 0),
    ];

    final Map<String, List<int>> rows = packRows(lanes, moves);

    expect(rows['A'], <int>[0, 1, 2]);
    // 目标行要越过起点行（2），所以 B 整列从第 3 行起。
    expect(rows['B'], <int>[3, 4, 5]);
    expectChannelsClear(lanes, moves, rows);
  });

  test('插不通不会死循环（轮数用完就认）', () {
    final List<SeqLane> lanes = <SeqLane>[lane('A', 2), lane('B', 2)];
    final List<MoveLink> moves = <MoveLink>[
      const MoveLink(fromLane: 'A', fromStep: 1, toLane: 'B', toStep: 0),
      const MoveLink(fromLane: 'B', fromStep: 1, toLane: 'A', toStep: 0),
    ];

    // 只要求它能返回、且行号都非负；两条线互相顶的时候不保证都不穿卡。
    final Map<String, List<int>> rows = packRows(lanes, moves, maxPass: 4);
    expect(rows['A'], hasLength(2));
    expect(rows['B'], hasLength(2));
    expect(
      rows.values.expand((List<int> r) => r).every((int i) => i >= 0),
      isTrue,
    );
  });
}
