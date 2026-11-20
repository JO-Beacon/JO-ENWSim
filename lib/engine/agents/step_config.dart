import '../../model/provider.dart';

/// 一个步骤实际选中的 provider + model。
///
/// 这是组合根解析 ModelPlan 后传给 LlmAgentRunner 的结果；
/// 引擎本身不读 ModelPlan，也不知道 provider 配置。
typedef StepModelChoice = ({Provider provider, String model});

/// 按步骤和角色解析模型。focus 只用于 CH_PERCEIVE / CH_ACT 这种角色步骤。
typedef StepModelResolver = StepModelChoice? Function(
  String stepId, {
  String focus,
});
