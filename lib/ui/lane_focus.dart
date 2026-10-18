// 画布上“展开某一列”的过渡。
//
// 以前是一根全局进度条（0→1），列宽按 `id == 正在展开的那列` 二选一插值。
// 问题：已经展开着 A，再点 B 时那根进度条本来就在 1，于是**一点动画都没有**，
// B 直接跳成展开、A 直接跳成收窄。
//
// 现在每列各有一个 0..1 的进度：
//   · 1 = 这一列整列展开
//   · 0 = 常态
// 换列时 A 的进度 1→0、B 的 0→1，**两边同时在动**，画面就是“收一个、开一个”。
//
// 另外还要一个“有人被聚焦的程度”（`any`，取各列最大值）：它负责让**其它列**
// 从常态宽度收窄。这一项跟着过渡一起动，所以收窄也是平滑的。

import 'dart:math' as math;

class LaneFocus {
  LaneFocus({this.timeConstant = 0.065});

  /// 时间常数（秒）。越小越快；65ms 大约 0.3 秒到位，跟 220ms 的 easeOut 手感接近。
  final double timeConstant;

  /// 列 id → 进度。
  final Map<String, double> _t = <String, double>{};

  String? _target;

  /// 某一列现在展开到什么程度（0..1）。
  double of(String laneId) => _t[laneId] ?? 0;

  /// 现在“有东西在展开”的程度：取各列里最大的那个。
  double get any {
    double g = 0;
    for (final double v in _t.values) {
      if (v > g) g = v;
    }
    return g;
  }

  /// 目标列（null = 谁都别展开）。
  String? get target => _target;

  /// 换目标。真正的过渡发生在 [advance] 里。
  void focus(String? laneId) {
    _target = laneId;
  }

  /// 什么都没展开、也没在动。
  bool get idle => _target == null && _t.values.every((double v) => v == 0);

  /// 清空（换世界时用：不同世界的列 id 会重名，旧进度不能带过去）。
  void clear() {
    _t.clear();
    _target = null;
  }

  /// 往前走 dt 秒。返回 true = 还在动，调用方应该继续要下一帧。
  bool advance(double dt, Iterable<String> laneIds) {
    // 指数趋近：每帧走掉剩余距离的一部分。这样和帧率无关，
    // 掉帧的时候不会一夜之间走完。
    final double k = 1 - math.exp(-dt / timeConstant);
    bool moving = false;
    for (final String id in laneIds) {
      final double goal = id == _target ? 1.0 : 0.0;
      final double cur = _t[id] ?? 0;
      final double next = cur + (goal - cur) * k;
      if ((next - goal).abs() < 0.004) {
        // 快到了就吸住；否则永远差那么一点点，动画停不下来。
        if (cur != goal) {
          _t[id] = goal;
          moving = true;
        }
      } else {
        _t[id] = next;
        moving = true;
      }
    }
    return moving;
  }

  /// 一列的宽度：常态 → （有人展开时）收窄 → （自己展开时）整列宽。
  double width(
    String laneId, {
    required double compact,
    required double shrunk,
    required double focus,
  }) {
    return compact + (shrunk - compact) * any + (focus - shrunk) * of(laneId);
  }
}
