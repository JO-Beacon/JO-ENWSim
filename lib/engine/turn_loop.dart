// 通用回合循环
//
// 一回合内：
//   GM_OBSERVE_SCENE 先过滤每个角色此刻可感知的现场
//   CH_PERCEIVE 每个角色只看自己的现场和新事件
//   GM_ELIGIBILITY 程序给基础 eligible，AI 只能排除
//   GM_SELECT_ACTOR AI 从 eligible 里选唯一 actor
//   CH_ACT 该 actor 写行动记录
//   GM_RESOLVE_ACTION 只对物理/对抗行动裁定
//   SYS_RECORD 程序落账（无伦谁被选中）
//   GM_NARRATE 渲染本回合
//
// 这里不直接发 HTTP：AI 调用由 TurnAgents 注入，方便测试，也方便以后换成
// 正式 LlmClient。谁被选中，循环就处理谁，不写死灵梦/慧音。

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'c_writer.dart';
import 'causal_context.dart';
import 'character_memory.dart';
import 'engine_state.dart';
import 'ledger.dart';
import 'memory_agent.dart';
import 'memory_recall.dart';
import 'perception.dart';
import 'render_check.dart';
import 'render_view.dart';
import 'sequence.dart';
import 'state_delta.dart';
import 'step_id.dart';
import 'time_label.dart';
import 'turn_session.dart';

typedef _ActionClaim = ({String subject, String? property, String value});
typedef _ContestAttempt = ({NarrativeScene scene, Map<String, Object?> action, StateDelta delta,
    Set<_ActionClaim> claims});

/// 一次 AI 向玩家（人）求助的请求。不是角色台词，也不进事件。
class PlayerQuestion {
  const PlayerQuestion({
    required this.step,
    required this.code,
    required this.reason,
    required this.question,
    this.options = const <String>[],
    this.kind = 'direction',
  });

  final String step;
  final String code;
  final String reason;
  final String question;
  final List<String> options;

  /// fact / direction / choice。决定玩家的回答要不要写成世界事实。
  final String kind;

  Map<String, Object?> toJson() => <String, Object?>{
        'step': step,
        'code': code,
        'reason': reason,
        'question': question,
        if (options.isNotEmpty) 'options': options,
        'kind': kind,
      };

}

class AskPlayerException implements Exception {
  const AskPlayerException(
    this.request, {
    this.journalKey = '',
    this.answer,
  });

  final PlayerQuestion request;
  final String journalKey;

  /// 恢复时如果已经有玩家回答，就不弹窗，直接重试。
  final String? answer;

  @override
  String toString() => 'AskPlayer(${request.step}): ${request.question}';
}

/// 程序耗尽重试预算后向玩家本人移交，独立于角色的行动和认知。
class RetryExhaustedException extends AskPlayerException {
  RetryExhaustedException({required String step, required String reason})
      : super(retryExhaustedQuestion(step: step, reason: reason));
}

PlayerQuestion retryExhaustedQuestion({required String step, required String reason}) =>
    PlayerQuestion(
      step: step,
      code: 'retry_exhausted',
      reason: reason,
      question: '这一步已耗尽重试次数，需要玩家本人处理。请给出处理指令，'
          '或先修改相关内容，再继续推演。',
      options: const <String>['按当前内容重新尝试'],
    );

/// 玩家暂时不回答，不是错误；保留 session，等下次继续。
class PlayerPausedException implements Exception {
  const PlayerPausedException(this.request);

  final PlayerQuestion request;

  @override
  String toString() => 'PlayerPaused(${request.step}): ${request.question}';
}

typedef PlayerAsker = Future<String?> Function(PlayerQuestion question);

/// 人控角色的 CH_ACT 行动记录提供者。
///
/// 只有 GM_SELECT_ACTOR 选中 [TurnLoop.controlledCharacter] 时才会调用；返回 null 表示
/// 现在没有玩家输入，回合停在“等玩家行动”，不写 CH_ACT checkpoint。
typedef PlayerActionHandler = Future<Map<String, Object?>?> Function({
  required String actor,
  required NarrativeScene scene,
});
typedef StageCallback = void Function(String stage);

typedef ContestDecider = Future<Map<String, Object?>> Function(
  String subjectId,
  List<Map<String, Object?>> attempts,
  List<String> errors,
);

typedef TurnPresentation = ({
  Map<String, Object?> render,
  String publicText,
  String godNote,
  RenderCheckResult check,
  List<String> warnings,
});
typedef CheckpointCallback = void Function(
  String stage,
  Map<String, Object?> data,
);

/// 单步执行到某个 stage 后，用这个异常把控制权交回给界面。
class StagePause implements Exception {
  const StagePause(this.stage);

  final String stage;

  @override
  String toString() => 'StagePause($stage)';
}

/// 需要 GM_RESOLVE_ACTION 的动作类型：物理/对抗。
const Set<String> kArKinds = <String>{
  'attack',
  'dodge',
  'grapple',
  'chase',
  'flee',
  'steal',
  'lockpick',
  'disarm',
  'spell_contest',
  'interact',
};

/// CH_ACT 可以声明的能力名。requires 必须写；没有要求就写 []。
const Set<String> kCapabilities = <String>{
  'use_left_arm',
  'use_right_arm',
  'run',
  'stand',
  'speak',
  'cast',
  'act',
};

bool needsAr(String actionKind) => kArKinds.contains(actionKind);

enum RenderPov { omniscient, player }

/// 每个 AI 步骤的接口。生产实现接 LlmClient；测试用假的。
abstract class TurnAgents {
  Future<Map<String, Object?>> perceive({
    required String name,
    required String context,
    required String events,
  });

  /// CH_PERCEIVE 的图片版：默认忽略图片，旧实现不用改。
  Future<Map<String, Object?>> perceiveWithImages({
    required String name,
    required String context,
    required String events,
    List<String> imageAssetIds = const <String>[],
  }) => perceive(name: name, context: context, events: events);

  Future<List<String>> selectEligible({
    required List<String> baseEligible,
    required List<String> cast,
    String playerNotes = '',
    List<String> errors = const <String>[],
    List<String>? previous,
  });

  Future<String?> selectActor({
    required List<String> eligible,
    required Map<String, Map<String, Object?>> percepts,
    String playerNotes = '',
    List<String> errors = const <String>[],
    String? previous,
  });

  /// CH_MEMORY_WRITE 写侧：没有实现时返回 null，旧测试/旧路径回退到程序写一条感知。
  Future<List<MemoryOperation>?> manageMemory({
    required String characterId,
    required Map<String, Object?> percepts,
    required List<CharacterMemory> memory,
    required Set<String> allowedEventIds,
  }) async =>
      null;

  /// CH_MEMORY_WRITE 召回侧：没有实现时返回 null，旧路径继续读全部活动记忆。
  Future<List<String>?> recallMemory({
    required String characterId,
    required NarrativeScene scene,
    required Map<String, Object?> percepts,
    required List<CharacterMemory> memory,
  }) async =>
      null;

  Future<Map<String, Object?>> act({
    required String name,
    required String context,
    required String perceive,
    required List<String> present,
  });

  /// 把玩家对某一步的回答交给实现方；只有上帝层会用到。
  void setPlayerHelp(Map<String, String> help);

  /// 把某个 AI 调用的回答写进恢复日志。
  void recordPlayerAnswer(String journalKey, String answer);

  /// 只清理失败步骤的模型回放；保留玩家的处理记录。
  void prepareRetry(String stage) {}

  void recordIntervention(String key, PlayerQuestion question, String answer) {
    recordPlayerAnswer(key, answer);
  }

  Future<Map<String, Object?>> adjudicate({
    required Map<String, Object?> action,
    required String actor,
    required String? target,
    required String place,
    required List<String> present,
    List<String> errors = const <String>[],
    Map<String, Object?>? previous,
    String playerNotes = '',
  });

  Future<Map<String, Object?>> render({
    required List<WorldEvent> events,
    RenderPov pov = RenderPov.omniscient,
    String observerId = '',
    NarrativeScene? scene,
    List<String> errors = const <String>[],
    Map<String, Object?>? previous,
  });
}

/// 可选的新协议，避免给旧的 TurnAgents 实现增加必需成员。
abstract interface class ArchiveRecallAgents {
  Future<MemoryRecallResult> recallWithArchive({
    required NarrativeScene scene,
    required Map<String, Object?> percepts,
    required MemoryRecallService service,
  });
}

extension ArchiveRecallAdapter on TurnAgents {
  Future<MemoryRecallResult> recallWithArchive({
    required NarrativeScene scene,
    required Map<String, Object?> percepts,
    required MemoryRecallService service,
  }) async {
    final TurnAgents runner = this;
    if (runner is ArchiveRecallAgents) {
      return (runner as ArchiveRecallAgents).recallWithArchive(
        scene: scene, percepts: percepts, service: service);
    }
    return service.legacy(await recallMemory(
      characterId: service.characterId, scene: scene,
      percepts: percepts, memory: service.active));
  }
}

class ActValidationError {
  const ActValidationError({
    required this.code,
    required this.message,
    this.segmentIndex,
  });

  final String code;
  final String message;
  final int? segmentIndex;

  Map<String, Object?> toJson() => <String, Object?>{
        'code': code,
        'message': message,
        if (segmentIndex != null) 'segment': segmentIndex,
      };
}

class ParallelPlaceOpening {
  const ParallelPlaceOpening({
    required this.place,
    this.why = '',
    this.members = const <String>[],
  });

  final String place;
  final String why;

  /// 由程序按地点算；GM_OPEN_PLACE 只负责选地点，不负责编在场名单。
  final List<String> members;

  Map<String, Object?> toJson() => <String, Object?>{
        'place': place,
        'why': why,
        'members': members,
      };
}

class OpenPlaceResult {
  const OpenPlaceResult({
    required this.openParallelPlace,
    required this.why,
    this.place = '',
    this.members = const <String>[],
    this.openings = const <ParallelPlaceOpening>[],
  });

  final bool openParallelPlace;
  final String why;

  /// 兼容单地点调用方的第一个地点；多地点请用 [allOpenings]。
  final String place;

  /// 第一个地点的在场名单。
  final List<String> members;

  /// GM_OPEN_PLACE 本次决定开启的全部并行地点。
  final List<ParallelPlaceOpening> openings;

  /// 新协议用 [openings]；旧构造器（单个 place）仍归一化成一条。
  List<ParallelPlaceOpening> get allOpenings {
    if (openings.isNotEmpty) return openings;
    if (openParallelPlace && place.trim().isNotEmpty) {
      return <ParallelPlaceOpening>[
        ParallelPlaceOpening(place: place, why: why, members: members),
      ];
    }
    return const <ParallelPlaceOpening>[];
  }
}

class MergePlaceResult {
  const MergePlaceResult({
    required this.merge,
    required this.why,
    this.into = '',
  });

  final bool merge;
  final String why;

  /// merge=true 时并到哪条序列（序列 id）。
  final String into;
}

typedef OpenPlaceDecider = Future<OpenPlaceResult> Function({
  required NarrativeScene scene,
  required List<WorldEvent> events,
  List<String>? errors,
  OpenPlaceResult? previous,
});
typedef RouteDecider = Future<String> Function({
  required NarrativeScene scene,
  required List<WorldEvent> events,
  List<String>? errors,
  String? previous,
});
typedef EnvironmentSource = Future<List<WorldEvent>> Function({
  required NarrativeScene scene,
  required List<WorldEvent> events,
  String? feedback,
});
typedef CastDecider = Future<List<String>> Function({
  required NarrativeScene scene,
  required List<String> knownCast,
  List<String>? errors,
  List<String>? previous,
});
typedef MergePlaceDecider = Future<MergePlaceResult> Function({
  required NarrativeScene scene,
  required List<WorldEvent> events,
});
typedef RCheck = Future<List<String>> Function({
  required String publicText,
  required String godNote,
  required List<WorldEvent> events,
});

typedef SceneObserver = Future<Map<String, String>> Function({
  required NarrativeScene scene,
  required TurnState state,
  required List<String> observers,
});

/// 回合中止。现在只用于 CH_ACT 重试预算耗尽；以后运行状态的 StopPoint 也复用这个结构。
class TurnStop {
  const TurnStop({
    required this.code,
    required this.reason,
    this.question = '',
    this.options = const <String>[],
  });

  final String code;
  final String reason;
  final String question;
  final List<String> options;

  Map<String, Object?> toJson() => <String, Object?>{
        'status': 'stop',
        'code': code,
        'reason': reason,
        if (question.isNotEmpty) 'question': question,
        if (options.isNotEmpty) 'options': options,
      };
}

class TurnTrace {
  const TurnTrace({
    required this.percepts,
    required this.eligible,
    required this.chosen,
    required this.action,
    required this.arbitration,
    required this.stateDelta,
    required this.events,
    required this.render,
    required this.renderViolations,
    required this.blocked,
    required this.stop,
    required this.actErrors,
    this.openPlace = const OpenPlaceResult(
      openParallelPlace: false,
      why: '本回合未到 GM_OPEN_PLACE',
    ),
    this.route = 'turn',
    this.environmentEvents = const <WorldEvent>[],
    this.mergePlace = const MergePlaceResult(merge: false, why: '本回合未到 GM_MERGE_PLACE'),
    this.openPlaceErrors = const <String>[],
    this.routeErrors = const <String>[],
    this.castErrors = const <String>[],
    this.castFailureStep = StepId.gmEligibility,
    this.selectActorErrors = const <String>[],
    this.perceiveErrors = const <String>[],
    this.environmentErrors = const <String>[],
    this.resolveErrors = const <String>[],
    this.needsReview = false,
    this.reviewWarnings = const <String>[],
    this.rejectedEvents = const <WorldEvent>[],
    this.cast = const <String>[],
    this.orderedDeltas = const <StateDelta>[],
  });

  final Map<String, Map<String, Object?>> percepts;
  final List<String> eligible;
  final String? chosen;
  final Map<String, Object?>? action;
  final Map<String, Object?>? arbitration;
  final StateDelta? stateDelta;
  final List<StateDelta> orderedDeltas;
  final List<WorldEvent> events;
  final Map<String, Object?>? render;

  /// GM_NARRATE 的程序硬校验违规；非空表示正文不能交给玩家。
  final List<RenderViolation> renderViolations;

  /// 兜底硬拦下来的能力；正常情况由 CH_ACT 校验回给模型重写，这里防漏。
  final List<FunctionalConstraint> blocked;

  /// 回合中止；现在只有 CH_ACT 重试预算耗尽。非空表示这一回合没有落账。
  final TurnStop? stop;

  /// 本回合 CH_ACT 收到过的契约错误；修好后仍保留，便于展示。
  final List<ActValidationError> actErrors;

  final OpenPlaceResult openPlace;
  /// 本回合走的是 env（环境更新）还是 turn（角色回合）。
  final String route;
  final List<WorldEvent> environmentEvents;
  final MergePlaceResult mergePlace;

  /// GM_OPEN_PLACE 输出不合格的错误；非空表示这一回合没有决定并行地点，不推进。
  final List<String> openPlaceErrors;

  /// GM_ROUTE 输出不合格的错误；非空表示这一回合没有决定路线，不推进。
  final List<String> routeErrors;

  /// GM_ELIGIBILITY 输出不合格的错误；非空表示这一回合没有确定 cast/eligible，不推进。
  final List<String> castErrors;
  final String castFailureStep;

  /// GM_SELECT_ACTOR 输出不合格的错误；非空表示这一回合没有选出 actor，不推进。
  final List<String> selectActorErrors;

  /// CH_PERCEIVE 引用了候选集外的事件时的错误；非空表示这一回合不推进。
  final List<String> perceiveErrors;

  /// GM_ENV_UPDATE 环境事件在 SYS_RECORD 校验里不合格的错误；非空表示这一回合不落账。
  final List<String> environmentErrors;

  /// GM_RESOLVE_ACTION 输出不合格时的错误；非空表示这一回合不落账。
  final List<String> resolveErrors;

  /// GM_RESOLVE_ACTION 说 unresolved 时置 true；需要人工看，不默认命中/失败。
  final bool needsReview;

  /// 可选 GM_REVIEW_NARRATION AI 的软警告；不替代程序硬校验。
  final List<String> reviewWarnings;

  /// 被拒绝的尝试；只留痕，不进记忆 / 正文。
  final List<WorldEvent> rejectedEvents;

  /// GM_ELIGIBILITY 最终 cast（AI 声明后经程序过滤）。
  final List<String> cast;

  /// 无交互宿主也能取得结构化求助；有 askPlayer 时由循环当场移交。
  PlayerQuestion? get playerIntervention {
    if (arbitration?['outcome'] == 'unresolved') {
      return PlayerQuestion(
        step: StepId.gmResolveAction,
        code: 'unresolved_action',
        reason: '${arbitration?['reason'] ?? arbitration?['result'] ?? '行动结果尚未确定'}',
        question: '裁定无法确定这次行动的结果。请补充裁定依据或给出处理指令，再重新裁定。',
      );
    }
    final Map<String, List<String>> failures = <String, List<String>>{
      'GM_OPEN_PLACE': openPlaceErrors, 'GM_ROUTE': routeErrors, 'CH_PERCEIVE': perceiveErrors, castFailureStep: castErrors,
      'GM_SELECT_ACTOR': selectActorErrors, 'GM_ENV_UPDATE': environmentErrors, 'GM_RESOLVE_ACTION': resolveErrors,
      'GM_NARRATE': <String>[
        for (final RenderViolation v in renderViolations) '${v.code}：${v.message}',
        ...reviewWarnings,
      ],
    };
    for (final MapEntry<String, List<String>> failure in failures.entries) {
      if (failure.value.isNotEmpty) {
        return retryExhaustedQuestion(step: failure.key, reason: failure.value.join('\n'));
      }
    }
    if (stop?.code == 'step_budget') {
      return retryExhaustedQuestion(step: 'CH_ACT', reason: <String>[
        stop!.reason, for (final ActValidationError e in actErrors) e.message,
      ].join('\n'));
    }
    return null;
  }
}

