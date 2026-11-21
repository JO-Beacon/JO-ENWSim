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
import 'intent_beat.dart';
import 'ledger.dart';
import 'memory_agent.dart';
import 'memory_recall.dart';
import 'perception.dart';
import 'render_check.dart';
import 'render_view.dart';
import 'sequence.dart';
import 'state_delta.dart';
import 'step_id.dart';
import 'turn_session.dart';

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

  /// 把玩家对某一步的回答交给实现方；只有上帝层会用到。
  void setPlayerHelp(Map<String, String> help);

  /// 把某个 AI 调用的回答写进恢复日志。
  void recordPlayerAnswer(String journalKey, String answer);

  /// 只清理失败步骤的模型回放；保留玩家的处理记录。
  void prepareRetry(String stage) {}

  void recordIntervention(String key, PlayerQuestion question, String answer) {
    recordPlayerAnswer(key, answer);
  }

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
    this.perceiveErrors = const <String>[],
    this.environmentErrors = const <String>[],
    this.needsReview = false,
    this.reviewWarnings = const <String>[],
    this.rejectedEvents = const <WorldEvent>[],
    this.cast = const <String>[],
    this.orderedDeltas = const <StateDelta>[],
    this.intentBeat = false,
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

  /// CH_PERCEIVE 引用了候选集外的事件时的错误；非空表示这一回合不推进。
  final List<String> perceiveErrors;

  /// GM_ENV_UPDATE 环境事件在 SYS_RECORD 校验里不合格的错误；非空表示这一回合不落账。
  final List<String> environmentErrors;

  /// 裁决说 unresolved 时置 true；需要人工看，不默认命中/失败。
  final bool needsReview;

  /// 可选 GM_REVIEW_NARRATION AI 的软警告；不替代程序硬校验。
  final List<String> reviewWarnings;

  /// 被拒绝的尝试；只留痕，不进记忆 / 正文。
  final List<WorldEvent> rejectedEvents;

  /// GM_ELIGIBILITY 最终 cast（AI 声明后经程序过滤）。
  final List<String> cast;

  /// 本回合走的是意图回合（一拍一个行动者，先意图后裁决）。
  final bool intentBeat;

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
      'GM_OPEN_PLACE': openPlaceErrors,
      'GM_ROUTE': routeErrors,
      'CH_PERCEIVE': perceiveErrors,
      'GM_ENV_UPDATE': environmentErrors,
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
    if (stop?.code == 'intent_beat') {
      return retryExhaustedQuestion(
        step: StepId.chIntent,
        reason: stop!.reason,
      );
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
    this.perceiveStepBudget = 3,
    this.environmentStepBudget = 3,
    this.rStepBudget = 3,
    this.openPlaceDecider,
    this.routeDecider,
    this.environmentSource,
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
    this.responseRevisions = const <String, String>{},
    this.actorsDue,
    this.recoveryContext = '',
    this.eventNamespace = '',
    this.intentAgents,
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

  /// 意图回合的 AI 步骤；没有它就只能跑开场/环境/呈现这些不产生角色拍的循环。
  final IntentBeatAgents? intentAgents;
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

  /// 每个角色最多允许几次 CH_PERCEIVE：引用了候选集外的事件就带着错误重写。
  final int perceiveStepBudget;

  /// GM_ENV_UPDATE 最多重试几次；环境事件过不了 SYS_RECORD 校验就带着错误重写。
  final int environmentStepBudget;

  /// GM_NARRATE 最多重试几次；正文有硬性违规就带着错误重写。
  final int rStepBudget;

  final OpenPlaceDecider? openPlaceDecider;
  final RouteDecider? routeDecider;
  final EnvironmentSource? environmentSource;
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

    // 意图回合：一拍只有一个行动者。
    return _runIntentTurn(
      cast: actors.isNotEmpty
          ? actors
          : <String>[for (final CharacterSnapshot c in scene.cast) c.name],
      incoming: incoming,
      openPlace: openPlace,
      route: route,
      worldId: resume?.worldId ?? '',
      resume: resume,
    );






  }

  /// 意图回合：在场角色各交一条意图，统一裁决，结果记进事件。
  Future<TurnTrace> _runIntentTurn({
    required List<String> cast,
    required List<WorldEvent> incoming,
    required OpenPlaceResult openPlace,
    required String route,
    required String worldId,
    TurnSession? resume,
  }) async {
    final List<String> due = actorsDue?.call(cast) ?? cast;
    final String? actor = due.isEmpty ? null : due.first;
    if (actor == null) {
      return TurnTrace(
        percepts: const <String, Map<String, Object?>>{},
        eligible: cast,
        chosen: null,
        action: null,
        arbitration: null,
        stateDelta: null,
        events: const <WorldEvent>[],
        render: null,
        renderViolations: const <RenderViolation>[],
        blocked: const <FunctionalConstraint>[],
        stop: const TurnStop(code: 'no_actor', reason: '没有可行动的角色'),
        actErrors: const <ActValidationError>[],
        openPlace: openPlace,
        route: route,
        cast: cast,
        intentBeat: true,
      );
    }
    final IntentBeat beat = IntentBeat(
      scene: scene,
      agents: intentAgents!,
      memory: memory,
      controlledCharacter: controlledCharacter,
      startSeq: _seq,
      turnIndex: (causalContext?.state.worldStep ?? 0) + 1,
      checkpoints: <String, Map<String, Object?>>{
        for (final MapEntry<String, TurnCheckpoint> e
            in (resume?.checkpoints ?? const <String, TurnCheckpoint>{}).entries)
          e.key: e.value.data,
      },
      onCheckpoint: (String stage, Map<String, Object?> data) {
        _stage(stage);
        _checkpoint(stage, data);
      },
      sceneAt: (String place, Map<String, Object?> stateDelta) =>
          _sceneAt(place, StateDelta.fromAction(stateDelta)),
      validateDelta: (String who, Map<String, Object?> stateDelta) {
        final TurnState? state = causalContext?.state;
        if (state == null) return const <String>[];
        return state.transitionErrors(
          StateDelta.fromAction(stateDelta),
          actor: who,
          place: scene.place,
        );
      },
      recall: ({
        required String characterId,
        required String delivered,
        required List<CharacterMemory> active,
      }) async {
        final String recallStage = 'CH_MEMORY_RECALL:$characterId';
        final TurnCheckpoint? savedRecall = resume?.checkpoints[recallStage];
        final Object? savedIds = savedRecall?.data['memory_ids'];
        if (savedIds is List) {
          return <String>[for (final Object? id in savedIds) '$id'];
        }
        final MemoryRecallService service = MemoryRecallService(
          worldId: worldId,
          characterId: characterId,
          memory: memory.allEntries(),
          currentMemory: memory.allEntries,
        );
        final MemoryRecallResult recalled = await agents.recallWithArchive(
          scene: scene,
          percepts: <String, Object?>{'delivered': delivered},
          service: service,
        );
        if (recalled.activeIds != null) {
          _stage(recallStage);
          _checkpoint(recallStage, <String, Object?>{
            'character': characterId,
            'memory_ids': recalled.activeIds!.toList(),
          });
        }
        return (recalled.activeIds ??
                <String>{for (final CharacterMemory m in active) m.id})
            .toList();
      },
      playerIntent: playerActionHandler == null
          ? null
          : (String who) async {
              final Map<String, Object?>? action =
                  await playerActionHandler!(actor: who, scene: scene);
              if (action == null) {
                throw PlayerPausedException(PlayerQuestion(
                  step: StepId.chIntent,
                  code: 'player_action',
                  reason: '轮到 $who 提交意图。',
                  question: '轮到 $who 行动，请输入行动意图。',
                ));
              }
              return _intentFromAction(who, action);
            },
    );
    final IntentBeatResult result = await beat.run(
      actor: actor,
      incoming: incoming,
      objectiveWorld: causalContext?.godText(scene.place) ?? '{}',
      cast: cast,
    );
    final PublicClaim? claim = result.claim;
    final IntentSettlement? settlement = result.settlement;
    final WorldEvent? recorded = result.event;
    if (!result.ok || claim == null || settlement == null || recorded == null) {
      return TurnTrace(
        percepts: const <String, Map<String, Object?>>{},
        eligible: cast,
        chosen: actor,
        action: null,
        arbitration: null,
        stateDelta: null,
        events: const <WorldEvent>[],
        render: null,
        renderViolations: const <RenderViolation>[],
        blocked: const <FunctionalConstraint>[],
        stop: TurnStop(code: 'intent_beat', reason: result.errors.join('\n')),
        actErrors: const <ActValidationError>[],
        openPlace: openPlace,
        route: route,
        cast: cast,
        intentBeat: true,
      );
    }
    // 过程步骤由 IntentBeat 的 onCheckpoint 逐段写回；这里只处理结果。
    _seq += 1;
    final StateDelta delta = StateDelta.fromAction(settlement.stateDelta);
    final TurnPresentation? narration =
        deferPresentation ? null : await _narrate(<WorldEvent>[recorded], null);
    final WorldEvent event = narration == null
        ? recorded
        : recorded.copyWith(
            publicText: narration.publicText,
            godNote: narration.godNote,
          );
    final Map<String, Map<String, Object?>> percepts =
        <String, Map<String, Object?>>{
      actor: <String, Object?>{
        'intent': result.intent?.text ?? '',
        'result': settlement.result,
        'self_text': settlement.selfText,
      },
      for (final MapEntry<String, String> seen in event.observations.entries)
        if (seen.key.replaceFirst('char:', '') != actor)
          seen.key.replaceFirst('char:', ''): <String, Object?>{
            'seen': seen.value,
          },
    };
    final MergePlaceResult mergePlace = await _decideMergePlace(
      events: <WorldEvent>[event],
      remainingCast: _remainingCast(delta),
    );
    return TurnTrace(
      percepts: percepts,
      eligible: cast,
      chosen: actor,
      action: <String, Object?>{
        'intent': result.intent?.text ?? '',
        ...claim.toJson(),
      },
      arbitration: settlement.toJson(),
      stateDelta: delta.isEmpty ? null : delta,
      orderedDeltas: <StateDelta>[delta],
      events: <WorldEvent>[event],
      render: narration?.render,
      renderViolations: narration?.check.violations ?? const <RenderViolation>[],
      blocked: const <FunctionalConstraint>[],
      stop: null,
      actErrors: const <ActValidationError>[],
      openPlace: openPlace,
      route: route,
      mergePlace: mergePlace,
      cast: cast,
      needsReview: settlement.result == 'unresolved',
      intentBeat: true,
    );
  }

  CharacterIntent _intentFromAction(String actor, Map<String, Object?> action) {
    final String intent = '${action['intent'] ?? ''}'.trim();
    final List<String> parts = <String>[];
    final Object? segments = action['segments'];
    if (segments is List) {
      for (final Object? segment in segments) {
        if (segment is Map && '${segment['text'] ?? ''}'.trim().isNotEmpty) {
          parts.add('${segment['text']}'.trim());
        }
      }
    }
    final String text = intent.isNotEmpty ? intent : parts.join('；');
    return CharacterIntent(
      id: 'intent:$actor:${DateTime.now().microsecondsSinceEpoch}',
      actor: 'char:$actor',
      text: text,
      desired: text,
    );
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

  /// 按地点组一份现场：当前位置从权威状态和这次移动里算。
  NarrativeScene _sceneAt(String place, StateDelta delta) {
    final NarrativeScene? configured = sceneForPlace?.call(place);
    final Map<String, CharacterSnapshot> cast = <String, CharacterSnapshot>{
      if (place == scene.place)
        for (final CharacterSnapshot c in scene.cast) c.id: c,
      if (configured != null)
        for (final CharacterSnapshot c in configured.cast) c.id: c,
    };
    final Map<String, String> locations = <String, String>{
      if (causalContext != null)
        for (final EntityRecord e in causalContext!.state.entities.values)
          if (e.kind == 'character') e.name: e.location.replaceFirst('place:', ''),
      ...?causalContext?.state.locations,
      ...delta.moves,
    };
    final Map<String, String> names = <String, String>{
      ...scene.names,
      ...?configured?.names,
      if (causalContext != null)
        for (final EntityRecord e in causalContext!.state.entities.values)
          if (e.kind == 'character') e.id: e.name,
    };
    for (final MapEntry<String, String> located in locations.entries) {
      final String id = 'char:${located.key}';
      if (located.value == place) {
        cast.putIfAbsent(
          id,
          () => scene.byId(id) ??
              CharacterSnapshot(id: id, name: located.key, nearby: true),
        );
      } else {
        cast.remove(id);
      }
    }
    return NarrativeScene(place: place, cast: cast.values.toList(), names: names);
  }

  /// 本回合结束后还留在当前序列里的角色。
  List<String> _remainingCast(StateDelta delta) {
    final List<String> out = <String>[];
    for (final CharacterSnapshot c in scene.cast) {
      final String? movedTo = delta.moves[c.name];
      if (movedTo == null || movedTo.trim() == scene.place.trim()) {
        out.add(c.name);
      }
    }
    for (final MapEntry<String, String> e in delta.moves.entries) {
      if (e.value.trim() == scene.place.trim() && !out.contains(e.key)) {
        out.add(e.key);
      }
    }
    return out;
  }

  /// 本回合结束后还留在当前序列里的角色。
  ///
  /// 只有“人都走光了”的线才允许合并；否则把两列硬并会让人瞬移。
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
        final Object reviewedRender = checkpoint?.data['reviewedRender'] ?? originalRender;
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

  int _nextEventSeq(List<WorldEvent> events) {
    int next = _seq;
    for (final WorldEvent e in events) {
      final Match? m = RegExp(r'^E(\d+)$').firstMatch(e.id);
      final int? n = m == null ? null : int.tryParse(m.group(1)!);
      if (n != null && n >= next) next = n + 1;
    }
    return next;
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

}
