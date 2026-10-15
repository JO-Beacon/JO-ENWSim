// 角色的「选择」。
//
// 跟「能力声明」分开：
//   · 能力声明（ModelCaps）在模型那边 —— 客观事实
//   · 选择（这里）跟着**角色** —— 每个角色各有一整套
//
// 采样策略、最大输出、流式、推理档位、要不要 JSON 都在这里。
// 模型那边不再放这些东西。

/// 一个角色的「选择」。
class CharChoices {
  const CharChoices({
    this.temperature = '',
    this.topP = '',
    this.maxOutput = '',
    this.stream = false,
    this.effortLevel = '',
    this.effortBudget = '',
    this.jsonOutput = false,
  });

  /// 温度。空 = 不禁用 / 不传。
  final String temperature;

  /// 核采样 top_p。空 = 不传。
  final String topP;

  /// 最大输出。空 = 不传（用服务端默认）。
  /// 注意这是**这次用多少**，跟模型那边「最多能输出多少」不是一回事。
  final String maxOutput;

  /// 流式输出
  final bool stream;

  /// 推理档位。**等级与预算两个都存**，因为不同厂商形状不同
  /// （有的用等级、有的用预算、有的两个都有），到底发哪个由引擎按模型决定。
  final String effortLevel;
  final String effortBudget;

  /// 请求 JSON 输出
  final bool jsonOutput;

  bool get isEmpty =>
      temperature.isEmpty &&
      topP.isEmpty &&
      maxOutput.isEmpty &&
      !stream &&
      effortLevel.isEmpty &&
      effortBudget.isEmpty &&
      !jsonOutput;

  CharChoices copyWith({
    String? temperature,
    String? topP,
    String? maxOutput,
    bool? stream,
    String? effortLevel,
    String? effortBudget,
    bool? jsonOutput,
  }) =>
      CharChoices(
        temperature: temperature ?? this.temperature,
        topP: topP ?? this.topP,
        maxOutput: maxOutput ?? this.maxOutput,
        stream: stream ?? this.stream,
        effortLevel: effortLevel ?? this.effortLevel,
        effortBudget: effortBudget ?? this.effortBudget,
        jsonOutput: jsonOutput ?? this.jsonOutput,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'temperature': temperature,
        'topP': topP,
        'maxOutput': maxOutput,
        'stream': stream,
        'effortLevel': effortLevel,
        'effortBudget': effortBudget,
        'jsonOutput': jsonOutput,
      };

  static CharChoices fromJson(Map<String, Object?> j) => CharChoices(
        temperature: '${j['temperature'] ?? ''}',
        topP: '${j['topP'] ?? ''}',
        maxOutput: '${j['maxOutput'] ?? ''}',
        stream: j['stream'] == true,
        effortLevel: '${j['effortLevel'] ?? ''}',
        effortBudget: '${j['effortBudget'] ?? ''}',
        jsonOutput: j['jsonOutput'] == true,
      );
}