class TurnLoop {
  TurnLoop({
    required this.scene,
    required this.agents,
    this.causalContext,
    MemoryStore? memoryStore,
    this.ledger,
    this.engine = const PerceptionEngine(),
    this.constraints = const <FunctionalConstraint>[],
    this.openPlaceStepBudget = 3,
    this.routeStepBudget = 3,
    this.castStepBudget = 3,
    this.selectActorStepBudget = 3,
    this.perceiveStepBudget = 3,
    this.actStepBudget = 8,
    this.resolveStepBudget = 3,
    this.environmentStepBudget = 3,
    this.rStepBudget = 3,
    this.openPlaceDecider,
    this.routeDecider,
    this.environmentSource,
    this.castDecider,
    this.mergePlaceDecider,
    this.parallelPlaceCandidates = const <ParallelPlaceCandidate>[],
    this.otherParallelPlaces = const <ParallelPlaceInfo>[],
    this.pov = RenderPov.omniscient,
    this.entityNames = const <String>[],
    this.cWriter = const CWriter(),
    this.rCheck,
    this.sceneForPlace,
    this.sceneObserver,
    this.controlledCharacter = '',
    this.playerActionHandler,
    this.askPlayer,
    this.onStage,
    this.onCheckpoint,
    this.deferPresentation = false,
    this.contestDecider,
    this.responseRevisions = const <String, String>{},
    this.actorsDue,
    this.recoveryContext = '',
    this.eventNamespace = '',
    Map<String, String>? playerHelp,
    int startSeq = 1,
  })  : memory = memoryStore ?? MemoryStore(),
        _playerHelp = Map<String, String>.of(
          playerHelp ?? const <String, String>{},
        ),
        _seq = startSeq;

  final NarrativeScene scene;
  final bool deferPresentation;
  final String eventNamespace;
  final ContestDecider? contestDecider;
  final Map<String, String> responseRevisions;
  final List<String> Function(List<String> eligible)? actorsDue;

  /// 角色记忆；每回合只增不改事件，随 TurnState 快照一起存。
  final MemoryStore memory;
  final TurnAgents agents;
  final CausalContext? causalContext;
  final Map<String, Set<String>> deliveryReceipts = <String, Set<String>>{};
  final Ledger? ledger;
  final PerceptionEngine engine;

  /// 上一回合结束时的功能限制；CH_ACT 声明 requires 后先做可行性校验，不满足回给 CH_ACT 重写。
  final List<FunctionalConstraint> constraints;

  /// GM_OPEN_PLACE 最多重试几次；说要开启但地点不合格就带着错误重写。
  final int openPlaceStepBudget;

  /// GM_ROUTE 最多重试几次；只能返回 env 或 turn，其它输出带着错误重写。
  final int routeStepBudget;

  /// GM_ELIGIBILITY 最多重试几次；返回 cast 外的名字就带着错误重写。
  final int castStepBudget;

  /// GM_SELECT_ACTOR 最多重试几次；返回 eligible 外的名字就带着错误重写。
  final int selectActorStepBudget;

  /// 每个角色最多允许几次 CH_PERCEIVE：引用了候选集外的事件就带着错误重写。
  final int perceiveStepBudget;

  /// 同一回合最多允许几个 CH_ACT step。这是回合预算，不是“改错次数”；
  /// 合格行动会提前结束，预算耗尽就中止。
  final int actStepBudget;

  /// GM_RESOLVE_ACTION 最多重试几次；裁定不合格就带着错误重写。
  final int resolveStepBudget;

  /// GM_ENV_UPDATE 最多重试几次；环境事件过不了 SYS_RECORD 校验就带着错误重写。
  final int environmentStepBudget;

  /// GM_NARRATE 最多重试几次；正文有硬性违规就带着错误重写。
  final int rStepBudget;

  final OpenPlaceDecider? openPlaceDecider;
  final RouteDecider? routeDecider;
  final EnvironmentSource? environmentSource;
  final CastDecider? castDecider;
  final MergePlaceDecider? mergePlaceDecider;

  /// 有角色、但还没有 active 序列覆盖的地点；空 = 这回合不问 GM_OPEN_PLACE。
  final List<ParallelPlaceCandidate> parallelPlaceCandidates;

  /// 除当前序列外的 active 序列；空 = 这回合不问 GM_MERGE_PLACE。
  final List<ParallelPlaceInfo> otherParallelPlaces;
  final RenderPov pov;
  final List<String> entityNames;
  final CWriter cWriter;
  final RCheck? rCheck;
  final NarrativeScene Function(String place)? sceneForPlace;
  final SceneObserver? sceneObserver;
  final Map<String, String> _sceneObservations = <String, String>{};

  /// 当前由人控制的角色；空 = 全部交给 AI。
  final String controlledCharacter;

  /// 人控角色的 CH_ACT 行动记录；只有 GM_SELECT_ACTOR 选中 controlledCharacter 时才会调用。
  final PlayerActionHandler? playerActionHandler;

  /// 上帝层可主动求助；任何步骤耗尽预算后都由程序向玩家本人移交。
  final PlayerAsker? askPlayer;

  /// 每个 stage 完成后回调；单步模式在这里抛 StagePause。
  final StageCallback? onStage;

  /// 每个 stage 的语义结果；用于 TurnSession checkpoint。
  final CheckpointCallback? onCheckpoint;
  final String recoveryContext;
  final Map<String, String> _playerHelp;
  final Map<String, TurnCheckpoint> _completed = <String, TurnCheckpoint>{};

  void _stage(String stage) => onStage?.call(stage);

  void _checkpoint(String stage, Map<String, Object?> data) {
    _completed[stage] = TurnCheckpoint(stage: stage, data: data);
    onCheckpoint?.call(stage, data);
  }

  int _seq;

  String _eventId(String prefix) {
    final String id = '$prefix${_seq++}';
    return eventNamespace.isEmpty ? id : '$id-$eventNamespace';
  }

  /// 跑一个 actor 回合。newEvents 是上一回合产生的事件。
  ///
  /// actorNames 是现场所有能行动的角色；不再区分 NPC / 当前操控角色。
  /// npcNames 是旧调用名，保留给已有调用点。
  Future<TurnTrace> run({
    required List<WorldEvent> newEvents,
    List<String>? actorNames,
    List<String>? npcNames,
    List<String>? perceptionNames,
    TurnSession? resume,
  }) async {
    _completed
      ..clear()
      ..addAll(resume?.checkpoints ?? const <String, TurnCheckpoint>{});
    final List<CharacterMemory> initialMemory = memory.allEntries();
    final int initialSeq = _seq;
    final String context = sha256.convert(utf8.encode(jsonEncode(<String, Object?>{
      'engineContract': 'core-boundary-fixes-20261118',
      'configuration': recoveryContext,
      'state': causalContext?.state.toCheckpointJson(),
      'worldStep': causalContext?.state.worldStep,
      'rules': causalContext?.rules,
      'opening': causalContext?.opening,
      'place': scene.place,
      'cast': <Object?>[for (final CharacterSnapshot c in scene.cast)
        <String, Object?>{'id': c.id, 'nearby': c.nearby, 'aliases': c.aliases, 'distance': c.distanceNote}],
      'notes': scene.playerNotes, 'characterNotes': scene.characterNotes,
      'sceneObservations': scene.observations,
      'incoming': <Object?>[for (final WorldEvent e in newEvents) worldEventToJson(e)],
      'memory': <Object?>[for (final CharacterMemory m in initialMemory) m.toJson()],
      'actors': actorNames ?? npcNames,
      'perceivers': perceptionNames,
      'controlledCharacter': controlledCharacter,
      'pov': pov.name,
      'constraints': <Object?>[for (final FunctionalConstraint c in constraints) c.toJson()],
      'parallelPlaceCandidates': <Object?>[
        for (final ParallelPlaceCandidate c in parallelPlaceCandidates) c.toJson(),
      ],
      'otherParallelPlaces': <Object?>[
        for (final ParallelPlaceInfo p in otherParallelPlaces)
          <String, Object?>{'id': p.id, 'place': p.place, 'status': p.status, 'members': p.members},
      ],
    }))).toString();
    final TurnCheckpoint? recovery = _completed[StepId.sysRecovery];
    final Object? savedHelp = recovery?.data['help'];
    if (savedHelp is Map) {
      for (final MapEntry<Object?, Object?> e in savedHelp.entries) {
        _playerHelp['${e.key}'] = '${e.value}';
      }
    }
    if (recovery == null) {
      // 普通单步暂停也要能判断恢复点是否仍适用。
      _checkpoint('SYS_RECOVERY', <String, Object?>{
        'context': context, 'pending': false,
        'help': Map<String, String>.of(_playerHelp),
        'invalidate': const <String>[],
      });
    } else if (recovery.data['context'] != context) {
      final List<String> invalidated = _completed.keys.where((String k) => k != StepId.sysRecovery).toList();
      for (final String key in invalidated) { _completed.remove(key); }
      agents.prepareRetry('*');
      _checkpoint('SYS_RECOVERY', <String, Object?>{
        ...recovery.data, 'context': context, 'invalidate': invalidated,
      });
    }
    if (recovery?.data['pending'] == true) {
      await _resolveIntervention(_completed[StepId.sysRecovery]!.data);
    }
    while (true) {
      memory.restore(initialMemory);
      deliveryReceipts.clear();
      _sceneObservations.clear();
      _seq = initialSeq;
      PlayerQuestion request;
      try {
        final TurnTrace trace = await _run(
          newEvents: newEvents, actorNames: actorNames, npcNames: npcNames,
          perceptionNames: perceptionNames,
          resume: TurnSession(
            id: resume?.id ?? '', worldId: resume?.worldId ?? '',
            parallelPlaceId: resume?.parallelPlaceId ?? '', rawInput: resume?.rawInput ?? '',
            journal: resume?.journal ?? TurnJournal(), checkpoints: Map.of(_completed),
          ),
        );
        final PlayerQuestion? failure = trace.playerIntervention;
        if (failure == null || askPlayer == null) return trace;
        request = failure;
      } on RetryExhaustedException catch (failure) {
        if (askPlayer == null) rethrow;
        request = failure.request;
      }
      await _intervene(request, context: context);
    }
  }

  Future<void> _intervene(PlayerQuestion request, {required String context}) async {
    final String stage = request.step;
    final String base = StepId.base(stage);
    final Set<String> invalidate = <String>{stage};
    if (base == StepId.gmNarrate) {
      invalidate.add(StepId.gmMergePlace);
      agents.prepareRetry(StepId.gmReviewNarration);
    }
    if (base == StepId.gmResolveAction || base == StepId.chAct || base == StepId.gmParseInput) {
      invalidate.addAll(<String>[
        StepId.gmResolveAction, StepId.sysRecord, StepId.gmNarrate, StepId.gmMergePlace,
      ]);
      if (base == StepId.gmParseInput) invalidate.add(StepId.chAct);
    }
    if (base == StepId.chMemoryRecall) {
      invalidate.addAll(<String>[
        StepId.chAct, StepId.gmParseInput, StepId.gmResolveAction,
        StepId.sysRecord, StepId.gmNarrate, StepId.gmMergePlace,
      ]);
    }
    if (base == StepId.gmReviewNarration) {
      invalidate.add(StepId.gmMergePlace);
      final TurnCheckpoint? r = _completed[StepId.gmNarrate];
      if (r != null) {
        final Map<String, Object?> data = Map.of(r.data)..remove('warnings');
        _checkpoint('GM_NARRATE', data);
      }
    }
    for (final String key in invalidate) {
      _completed.remove(key);
      agents.prepareRetry(key);
    }
    if (invalidate.contains(StepId.gmNarrate)) agents.prepareRetry(StepId.gmReviewNarration);
    final Map<String, Object?> data = <String, Object?>{
      ...request.toJson(), 'pending': true,
      'key': '${StepId.sysRecovery}#$stage#${DateTime.now().microsecondsSinceEpoch}',
      'help': Map<String, String>.of(_playerHelp), 'context': context,
      'invalidate': invalidate.toList(),
    };
    _checkpoint('SYS_RECOVERY', data);
    agents.prepareRetry(stage);
    await _resolveIntervention(data);
  }

  Future<void> _resolveIntervention(Map<String, Object?> data) async {
    final PlayerQuestion request = PlayerQuestion(
      step: '${data['step']}', code: '${data['code'] ?? 'retry_exhausted'}', reason: '${data['reason']}',
      question: '${data['question']}', options: _stringsFromCheckpoint(data['options']),
    );
    await _askPlayerHelp(AskPlayerException(request, journalKey: '${data['key']}'));
    agents.prepareRetry(request.step);
    _checkpoint('SYS_RECOVERY', <String, Object?>{
      ...data, 'pending': false, 'invalidate': const <String>[],
      'help': Map<String, String>.of(_playerHelp),
    });
  }

