// 流程步骤，以及“每个世界的模型配置”。
//
// 每个 AI 步骤都能单独指定模型；展示与配置共用正式语义标识。
// 配置挂在**世界**上：世界默认一份 + 每步可覆盖。
// 全局默认不在这里——全局默认在设置里。

import '../engine/step_id.dart';

export '../engine/step_id.dart';

/// 流程里的一步。设置页的提示词框与模型配置共用这一份。
typedef StepKind = EngineStep;

/// 每一步的**默认提示词**。
///
/// 为什么要有这份：设置 → 引擎 里那些框如果是空的，用户就
/// **看不见、也改不了**引擎到底在跟模型说什么 —— 那等于暗地里另用一套。
/// 所以：框里默认显示这里的内容，用户改了存起来，引擎读存的那份。
///
/// 这里写的只是**这一步的任务**。世界观、角色卡、最近的历史、
/// 输出格式那些公共部分由引擎自己拼，不进这些框。
const Map<String, String> kDefaultPrompts = <String, String>{
  StepId.gmOpenPlace:
      '判断要不要为别处正在发生的事开启一条并行地点。'
      '如果两头已经各走各的、再放一起已经说不通，就该开启；'
      '否则保持原样。把判断与一句理由写出来。',
  StepId.gmRoute:
      '判断本回合该做哪一件：\n'
      '  env  = 环境更新（推进世界自身的事件：昼夜、天气、火势、人群）\n'
      '  turn = 角色回合（某个角色行动一次）\n'
      '没有外部规则，你自己看当前情势定。',
  StepId.gmEnvironment:
      '把世界自身的事件往前推一步。'
      '不要写任何角色的主动行为——那是角色回合的事。'
      '时间标签用文本（比如“入夜之后”），不要用时间戳。',
  StepId.gmCast: '从当前现场已知角色中确定在场名单，不能添加未知角色。',
  StepId.gmObserveScene: '依据当前环境、遮挡和角色状态，分别给出每个角色此刻可以感知的现场。'
      '隐藏事实、容器内部、他人内心和已经过去的事件不能因来到现场而自动获知。',
  StepId.gmEligibility: '判断这一步有资格行动的角色。只能从程序给出的基础名单中排除角色。',
  StepId.gmSelectActor:
      '据每个参与角色各自感知到的内容，'
      '挑唯一一个该行动的角色。只能从参与者里挑。',
  StepId.gmMergePlace:
      '判断这条序列要不要和别的序列合并。'
      '两边已经汇到同一处、分开写反而零碎，就该合；否则保持原样。'
      '把判断与一句理由写出来。',
  StepId.chPerceive:
      '写出这个角色此刻感知到了什么。'
      '只能写它能知道的：看得见、听得见、摸得着的。'
      '不要写它的想法或决定（那是下一步的事），也不要写别人的内心。',
  StepId.chAct:
      '写出这个角色这一步的行为。'
      '一行到几句话，写它做了什么、说了什么，不要写别人的反应。'
      '时间标签用文本，不要用时间戳。',
  StepId.chMemoryWrite:
      '整理这个角色自己的第一人称记忆。只能使用 encode / reinforce / compress / reinterpret / archive，'
      '不能写事件、事实或别人的记忆。',
  StepId.chMemoryRecall:
      '只从这个角色自己的记忆里，选出此刻会想起的条目；不能编造 id。',
  StepId.gmParseInput: '解析玩家原文，不改写原意；未决信息请向玩家本人澄清。',
  StepId.gmResolveAction: '依据世界规则和当前权威状态裁定这一个行动，区分客观结果与各角色见闻。',
  StepId.gmNarrate: '仅依据已接受事件生成正文，行动尝试的实际结果以裁定为准。',
  StepId.gmReviewNarration: '检查正文是否增加事件之外的动作、反应、心理或因果，只报告问题。',
};

/// 这一步默认的提示词（没有就是空串）。
String kDefaultPromptOf(String id) => kDefaultPrompts[id] ?? '';

/// 展示、提示词和逐步模型配置共用正式步骤清单。
const List<StepKind> kSteps = kAiSteps;

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

  ModelPlan copyWith({String? defaultRef, Map<String, String>? byStep}) =>
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
              (Object? k, Object? v) => MapEntry<String, String>('$k', '$v'),
            )
          : const <String, String>{},
    );
  }
}
