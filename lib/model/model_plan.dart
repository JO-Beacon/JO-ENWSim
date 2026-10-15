// 流程步骤，以及“每个世界的模型配置”。
//
// 每一步（A₀–A₄ / B₁ / B₂）都能**单独指定模型**。
// 配置挂在**世界**上：世界默认一份 + 每步可覆盖。
// 全局默认不在这里——全局默认在设置里。

/// 流程里的一步。设置页的提示词框与模型配置共用这一份。
typedef StepKind = ({String id, String title, String hint});

/// 流程图里的七步。
const List<StepKind> kSteps = <StepKind>[
  (id: 'A0', title: '是否分裂序列', hint: '判断这条序列要不要裂成两条'),
  (id: 'A1', title: '环境更新', hint: '把世界自身的事件推进到当前时刻'),
  (id: 'A2', title: '框选参与的角色', hint: '本回合有资格行动的角色'),
  (id: 'A3', title: '框选唯一的角色', hint: '从参与角色里挑出唯一的那个去行动'),
  (id: 'A4', title: '是否需要合并', hint: '要不要和其他序列合并'),
  (id: 'B1', title: '角色感知', hint: '该角色感知到了什么'),
  (id: 'B2', title: '角色行为', hint: '该角色如何行动'),
];

/// 一次模型选择：哪个服务商下的哪个模型。
///
/// 为什么要带上服务商：同一个模型 id 可能在多个服务商下都有。
class ModelPick {
  const ModelPick({required this.providerId, required this.modelId});

  final String providerId;
  final String modelId;

  bool get isEmpty => providerId.trim().isEmpty || modelId.trim().isEmpty;

  /// 存成一行字符串用的键。
  /// 用 \u0000 分隔：模型 id 里可能有斜杠、冒号之类，用普通符号不安全。
  String get key => '$providerId\u0000$modelId';

  static ModelPick? of(String? key) {
    if (key == null || key.isEmpty) return null;
    final int i = key.indexOf('\u0000');
    if (i <= 0) return null;
    return ModelPick(
      providerId: key.substring(0, i),
      modelId: key.substring(i + 1),
    );
  }
}

/// 一层模型配置：一个“本层默认” + 逐步骤覆盖。
///
/// 两级共用同一个结构：
///   - 世界级：挂在世界上，存在世界数据里
///   - 全局级：放在设置 → 引擎里，存盘
///
/// 取用顺序：这一步(本世界) → 本世界默认 → 这一步的全局默认 → 全局总默认。
/// 每一层只存自己那两级，不重复存下层。
class ModelPlan {
  const ModelPlan({
    this.defaultRef = '',
    this.byStep = const <String, String>{},
  });

  /// 本层默认（[ModelPick.key]）。空 = 没设。
  final String defaultRef;

  /// 步骤 id → [ModelPick.key]。缺 / 空 = 跟随本层默认。
  final Map<String, String> byStep;

  /// 这一步实际用的键（还没轮到全局默认）。
  String stepKey(String id) => byStep[id] ?? '';

  ModelPlan copyWith({
    String? defaultRef,
    Map<String, String>? byStep,
  }) =>
      ModelPlan(
        defaultRef: defaultRef ?? this.defaultRef,
        byStep: byStep ?? this.byStep,
      );

  ModelPlan withStep(String id, String key) {
    final Map<String, String> next = <String, String>{...byStep};
    if (key.isEmpty) {
      next.remove(id);
    } else {
      next[id] = key;
    }
    return copyWith(byStep: next);
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'defaultRef': defaultRef,
        'byStep': byStep,
      };

  static ModelPlan fromJson(Map<String, Object?> j) {
    final Object? raw = j['byStep'];
    return ModelPlan(
      defaultRef: '${j['defaultRef'] ?? ''}',
      byStep: raw is Map
          ? raw.map(
              (Object? k, Object? v) =>
                  MapEntry<String, String>('$k', '$v'),
            )
          : const <String, String>{},
    );
  }
}