  Future<TurnTrace> _run({
    required List<WorldEvent> newEvents,
    List<String>? actorNames,
    List<String>? npcNames,
    List<String>? perceptionNames,
    TurnSession? resume,
  }) async {
    final List<String> actors = actorNames ?? npcNames ?? const <String>[];
    if (pov == RenderPov.player && controlledCharacter.trim().isEmpty) {
      throw const FormatException('角色视角需要先选择操控角色，或切换为全知视角');
    }
    final List<String> perceivers = perceptionNames ?? actors;
    agents.setPlayerHelp(_playerHelp);

    OpenPlaceResult openPlace;
    final TurnCheckpoint? openPlaceCheckpoint = resume?.checkpoints['GM_OPEN_PLACE'];
    if (openPlaceCheckpoint != null) {
      openPlace = _openPlaceFromCheckpoint(openPlaceCheckpoint.data);
    } else {
      final ({OpenPlaceResult result, List<String> errors}) openPlaceDecision =
          await _decideOpenPlace(newEvents);
      openPlace = openPlaceDecision.result;
      if (openPlaceDecision.errors.isNotEmpty) {
        return _decisionError(
          openPlace: openPlace,
          route: 'error',
          openPlaceErrors: openPlaceDecision.errors,
        );
      }
      _stage('GM_OPEN_PLACE');
      _checkpoint('GM_OPEN_PLACE', <String, Object?>{
        'openParallelPlace': openPlace.openParallelPlace,
        'why': openPlace.why,
        'place': openPlace.place,
        'members': openPlace.members,
        'openings': <Object?>[
          for (final ParallelPlaceOpening opening in openPlace.allOpenings)
            opening.toJson(),
        ],
      });
    }

    // GM_ROUTE：决定这一回合走环境更新还是角色回合。
    // 没注入时沿用单序列默认 turn；UI 会注入 AI 版本。
    String route;
    final TurnCheckpoint? routeCheckpoint = resume?.checkpoints['GM_ROUTE'];
    if (routeCheckpoint != null) {
      route = '${routeCheckpoint.data['route'] ?? 'turn'}';
    } else {
      final ({String route, List<String> errors}) routeDecision =
          await _decideRoute(newEvents);
      if (routeDecision.errors.isNotEmpty) {
        return _decisionError(
          openPlace: openPlace,
          route: 'error',
          routeErrors: routeDecision.errors,
        );
      }
      route = routeDecision.route;
      _stage('GM_ROUTE');
      _checkpoint('GM_ROUTE', <String, Object?>{'route': route});
    }
    if (route == 'env') {
      return _runEnvironmentTurn(
        openPlace: openPlace,
        events: newEvents,
        perceptionNames: perceivers,
        resume: resume,
        reason: 'GM_ROUTE 选择环境更新',
      );
    }

    final List<WorldEvent> incoming = newEvents;
    // newEvents 已经占用了 E 编号；CH_ACT/SYS_RECORD 不能从同一个 startSeq 再发一遍。
    _seq = _nextEventSeq(incoming);

    // CH_PERCEIVE：每个 NPC 只看自己还没感知过的新事件。
    final ({Map<String, Map<String, Object?>> percepts, List<String> errors})
        perceived = await _perceiveAndRemember(
      events: incoming,
      names: perceivers,
      resume: resume,
    );
    final Map<String, Map<String, Object?>> percepts = perceived.percepts;
    final Map<String, Map<String, Object?>> scheduling = <String, Map<String, Object?>>{};
    for (final String name in actors) {
      final List<String> motivation = <String>[
        for (final CharacterMemory m in memory.activeForCharacter('char:$name'))
          '${m.text}${m.attention.isEmpty ? '' : '；当前关注：${m.attention}'}',
        if (causalContext != null)
          for (final EntityRecord p in causalContext!.state.ongoingProcesses)
            if (p.state['owner'] == name) '${p.name}；完成条件：${p.state['completion_condition']}',
        if (causalContext != null)
          for (final InnerEntry i in causalContext!.state.inner)
            if (i.characterId == 'char:$name' || i.characterId == name) i.text,
      ];
      // 全量记忆只供全知调度判断，不作为角色感知回灌给行为模型。
      scheduling[name] = <String, Object?>{
        ...?percepts[name], 'ongoing_motivation': motivation,
      };
    }
    final List<String> perceiveErrors = perceived.errors;
    if (perceiveErrors.isNotEmpty) {
      return TurnTrace(
        percepts: percepts,
        eligible: const <String>[],
        chosen: null,
        action: null,
        arbitration: null,
        stateDelta: null,
        events: const <WorldEvent>[],
        render: null,
        renderViolations: const <RenderViolation>[],
        blocked: const <FunctionalConstraint>[],
        stop: null,
        actErrors: const <ActValidationError>[],
        perceiveErrors: perceiveErrors,
        openPlace: openPlace,
        environmentEvents: const <WorldEvent>[],
      );
    }

    // CH_PERCEIVE 的感知先落成角色记忆（还没有 CH_MEMORY_WRITE，程序只做组装）。
    // GM_ELIGIBILITY：cast 可由 AI 声明；程序只允许它从当前场景里选。eligible 由程序算。
    final List<String> sceneCast = <String>[
      for (final CharacterSnapshot c in scene.cast) c.name,
    ];
    final TurnCheckpoint? castCheckpoint = resume?.checkpoints['GM_CAST'];
    List<String> cast = sceneCast;
    if (castCheckpoint != null) {
      cast = _stringsFromCheckpoint(castCheckpoint.data['cast']);
    } else if (castDecider != null) {
      final List<String> errors = <String>[];
      List<String> previous = sceneCast;
      bool accepted = false;
      for (int step = 1; step <= castStepBudget; step++) {
        final List<String> raw = await _withAsk(
          StepId.gmCast,
          () => castDecider!(
            scene: scene,
            knownCast: sceneCast,
            errors: errors,
            previous: step == 1 ? null : previous,
          ),
        );
        final List<String> bad = <String>[
          for (final String name in raw)
            if (!sceneCast.contains(name)) name,
        ];
        if (bad.isEmpty) {
          final List<String> unique = <String>[];
          for (final String name in raw) {
            if (!unique.contains(name)) unique.add(name);
          }
          cast = unique;
          accepted = true;
          break;
        }
        errors
          ..clear()
          ..add('GM_CAST 返回了当前场景外的人：${bad.join('、')}');
        previous = raw;
      }
      if (!accepted) {
        return _decisionError(
          openPlace: openPlace,
          route: 'error',
          castErrors: errors,
          castFailureStep: StepId.gmCast,
        );
      }
      _stage('GM_CAST');
      _checkpoint('GM_CAST', <String, Object?>{'cast': cast});
    } else {
      _stage('GM_CAST');
      _checkpoint('GM_CAST', <String, Object?>{'cast': cast});
    }
    // 不再排除上一回合 actor：同一角色可以连续行动。
    final List<String> baseEligible =
        actors.where((String n) => cast.contains(n)).toList();
    final TurnCheckpoint? eligibleCheckpoint =
        resume?.checkpoints['GM_ELIGIBILITY'];
    List<String> eligible = const <String>[];
    if (eligibleCheckpoint != null) {
      eligible = _stringsFromCheckpoint(
        eligibleCheckpoint.data['eligible'],
      );
    } else {
      final List<String> errors = <String>[];
      List<String> previous = const <String>[];
      bool accepted = false;
      for (int step = 1; step <= castStepBudget; step++) {
        final List<String> raw = await _withAsk(
          'GM_ELIGIBILITY',
          () => agents.selectEligible(
            baseEligible: baseEligible,
            cast: cast,
            playerNotes: scene.playerNotes,
            errors: errors,
            previous: step == 1 ? null : previous,
          ),
        );
        final List<String> bad = <String>[
          for (final String name in raw)
            if (!baseEligible.contains(name)) name,
        ];
        if (bad.isEmpty) {
          final List<String> unique = <String>[];
          for (final String name in raw) {
            if (!unique.contains(name)) unique.add(name);
          }
          eligible = unique;
          accepted = true;
          break;
        }
        errors
          ..clear()
          ..add(
            'GM_ELIGIBILITY 返回了基础 eligible 之外的人：${bad.join('、')}。'
            '只能从 base eligible 里排除，不能添加。',
          );
        previous = raw;
      }
      if (!accepted) {
        return _decisionError(
          openPlace: openPlace,
          route: 'error',
          castErrors: errors,
        );
      }
      _stage('GM_ELIGIBILITY');
      _checkpoint('GM_ELIGIBILITY', <String, Object?>{
        'cast': cast,
        'eligible': eligible,
      });
    }
    if (eligible.isEmpty) {
      return _runEnvironmentTurn(
        openPlace: openPlace,
        events: newEvents,
        perceptionNames: perceivers,
        resume: resume,
        reason: '没有可行动角色，改为环境更新',
      );
    }

    // GM_SELECT_ACTOR：AI 选唯一 actor
    final TurnCheckpoint? selectActorCheckpoint = resume?.checkpoints['GM_SELECT_ACTOR'];
    String? chosenCandidate;
    if (selectActorCheckpoint != null) {
      final String saved = '${selectActorCheckpoint.data['chosen'] ?? ''}'.trim();
      if (saved.isEmpty || !eligible.contains(saved)) {
        return _decisionError(
          openPlace: openPlace,
          route: 'error',
          selectActorErrors: <String>['GM_SELECT_ACTOR checkpoint 里的角色不在 eligible 里：$saved'],
        );
      }
      chosenCandidate = saved;
    } else {
      final List<String> selectable = actorsDue?.call(eligible) ?? eligible;
      final List<String> errors = <String>[];
      String? previous;
      bool accepted = false;
      for (int step = 1; step <= selectActorStepBudget; step++) {
        final String? raw = await _withAsk(
          'GM_SELECT_ACTOR',
          () => agents.selectActor(
            eligible: selectable,
            percepts: scheduling,
            playerNotes: scene.playerNotes,
            errors: errors,
            previous: step == 1 ? null : previous,
          ),
        );
        final String name = (raw ?? '').trim();
        if (name.isEmpty) {
          errors
            ..clear()
            ..add('GM_SELECT_ACTOR 没有返回角色名。必须从 eligible 里选一个。');
          previous = name;
          continue;
        }
        if (!selectable.contains(name)) {
          errors
            ..clear()
            ..add('GM_SELECT_ACTOR 选了 eligible 之外的人：$name');
          previous = name;
          continue;
        }
        chosenCandidate = name;
        accepted = true;
        break;
      }
      if (!accepted) {
        return _decisionError(
          openPlace: openPlace,
          route: 'error',
          selectActorErrors: errors,
        );
      }
      _stage('GM_SELECT_ACTOR');
      _checkpoint('GM_SELECT_ACTOR', <String, Object?>{
        'eligible': eligible,
        'chosen': chosenCandidate,
      });
    }
    final String chosen = chosenCandidate!;

    // 召回服务绑定角色、状态与预算；中间进度不是阶段完成。
    final String recallStage = 'CH_MEMORY_RECALL:$chosen';
    final TurnCheckpoint? recallCheckpoint =
        resume?.checkpoints[recallStage];
    late final MemoryRecallService recallService;
    late final MemoryRecallResult recalled;
    try {
      final bool modern = recallCheckpoint?.data.containsKey('recall_protocol') ?? false;
      recallService = MemoryRecallService(
        worldId: resume?.worldId ?? '', characterId: 'char:$chosen',
        memory: memory.allEntries(), currentMemory: memory.allEntries,
        checkpoint: modern ? recallCheckpoint!.data : null,
        allowRebase: responseRevisions.keys.any((String key) =>
            key.startsWith('${StepId.chMemoryWrite}#$chosen#') ||
            key.startsWith('checkpoint:${StepId.chMemoryWrite}:$chosen:') ||
            key == 'checkpoint:${StepId.chMemoryWrite}:$chosen'),
        onChanged: (Map<String, Object?> data) => _checkpoint(recallStage, data),
      );
      if (modern) recallService.applyRequestRevisions(responseRevisions);
      if (modern && recallService.result != null) {
        recalled = recallService.result!;
      } else if (recallCheckpoint != null && !modern) {
        // 旧 checkpoint 只能选择活动记忆，不获得归档访问权。
        recalled = recallService.legacy(
          _stringsFromCheckpoint(recallCheckpoint.data['memory_ids']));
      } else {
        recalled = await agents.recallWithArchive(
          scene: scene, percepts: percepts[chosen] ?? <String, Object?>{},
          service: recallService,
        );
        recallService.validate(recalled);
        if (recalled.activeIds != null) {
          _stage(recallStage);
          _checkpoint(recallStage, recallService.result != null
            ? recallService.toCheckpoint()
            : <String, Object?>{
                'character': 'char:$chosen',
                'memory_ids': recalled.activeIds!.toList(),
              });
        }
      }
      recallService.validate(recalled);
    } on MemoryRecallException catch (err) {
      throw RetryExhaustedException(step: recallStage, reason: err.message);
    }

    // CH_ACT：该 actor 写行动记录。校验错误作为 observation 回给 CH_ACT，
    // 同一回合继续，直到合格行动 / 回合预算耗尽。
    final List<String> present = <String>[
      for (final CharacterSnapshot c in scene.cast) c.name,
    ];
    final List<ActValidationError> actErrors = <ActValidationError>[];
    // 裁定保存点已记录它实际使用的行动，续跑直接使用这对输入和结果。
    final TurnCheckpoint? savedRuling = resume?.checkpoints[StepId.gmResolveAction];
    final Object? ruledAction = savedRuling?.data['arbitration'] is Map &&
            savedRuling?.data['actor'] == chosen
        ? savedRuling?.data['action'] : null;
    Map<String, Object?> action = ruledAction is Map
        ? Map<String, Object?>.from(ruledAction) : <String, Object?>{};
    bool actionValid = ruledAction is Map;
    TurnCheckpoint? actCheckpoint = resume?.checkpoints['CH_ACT'];
    Map<String, Object?>? revisedRecordAction;
    if (actionValid && actCheckpoint != null &&
        (responseRevisions.containsKey('checkpoint:${StepId.chAct}') ||
            responseRevisions.containsKey(actCheckpoint.data['response_key']))) {
      revisedRecordAction = actCheckpoint.data['action'] is Map
          ? Map<String, Object?>.from(actCheckpoint.data['action'] as Map)
          : <String, Object?>{};
      final ActValidationError? savedError = _validateAct(revisedRecordAction, actor: chosen);
      if (savedError != null) {
        throw FormatException('修订后的行动不合格：${savedError.message}');
      }
    }
    if (!actionValid && actCheckpoint != null) {
      action = actCheckpoint.data['action'] is Map
          ? Map<String, Object?>.from(actCheckpoint.data['action'] as Map)
          : <String, Object?>{};
      final ActValidationError? savedError = _validateAct(action, actor: chosen);
      actionValid = savedError == null;
      if (savedError != null) {
        if (responseRevisions.containsKey('checkpoint:${StepId.chAct}') ||
            responseRevisions.containsKey(actCheckpoint.data['response_key'])) {
          throw FormatException('修订后的行动不合格：${savedError.message}');
        }
        actErrors.add(savedError);
        actCheckpoint = null;
        final List<String> invalidated = <String>[
          StepId.chAct, StepId.gmResolveAction, StepId.sysRecord,
          StepId.gmNarrate, StepId.gmMergePlace,
          if (chosen == controlledCharacter) StepId.gmParseInput,
        ];
        for (final String stage in invalidated) {
          _completed.remove(stage);
          agents.prepareRetry(stage);
        }
        resume = resume?.withoutCheckpoints(invalidated);
        _checkpoint('SYS_RECOVERY', <String, Object?>{
          ..._completed[StepId.sysRecovery]!.data, 'invalidate': invalidated,
        });
      }
    }
    if (!actionValid && chosen == controlledCharacter) {
      // 人控角色的 CH_ACT：等玩家输入，GM_PARSE_INPUT 在 workspace 的 provider 里解析。
      final PlayerActionHandler? provider = playerActionHandler;
      if (provider == null) {
        return _playerActionStop(
          openPlace: openPlace,
          percepts: percepts,
          eligible: eligible,
          chosen: chosen,
          reason: '轮到当前操控角色行动，但没有接玩家输入。',
        );
      }
      final Map<String, Object?>? playerAction = await provider(
        actor: chosen,
        scene: scene,
      );
      if (playerAction == null) {
        return _playerActionStop(
          openPlace: openPlace,
          percepts: percepts,
          eligible: eligible,
          chosen: chosen,
          reason: '轮到当前操控角色行动，等待玩家输入。',
        );
      }
      action = playerAction;
      final ActValidationError? error = _validateAct(action, actor: chosen);
      if (error != null) {
        return _playerActionStop(
          openPlace: openPlace,
          percepts: percepts,
          eligible: eligible,
          chosen: chosen,
          reason: '玩家行动不合格：${error.message}',
          actErrors: <ActValidationError>[error],
        );
      }
      actionValid = true;
    } else if (!actionValid) {
      for (int actStep = 1; actStep <= actStepBudget; actStep++) {
        final Map<String, Object?> perceive =
            percepts[chosen] ?? <String, Object?>{};
        action = await agents.act(
          name: chosen,
          context: _characterContext(
            'char:$chosen',
            onlyMemoryIds: recalled.activeIds,
            archivedContext: recallService.contextFor(recalled),
          ),
          perceive: _actInput(perceive, actErrors, action),
          present: present,
        );
        final ActValidationError? error = _validateAct(action, actor: chosen);
        if (error == null) {
          actionValid = true;
          break;
        }
        actErrors.add(error);
      }
    }
    final TurnStop? stop = actionValid
        ? null
        : TurnStop(
            code: 'step_budget',
            reason: 'CH_ACT 连续 $actStepBudget 步没有给出合格行动',
          );
    if (stop != null) {
      return TurnTrace(
        percepts: percepts,
        eligible: eligible,
        chosen: chosen,
        action: action,
        arbitration: null,
        stateDelta: null,
        events: const <WorldEvent>[],
        render: null,
        renderViolations: const <RenderViolation>[],
        blocked: const <FunctionalConstraint>[],
        stop: stop,
        actErrors: actErrors,
        openPlace: openPlace,
        rejectedEvents: <WorldEvent>[
          _rejectedEvent(chosen, action, stop.reason),
        ],
      );
    }

    if (actCheckpoint == null && ruledAction is! Map) {
      _stage('CH_ACT');
      _checkpoint('CH_ACT', <String, Object?>{
        'actor': chosen,
        'action': action,
      });
    }
    // 兜底：正常情况下 _validateAct 已经拦过；这里只防漏。
    final List<String> requires = _requiredCapabilities(action);
    final List<FunctionalConstraint> blocked = <FunctionalConstraint>[
      for (final FunctionalConstraint c in constraints)
        if (c.who == chosen &&
            c.state == ConstraintState.cannot &&
            requires.contains(c.capability))
          c,
    ];
    if (blocked.isNotEmpty) {
      return TurnTrace(
        percepts: percepts,
        eligible: eligible,
        chosen: chosen,
        action: action,
        arbitration: null,
        stateDelta: null,
        events: const <WorldEvent>[],
        render: null,
        renderViolations: const <RenderViolation>[],
        blocked: blocked,
        stop: null,
        actErrors: actErrors,
        openPlace: openPlace,
        rejectedEvents: <WorldEvent>[
          _rejectedEvent(chosen, action, '功能限制：${blocked.map((c) => c.capability).join('、')}'),
        ],
      );
    }

    final TurnCheckpoint? resolveCheckpoint = resume?.checkpoints[StepId.gmResolveAction];
    final TurnCheckpoint? cCheckpoint = resume?.checkpoints[StepId.sysRecord];
    if (resolveCheckpoint == null && cCheckpoint == null) {
      final TurnTrace? contested = await _contest(
        choice: chosen, action: action, eligible: eligible, percepts: percepts, openPlace: openPlace, resume: resume,
      );
      if (contested != null) return contested;
    }

    // GM_RESOLVE_ACTION：只有物理/对抗行动才裁定。
    Map<String, Object?>? arbitration;
    if (resolveCheckpoint != null) {
      final Object? saved = resolveCheckpoint.data['arbitration'];
      if (saved is! Map) throw const FormatException('已保存的裁定缺少裁定结果。');
      arbitration = Map<String, Object?>.from(saved);
      final List<String> savedErrors = _validateArbitration(arbitration, actor: chosen, action: action);
      if (savedErrors.isNotEmpty) {
        throw FormatException('已保存裁定不符合当前状态：${savedErrors.join('；')}');
      }
      if (arbitration['outcome'] != 'unresolved') _applyDeltas(arbitration);
    } else if (cCheckpoint == null && _requiresAr(action, chosen)) {
      Map<String, Object?> last = <String, Object?>{};
      final List<String> arErrors = <String>[];
      for (int resolveStep = 1; resolveStep <= resolveStepBudget; resolveStep++) {
        last = await _withAsk(
          'GM_RESOLVE_ACTION',
          () => agents.adjudicate(
            action: action,
            actor: chosen,
            target: _firstTarget(chosen, action),
            place: scene.place,
            present: present,
            errors: arErrors,
            previous: resolveStep == 1 ? null : last,
            playerNotes: scene.playerNotes,
          ),
        );
        arErrors
          ..clear()
          ..addAll(_validateArbitration(last, actor: chosen, action: action));
        if (arErrors.isEmpty) {
          arbitration = last;
          break;
        }
      }
      if (arErrors.isNotEmpty) {
        return TurnTrace(
          percepts: percepts,
          eligible: eligible,
          chosen: chosen,
          action: action,
          arbitration: last,
          stateDelta: null,
          events: const <WorldEvent>[],
          render: null,
          renderViolations: const <RenderViolation>[],
          blocked: const <FunctionalConstraint>[],
          stop: null,
          actErrors: actErrors,
          resolveErrors: arErrors,
          openPlace: openPlace,
          environmentEvents: const <WorldEvent>[],
          rejectedEvents: <WorldEvent>[
            _rejectedEvent(chosen, action, 'GM_RESOLVE_ACTION 校验失败：${arErrors.join('；')}'),
          ],
        );
      }
      if (arbitration!['outcome'] != 'unresolved') _applyDeltas(arbitration);
      _stage('GM_RESOLVE_ACTION');
      _checkpoint('GM_RESOLVE_ACTION', <String, Object?>{
        'actor': chosen,
        'action': action,
        'arbitration': arbitration,
      });
    }

    if (arbitration?['outcome'] == 'unresolved') {
      return TurnTrace(
        percepts: percepts, eligible: eligible, chosen: chosen, action: action,
        arbitration: arbitration, stateDelta: null, events: const <WorldEvent>[],
        render: null, renderViolations: const <RenderViolation>[],
        blocked: const <FunctionalConstraint>[], stop: null, actErrors: actErrors,
        openPlace: openPlace, cast: cast, needsReview: true,
      );
    }

    // 状态变化：对抗行动以 GM_RESOLVE_ACTION 为准；非对抗行动看 CH_ACT 的 state_delta。
    final StateDelta stateDelta;
    final List<WorldEvent> recorded;
    if (cCheckpoint != null) {
      stateDelta = StateDelta.fromAction(cCheckpoint.data['stateDelta']);
      recorded = _eventsFromCheckpoint(cCheckpoint.data);
      final List<String> savedErrors = causalContext?.state.transitionErrors(
          stateDelta, actor: chosen, place: scene.place, adjudicated: arbitration != null) ?? <String>[];
      if (savedErrors.isNotEmpty) {
        throw FormatException('已保存状态变化不符合当前状态：${savedErrors.join('；')}');
      }
    } else {
      stateDelta = arbitration != null
          ? StateDelta.fromArbiter(arbitration)
          : StateDelta.fromAction(action['state_delta']);
      recorded = _record(chosen, revisedRecordAction ?? action, stateDelta, arbitration);
      _stage('SYS_RECORD');
      _checkpoint('SYS_RECORD', <String, Object?>{
        'events': <Object?>[
          for (final WorldEvent e in recorded) worldEventToJson(e),
        ],
        'stateDelta': stateDelta.toJson(),
      });
    }

    final TurnPresentation? narration = deferPresentation
        ? null
        : await _narrate(recorded, resume?.checkpoints[StepId.gmNarrate]);
    final List<String> reviewWarnings = narration?.warnings ?? const <String>[];
    final List<WorldEvent> events = <WorldEvent>[
      for (final WorldEvent event in recorded)
        if (narration == null) event else
          event.copyWith(publicText: narration.publicText, godNote: narration.godNote),
    ];
    final TurnCheckpoint? mergePlaceCheckpoint = resume?.checkpoints['GM_MERGE_PLACE'];
    final MergePlaceResult mergePlace;
    if (mergePlaceCheckpoint != null) {
      mergePlace = _mergePlaceFromCheckpoint(mergePlaceCheckpoint.data);
    } else {
      mergePlace = await _decideMergePlace(
        events: events,
        remainingCast: _remainingCast(stateDelta),
      );
      _stage('GM_MERGE_PLACE');
      _checkpoint('GM_MERGE_PLACE', <String, Object?>{
        'merge': mergePlace.merge,
        'why': mergePlace.why,
        'into': mergePlace.into,
      });
    }
    final bool needsReview =
        '${arbitration?['outcome'] ?? ''}' == 'unresolved' ||
            reviewWarnings.isNotEmpty;

    return TurnTrace(
      percepts: percepts,
      eligible: eligible,
      chosen: chosen,
      action: action,
      arbitration: arbitration,
      stateDelta: stateDelta.isEmpty ? null : stateDelta,
      events: events,
      render: narration?.render,
      renderViolations: narration?.check.violations ?? const <RenderViolation>[],
      blocked: const <FunctionalConstraint>[],
      stop: null,
      actErrors: actErrors,
      openPlace: openPlace,
      route: route,
      environmentEvents: const <WorldEvent>[],
      mergePlace: mergePlace,
      needsReview: needsReview,
      reviewWarnings: reviewWarnings,
      cast: cast,
    );
  }

