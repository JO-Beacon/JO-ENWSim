// 画布“展开某一列”的过渡。
//
// 核心不是“能不能展开”，而是**换列时有没有动画**：
// 以前是一根全局 0→1 的进度条，已经展开着 A 再点 B，进度条本来就在 1，
// 于是 B 直接跳成展开、A 直接跳成收窄 —— 一点过渡都没有。
//
// 现在每列各有一个进度，换列时 A 收、B 开，两边同时在动。

import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/ui/lane_focus.dart';

const List<String> lanes = <String>['a', 'b', 'c'];

/// 一直推到不动为止，返回推了多少次（防止死循环用）。
int settle(LaneFocus f, {double dt = 1 / 60, int limit = 600}) {
  int n = 0;
  while (f.advance(dt, lanes)) {
    n++;
    if (n > limit) fail('推了 $limit 帧还没停下来（永远不会收敛？）');
  }
  return n;
}

double w(LaneFocus f, String id) =>
    f.width(id, compact: 260, shrunk: 150, focus: 540);

void main() {
  test('没聚焦时所有列都是常态宽', () {
    final LaneFocus f = LaneFocus();
    for (final String id in lanes) {
      expect(w(f, id), 260);
    }
    // 没目标、没进度：不需要帧。
    expect(f.advance(1 / 60, lanes), isFalse);
  });

  test('展开 A：A 变宽、其它两列同时收窄', () {
    final LaneFocus f = LaneFocus()..focus('a');
    f.advance(1 / 60, lanes);

    // 第一帧就该**两边都在动**：A 比常态宽，B/C 比常态窄。
    expect(w(f, 'a'), greaterThan(260));
    expect(w(f, 'b'), lessThan(260));
    expect(w(f, 'c'), lessThan(260));

    settle(f);
    expect(w(f, 'a'), 540);
    expect(w(f, 'b'), 150);
    expect(w(f, 'c'), 150);
  });

  test('已经展开 A，再点 B：两边同时动（不是一下跳过去）', () {
    final LaneFocus f = LaneFocus()..focus('a');
    settle(f);
    expect(w(f, 'a'), 540);
    expect(w(f, 'b'), 150);

    // 换到 B。
    f.focus('b');
    f.advance(1 / 60, lanes);
    // A 正在收回、B 正在展开 —— 这两条同时成立就是“有动画”。
    expect(w(f, 'a'), lessThan(540));
    expect(w(f, 'a'), greaterThan(150));
    expect(w(f, 'b'), greaterThan(150));
    expect(w(f, 'b'), lessThan(540));

    settle(f);
    expect(w(f, 'a'), 150);
    expect(w(f, 'b'), 540);
    expect(w(f, 'c'), 150);
  });

  test('再换回 A：同样有过渡（不是只有第一次有）', () {
    final LaneFocus f = LaneFocus()..focus('a');
    settle(f);
    f.focus('b');
    settle(f);
    f.focus('a');
    f.advance(1 / 60, lanes);

    expect(w(f, 'a'), greaterThan(150));
    expect(w(f, 'b'), lessThan(540));
    settle(f);
    expect(w(f, 'a'), 540);
    expect(w(f, 'b'), 150);
  });

  test('收起时所有列平滑回到常态宽', () {
    final LaneFocus f = LaneFocus()..focus('b');
    settle(f);
    f.focus(null);
    f.advance(1 / 60, lanes);
    // 中间的某一步：B 比常态宽、比展开窄；其它列也在往回长。
    expect(w(f, 'b'), greaterThan(260));
    expect(w(f, 'b'), lessThan(540));
    expect(w(f, 'a'), lessThan(260));

    settle(f);
    for (final String id in lanes) {
      expect(w(f, id), 260);
    }
    expect(f.idle, isTrue);
  });

  test('换世界清空进度', () {
    final LaneFocus f = LaneFocus()..focus('a');
    settle(f);
    f.clear();
    expect(f.of('a'), 0);
    expect(w(f, 'a'), 260);
    expect(f.target, isNull);
  });

  test('帧率不同，走到位的时间差不多（不靠“每帧固定走一点”）', () {
    final LaneFocus slow = LaneFocus()..focus('a');
    final LaneFocus fast = LaneFocus()..focus('a');
    // 60fps 跑 0.3 秒 / 30fps 跑 0.3 秒
    for (int i = 0; i < 18; i++) {
      slow.advance(1 / 60, lanes);
    }
    for (int i = 0; i < 9; i++) {
      fast.advance(1 / 30, lanes);
    }
    expect((slow.of('a') - fast.of('a')).abs(), lessThan(0.02));
    expect(slow.of('a'), greaterThan(0.95));
  });
}
