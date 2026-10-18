// 卡片“长高 / 收回去”的过渡。
//
// 用户报的两个毛病都在这里钉住：
//   1. **换选中时，旧卡要有收回动画**（不是一下缩回去）；
//   2. **不能多出一段不该有的位移**（旧卡那点额外高度不能被套到新卡那里）。

import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/ui/card_extra.dart';

const double card = 92;

/// 一直推到不动为止。
void settle(CardExtra c, {String lane = 'a', int row = 0, double value = 0}) {
  int n = 0;
  while (c.advance(1 / 60, target: (lane, row), targetValue: value)) {
    if (++n > 600) fail('推了 600 帧还没停（不会收敛？）');
  }
}

double height(CardExtra c, String lane, int row) => card + c.of(lane, row);

void main() {
  test('什么都没选：所有卡都是常规高度、不用推帧', () {
    final CardExtra c = CardExtra();
    expect(height(c, 'a', 0), card);
    expect(c.padAbove(3), 0);
    expect(c.idle, isTrue);
    expect(c.advance(1 / 60), isFalse);
  });

  test('选中一张：它长高，下面的行整体让位', () {
    final CardExtra c = CardExtra();
    c.advance(1 / 60, target: ('a', 0), targetValue: 120);
    // 第一帧就该在长，而且下面的行已经开始让位。
    expect(height(c, 'a', 0), greaterThan(card));
    expect(c.padAbove(1), greaterThan(0));
    // 同一行下面别的列不受影响；上面的行更不受影响。
    expect(c.padAbove(0), 0);

    settle(c, value: 120);
    expect(height(c, 'a', 0), card + 120);
    expect(c.padAbove(1), 120);
    expect(c.padAbove(5), 120);
  });

  test('从 A 换到 B：A 在收回、B 在长高，同时发生', () {
    final CardExtra c = CardExtra();
    c.advance(1 / 60, target: ('a', 0), targetValue: 120);
    settle(c, value: 120);
    expect(height(c, 'a', 0), card + 120);

    // 换到第 2 行的另一张卡。
    c.advance(1 / 60, target: ('b', 2), targetValue: 40);
    // ① A 正在收回：既没一下缩回常规，也不是原样不动。
    expect(c.of('a', 0), lessThan(120));
    expect(c.of('a', 0), greaterThan(0));
    // ② B 正在长高。
    expect(c.of('b', 2), greaterThan(0));
    expect(c.of('b', 2), lessThan(40));

    settle(c, lane: 'b', row: 2, value: 40);
    expect(c.of('a', 0), 0, reason: 'A 应该收干净了');
    expect(height(c, 'b', 2), card + 40);
    // 让位只算 B 上面那张 A 的残留（已经 0）+ B 自己的行不算在里面。
    expect(c.padAbove(2), 0);
    expect(c.padAbove(3), 40);
  });

  test('取消选中：卡慢慢缩回去，下面的行慢慢回来', () {
    final CardExtra c = CardExtra();
    c.advance(1 / 60, target: ('a', 1), targetValue: 120);
    settle(c, lane: 'a', row: 1, value: 120);
    expect(c.padAbove(2), 120);

    // 取消：目标没了，全部往 0 走。
    c.advance(1 / 60);
    expect(c.of('a', 1), lessThan(120), reason: '该收回去的地方必须有动画');
    expect(c.of('a', 1), greaterThan(0));
    expect(c.padAbove(2), lessThan(120));

    settle(c);
    expect(c.of('a', 1), 0);
    expect(c.padAbove(2), 0);
    expect(c.idle, isTrue);
  });

  test('换选中时不会多出一段“上一张卡”的位移', () {
    final CardExtra c = CardExtra();
    // A 在第 0 行、B 在第 3 行：换过去时，第 1、2 行**不该**被顶下去。
    c.advance(1 / 60, target: ('a', 0), targetValue: 200);
    settle(c, value: 200);
    expect(c.padAbove(1), 200);

    c.advance(1 / 60, target: ('b', 3), targetValue: 0);
    // 关键：第 1、2 行只受 A 的影响，而 A 是在**收回**，所以只会变小。
    expect(c.padAbove(1), lessThan(200));
    expect(c.padAbove(2), lessThan(200));
    // 第 3 行以上（含 A 残留 + 没有 B）也只会比原来小。
    expect(c.padAbove(3), lessThan(200));
  });

  test('帧率不同，到位时间一致', () {
    final CardExtra slow = CardExtra();
    final CardExtra fast = CardExtra();
    for (int i = 0; i < 18; i++) {
      slow.advance(1 / 60, target: ('a', 0), targetValue: 100);
    }
    for (int i = 0; i < 9; i++) {
      fast.advance(1 / 30, target: ('a', 0), targetValue: 100);
    }
    expect((slow.of('a', 0) - fast.of('a', 0)).abs(), lessThan(2));
    expect(slow.of('a', 0), greaterThan(95));
  });

  test('清空（换世界）', () {
    final CardExtra c = CardExtra();
    c.advance(1 / 60, target: ('a', 0), targetValue: 80);
    settle(c, value: 80);
    c.clear();
    expect(c.of('a', 0), 0);
    expect(c.idle, isTrue);
  });
}