  /// 单件物品或已知单值属性的互斥尝试共同引用同一份基础状态。
  Future<TurnTrace?> _contest({
    required String choice,
    required Map<String, Object?> action,
    required List<String> eligible,
    required Map<String, Map<String, Object?>> percepts,
    required OpenPlaceResult openPlace,
    required TurnSession? resume,
  }) async {
    final ContestDecider? adjudicate = contestDecider;
    final CausalContext? context = causalContext;
    if (adjudicate == null || context == null) return null;
    final TurnState base = context.state;
    _ContestAttempt? candidateOf(String actor, Map<String, Object?> attempt, NarrativeScene location) {
      if (identical(location, scene) && _validateAct(attempt, actor: actor) != null) return null;
      final StateDelta delta = StateDelta.fromAction(attempt['state_delta']);
      if (delta.isEmpty || delta.moves.isNotEmpty || delta.injuries.isNotEmpty ||
          delta.constraints.isNotEmpty || delta.discoveries.isNotEmpty || delta.processes.isNotEmpty) {
        return null;
      }
      final Set<_ActionClaim> claims = <_ActionClaim>{};
      for (final StateItemDelta item in delta.items) {
        if (item.kind != 'take' || item.to?.replaceFirst('char:', '') != actor ||
            base.entities[item.itemId]?.kind != 'item') {
          return null;
        }
        claims.add((subject: item.itemId, property: null, value: actor));
      }
      for (final StateFactDelta fact in delta.facts) {
        final EntityRecord? entity = base.entities[fact.subject];
        if (entity == null || fact.operation != 'set' ||
            (entity.location != location.place && entity.location != 'place:${location.place}' &&
                entity.id != 'place:${location.place}')) {
          return null;
        }
        final int current = base.facts.where((FactRecord record) =>
            record.untilEvent.isEmpty && record.subject == fact.subject && record.predicate == fact.predicate).length;
        if (current != 1) return null;
        claims.add((subject: fact.subject, property: fact.predicate, value: fact.object));
      }
      if (claims.map((claim) => (claim.subject, claim.property)).toSet().length != claims.length) return null;
      return (scene: location, action: attempt, delta: delta, claims: claims);
    }
    final _ContestAttempt? first = candidateOf(choice, action, scene);
    if (first == null) return null;
    final _ActionClaim primary = first.claims.first;
    final EntityRecord subject = base.entities[primary.subject]!;
    final Map<String, NarrativeScene> candidates = <String, NarrativeScene>{
      for (final String actor in eligible) if (actor != choice) actor: scene,
    };
    for (final ParallelPlaceInfo place in otherParallelPlaces) {
      if (!place.isActive || sceneForPlace == null || !first.claims.any((claim) =>
          claim.property == null && base.facts.any((FactRecord fact) =>
            fact.untilEvent.isEmpty && fact.subject == claim.subject &&
            fact.predicate == 'shared_access' && fact.object == place.place))) {
        continue;
      }
      final NarrativeScene remote = sceneForPlace!(place.place);
      for (final String actor in place.members) {
        if (actor != choice && !base.constraints.any((FunctionalConstraint constraint) =>
            constraint.who == actor && constraint.capability == 'act' &&
            constraint.state == ConstraintState.cannot)) {
          candidates.putIfAbsent(actor, () => remote);
        }
      }
    }
    final Map<String, _ContestAttempt> collected = <String, _ContestAttempt>{choice: first};
    for (final MapEntry<String, NarrativeScene> candidate in candidates.entries) {
      final String actor = candidate.key;
      final NarrativeScene location = candidate.value;
      final String stage = 'CH_ACT:contest:$actor';
      final TurnCheckpoint? saved = resume?.checkpoints[stage];
      final Map<String, Object?>? next;
      if (saved != null && saved.data['action'] is Map) {
        next = Map<String, Object?>.from(saved.data['action'] as Map);
      } else {
        next = actor == controlledCharacter
            ? await playerActionHandler?.call(actor: actor, scene: location)
            : await agents.act(
                name: actor,
                context: identical(location, scene)
                    ? _characterContext('char:$actor')
                    : context.characterView('char:$actor', location),
                perceive: jsonEncode(percepts[actor] ?? const <String, Object?>{}),
                present: location.cast.map((CharacterSnapshot character) => character.name).toList(),
              );
        if (next == null) {
          return _playerActionStop(
            openPlace: openPlace, percepts: percepts, eligible: eligible, chosen: actor,
            reason: '轮到当前操控角色回应，整条时间线等待输入。',
          );
        }
        _stage(stage);
        _checkpoint(stage, <String, Object?>{'actor': actor, 'action': next});
      }
      final Map<String, Object?> attempt = next;
      final _ContestAttempt? claim = candidateOf(actor, attempt, location);
      if (claim == null) continue;
      if (!identical(location, scene) && claim.claims.any((claim) =>
          claim.property != null || !base.facts.any((FactRecord fact) =>
              fact.untilEvent.isEmpty && fact.subject == claim.subject &&
              fact.predicate == 'shared_access' && fact.object == location.place))) {
        continue;
      }
      if (base.constraints.any((FunctionalConstraint constraint) =>
          constraint.who == actor && constraint.state == ConstraintState.cannot &&
          _requiredCapabilities(attempt).contains(constraint.capability))) {
        continue;
      }
      collected[actor] = claim;
    }
    final Map<String, _ContestAttempt> attempts = <String, _ContestAttempt>{choice: first};
    bool grew;
    do {
      grew = false;
      for (final entry in collected.entries) {
        if (!attempts.containsKey(entry.key) &&
            attempts.values.any((other) => _relatedAttempts(entry.value, other))) {
          attempts[entry.key] = entry.value;
          grew = true;
          break;
        }
      }
    } while (grew);
    if (attempts.length < 2) return null;

    const String contestStage = 'GM_RESOLVE_ACTION:contest';
    final Map<String, Set<String>> before = <String, Set<String>>{
      for (final String actor in attempts.keys) actor: <String>{},
    };
    for (final String earlier in attempts.keys) {
      final Object? boundary = attempts[earlier]!.action['time_boundary_id'];
      if (boundary is! String || boundary.isEmpty) continue;
      final Set<String> after = _laterBoundaries(base, boundary);
      for (final String later in attempts.keys) {
        if (after.contains(attempts[later]!.action['time_boundary_id'])) before[later]!.add(earlier);
      }
    }
    final List<String> ordered = <String>[];
    final Set<String> pending = attempts.keys.toSet();
    while (pending.isNotEmpty) {
      final String? next = pending.where((actor) => !before[actor]!.any(pending.contains)).firstOrNull;
      if (next == null) break;
      ordered.add(next);
      pending.remove(next);
    }
    String? validateSuccesses(Set<String> successful) {
      if (successful.isEmpty || !attempts.keys.toSet().containsAll(successful)) return '成功者必须是已收集的尝试者。';
      if (pending.isNotEmpty) return '已记录的时间关系有循环。';
      TurnState checking = base;
      final List<String> previous = <String>[];
      for (final String actor in ordered.where(successful.contains)) {
        final _ContestAttempt attempt = attempts[actor]!;
        if (previous.any((other) => !before[actor]!.contains(other) &&
            _relatedAttempts(attempt, attempts[other]!))) {
          return '无法确定先后的相关尝试不得同时改变前提或结果。';
        }
        if (!_contestPreconditionsHold(checking, attempt.action)) return '尝试的前提在轮到结算时不成立：$actor。';
        final List<String> problems = checking.transitionErrors(attempt.delta, actor: actor, place: attempt.scene.place);
        if (problems.isNotEmpty) return problems.join('；');
        checking = checking.applyDelta(attempt.delta);
        previous.add(actor);
      }
      return null;
    }

    final TurnCheckpoint? saved = resume?.checkpoints[contestStage];
    Set<String> successful = <String>{};
    final bool completelyOrdered = pending.isEmpty && ordered.indexed.every(
      (entry) => before[entry.$2]!.containsAll(ordered.take(entry.$1)),
    );
    if (saved == null && completelyOrdered) {
      for (final String actor in ordered) {
        if (validateSuccesses(<String>{...successful, actor}) == null) successful.add(actor);
      }
    }
    if (successful.isNotEmpty) {
      _stage(contestStage);
      _checkpoint(contestStage, <String, Object?>{'successful': ordered.where(successful.contains).toList()});
    } else {
      final List<String> errors = <String>[];
      for (int retry = 0; retry < resolveStepBudget; retry++) {
        final Map<String, Object?> decision = saved != null
            ? saved.data
            : await adjudicate(subject.id, <Map<String, Object?>>[
                for (final entry in attempts.entries)
                  <String, Object?>{
                    'actor': entry.key, 'place': entry.value.scene.place, 'action': entry.value.action,
                    if (primary.property != null) 'contested_property': primary.property,
                    if (before[entry.key]!.isNotEmpty) 'must_follow': before[entry.key]!.toList(),
                  },
              ], errors);
        if (decision['outcome'] == 'unresolved') break;
        final Set<String> proposed = decision['successful'] is List
            ? (decision['successful'] as List).whereType<String>().toSet()
            : <String>{'${decision['winner'] ?? ''}'};
        final String? problem = validateSuccesses(proposed);
        if (problem == null) {
          successful = proposed;
          if (saved == null) {
            _stage(contestStage);
            _checkpoint(contestStage, decision);
          }
          break;
        }
        if (saved != null) break;
        errors.add(problem);
      }
    }
    if (successful.isEmpty) {
      final List<String> viable = ordered.where((actor) => validateSuccesses(<String>{actor}) == null).toList();
      final String? ruling = await askPlayer?.call(PlayerQuestion(
        step: contestStage, code: 'unresolved_action',
        reason: '已收集各自的尝试，尚无足够依据确定实际结果。',
        question: '哪项尝试成立？',
        options: viable,
      ));
      if (ruling == null || !viable.contains(ruling)) {
        return _playerActionStop(
          openPlace: openPlace, percepts: percepts, eligible: eligible, chosen: choice,
          reason: '冲突行动尚未裁定，整条时间线等待玩家。',
        );
      }
      successful = <String>{ruling};
      _stage(contestStage);
      _checkpoint(contestStage, <String, Object?>{'winner': ruling});
    }
    final List<StateDelta> deltas = <StateDelta>[
      for (final String actor in ordered.where(successful.contains)) attempts[actor]!.delta,
    ];
    String outcomeText(String actor) {
      final _ContestAttempt attempt = attempts[actor]!;
      if (attempt.claims.length == 1 && attempt.claims.single.property == null) {
        final String item = base.entities[attempt.claims.single.subject]!.name;
        return successful.contains(actor) ? '$actor取得了$item。' : '$actor试图取得$item，没有拿到。';
      }
      final String names = attempt.claims.map((claim) => base.entities[claim.subject]!.name).toSet().join('、');
      return successful.contains(actor) ? '$actor成功操作了$names。' : '$actor试图操作$names，没有成功。';
    }
    final List<WorldEvent> recorded = <WorldEvent>[];
    for (final String actor in ordered) {
      final _ContestAttempt attempt = attempts[actor]!;
      final bool success = successful.contains(actor);
      final StateDelta delta = success ? attempt.delta : const StateDelta();
      final Delivery delivery = Delivery(channel: DeliveryChannel.visual, form: 'gesture',
          audience: attempt.delta.facts.every((fact) => fact.visibility == 'public')
              ? Audience.scene : Audience.hidden);
      recorded.add(cWriter.commitValidated(
          event: WorldEvent(
            id: 'CONTEST-${_seq++}', kind: WorldEventKind.action, actor: 'char:$actor',
            content: outcomeText(actor),
            delivery: delivery,
            segments: <EventSegment>[
              EventSegment(kind: WorldEventKind.action, text: outcomeText(actor), delivery: delivery),
            ],
            placeId: attempt.scene.place, turnIndex: base.worldStep + 1,
            outcome: success ? 'success' : 'failure',
            effects: delta.effectRecords,
            stateChanges: success ? delta.toJson() : const <String, Object?>{},
          ),
          scene: attempt.scene, engine: engine,
        ));
    }
    final TurnPresentation? narration = deferPresentation ? null : await _narrate(recorded, null);
    return TurnTrace(
      percepts: percepts, eligible: eligible, chosen: choice, action: action,
      arbitration: <String, Object?>{
        if (successful.length == 1) 'winner': successful.single,
        'successful': ordered.where(successful.contains).toList(), 'outcome': 'resolved',
      },
      stateDelta: StateDelta.combine(deltas), orderedDeltas: deltas, events: recorded,
      render: narration?.render,
      renderViolations: narration?.check.violations ?? const <RenderViolation>[],
      blocked: const <FunctionalConstraint>[], stop: null, actErrors: const <ActValidationError>[],
      openPlace: openPlace, needsReview: narration?.warnings.isNotEmpty ?? false,
    );
  }

  bool _contestPreconditionsHold(TurnState state, Map<String, Object?> action) {
    final Object? preconditions = action['preconditions'];
    if (preconditions == null) return true;
    return preconditions is List && preconditions.every((Object? condition) =>
        condition is Map && state.facts.any((FactRecord fact) =>
          fact.untilEvent.isEmpty && fact.subject == condition['subject'] &&
          fact.predicate == condition['predicate'] && fact.object == condition['object']));
  }

