/// 面向玩家展示的正式步骤标识。职责和名称稳定，执行顺序另行表示。
abstract final class StepId {
  static const String gmOpenPlace = 'GM_OPEN_PLACE';
  static const String gmRoute = 'GM_ROUTE';
  static const String gmEnvironment = 'GM_ENV_UPDATE';
  static const String gmCast = 'GM_CAST';
  static const String gmObserveScene = 'GM_OBSERVE_SCENE';
  static const String gmEligibility = 'GM_ELIGIBILITY';
  static const String gmSelectActor = 'GM_SELECT_ACTOR';
  static const String gmResolveAction = 'GM_RESOLVE_ACTION';
  static const String gmMergePlace = 'GM_MERGE_PLACE';
  static const String gmNarrate = 'GM_NARRATE';
  static const String gmReviewNarration = 'GM_REVIEW_NARRATION';
  static const String chPerceive = 'CH_PERCEIVE';
  static const String chMemoryWrite = 'CH_MEMORY_WRITE';
  static const String chMemoryRecall = 'CH_MEMORY_RECALL';
  static const String chAct = 'CH_ACT';
  static const String chIntent = 'CH_INTENT';
  static const String gmFileClaim = 'GM_FILE_CLAIM';
  static const String gmResolveBeat = 'GM_RESOLVE_BEAT';
  static const String gmOutcomeView = 'GM_OUTCOME_VIEW';
  static const String gmParseInput = 'GM_PARSE_INPUT';
  static const String sysRecord = 'SYS_RECORD';
  static const String sysRecovery = 'SYS_RECOVERY';
  static const String sysCommit = 'SYS_COMMIT';

  static String base(String id) => id.split(':').first;

  static String title(String id) {
    final String key = base(id);
    for (final EngineStep step in <EngineStep>[...kAiSteps, ...kLegacySteps]) {
      if (step.id == key) return step.title;
    }
    return switch (key) {
      sysRecord => '记录事件',
      sysRecovery => '玩家接管与恢复',
      sysCommit => '提交回合',
      _ => key,
    };
  }

  static String label(String id) {
    final String key = id;
    final String name = title(key);
    return name == key ? key : '$key · $name';
  }
}

typedef EngineStep = ({String id, String title, String hint});

const List<EngineStep> kAiSteps = <EngineStep>[
  (id: StepId.gmOpenPlace, title: '判断开启并行地点', hint: '判断是否为已知地点开启并行序列'),
  (id: StepId.gmRoute, title: '选择回合路线', hint: '决定环境更新或角色行动'),
  (id: StepId.gmEnvironment, title: '推进环境变化', hint: '提出世界自身的事件和持续变化'),
  (id: StepId.gmObserveScene, title: '裁定现场见闻', hint: '把当前环境过滤为每个角色此刻可感知的现场'),
  (id: StepId.chMemoryWrite, title: '整理角色记忆', hint: '提出该角色自己的记忆操作'),
  (id: StepId.chIntent, title: '提出行动意图', hint: '依据投递的见闻和记忆，一次写出行动意图'),
  (id: StepId.gmFileClaim, title: '立案', hint: '把私人意图转成公开主张，不替角色扩知'),
  (id: StepId.gmResolveBeat, title: '裁决这一拍', hint: '结算这一拍行动意图的成败与各人见闻'),
  (id: StepId.gmOutcomeView, title: '翻译结果见闻', hint: '把客观结算翻成某个角色能感知到的那份'),
  (id: StepId.gmParseInput, title: '解析玩家输入', hint: '从 GM 侧将玩家原文解析为角色行动、台词和内心'),
  (id: StepId.gmNarrate, title: '生成叙事正文', hint: '依据已接受事件生成玩家看到的正文'),
  (id: StepId.gmReviewNarration, title: '复核叙事正文', hint: '复核正文是否增加事件之外的事实'),
  (id: StepId.gmMergePlace, title: '判断合并并行地点', hint: '判断是否并入其他活动序列'),
];

/// 旧链只用于读取旧存档；不再出现在设置、流程和提示词编辑里。
const List<EngineStep> kLegacySteps = <EngineStep>[
  (id: StepId.chPerceive, title: '角色感知', hint: '理解该角色当前可感知的新事件'),
  (id: StepId.gmCast, title: '确定在场角色', hint: '从现场已知角色中确定在场名单'),
  (id: StepId.gmEligibility, title: '筛选行动资格', hint: '从程序基础名单中排除不能行动的角色'),
  (id: StepId.gmSelectActor, title: '选择行动角色', hint: '从合格名单中选出唯一行动者'),
  (id: StepId.chMemoryRecall, title: '召回角色记忆', hint: '选出该角色此刻会想起的记忆'),
  (id: StepId.chAct, title: '提出角色行动', hint: '依据角色所知提出本步行动记录'),
  (id: StepId.gmResolveAction, title: '裁定行动结果', hint: '依据权威状态裁定行动的结果和各角色见闻'),
];
