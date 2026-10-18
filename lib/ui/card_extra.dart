// 画布上“某张卡长高 / 收回去”的过渡。
//
// 为什么不能只记一个数：
//   · 从 A 换到 B 时，**A 要收、B 要长**，两件事得同时成立；
//   · 只记一个数的话，A 会直接缩回原样（没有动画），
//     而那个数会被套到 B 所在的行上 —— 于是画面上冒出一段根本不该有的位移。
//
// 所以按“哪张卡”（列 id + 行号）分别记，各自往各自的目标走。
// 下面的行要整体让位，让位的量 = 它上面所有卡多出来的高度之和。

import 'dart:math' as math;

class CardExtra {
  CardExtra({this.timeConstant = 0.065});

  /// 时间常数（秒）。65ms 大约 0.3 秒到位。
  final double timeConstant;

  final Map<(String, int), double> _v = <(String, int), double>{};

  /// 这张卡现在多出来多少高度（动画值）。
  double of(String laneId, int row) => _v[(laneId, row)] ?? 0;

  /// 第 row 行**以上**累计多出来多少（下面的行要整体让位）。
  double padAbove(int row) {
    double s = 0;
    for (final MapEntry<(String, int), double> e in _v.entries) {
      if (e.key.$2 < row) s += e.value;
    }
    return s;
  }

  /// 现在每张卡多出来多少（给画底层连线的那层用）。
  Map<(String, int), double> get values =>
      Map<(String, int), double>.unmodifiable(_v);

  /// 什么都没在动。
  bool get idle => _v.isEmpty;

  void clear() => _v.clear();

  /// 往前推 dt 秒。目标：`target` 那张卡 → [targetValue]，其它一律 → 0。
  /// 返回 true = 还在动，调用方应该继续要下一帧。
  bool advance(double dt, {(String, int)? target, double targetValue = 0}) {
    final double k = 1 - math.exp(-dt / timeConstant);
    bool moving = false;
    final Set<(String, int)> keys = <(String, int)>{
      if (target != null) target,
      ..._v.keys,
    };
    for (final (String, int) key in keys) {
      final double goal = key == target ? targetValue : 0;
      final double cur = _v[key] ?? 0;
      final double next = cur + (goal - cur) * k;
      if ((next - goal).abs() < 0.5) {
        // 快到了就吸住，不然永远差那么一点点、永远停不下来。
        if (cur != goal) {
          _v[key] = goal;
          moving = true;
        }
      } else {
        _v[key] = next;
        moving = true;
      }
    }
    // 收干净的就丢掉，别越攒越多。
    _v.removeWhere(((String, int) key, double v) => v == 0 && key != target);
    return moving;
  }

  /// 还有卡没走到目标吗（不用推也想知道要不要推）。
  bool needsAdvance({(String, int)? target, double targetValue = 0}) {
    for (final MapEntry<(String, int), double> e in _v.entries) {
      final double goal = e.key == target ? targetValue : 0;
      if ((e.value - goal).abs() >= 0.5) return true;
    }
    if (target != null) {
      final double cur = _v[target] ?? 0;
      if ((cur - targetValue).abs() >= 0.5) return true;
    }
    return false;
  }
}