  bool _relatedAttempts(_ContestAttempt a, _ContestAttempt b) {
    bool affects(Set<_ActionClaim> changes, Map<String, Object?> action) {
      final Object? preconditions = action['preconditions'];
      return preconditions is List && preconditions.any((condition) => condition is Map &&
          changes.any((claim) => claim.subject == condition['subject'] && claim.property == condition['predicate']));
    }
    return affects(a.claims, b.action) || affects(b.claims, a.action) ||
        a.claims.any((left) => b.claims.any((right) => left.subject == right.subject &&
            left.property == right.property && left.value != right.value));
  }

  Set<String> _laterBoundaries(TurnState state, String boundary) {
    final Set<String> known = <String>{
      for (final FactRecord fact in state.facts)
        if (fact.untilEvent.isEmpty && fact.predicate == 'time_boundary' && fact.evidence.trim().isNotEmpty) fact.id,
    };
    if (!known.contains(boundary)) return <String>{};
    final Set<String> reached = <String>{};
    final List<String> pending = <String>[boundary];
    while (pending.isNotEmpty) {
      final String current = pending.removeLast();
      for (final FactRecord fact in state.facts) {
        if (fact.untilEvent.isEmpty && fact.predicate == 'time_before' && fact.subject == current &&
            known.contains(fact.object) && reached.add(fact.object)) {
          pending.add(fact.object);
        }
      }
    }
    return reached;
  }

  Future<void> _askPlayerHelp(AskPlayerException error) async {
    final String? saved = error.answer;
    if (saved != null && saved.trim().isNotEmpty) {
      _playerHelp[error.request.step] = saved.trim();
      agents.setPlayerHelp(_playerHelp);
      return;
    }
    final PlayerAsker? maybeAsker = askPlayer;
    if (maybeAsker == null) throw error;
    final PlayerAsker asker = maybeAsker;
    final String? answer = await asker(error.request);
    if (answer == null || answer.trim().isEmpty) {
      throw PlayerPausedException(error.request);
    }
    final String text = answer.trim();
    _playerHelp[error.request.step] = text;
    agents.setPlayerHelp(_playerHelp);
    if (error.journalKey.isNotEmpty) {
      if (error.request.code == 'retry_exhausted' || error.request.code == 'unresolved_action') {
        agents.recordIntervention(error.journalKey, error.request, text);
      } else {
        agents.recordPlayerAnswer(error.journalKey, text);
      }
    }
  }

  Future<T> _withAsk<T>(String step, Future<T> Function() call) async {
    while (true) {
      try {
        return await call();
      } on RetryExhaustedException {
        rethrow;
      } on AskPlayerException catch (error) {
        await _askPlayerHelp(error);
      }
    }
  }

  Future<({String route, List<String> errors})> _decideRoute(
    List<WorldEvent> events,
  ) async {
    if (routeDecider == null) {
      return (route: 'turn', errors: const <String>[]);
    }
    String last = '';
    final List<String> errors = <String>[];
    for (int routeStep = 1; routeStep <= routeStepBudget; routeStep++) {
      last = await _withAsk(
        'GM_ROUTE',
        () => routeDecider!(
          scene: scene,
          events: events,
          errors: errors,
          previous: routeStep == 1 || last.isEmpty ? null : last,
        ),
      );
      final String route = last.trim();
      errors.clear();
      if (route == 'env' || route == 'turn') {
        return (route: route, errors: const <String>[]);
      }
      errors.add(
        'GM_ROUTE 只能返回 env 或 turn，收到：${route.isEmpty ? '（空）' : route}',
      );
    }
    return (route: '', errors: errors);
  }

  TurnTrace _decisionError({
    required OpenPlaceResult openPlace,
    required String route,
    List<String> openPlaceErrors = const <String>[],
    List<String> routeErrors = const <String>[],
    List<String> castErrors = const <String>[],
    String castFailureStep = StepId.gmEligibility,
    List<String> selectActorErrors = const <String>[],
  }) {
    return TurnTrace(
      percepts: const <String, Map<String, Object?>>{},
      eligible: const <String>[],
      chosen: null,
      action: null,
      arbitration: null,
      stateDelta: null,
      events: const <WorldEvent>[],
      render: null,
      renderViolations: const <RenderViolation>[],
      blocked: const <FunctionalConstraint>[],
      stop: null,
      actErrors: const <ActValidationError>[],
      openPlace: openPlace,
      route: route,
      openPlaceErrors: openPlaceErrors,
      routeErrors: routeErrors,
      castErrors: castErrors,
      castFailureStep: castFailureStep,
      selectActorErrors: selectActorErrors,
    );
  }

  TurnTrace _playerActionStop({
    required OpenPlaceResult openPlace,
    required Map<String, Map<String, Object?>> percepts,
    required List<String> eligible,
    required String chosen,
    required String reason,
    List<ActValidationError> actErrors = const <ActValidationError>[],
  }) {
    return TurnTrace(
      percepts: percepts,
      eligible: eligible,
      chosen: chosen,
      action: null,
      arbitration: null,
      stateDelta: null,
      events: const <WorldEvent>[],
      render: null,
      renderViolations: const <RenderViolation>[],
      blocked: const <FunctionalConstraint>[],
      stop: TurnStop(code: 'player_action', reason: reason),
      actErrors: actErrors,
      openPlace: openPlace,
      route: 'player',
    );
  }

  /// GM_OPEN_PLACE：只在“有角色、但还没被任何 active 序列覆盖”的地点里选。
  ///
  /// 没有候选地点就不问模型——省一次调用，也防止 AI 凭空造一个地点。
  Future<({OpenPlaceResult result, List<String> errors})> _decideOpenPlace(
    List<WorldEvent> events,
  ) async {
    if (openPlaceDecider == null) {
      return (
        result: const OpenPlaceResult(openParallelPlace: false, why: '没有接 GM_OPEN_PLACE'),
        errors: const <String>[],
      );
    }
    if (parallelPlaceCandidates.isEmpty) {
      return (
        result: const OpenPlaceResult(openParallelPlace: false, why: '没有需要开启的并行地点'),
        errors: const <String>[],
      );
    }
    OpenPlaceResult last = const OpenPlaceResult(openParallelPlace: false, why: '');
    final List<String> errors = <String>[];
    for (int openPlaceStep = 1; openPlaceStep <= openPlaceStepBudget; openPlaceStep++) {
      last = await _withAsk(
        'GM_OPEN_PLACE',
        () => openPlaceDecider!(
          scene: scene,
          events: events,
          errors: errors,
          previous: openPlaceStep == 1 ? null : last,
        ),
      );
      final OpenPlaceResult normalized = _normalizeOpenPlace(last);
      errors
        ..clear()
        ..addAll(_validateOpenPlace(normalized));
      if (errors.isEmpty) {
        return (result: normalized, errors: const <String>[]);
      }
      last = normalized;
    }
    return (
      result: OpenPlaceResult(
        openParallelPlace: false,
        why: 'GM_OPEN_PLACE 连续 $openPlaceStepBudget 次不合格',
      ),
      errors: errors,
    );
  }

  OpenPlaceResult _openPlaceFromCheckpoint(Map<String, Object?> data) {
    final List<ParallelPlaceOpening> openings = <ParallelPlaceOpening>[];
    final Object? raw = data['openings'];
    if (raw is List) {
      for (final Object? item in raw) {
        if (item is! Map) continue;
        final Map<String, Object?> j = Map<String, Object?>.from(item);
        final String place = '${j['place'] ?? ''}'.trim();
        if (place.isEmpty) continue;
        openings.add(
          ParallelPlaceOpening(
            place: place,
            why: '${j['why'] ?? ''}',
            members: _stringsFromCheckpoint(j['members']),
          ),
        );
      }
    }
    return OpenPlaceResult(
      openParallelPlace: openings.isNotEmpty,
      why: '${data['why'] ?? ''}',
      place: openings.isEmpty ? '' : openings.first.place,
      members: openings.isEmpty ? const <String>[] : openings.first.members,
      openings: openings,
    );
  }

  MergePlaceResult _mergePlaceFromCheckpoint(Map<String, Object?> data) => MergePlaceResult(
        merge: data['merge'] == true,
        why: '${data['why'] ?? ''}',
        into: '${data['into'] ?? ''}',
      );

  List<String> _stringsFromCheckpoint(Object? raw) {
    if (raw is! List) return const <String>[];
    return <String>[for (final Object? x in raw) '$x'];
  }

  List<WorldEvent> _eventsFromCheckpoint(Map<String, Object?> data) {
    final List<WorldEvent> out = <WorldEvent>[];
    final Object? raw = data['events'];
    if (raw is List) {
      for (final Object? item in raw) {
        if (item is Map) {
          out.add(worldEventFromJson(Map<String, Object?>.from(item)));
        }
      }
    }
    return out;
  }

  OpenPlaceResult _normalizeOpenPlace(OpenPlaceResult raw) {
    final List<ParallelPlaceOpening> source = raw.allOpenings;
    if (source.isEmpty) return raw;
    final List<ParallelPlaceOpening> normalized = <ParallelPlaceOpening>[];
    for (final ParallelPlaceOpening opening in source) {
      ParallelPlaceCandidate? match;
      for (final ParallelPlaceCandidate c in parallelPlaceCandidates) {
        if (c.place.trim() == opening.place.trim()) {
          match = c;
          break;
        }
      }
      normalized.add(
        ParallelPlaceOpening(
          place: match?.place ?? opening.place.trim(),
          why: opening.why,
          members: match == null
              ? List<String>.of(opening.members)
              : List<String>.of(match.members),
        ),
      );
    }
    return OpenPlaceResult(
      openParallelPlace: normalized.isNotEmpty,
      why: raw.why,
      place: normalized.first.place,
      members: normalized.first.members,
      openings: normalized,
    );
  }

  List<String> _validateOpenPlace(OpenPlaceResult raw) {
    final List<ParallelPlaceOpening> openings = raw.allOpenings;
    if (openings.isEmpty) {
      return raw.openParallelPlace
          ? const <String>['GM_OPEN_PLACE 说要开新线，但没有给地点']
          : const <String>[];
    }
    final List<String> errors = <String>[];
    final Set<String> seen = <String>{};
    for (final ParallelPlaceOpening opening in openings) {
      final String place = opening.place.trim();
      if (place.isEmpty) {
        errors.add('GM_OPEN_PLACE 开启的地点为空');
        continue;
      }
      if (!seen.add(place)) {
        errors.add('GM_OPEN_PLACE 重复开启同一个地点：$place');
        continue;
      }
      if (!parallelPlaceCandidates.any(
        (ParallelPlaceCandidate c) => c.place.trim() == place,
      )) {
        errors.add('GM_OPEN_PLACE 指定的地点不在待开启并行地点候选里：$place');
      }
    }
    return errors;
  }

  /// 本回合结束后还留在当前序列里的角色。
  ///
  /// 只有“人都走光了”的线才允许合并；否则把两列硬并会让人瞬移。
  List<String> _remainingCast(StateDelta delta) {
    final List<String> out = <String>[];
    for (final CharacterSnapshot c in scene.cast) {
      final String? movedTo = delta.moves[c.name];
      if (movedTo == null || movedTo.trim() == scene.place.trim()) {
        out.add(c.name);
      }
    }
    // 本回合刚走进来的人也算“本线还有人”。
    for (final MapEntry<String, String> e in delta.moves.entries) {
      if (e.value.trim() == scene.place.trim() && !out.contains(e.key)) {
        out.add(e.key);
      }
    }
    return out;
  }

  /// GM_MERGE_PLACE：SYS_RECORD 先看有没有别的未合并序列；没有就不问。
  /// 有，且本线已经没人了，才让 GM_MERGE_PLACE 选目标；目标必须是现有的 active 序列。
  Future<MergePlaceResult> _decideMergePlace({
    required List<WorldEvent> events,
    required List<String> remainingCast,
  }) async {
    if (otherParallelPlaces.isEmpty) {
      return const MergePlaceResult(merge: false, why: '没有其他未合并序列');
    }
    if (causalContext?.state.ongoingProcesses.any((EntityRecord process) =>
        process.location == scene.place || process.location == 'place:${scene.place}') ?? false) {
      return const MergePlaceResult(merge: false, why: '此处还有持续过程。');
    }
    if (remainingCast.isNotEmpty) {
      return MergePlaceResult(
        merge: false,
        why: '本线还有角色，不能合并：${remainingCast.join('、')}',
      );
    }
    if (mergePlaceDecider == null) {
      return const MergePlaceResult(merge: false, why: '没有接 GM_MERGE_PLACE');
    }
    final MergePlaceResult raw = await _withAsk(
      'GM_MERGE_PLACE',
      () => mergePlaceDecider!(scene: scene, events: events),
    );
    if (!raw.merge) return raw;
    final String into = raw.into.trim();
    ParallelPlaceInfo? target;
    for (final ParallelPlaceInfo l in otherParallelPlaces) {
      if (l.id == into && l.isActive) {
        target = l;
        break;
      }
    }
    if (target == null) {
      return MergePlaceResult(
        merge: false,
        why: 'GM_MERGE_PLACE 指定的序列不存在：${into.isEmpty ? '（空）' : into}',
      );
    }
    return MergePlaceResult(merge: true, into: target.id, why: raw.why);
  }

  Future<TurnTrace> _runEnvironmentTurn({
    required OpenPlaceResult openPlace,
    required List<WorldEvent> events,
    required List<String> perceptionNames,
    required String reason,
    TurnSession? resume,
  }) async {
    List<WorldEvent> environmentEvents = const <WorldEvent>[];
    List<String> environmentErrors = <String>[];
    final TurnCheckpoint? environmentCheckpoint = resume?.checkpoints['GM_ENV_UPDATE'];
    final TurnCheckpoint? envCCheckpoint = resume?.checkpoints['SYS_RECORD'];
    final TurnCheckpoint? envSource =
        envCCheckpoint ?? environmentCheckpoint;
    if (envSource != null) {
      environmentEvents = _eventsFromCheckpoint(envSource.data);
      TurnState? proposed = causalContext?.state;
      for (final WorldEvent event in environmentEvents) {
        final List<String> errors = StateDelta.proposalErrors(event.stateChanges);
        if (errors.isNotEmpty) throw FormatException(errors.join('；'));
        final StateDelta changes = StateDelta.fromAction(event.stateChanges);
        if (changes.moves.isNotEmpty || changes.processes.any((ProcessDelta p) => p.owner.isNotEmpty)) {
          throw const FormatException('已保存环境事件不能替角色决定行动');
        }
        proposed = proposed?.applyDelta(changes);
        if (cWriter.validate(event, scene).isNotEmpty) {
          throw const FormatException('已保存环境事件未通过落账校验');
        }
      }
    } else {
      for (int environmentStep = 1; environmentStep <= environmentStepBudget; environmentStep++) {
        if (environmentSource == null) {
          environmentEvents = const <WorldEvent>[];
          break;
        }
        final String? feedback =
            environmentErrors.isEmpty ? null : environmentErrors.join('\n');
        environmentErrors = <String>[];
        List<WorldEvent> raw;
        try {
          raw = await _withAsk(
            'GM_ENV_UPDATE',
            () => environmentSource!(
              scene: scene,
              events: events,
              feedback: feedback,
            ),
          );
        } on AskPlayerException {
          rethrow;
        } on PlayerPausedException {
          rethrow;
        } catch (err) {
          environmentErrors.add('$err');
          continue;
        }
        environmentEvents = <WorldEvent>[];
        TurnState? proposedState = causalContext?.state;
        for (final WorldEvent e in raw) {
          try {
            final List<String> errors = StateDelta.proposalErrors(e.stateChanges);
            if (errors.isNotEmpty) throw FormatException(errors.join('；'));
            final StateDelta changes = StateDelta.fromAction(e.stateChanges);
            if (changes.moves.isNotEmpty || changes.processes.any((ProcessDelta p) => p.owner.isNotEmpty)) {
              throw const FormatException('环境阶段不能替角色决定移动或持续行动');
            }
            if (proposedState != null) proposedState = proposedState.applyDelta(changes);
            environmentEvents.add(
              cWriter.commitValidated(
                event: e.copyWith(turnIndex: (causalContext?.state.worldStep ?? 0) + 1),
                scene: scene,
                engine: engine,
              ),
            );
          } catch (err) {
            environmentErrors.add('$err');
          }
        }
        if (causalContext != null && environmentErrors.isEmpty) {
          environmentErrors.addAll(causalContext!.state.transitionErrors(StateDelta.combine(
              environmentEvents.map((WorldEvent e) => StateDelta.fromAction(e.stateChanges)))));
        }
        if (environmentErrors.isEmpty) break;
      }
      if (environmentErrors.isNotEmpty) {
        return TurnTrace(
          percepts: const <String, Map<String, Object?>>{},
          eligible: const <String>[],
          chosen: null,
          action: null,
          arbitration: null,
          stateDelta: null,
          events: const <WorldEvent>[],
          render: null,
          renderViolations: const <RenderViolation>[],
          blocked: const <FunctionalConstraint>[],
          stop: null,
          actErrors: const <ActValidationError>[],
          openPlace: openPlace,
          route: 'env',
          environmentErrors: environmentErrors,
          rejectedEvents: const <WorldEvent>[],
        );
      }
      _stage('GM_ENV_UPDATE');
      _checkpoint('GM_ENV_UPDATE', <String, Object?>{
        'events': <Object?>[
          for (final WorldEvent e in environmentEvents) worldEventToJson(e),
        ],
      });
    }
    if (environmentEvents.isEmpty) {
      return TurnTrace(
        percepts: const <String, Map<String, Object?>>{},
        eligible: const <String>[],
        chosen: null,
        action: null,
        arbitration: null,
        stateDelta: null,
        events: const <WorldEvent>[],
        render: null,
        renderViolations: const <RenderViolation>[],
        blocked: const <FunctionalConstraint>[],
        stop: TurnStop(
          code: 'no_environment_event',
          reason: reason,
        ),
        actErrors: const <ActValidationError>[],
        openPlace: openPlace,
        route: 'env',
      );
    }
    if (envCCheckpoint == null) {
      _stage('SYS_RECORD');
      _checkpoint('SYS_RECORD', <String, Object?>{
        'events': <Object?>[
          for (final WorldEvent e in environmentEvents) worldEventToJson(e),
        ],
      });
    }

    // 环境事件也要当场被在场角色感知并写进记忆，不能等下一个角色回合。
    final ({Map<String, Map<String, Object?>> percepts, List<String> errors})
        envPerceived = await _perceiveAndRemember(
      events: <WorldEvent>[...events, ...environmentEvents],
      names: perceptionNames,
      resume: resume,
      batch: 'env',
      observationState: causalContext?.state.applyDelta(
        StateDelta.combine(environmentEvents.map((WorldEvent e) => StateDelta.fromAction(e.stateChanges))),
        atTurn: (causalContext?.state.worldStep ?? 0) + 1,
      ).withEvents(<WorldEvent>[...?causalContext?.state.events, ...environmentEvents]),
    );
    if (envPerceived.errors.isNotEmpty) {
      return TurnTrace(
        percepts: envPerceived.percepts,
        eligible: const <String>[],
        chosen: null,
        action: null,
        arbitration: null,
        stateDelta: null,
        events: const <WorldEvent>[],
        render: null,
        renderViolations: const <RenderViolation>[],
        blocked: const <FunctionalConstraint>[],
        stop: null,
        actErrors: const <ActValidationError>[],
        perceiveErrors: envPerceived.errors,
        openPlace: openPlace,
        route: 'env',
        environmentEvents: environmentEvents,
      );
    }

    final TurnPresentation? narration = deferPresentation ? null
        : await _narrate(environmentEvents, resume?.checkpoints[StepId.gmNarrate]);
    final List<String> warnings = narration?.warnings ?? const <String>[];
    final List<WorldEvent> rendered = <WorldEvent>[
      for (final WorldEvent event in environmentEvents)
        if (narration == null) event else
          event.copyWith(publicText: narration.publicText, godNote: narration.godNote),
    ];
    final TurnCheckpoint? mergePlaceCheckpoint = resume?.checkpoints['GM_MERGE_PLACE'];
    final MergePlaceResult mergePlace;
    if (mergePlaceCheckpoint != null) {
      mergePlace = _mergePlaceFromCheckpoint(mergePlaceCheckpoint.data);
    } else {
      mergePlace = await _decideMergePlace(
        events: rendered,
        remainingCast: <String>[
          for (final CharacterSnapshot c in scene.cast) c.name,
        ],
      );
      _stage('GM_MERGE_PLACE');
      _checkpoint('GM_MERGE_PLACE', <String, Object?>{
        'merge': mergePlace.merge,
        'why': mergePlace.why,
        'into': mergePlace.into,
      });
    }
    return TurnTrace(
      percepts: envPerceived.percepts,
      eligible: const <String>[],
      chosen: null,
      action: null,
      arbitration: null,
      stateDelta: StateDelta.combine(environmentEvents.map(
          (WorldEvent e) => StateDelta.fromAction(e.stateChanges))),
      events: const <WorldEvent>[],
      render: narration?.render,
      renderViolations: narration?.check.violations ?? const <RenderViolation>[],
      blocked: const <FunctionalConstraint>[],
      stop: null,
      actErrors: const <ActValidationError>[],
      openPlace: openPlace,
      route: 'env',
      environmentEvents: rendered,
      mergePlace: mergePlace,
      needsReview: warnings.isNotEmpty,
      reviewWarnings: warnings,
    );
  }

