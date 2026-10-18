import 'demo.dart';

// 画布的竖向几何，以及“换地点线要走空档”的排版。
//
// 这些数原先散在 workspace.dart 里，跟排版算法挨着才好改；现在挪到这里，
// 是因为排版要能被单元测试直接算 —— 它不该藏在 State 里。

/// 列间空隙。
const double kGap = 28;

/// 表头高度。
const double kHeaderH = 56;

/// 卡片高度（未拉高时）。
const double kCardH = 92;

/// 行间空隙。
const double kCardGap = 34;

/// 行高 = 卡高 + 行距。
const double kRowH = kCardH + kCardGap;

/// 排版：每条序列的事件各占一行。返回 laneId → 每个事件的行号。
///
/// **换地点线要经过的格子必须留空**。一条换地点线分两段：起点列里从卡底到
/// 目标行上方那条空隙的竖段，和空隙里横穿中间几列的横段。两段都不能压在卡上；
/// 走不通就插空行（该列从某一步起整体下移一格），直到走通。
///
/// 判断里**不算**选中拉高的额外高度：拉高的卡自己顶多占到下一个行顶上方
/// `kGap` 处，而横段跑在行顶上方 `kGap/2`，仍有余量；把选中算进来会让一选卡
/// 就整块重排、线跟着跳。
///
/// 最多 [maxPass] 轮。插不通就认 —— 宁可线难看，也不许死循环。
Map<String, List<int>> packRows(
  List<SeqLane> lanes,
  List<MoveLink> moves, {
  int maxPass = 64,
}) {
  final Map<String, List<int>> rows = <String, List<int>>{};
  for (final SeqLane l in lanes) {
    rows[l.id] = <int>[for (int i = 0; i < l.events.length; i++) i];
  }

  double rowTop(int i) => kHeaderH + i * kRowH;
  double cardBottom(int i) => rowTop(i) + kCardH;

  // 这一列从第 [from] 步起整体下移一格 —— 等于插一个空行。
  void pushDown(String laneId, int from) {
    final List<int> r = rows[laneId]!;
    for (int k = from; k < r.length; k++) {
      r[k] += 1;
    }
  }

  int laneIndex(String id) => lanes.indexWhere((SeqLane l) => l.id == id);

  for (int pass = 0; pass < maxPass; pass++) {
    bool changed = false;
    for (final MoveLink m in moves) {
      final List<int>? src = rows[m.fromLane];
      final List<int>? dst = rows[m.toLane];
      if (src == null || dst == null) continue;
      if (m.fromStep >= src.length || m.toStep >= dst.length) continue;

      final int sr = src[m.fromStep];
      final int dr = dst[m.toStep];

      // 往上走（换回先走过的地点）：竖线得倒着穿过起点列里更早的那几张卡，
      // 那些卡动不了 —— 只能把目标行压到起点行下面，让线改成往下走。
      if (dr <= sr) {
        pushDown(m.toLane, m.toStep);
        changed = true;
        continue;
      }

      final double yH = rowTop(dr) - kGap / 2;

      // ① 竖段：起点列里夹在源卡和目标行之间的卡。
      bool blocked = false;
      for (int k = 0; k < src.length && !blocked; k++) {
        if (k == m.fromStep) continue;
        blocked = src[k] > sr && src[k] < dr;
      }
      if (blocked) {
        pushDown(m.fromLane, m.fromStep + 1);
        changed = true;
        continue;
      }

      // ② 横段：它横穿的是中间那几列（列序 = 世界里的顺序）。
      //     通道高度是 yH，这高度上不能有卡。按现在的 kCardH / kCardGap，
      //     上下两张卡分别离 yH 还有 14 / 20，本来就不会撞；留着这一条是
      //     为了以后改卡高、改间距时不默默穿卡。
      final int a = laneIndex(m.fromLane);
      final int b = laneIndex(m.toLane);
      final int lo = (a < b ? a : b) + 1;
      final int hi = (a < b ? b : a);
      for (int li = lo; li < hi && !blocked; li++) {
        final SeqLane mid = lanes[li];
        final List<int> r = rows[mid.id]!;
        for (int k = 0; k < r.length; k++) {
          if (rowTop(r[k]) < yH && yH < cardBottom(r[k])) {
            blocked = true;
            break;
          }
        }
      }
      if (blocked) {
        pushDown(m.toLane, m.toStep);
        changed = true;
      }
    }
    if (!changed) break;
  }
  return rows;
}
