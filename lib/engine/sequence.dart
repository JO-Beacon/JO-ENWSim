// 序列（= 地点）在引擎里的轻量视图。
//
// 画布用 `ParallelPlace`（带步、带排版），引擎只关心“这条线在哪、还开不开、
// 并到哪、现场有谁”。这样 TurnLoop 不需要 import World，也方便单测。

/// 一条序列对引擎的公开信息。
class ParallelPlaceInfo {
  const ParallelPlaceInfo({
    required this.id,
    required this.place,
    this.status = 'active',
    this.parentId = '',
    this.mergeInto = '',
    this.members = const <String>[],
  });

  final String id;
  final String place;

  /// active / merged。只有 active 的序列会参与并行地点和合并判断。
  final String status;

  /// 开启并行地点时从哪条序列分出来；空 = 不是并行地点产生的。
  final String parentId;

  /// 合并目标序列 id；空 = 没合并。
  final String mergeInto;

  /// 这条序列现场的角色名。
  final List<String> members;

  bool get isActive => status == 'active';
}

/// 可以开成新列的地点：有角色在那里，但还没有一条 active 的序列覆盖它。
class ParallelPlaceCandidate {
  const ParallelPlaceCandidate({required this.place, required this.members});

  final String place;
  final List<String> members;

  Map<String, Object?> toJson() => <String, Object?>{
        'place': place,
        'members': members,
      };
}