  /// 两种回合共用：硬错误与语义意见都反馈给正文，预算跨暂停保存。
  Future<TurnPresentation> presentCommitted(
    List<WorldEvent> events, {
    TurnCheckpoint? checkpoint,
    Map<String, Object?> Function(Map<String, Object?>)? reviseDraft,
  }) => _narrate(events, checkpoint, reviseDraft: reviseDraft);

  Future<TurnPresentation> _narrate(
    List<WorldEvent> events,
    TurnCheckpoint? checkpoint, {
    Map<String, Object?> Function(Map<String, Object?>)? reviseDraft,
  }) async {
    final String observer = 'char:$controlledCharacter';
    final List<WorldEvent> allowed = pov == RenderPov.player
        ? renderView(events, scene, observer) : events;
    final NarrativeScene allowedScene = pov == RenderPov.player
        ? renderScene(scene, observer) : scene;
    if (pov == RenderPov.player && checkpoint != null && checkpoint.data['observer'] != observer) {
      // 旧检查点没有绑定观察者，不能把其中的全知正文作为角色重写上下文。
      checkpoint = null;
      agents.prepareRetry(StepId.gmNarrate);
      agents.prepareRetry(StepId.gmReviewNarration);
    }
    Map<String, Object?> render = checkpoint?.data['render'] is Map
        ? Map<String, Object?>.from(checkpoint!.data['render'] as Map) : <String, Object?>{};
    int attempts = checkpoint == null ? 0 : (checkpoint.data['attempts'] as int? ?? 1);
    bool saved = checkpoint != null;
    List<String> feedback = <String>[];
    while (true) {
      if (!saved) {
        attempts++;
        render = pov == RenderPov.player && allowed.isEmpty
            ? <String, Object?>{'public_text': '当前没有可感知的新变化。', 'god_note': ''}
            : await agents.render(events: allowed, pov: pov, observerId: observer, scene: scene,
                errors: feedback, previous: render.isEmpty ? null : render);
        if (pov == RenderPov.player) render = <String, Object?>{...render, 'god_note': ''};
      }
      final Map<String, Object?> originalRender = render;
      final Map<String, Object?> revisedRender = reviseDraft?.call(render) ?? render;
      final String publicText = '${revisedRender['public_text'] ?? ''}';
      final String godNote = pov == RenderPov.player ? '' : '${revisedRender['god_note'] ?? ''}';
      final RenderCheckResult check = const RenderChecker().check(
        publicText: publicText, godNote: godNote, events: allowed,
        scene: allowedScene, entityNames: <String>[...entityNames, ...scene.names.values],
      );
      final Map<String, Object?> data = <String, Object?>{
        'render': originalRender,
        'publicText': '${originalRender['public_text'] ?? ''}',
        'godNote': pov == RenderPov.player ? '' : '${originalRender['god_note'] ?? ''}',
        'attempts': attempts,
        'observer': pov == RenderPov.player ? observer : '',
        'violations': <Object?>[for (final RenderViolation v in check.violations) v.toJson()],
      };
      if (!saved) {
        _stage(StepId.gmNarrate);
        _checkpoint(StepId.gmNarrate, data);
      }
      List<String> warnings = <String>[];
      if (check.ok) {
        final Object? reviewedRender = checkpoint?.data['reviewedRender'] ?? originalRender;
        final Object? stored = saved && jsonEncode(reviewedRender) == jsonEncode(revisedRender)
            ? checkpoint?.data['warnings'] : null;
        if (saved && stored == null && checkpoint?.data['warnings'] is List) {
          agents.prepareRetry(StepId.gmReviewNarration);
        }
        warnings = stored is List ? <String>[for (final Object? w in stored) '$w']
            : rCheck == null || (pov == RenderPov.player && allowed.isEmpty) ? <String>[]
            : await rCheck!(publicText: publicText, godNote: godNote, events: allowed);
        _checkpoint(StepId.gmNarrate, <String, Object?>{
          ...data, 'warnings': warnings,
          if (!identical(originalRender, revisedRender)) 'reviewedRender': revisedRender,
        });
      }
      feedback = <String>[
        for (final RenderViolation v in check.violations) '${v.code}：${v.message}',
        for (final String warning in warnings) '正文语义复核：$warning',
      ];
      if (feedback.isEmpty || attempts >= rStepBudget) {
        return (render: revisedRender, publicText: publicText, godNote: godNote, check: check, warnings: warnings);
      }
      // 旧正文及其复核不能用于下一版，恢复后的调用序号也不能串用旧返回。
      agents.prepareRetry(StepId.gmNarrate);
      agents.prepareRetry(StepId.gmReviewNarration);
      _completed.remove(StepId.gmMergePlace);
      _checkpoint(StepId.sysRecovery, <String, Object?>{
        ...?_completed[StepId.sysRecovery]?.data, 'invalidate': <String>[StepId.gmMergePlace],
      });
      render = revisedRender;
      saved = false;
    }
  }

  /// 用同一份世界位置构造目的地现场，保留该地角色自己的称呼。
  NarrativeScene _sceneAt(String place, StateDelta delta) {
    final NarrativeScene? configured = sceneForPlace?.call(place);
    final Map<String, CharacterSnapshot> cast = <String, CharacterSnapshot>{
      if (place == scene.place) for (final CharacterSnapshot c in scene.cast) c.id: c,
      if (configured != null) for (final CharacterSnapshot c in configured.cast) c.id: c,
    };
    final Map<String, String> locations = <String, String>{
      if (causalContext != null)
        for (final EntityRecord e in causalContext!.state.entities.values)
          if (e.kind == 'character') e.name: e.location.replaceFirst('place:', ''),
      ...?causalContext?.state.locations,
      ...delta.moves,
    };
    final Map<String, String> names = <String, String>{
      ...scene.names, ...?configured?.names,
      if (causalContext != null)
        for (final EntityRecord e in causalContext!.state.entities.values)
          if (e.kind == 'character') e.id: e.name,
    };
    for (final MapEntry<String, String> located in locations.entries) {
      final String id = 'char:${located.key}';
      if (located.value == place) {
        cast.putIfAbsent(id, () => scene.byId(id) ?? CharacterSnapshot(
          id: id, name: located.key, nearby: true));
      } else {
        cast.remove(id);
      }
    }
    return NarrativeScene(place: place, cast: cast.values.toList(), names: names);
  }

  Iterable<NarrativeScene> _arrivalScenes(StateDelta delta) sync* {
    for (final String place in delta.moves.values.toSet()) {
      if (place != scene.place) yield _sceneAt(place, delta);
    }
  }

  List<Witness> _arrivalWitnesses(WorldEvent event, StateDelta delta) {
    final Map<String, Witness> witnesses = <String, Witness>{
      for (final Witness w in event.witnesses) w.characterId: w,
    };
    for (final NarrativeScene destination in _arrivalScenes(delta)) {
      if (event.observationsResolved) {
        // 目的地只接收裁定给它的实际结果，不能看到出发地的尝试和秘密。
        for (final CharacterSnapshot c in destination.cast) {
          final String text = event.observations[c.id] ?? event.observations[c.name] ?? '';
          if (text.trim().isNotEmpty && !witnesses.containsKey(c.id)) {
            witnesses[c.id] = Witness(characterId: c.id, modality: 'sight',
              content: engine.localize(text, c, destination));
          }
        }
      } else {
        // 确定性的直接移动同样产生到达见闻，传达范围仍受原动作约束。
        for (final MapEntry<String, String> move in delta.moves.entries) {
          if (move.value != destination.place) continue;
          final WorldEvent arrival = WorldEvent(id: event.id, kind: WorldEventKind.action,
            actor: 'char:${move.key}', content: '到达${move.value}',
            delivery: event.delivery, source: 'movement', placeId: destination.place,
            timeLabel: event.timeLabel);
          for (final Witness w in engine.witnesses(arrival, destination)) {
            witnesses.putIfAbsent(w.characterId, () => w);
          }
        }
      }
    }
    return witnesses.values.toList();
  }

  List<String> _validateArbitration(Map<String, Object?>? a, {
    String? actor, Map<String, Object?>? action,
  }) {
    if (a == null) return <String>['GM_RESOLVE_ACTION 没有返回结果'];
    final List<String> errors = <String>[];
    final String outcome = '${a['outcome'] ?? ''}'.trim();
    if (!<String>{'success', 'failure', 'partial', 'unresolved'}
        .contains(outcome)) {
      errors.add('GM_RESOLVE_ACTION outcome 非法：$outcome');
    }
    final Object? deltas = a['deltas'];
    if (deltas is! List) {
      errors.add('GM_RESOLVE_ACTION deltas 必须是数组');
    } else {
      for (int i = 0; i < deltas.length; i++) {
        final Object? d = deltas[i];
        if (d is! Map) {
          errors.add('GM_RESOLVE_ACTION deltas[$i] 不是对象');
          continue;
        }
        final String kind = '${d['kind'] ?? ''}'.trim();
        if (!<String>{'steal', 'take', 'give', 'drop', 'move', 'injure', 'constraint', 'none'}.contains(kind)) {
          errors.add('GM_RESOLVE_ACTION deltas[$i] 的 kind 非法：$kind');
        }
        final Map<String, Object?> proposal = <String, Object?>{};
        if (kind == 'move') {
          proposal['move'] = <Object?, Object?>{d['id'] ?? d['actor'] ?? d['who']: d['to']};
        } else if (kind == 'injure') {
          proposal['injure'] = <Object?>[<String, Object?>{
            'who': d['who'] ?? d['id'], 'part': d['part'],
            'kind': d['injury_kind'] ?? d['wound_kind'],
            for (final String key in <String>['cause', 'treatment', 'note'])
              if (d.containsKey(key)) key: d[key],
          }];
        } else if (kind == 'constraint') {
          proposal['constraints'] = <Object?>[<String, Object?>{
            'who': d['who'] ?? d['id'], 'capability': d['capability'] ?? d['action'],
            'state': d['state'], if (d.containsKey('reason')) 'reason': d['reason'],
          }];
        } else if (<String>{'steal', 'take', 'give', 'drop'}.contains(kind)) {
          proposal['items'] = <Object?>[d];
        }
        errors.addAll(StateDelta.proposalErrors(proposal));
        if (causalContext != null && kind != 'none') {
          final StateDelta parsed = StateDelta.fromArbiter(<String, Object?>{'deltas': [d]});
          if (parsed.isEmpty) errors.add('GM_RESOLVE_ACTION deltas[$i] 缺少该类型必需的状态字段');
        }
      }
    }
    if ('${a['reason'] ?? ''}'.trim().isEmpty) {
      errors.add('GM_RESOLVE_ACTION reason 不能为空');
    }
    final String? timeLabelProblem =
        timeLabelError(normalizeTimeLabel(a['time_label']));
    if (timeLabelProblem != null) {
      errors.add('GM_RESOLVE_ACTION 的 $timeLabelProblem');
    }
    errors.addAll(StateDelta.proposalErrors(<String, Object?>{
      for (final String field in <String>['facts', 'discoveries', 'processes'])
        if (a.containsKey(field)) field: a[field],
    }));
    if (causalContext != null) {
      for (final String field in <String>['facts', 'discoveries', 'processes']) {
        final Object? raw = a[field];
        if (raw != null && (raw is! List || raw.any((Object? x) => x is! Map))) {
          errors.add('GM_RESOLVE_ACTION $field 必须是对象数组');
        }
      }
      if ('${a['result'] ?? ''}'.trim().isEmpty) errors.add('裁定必须记录实际结果 result');
      if (a['observations'] is! Map) {
        errors.add('裁定必须逐人给 observations，无人看见时用空对象');
      } else {
        final StateDelta movement = StateDelta.fromArbiter(a);
        final List<NarrativeScene> arrivals = _arrivalScenes(movement).toList();
        final Set<String> allowedObservers = <String>{
          for (final CharacterSnapshot c in scene.cast) c.id,
          for (final NarrativeScene arrival in arrivals)
            for (final CharacterSnapshot c in arrival.cast) c.id,
        };
        for (final Object? key in (a['observations'] as Map).keys) {
          final String id = '$key'.startsWith('char:') ? '$key' : 'char:$key';
          if (!allowedObservers.contains(id)) errors.add('结果观察者不在行动涉及的现场：$key');
          if ((a['observations'] as Map)[key] is! String) errors.add('逐人观察必须是文本：$key');
        }
        for (final NarrativeScene arrival in arrivals) {
          for (final CharacterSnapshot c in arrival.cast) {
            if (scene.byId(c.id) == null &&
                !(a['observations'] as Map).containsKey(c.id) &&
                !(a['observations'] as Map).containsKey(c.name)) {
              errors.add('跨地点移动必须给出目的地角色 ${c.id} 的见闻；没有感知则明确写空文本');
            }
          }
        }
      }
      errors.addAll(causalContext!.state.transitionErrors(StateDelta.fromArbiter(a),
          actor: actor, place: scene.place));
      if (outcome == 'success' && action != null &&
          _actionKinds(action).contains('steal') &&
          StateDelta.fromArbiter(a).items.isEmpty) {
        errors.add('抢夺成功必须给出已确认物品的归属变化');
      }
    }
    return errors;
  }

  /// 这个事件在某个角色眼里是什么；优先用落账时存下的 witnesses。
  Witness? _witnessOf(WorldEvent e, String characterId) {
    if (e.receivedBy.contains(characterId)) return null;
    final List<Witness> witnesses =
        e.witnessesResolved || e.witnesses.isNotEmpty ? e.witnesses : engine.witnesses(e, scene);
    for (final Witness w in witnesses) {
      if (w.characterId == characterId) return w;
    }
    return null;
  }

  /// 现场观察不伪造历史事件，结果按角色隔离并进入可恢复检查点。
  Future<void> _observeCurrentScene({required List<String> names, TurnSession? resume,
      String batch = '', TurnState? state}) async {
    if (sceneObserver == null || names.isEmpty || (state ?? causalContext?.state) == null) return;
    final String stage = batch.isEmpty ? StepId.gmObserveScene : '${StepId.gmObserveScene}:$batch';
    final TurnCheckpoint? checkpoint = resume?.checkpoints[stage];
    final Map<String, String> observations;
    if (checkpoint != null) {
      final Object? raw = checkpoint.data['observations'];
      if (raw is! Map || raw.values.any((Object? text) => text is! String)) {
        throw const FormatException('现场见闻检查点格式不合格');
      }
      observations = raw.map((Object? id, Object? text) => MapEntry('$id', '$text'));
    } else {
      observations = await _withAsk(stage, () => sceneObserver!(scene: scene,
        state: state ?? causalContext!.state, observers: names));
    }
    final Set<String> expected = names.map((String name) => 'char:$name').toSet();
    if (observations.keys.any((String id) => !expected.contains(id)) ||
        expected.any((String id) => !observations.containsKey(id))) {
      throw RetryExhaustedException(step: stage, reason: '现场见闻必须逐一对应本场景的观察角色');
    }
    for (final MapEntry<String, String> observation in observations.entries) {
      final CharacterSnapshot? observer = scene.byId(observation.key);
      if (observer != null) {
        _sceneObservations[observation.key] = engine.localize(observation.value, observer, scene);
      }
    }
    if (checkpoint == null) {
      _stage(stage);
      _checkpoint(stage, <String, Object?>{'observations': observations});
    }
  }

  /// 事件按交付回执去重；当前现场独立提供，感知结果再交给角色记忆整理。
  Future<({Map<String, Map<String, Object?>> percepts, List<String> errors})>
      _perceiveAndRemember({
    required List<WorldEvent> events,
    required List<String> names,
    TurnSession? resume,
    String batch = '',
    TurnState? observationState,
  }) async {
    await _observeCurrentScene(names: names, resume: resume, batch: batch, state: observationState);
    final Map<String, Map<String, Object?>> percepts =
        <String, Map<String, Object?>>{};
    final List<String> errorsOut = <String>[];
    for (final String name in names) {
      final String id = 'char:$name';
      final String suffix = batch.isEmpty ? name : '$name:$batch';
      final TurnCheckpoint? perceiveCheckpoint =
          resume?.checkpoints['CH_PERCEIVE:$suffix'];
      final TurnCheckpoint? mCheckpoint =
          resume?.checkpoints['CH_MEMORY_WRITE:$suffix'];
      Map<String, Object?> last = <String, Object?>{};
      Set<String> allowedIds = <String>{};
      bool perceiveDone = false;
      if (perceiveCheckpoint != null) {
        perceiveDone = true;
        last = perceiveCheckpoint.data['percepts'] is Map
            ? Map<String, Object?>.from(
                perceiveCheckpoint.data['percepts'] as Map,
              )
            : <String, Object?>{};
        allowedIds = _allowedIdsFromPercepts(last);
        final Object? savedAllowed = perceiveCheckpoint.data['allowedEventIds'];
        if (savedAllowed is List) allowedIds.addAll(savedAllowed.map((Object? x) => '$x'));
        percepts[name] = last;
      } else {
        final Set<String> seen = <String>{};
        for (final CharacterMemory m in memory.forCharacter(id)) {
          seen.addAll(m.sourceEvents);
        }
        final Set<String> imageIds = <String>{};
        final List<String> lines = <String>[];
        for (final WorldEvent e in events) {
          if (deliveryReceipts[e.id]?.contains(id) == true ||
              (e.uid.isNotEmpty && deliveryReceipts[e.uid]?.contains(id) == true)) {
            continue;
          }
          if (seen.contains(e.id) ||
              (e.uid.trim().isNotEmpty && seen.contains(e.uid))) {
            _acknowledge(id, <String>{e.id, if (e.uid.isNotEmpty) e.uid});
            continue;
          }
          final Witness? w = _witnessOf(e, id);
          if (w == null) continue;
          allowedIds.add(e.id);
          if (e.uid.trim().isNotEmpty) allowedIds.add(e.uid);
          if (w.modality == 'sight') imageIds.addAll(e.attachmentIds);
          final String notes = <String>[
            if (e.deliveryNote.trim().isNotEmpty) e.deliveryNote.trim(),
            if (e.distanceNote.trim().isNotEmpty) e.distanceNote.trim(),
          ].join('；');
          lines.add(
            '${e.id} ${notes.isEmpty ? w.content : '${w.content}（$notes）'}',
          );
        }
        final String charEvents = lines.join('\n');
        if (charEvents.isEmpty && (_sceneObservations[id] ?? '').trim().isEmpty) {
          percepts[name] = <String, Object?>{
            'percepts': <Object?>[],
            'attention': memory.activeForCharacter(id).any((CharacterMemory m) => m.attention.isNotEmpty)
                ? memory.activeForCharacter(id).lastWhere((CharacterMemory m) => m.attention.isNotEmpty).attention
                : '没有新动静',
          };
          continue;
        }
        final List<String> errors = <String>[];
        for (int perceiveStep = 1; perceiveStep <= perceiveStepBudget; perceiveStep++) {
          last = await agents.perceiveWithImages(
            name: name,
            context: _characterContext(id, observedState: observationState),
            events: _perceiveInput(charEvents, errors, last),
            imageAssetIds: imageIds.toList(),
          );
          errors
            ..clear()
            ..addAll(_validatePerceive(name, last, allowedIds));
          last = <String, Object?>{
            ...last,
            if ((_sceneObservations[id] ?? '').isNotEmpty) 'current_scene': _sceneObservations[id],
          };
          if (errors.isEmpty) break;
        }
        percepts[name] = last;
        if (errors.isNotEmpty) {
          errorsOut.add(
            '$name：CH_PERCEIVE 连续 $perceiveStepBudget 次不合格（${errors.join('；')}）',
          );
          continue;
        }
        _stage('CH_PERCEIVE:$suffix');
        _checkpoint('CH_PERCEIVE:$suffix', <String, Object?>{
          'name': name,
          'percepts': last,
          'allowedEventIds': allowedIds.toList(),
          'memory_refs': <Object?>[
            for (final CharacterMemory m in memory.activeForCharacter(id))
              <String, Object?>{'id': m.id, 'version': m.version},
          ],
        });
      }

      if (perceiveDone && mCheckpoint != null) {
        _applyMemoryCheckpoint(
          characterId: id,
          checkpoint: mCheckpoint,
          fallbackAllowedIds: allowedIds,
        );
        _acknowledge(id, allowedIds);
        continue;
      }

      final List<MemoryOperation>? ops = await agents.manageMemory(
        characterId: id,
        percepts: last,
        memory: memory.activeForCharacter(id),
        allowedEventIds: allowedIds,
      );
      if (ops == null) {
        _rememberPerceive(name, last);
      } else {
        final List<CharacterMemory> before = memory.forCharacter(id);
        final List<CharacterMemory> nextMemory = applyMemoryOperations(
          characterId: id,
          current: before,
          operations: ops,
          allowedEventIds: allowedIds,
        );
        memory.restoreCharacter(id, nextMemory);
        final List<CharacterMemory> after = memory.forCharacter(id);
        final List<CharacterMemory> changed = <CharacterMemory>[
          for (final CharacterMemory m in after)
            if (!before.any(
              (CharacterMemory old) =>
                  jsonEncode(old.toJson()) == jsonEncode(m.toJson()),
            ))
              m,
        ];
        _stage('CH_MEMORY_WRITE:$suffix');
        _checkpoint('CH_MEMORY_WRITE:$suffix', <String, Object?>{
          'character': id,
          'operations': <Object?>[
            for (final MemoryOperation o in ops) o.toJson(),
          ],
          'allowedEventIds': allowedIds.toList(),
          'changed': <Object?>[
            for (final CharacterMemory m in changed) m.toJson(),
          ],
          'memory_refs': <Object?>[
            for (final CharacterMemory m in memory.activeForCharacter(id))
              <String, Object?>{'id': m.id, 'version': m.version},
          ],
        });
      }
      _acknowledge(id, allowedIds);
    }
    return (percepts: percepts, errors: errorsOut);
  }

  Set<String> _allowedIdsFromPercepts(Map<String, Object?> percepts) {
    final Set<String> ids = <String>{};
    final Object? raw = percepts['percepts'];
    if (raw is List) {
      for (final Object? item in raw) {
        if (item is! Map) continue;
        final String id = '${item['event_id'] ?? ''}'.trim();
        if (id.isNotEmpty) ids.add(id);
      }
    }
    return ids;
  }

  void _applyMemoryCheckpoint({
    required String characterId,
    required TurnCheckpoint checkpoint,
    required Set<String> fallbackAllowedIds,
  }) {
    final Object? rawChanged = checkpoint.data['changed'];
    if (rawChanged is List && rawChanged.isNotEmpty) {
      final List<CharacterMemory> merged = <CharacterMemory>[
        ...memory.forCharacter(characterId),
      ];
      for (final Object? item in rawChanged) {
        if (item is! Map) continue;
        final CharacterMemory m = CharacterMemory.fromJson(
          Map<String, Object?>.from(item),
        );
        final int at = merged.indexWhere((CharacterMemory x) => x.id == m.id);
        if (at >= 0) {
          merged[at] = m;
        } else {
          merged.add(m);
        }
      }
      memory.restoreCharacter(characterId, merged);
      return;
    }
    final List<MemoryOperation> ops = <MemoryOperation>[];
    final Object? raw = checkpoint.data['operations'];
    if (raw is List) {
      for (final Object? item in raw) {
        if (item is Map) {
          final MemoryOperation? op = MemoryOperation.fromJson(
            Map<String, Object?>.from(item),
          );
          if (op != null) ops.add(op);
        }
      }
    }
    final Set<String> allowed = <String>{
      ...fallbackAllowedIds,
      ..._allowedFromCheckpoint(checkpoint.data['allowedEventIds']),
    };
    final List<CharacterMemory> nextMemory = applyMemoryOperations(
      characterId: characterId,
      current: memory.forCharacter(characterId),
      operations: ops,
      allowedEventIds: allowed,
    );
    memory.restoreCharacter(characterId, nextMemory);
  }

  Set<String> _allowedFromCheckpoint(Object? raw) {
    if (raw is! List) return <String>{};
    return <String>{for (final Object? x in raw) '$x'};
  }

  void _rememberPerceive(String name, Map<String, Object?> perceive) {
    final Object? raw = perceive['percepts'];
    if (raw is! List) return;
    final List<String> texts = <String>[];
    final Set<String> eventIds = <String>{};
    for (final Object? item in raw) {
      if (item is! Map) continue;
      final Map<String, Object?> p = item.cast<String, Object?>();
      final String eventId = '${p['event_id'] ?? ''}'.trim();
      final String content = '${p['content'] ?? ''}'.trim();
      if (eventId.isEmpty || content.isEmpty) continue;
      eventIds.add(eventId);
      texts.add(content);
    }
    if (texts.isEmpty) return;
    final String now = DateTime.now().toIso8601String();
    memory.add(
      CharacterMemory(
        id: newCharacterMemoryId(),
        characterId: 'char:$name',
        text: texts.join('\n'),
        kind: MemoryKind.episodic,
        origin: MemoryOrigin.model,
        sourceEvents: eventIds.toList(),
        attention: '${perceive['attention'] ?? ''}'.trim(),
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  List<String> _validatePerceive(
    String name,
    Map<String, Object?> raw,
    Set<String> allowedEventIds,
  ) {
    final List<String> errors = <String>[];
    final Object? percepts = raw['percepts'];
    if (percepts is! List) {
      return <String>['$name: CH_PERCEIVE 缺 percepts 数组'];
    }
    for (int i = 0; i < percepts.length; i++) {
      final Object? item = percepts[i];
      if (item is! Map) {
        errors.add('$name: percepts[$i] 不是对象');
        continue;
      }
      final String eventId = '${item['event_id'] ?? ''}'.trim();
      if (eventId.isEmpty) {
        errors.add('$name: percepts[$i] 缺 event_id');
      } else if (!allowedEventIds.contains(eventId)) {
        errors.add('$name: 引用了候选集外的事件 $eventId');
      }
    }
    return errors;
  }

  String _characterContext(String id, {Set<String>? onlyMemoryIds,
      String archivedContext = '', TurnState? observedState}) {
    final String base = memory.contextFor(
      id,
      scene,
      onlyIds: onlyMemoryIds,
    );
    final String notes = (scene.characterNotes[id] ?? '').trim();
    final CausalContext? current = observedState == null ? causalContext
        : CausalContext(state: observedState, rules: causalContext?.rules ?? '', opening: causalContext?.opening ?? '');
    return <String>[
      base,
      if (archivedContext.isNotEmpty) archivedContext,
      if (current != null) current.characterView(id, scene),
      if ((scene.observations[id] ?? '').isNotEmpty) scene.observations[id]!,
      if ((_sceneObservations[id] ?? '').isNotEmpty) '【此刻可感知的现场】\n${_sceneObservations[id]}',
      if (notes.isNotEmpty) '【给自己的补充】\n$notes',
    ].join('\n\n');
  }

  void _acknowledge(String characterId, Set<String> ids) {
    for (final String id in ids) {
      deliveryReceipts.putIfAbsent(id, () => <String>{}).add(characterId);
    }
  }

  bool _requiresAr(Map<String, Object?> action, String actor) {
    if (_actionKinds(action).any(needsAr) || action['resolution'] == 'adjudicate') return true;
    final CausalContext? context = causalContext;
    final StateDelta delta = StateDelta.fromAction(action['state_delta']);
    if (context == null) return false;
    final Object? preconditions = action['preconditions'];
    if (preconditions is List) {
      for (final Object? precondition in preconditions) {
        if (precondition is! Map || !context.state.facts.any((FactRecord f) =>
            f.untilEvent.isEmpty && f.subject == precondition['subject'] &&
            f.predicate == precondition['predicate'] && f.object == precondition['object'])) {
          return true;
        }
      }
    }
    if (delta.isEmpty) {
      return (action['segments'] as List).any((Object? s) => s is Map && s['kind'] == 'action' &&
          (action['resolution'] != 'direct' ||
              !<String>{'gesture', 'wait', 'observe'}.contains(s['action_kind'])));
    }
    if (action['resolution'] != 'direct' || delta.injuries.isNotEmpty ||
        delta.constraints.isNotEmpty || delta.facts.isNotEmpty ||
        delta.discoveries.isNotEmpty || delta.processes.isNotEmpty) {
      return true;
    }
    final TurnState state = context.state;
    if (state.transitionErrors(delta, actor: actor, place: scene.place,
        adjudicated: false).isNotEmpty) {
      return true;
    }
    bool accessible(String subject) => state.facts.any((FactRecord f) =>
        f.subject == subject && f.predicate == 'accessible' &&
        f.object == 'true' && f.untilEvent.isEmpty);
    for (final String destination in delta.moves.values) {
      if (action['duration'] == 'extended' || !accessible('place:$destination') ||
          !state.facts.any((FactRecord f) => f.untilEvent.isEmpty &&
              f.subject == 'place:${scene.place}' && f.predicate == 'connected_to' &&
              f.object == destination)) {
        return true;
      }
    }
    for (final StateItemDelta item in delta.items) {
      if (item.kind == 'take' && item.from != actor && !accessible(item.from ?? '')) {
        return true;
      }
    }
    return false;
  }

  String _perceiveInput(
    String events,
    List<String> errors,
    Map<String, Object?> previous,
  ) {
    if (errors.isEmpty) return events;
    return '$events\n\n【上一次 CH_PERCEIVE 输出】\n${jsonEncode(previous)}\n'
        '【CH_PERCEIVE 校验失败】\n${errors.join('\n')}\n'
        '请只引用上面【新事件】里的 event_id，重写。';
  }

  String _actInput(
    Map<String, Object?> perceive,
    List<ActValidationError> errors,
    Map<String, Object?> previousAction,
  ) {
    final String base = jsonEncode(perceive);
    if (errors.isEmpty) return base;
    return '$base\n\n【上一次 CH_ACT 输出】\n'
        '${jsonEncode(previousAction)}\n'
        '【CH_ACT 校验失败】\n'
        '${jsonEncode(errors.last.toJson())}\n'
        '请修正后重写；如果动作与状态冲突，换一个当前状态能做到的行动。';
  }

  ActValidationError? _validateAct(
    Map<String, Object?> action, {
    required String actor,
  }) {
    try {
      return _validateActRecord(action, actor: actor);
    } on FormatException catch (error) {
      return ActValidationError(code: 'ambiguous_reference', message: error.message);
    }
  }

  ActValidationError? _validateActRecord(
    Map<String, Object?> action, {
    required String actor,
  }) {
    final String status = '${action['status'] ?? ''}'.trim();
    if (status.isNotEmpty) {
      return ActValidationError(
        code: 'status_not_allowed',
        message: 'CH_ACT 不接受 status=$status；写正常行动。不能行动就写一条 action 段，例如“她没有动”。',
      );
    }
    final Object? raw = action['segments'];
    if (raw is! List || raw.isEmpty) {
      return const ActValidationError(
        code: 'segments',
        message: 'CH_ACT 没有 segments',
      );
    }
    final String timeLabel = normalizeTimeLabel(action['time_label']);
    final String? timeLabelProblem = timeLabelError(timeLabel);
    if (timeLabelProblem != null) {
      return ActValidationError(
        code: 'time_label',
        message: 'CH_ACT 的 $timeLabelProblem',
      );
    }
    if (action['duration'] != null &&
        !<String>{'instant', 'brief', 'extended'}.contains(action['duration'])) {
      return const ActValidationError(code: 'duration', message: 'duration 只能是 instant、brief 或 extended');
    }
    if (action['resolution'] != null &&
        !<String>{'direct', 'adjudicate'}.contains(action['resolution'])) {
      return const ActValidationError(code: 'resolution', message: 'resolution 只能是 direct 或 adjudicate');
    }
    if (action['preconditions'] != null && (action['preconditions'] is! List ||
        (action['preconditions'] as List).any((Object? p) => p is! Map ||
            p['subject'] is! String || p['predicate'] is! String || p['object'] is! String))) {
      return const ActValidationError(code: 'preconditions', message: 'preconditions 必须是 subject/predicate/object 前提数组');
    }
    if (raw.where((Object? x) => x is Map && x['kind'] == 'action').length > 1) {
      return const ActValidationError(code: 'action_boundary',
          message: '每步最多一个动作；后续动作、跨地点后行动和多目标对抗留到下一步');
    }
    if (action['wait_for_response'] == true &&
        raw.any((Object? x) => x is Map && x['kind'] == 'action')) {
      return const ActValidationError(code: 'response_boundary',
          message: '等待别人回应时不能同时预先执行依赖回应的动作');
    }
    for (int i = 0; i < raw.length; i++) {
      final Object? item = raw[i];
      if (item is! Map) {
        return ActValidationError(
          code: 'segment_type',
          message: 'CH_ACT segment[$i] 不是对象',
          segmentIndex: i,
        );
      }
      final Map<String, Object?> seg = item.cast<String, Object?>();
      final String kind = '${seg['kind'] ?? ''}'.trim();
      if ((kind != 'speech' && kind != 'action') || seg['kind'] != kind) {
        return ActValidationError(
          code: 'segment_kind',
          message: 'CH_ACT segment[$i] 的 kind 只能是 speech 或 action',
          segmentIndex: i,
        );
      }
      final Object? text = seg['text'];
      if (text is! String ||
          (kind == 'action' ? _actionText(actor, text) : text.trim()).isEmpty) {
        return ActValidationError(code: 'empty_content',
            message: 'CH_ACT segment[$i] 必须有非空正文', segmentIndex: i);
      }
      final Object? delivery = seg['delivery'];
      if (delivery is! Map ||
          !<String>{'voice', 'visual', 'mental', 'digital', 'other'}.contains(delivery['channel']) ||
          delivery['form'] is! String || (delivery['form'] as String).trim().isEmpty) {
        return ActValidationError(code: 'delivery',
            message: 'CH_ACT segment[$i] 必须有有效的 channel、form 和 audience', segmentIndex: i);
      }
      final Object? rawTarget = seg['target'];
      if (rawTarget != null && rawTarget is! String) {
        return ActValidationError(code: 'target_type',
            message: 'CH_ACT segment[$i] 的 target 必须是文本或 null', segmentIndex: i);
      }
      final String target = resolveTarget(actor, '${rawTarget ?? ''}') ?? '${rawTarget ?? ''}'.trim();
      final List<CValidationError> eventErrors = cWriter.validate(WorldEvent(
        id: '', kind: kind == 'speech' ? WorldEventKind.speech : WorldEventKind.action,
        content: kind == 'action' ? _actionText(actor, text) : text,
        actor: 'char:$actor', target: target.isEmpty ? null : target,
        delivery: Delivery(
          channel: deliveryChannelOf('${delivery['channel']}'), form: '${delivery['form']}',
          audience: audienceOf('${delivery['audience'] ?? delivery['range'] ?? 'unknown'}'),
        ),
      ), scene);
      if (eventErrors.isNotEmpty) {
        return ActValidationError(code: eventErrors.first.code,
            message: eventErrors.first.message, segmentIndex: i);
      }
      if (seg['action_kind'] != null &&
          !<String>{...kArKinds, 'gesture', 'wait', 'observe', 'move', 'take', 'give', 'drop'}.contains(seg['action_kind'])) {
        return ActValidationError(code: 'action_kind', message: '不认识的行动类型：${seg['action_kind']}', segmentIndex: i);
      }
      if (!seg.containsKey('requires')) {
        return ActValidationError(
          code: 'missing_requires',
          message: 'CH_ACT segment[$i] 缺少 requires；没有要求也要写 []，不能省略或写 null',
          segmentIndex: i,
        );
      }
      final Object? requires = seg['requires'];
      if (requires is! List) {
        return ActValidationError(
          code: 'requires_type',
          message: 'CH_ACT segment[$i] 的 requires 必须是数组；没有要求就写 []',
          segmentIndex: i,
        );
      }
      for (final Object? r in requires) {
        final String s = '$r'.trim();
        if (s.isEmpty) {
          return ActValidationError(
            code: 'requires_empty',
            message: 'CH_ACT segment[$i] 的 requires 里有空字符串',
            segmentIndex: i,
          );
        }
        if (!kCapabilities.contains(s)) {
          return ActValidationError(
            code: 'unknown_capability',
            message: 'CH_ACT segment[$i] 的 requires 不认识：$s',
            segmentIndex: i,
          );
        }
      }
      if (!seg.containsKey('perceivable_by')) {
        return ActValidationError(
          code: 'missing_perceivable_by',
          message: 'CH_ACT segment[$i] 缺少 perceivable_by；没有额外限制就写 []',
          segmentIndex: i,
        );
      }
      final Object? perceivable = seg['perceivable_by'];
      if (perceivable is! List) {
        return ActValidationError(
          code: 'perceivable_by_type',
          message: 'CH_ACT segment[$i] 的 perceivable_by 必须是数组',
          segmentIndex: i,
        );
      }
      for (final Object? p in perceivable) {
        if ('$p'.trim().isEmpty) {
          return ActValidationError(
            code: 'perceivable_by_empty',
            message: 'CH_ACT segment[$i] 的 perceivable_by 里有空字符串',
            segmentIndex: i,
          );
        }
      }
    }

    final List<String> requires = _requiredCapabilities(action);
    final List<String> blocked = <String>[
      for (final FunctionalConstraint c in constraints)
        if (c.who == actor &&
            c.state == ConstraintState.cannot &&
            requires.contains(c.capability))
          '${c.capability}${c.reason.isEmpty ? '' : '（${c.reason}）'}',
    ];
    if (blocked.isNotEmpty) {
      return ActValidationError(
        code: 'capability_blocked',
        message: '当前状态不允许 ${blocked.join('、')}；'
            '换一个不需要这些能力的行动，或写“没有动/没有回答”。',
      );
    }

    final Object? rawDelta = action['state_delta'];
    final List<String> deltaErrors = StateDelta.proposalErrors(rawDelta);
    if (deltaErrors.isNotEmpty) {
      return ActValidationError(code: 'state_delta_type', message: deltaErrors.join('；'));
    }
    if (rawDelta != null && rawDelta is! Map) {
      return const ActValidationError(code: 'state_delta_type', message: 'state_delta 必须是对象或 null');
    }
    if (rawDelta is Map) {
      final StateDelta delta = StateDelta.fromAction(rawDelta);
      if (!delta.isEmpty) {
        final bool hasAction = raw.any(
          (Object? item) => item is Map && '${item['kind']}' == 'action',
        );
        if (!hasAction) {
          return const ActValidationError(
            code: 'state_delta_without_action',
            message: 'state_delta 非空时至少要有一条 action segment；只有台词不能改位置/伤势/物品',
          );
        }
      }
    }
    return null;
  }

  List<String> _requiredCapabilities(Map<String, Object?> action) {
    final Object? raw = action['segments'];
    if (raw is! List) return const <String>[];
    final Set<String> out = <String>{};
    for (final Object? item in raw) {
      if (item is! Map) continue;
      // 语音台词必然需要发声，不能依赖模型自行填写。
      if (item['kind'] == 'speech' && item['delivery'] is Map &&
          (item['delivery'] as Map)['channel'] == 'voice') {
        out.add('speak');
      }
      final Object? requires = item['requires'];
      if (requires is! List) continue;
      for (final Object? r in requires) {
        final String s = '$r'.trim();
        if (s.isNotEmpty) out.add(s);
      }
    }
    return out.toList();
  }

  List<String> _actionKinds(Map<String, Object?> action) {
    final Object? raw = action['segments'];
    if (raw is! List) return const <String>[];
    final List<String> out = <String>[];
    for (final Object? item in raw) {
      if (item is Map) {
        final String kind = '${item['action_kind'] ?? ''}';
        if (kind.isNotEmpty) out.add(kind);
      }
    }
    return out;
  }

  String? _firstTarget(String actor, Map<String, Object?> action) {
    final Object? raw = action['segments'];
    if (raw is! List) return null;
    for (final Object? item in raw) {
      if (item is! Map || item['kind'] != 'action') continue;
      final String t = '${item['target'] ?? ''}'.trim();
      if (t.isEmpty) continue;
      return resolveTarget(actor, t) ?? t;
    }
    return null;
  }

  int _nextEventSeq(List<WorldEvent> events) {
    int next = _seq;
    for (final WorldEvent e in events) {
      final Match? m = RegExp(r'^E(\d+)$').firstMatch(e.id);
      final int? n = m == null ? null : int.tryParse(m.group(1)!);
      if (n != null && n >= next) next = n + 1;
    }
    return next;
  }

  WorldEvent _rejectedEvent(
    String actor,
    Map<String, Object?> action,
    String reason,
  ) {
    String text = '';
    WorldEventKind kind = WorldEventKind.action;
    final Object? raw = action['segments'];
    if (raw is List && raw.isNotEmpty && raw.first is Map) {
      final Map<String, Object?> seg =
          (raw.first! as Map).cast<String, Object?>();
      text = '${seg['text'] ?? ''}'.trim();
      if ('${seg['kind']}' == 'speech') kind = WorldEventKind.speech;
    }
    final String content = text.isEmpty ? reason : text;
    return WorldEvent(
      id: _eventId('GM_NARRATE'),
      kind: kind,
      content: content,
      actor: 'char:$actor',
      delivery: const Delivery(
        channel: DeliveryChannel.other,
        form: 'rejected',
        audience: Audience.hidden,
      ),
      status: WorldEventStatus.rejected,
      source: 'character_action',
      placeId: scene.place,
      timeLabel: normalizeTimeLabel(action['time_label']),
    );
  }

  List<WorldEvent> _record(
    String actor,
    Map<String, Object?> action,
    StateDelta delta,
    Map<String, Object?>? arbitration,
  ) {
    final List<Map<String, Object?>> extracted =
        cWriter.extract(action).segments;
    if (extracted.isEmpty) return const <WorldEvent>[];
    // 时间标记：这一步自己的优先；行动没写时才用裁定的，都没有就留空。
    final String ownTimeLabel = normalizeTimeLabel(action['time_label']);
    final String stepTimeLabel = ownTimeLabel.isNotEmpty
        ? ownTimeLabel
        : normalizeTimeLabel(arbitration?['time_label']);
    final List<Map<String, Object?>> turnEffects = delta.effectRecords;
    bool effectsAssigned = false;
    final List<WorldEvent> out = <WorldEvent>[];
    for (final Map<String, Object?> s in extracted) {
      final String kind = '${s['kind'] ?? ''}';
      if (kind != 'speech' && kind != 'action') continue;
      final String text = '${s['text'] ?? ''}';
      final String targetRaw = '${s['target'] ?? ''}';
      final String target = resolveTarget(actor, targetRaw) ?? targetRaw;
      final bool targetIsChar = target.isNotEmpty &&
          (scene.byId(
                target.startsWith('char:') ? target : 'char:$target',
              ) !=
              null);
      final String? eventTarget = target.isEmpty
          ? null
          : (targetIsChar
              ? (target.startsWith('char:') ? target : 'char:$target')
              : target);
      final Object? dRaw = s['delivery'];
      final Map<String, Object?> d =
          dRaw is Map ? dRaw.cast<String, Object?>() : <String, Object?>{};
      final String actionText = kind == 'action' ? _actionText(actor, text) : text;
      final WorldEventKind eventKind = kind == 'speech'
          ? WorldEventKind.speech
          : WorldEventKind.action;
      final String content = kind == 'speech' ? text : actionText;
      final DeliveryChannel channel =
          deliveryChannelOf('${d['channel'] ?? 'other'}');
      final List<String> perceivableBy = s['perceivable_by'] is List
          ? (s['perceivable_by']! as List)
              .map((Object? x) => '$x')
              .toList()
          : const <String>[];
      final Delivery delivery = Delivery(
        channel: channel,
        form: '${d['form'] ?? 'other'}',
        audience: audienceOf('${d['audience'] ?? d['range'] ?? 'unknown'}'),
      );
      final Set<String> linkMembers = <String>{};
      if (channel == DeliveryChannel.mental ||
          channel == DeliveryChannel.digital ||
          delivery.audience == Audience.link) {
        if (eventTarget != null && eventTarget.startsWith('char:')) {
          linkMembers.add(eventTarget);
        }
        linkMembers.add('char:$actor');
        for (final String p in perceivableBy) {
          final String id =
              p.trim().startsWith('char:') ? p.trim() : 'char:${p.trim()}';
          if (id.length > 'char:'.length) linkMembers.add(id);
        }
      }
      final bool attachEffects =
          kind == 'action' && !effectsAssigned && turnEffects.isNotEmpty;
      if (attachEffects) effectsAssigned = true;
      WorldEvent event = WorldEvent(
        id: _eventId('E'),
        kind: eventKind,
        content: content,
        actor: 'char:$actor',
        target: eventTarget,
        delivery: delivery,
        linkMembers: linkMembers.toList(),
        deliveryNote: '${s['delivery_note'] ?? ''}',
        distanceNote: '${s['distance_note'] ?? ''}',
        manner: '${s['manner'] ?? action['manner'] ?? ''}',
        segments: <EventSegment>[
          EventSegment(
            kind: eventKind,
            text: content,
            target: eventTarget,
            delivery: delivery,
            perceivableBy: perceivableBy,
          ),
        ],
        effects: attachEffects
            ? turnEffects
            : const <Map<String, Object?>>[],
        outcome: kind == 'action' ? '${arbitration?['outcome'] ?? ''}' : '',
        result: kind == 'action' ? '${arbitration?['result'] ?? ''}' : '',
        observationsResolved: kind == 'action' && arbitration?['observations'] is Map,
        observations: kind == 'action' && arbitration?['observations'] is Map
            ? (arbitration!['observations'] as Map).map(
                (Object? k, Object? v) => MapEntry('$k', '$v')) : const {},
        status: WorldEventStatus.proposed,
        source: actor == controlledCharacter ? 'player' : 'npc',
        placeId: scene.place,
        timeLabel: stepTimeLabel,
        turnIndex: (causalContext?.state.worldStep ?? 0) + 1,
        duration: '${action['duration'] ?? 'brief'}',
      );
      event = cWriter.commitValidated(
        event: event,
        scene: scene,
        engine: engine,
      );
      if (kind == 'action' && delta.moves.isNotEmpty) {
        event = event.copyWith(witnesses: _arrivalWitnesses(event, delta));
      }
      out.add(event);
    }
    return out;
  }

  /// 动作摘要：去掉重复的 actor 名和句首“她/他”，再做规范名替换。
  String _actionText(String actor, String text) {
    String t = text.trim();
    if (t.startsWith(actor)) t = t.substring(actor.length);
    if (t.startsWith('她') || t.startsWith('他')) t = t.substring(1);
    return canonicalize(t, scene, speakerId: 'char:$actor');
  }

  /// 把角色嘴里的称呼解析回 cast 名字。
  String? resolveTarget(String speakerName, String raw) {
    final String t = raw.trim();
    if (t.isEmpty) return null;
    if (scene.names.containsValue(t)) return t;
    final CharacterSnapshot? c = scene.byId('char:$speakerName');
    if (c != null) {
      final List<String> matches = <String>[
        for (final MapEntry<String, String> e in c.aliases.entries)
          if (e.value == t) e.key.replaceFirst('char:', ''),
      ];
      if (matches.length > 1) throw FormatException('称呼存在歧义：$t');
      for (final MapEntry<String, String> e in c.aliases.entries) {
        if (e.value == t) return e.key.replaceFirst('char:', '');
      }
    }
    return null;
  }

  void _applyDeltas(Map<String, Object?> arbitration) {
    final Object? raw = arbitration['deltas'];
    if (raw is! List || ledger == null) return;
    for (final Object? item in raw) {
      if (item is! Map) continue;
      final Map<String, Object?> d = item.cast<String, Object?>();
      final String kind = '${d['kind'] ?? ''}';
      if (kind == 'steal') {
        final String itemId = '${d['item_id'] ?? ''}';
        final String from = '${d['from'] ?? ''}';
        final String to = '${d['to'] ?? ''}';
        if (itemId.isNotEmpty && from.isNotEmpty && to.isNotEmpty) {
          ledger!.give(fromId: from, toId: to, itemId: itemId);
        }
      } else if (kind == 'drop') {
        final String itemId = '${d['item_id'] ?? ''}';
        final String by = '${d['by'] ?? d['from'] ?? ''}';
        final String place = '${d['place'] ?? d['to'] ?? ''}';
        if (itemId.isNotEmpty && by.isNotEmpty && place.isNotEmpty) {
          ledger!.drop(actorId: by, itemId: itemId, placeId: place);
        }
      } else if (kind == 'move') {
        final String id = '${d['id'] ?? d['actor'] ?? ''}';
        final String to = '${d['to'] ?? ''}';
        if (id.isNotEmpty && to.isNotEmpty) {
          ledger!.moveEntity(id, to);
        }
      }
      // injure / none：先记录在裁定里，账本暂不改。
    }
  }
}
