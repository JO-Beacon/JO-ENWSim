// 意图回合 · 新基座（单人一拍）
//
// 回合是轮流进行的：一拍只有一个行动者。它拿到自己的投递（见闻 + 召回后的记忆 +
// 状态），一次调用写出「意图」。意图不是客观动作，是世界还没答应的请求。
//
// 之后才轮到上帝：
//   立案官：私意图 → 公开主张。全知于世界，无知于人心；只把角色能知道的内容写进主张。
//   裁决：主张 + 物理事实 → 这一下的结算（成 / 败 / 部分 / 未定）。
//   结果投递：所有能感知到的角色各自看到结果。
//   记忆：行动者写「意图 + 结果」；目击者写自己看到的那份。
//
// 这里不直接发 HTTP：所有 AI 调用由 IntentBeatAgents 注入，方便测试，也方便接
// LlmAgentRunner。事件、记忆、可见性仍由程序守边界。

import 'dart:convert';

import 'character_memory.dart';
import 'engine_state.dart';
import 'memory_agent.dart';
import 'perception.dart';
import 'state_delta.dart';

/// 一条意图。角色自己的话可以带动机和私人记忆；它不是公开内容。
class CharacterIntent {
  const CharacterIntent({
    required this.id,
    required this.actor,
    required this.text,
    this.target = '',
    this.desired = '',
    this.means = '',
    this.conditions = const <String>[],
    this.success = '',
    this.failure = '',
    this.search = '',
  });

  final String id;

  /// char:角色名。
  final String actor;

  /// 角色自己的原话，可以含动机、回忆、打算。
  final String text;

  /// 对谁。可能是角色自己的称呼，立案时才归一。
  final String target;

  /// 想达成什么。
  final String desired;

  /// 用什么手段。
  final String means;

  /// 需要什么条件。
  final List<String> conditions;

  /// 什么算成。
  final String success;

  /// 什么算没成。
  final String failure;

  /// 可选的外部资料查询意图；不在这里返回结果。
  final String search;

  Map<String, Object?> toJson() => <String, Object?>{
        'intent_id': id,
        'actor': actor,
        'text': text,
        'target': target,
        'desired': desired,
        'means': means,
        'conditions': conditions,
        'success': success,
        'failure': failure,
        if (search.isNotEmpty) 'search': search,
      };

  static CharacterIntent fromJson(Map<String, Object?> j) => CharacterIntent(
        id: '${j['intent_id'] ?? j['id'] ?? ''}',
        actor: '${j['actor'] ?? ''}',
        text: '${j['text'] ?? ''}',
        target: '${j['target'] ?? ''}',
        desired: '${j['desired'] ?? ''}',
        means: '${j['means'] ?? ''}',
        conditions: j['conditions'] is List
            ? <String>[
                for (final Object? x in j['conditions'] as List) '$x',
              ]
            : const <String>[],
        success: '${j['success'] ?? ''}',
        failure: '${j['failure'] ?? ''}',
        search: '${j['search'] ?? ''}',
      );
}

/// 公开主张：立案官从意图里剥出来的「身体要做什么」。
/// 指称已经归一；文本里不出现角色不知道的名字、事实或理由。
class PublicClaim {
  const PublicClaim({
    required this.intentId,
    required this.actor,
    required this.kind,
    required this.text,
    this.targetId = '',
    this.delivery = const Delivery(
      channel: DeliveryChannel.visual,
      form: 'gesture',
      audience: Audience.scene,
    ),
    this.means = '',
    this.conditions = const <String>[],
    this.success = '',
    this.failure = '',
    this.perceivableBy = const <String>[],
  });

  final String intentId;
  final String actor;

  /// speech 或 action。
  final String kind;

  /// 「勇者想要用弓箭射恶龙的眼睛」这种公开说法，永远是试图，不是结果。
  final String text;

  /// 已归一的实体 id；解决不了就留空，由裁决按场面判。
  final String targetId;

  final Delivery delivery;
  final String means;
  final List<String> conditions;
  final String success;
  final String failure;
  final List<String> perceivableBy;

  Map<String, Object?> toJson() => <String, Object?>{
        'intent_id': intentId,
        'actor': actor,
        'kind': kind,
        'text': text,
        if (targetId.isNotEmpty) 'target': targetId,
        'delivery': <String, Object?>{
          'channel': delivery.channel.name,
          'form': delivery.form,
          'audience': delivery.audience.name,
        },
        if (means.isNotEmpty) 'means': means,
        if (conditions.isNotEmpty) 'conditions': conditions,
        if (success.isNotEmpty) 'success': success,
        if (failure.isNotEmpty) 'failure': failure,
        if (perceivableBy.isNotEmpty) 'perceivable_by': perceivableBy,
      };

  static PublicClaim fromJson(Map<String, Object?> j) {
    final Map<Object?, Object?> d = j['delivery'] is Map
        ? j['delivery'] as Map<Object?, Object?>
        : const <Object?, Object?>{};
    return PublicClaim(
      intentId: '${j['intent_id'] ?? ''}',
      actor: '${j['actor'] ?? ''}',
      kind: '${j['kind'] ?? ''}',
      text: '${j['text'] ?? ''}',
      targetId: '${j['target'] ?? ''}',
      delivery: Delivery(
        channel: deliveryChannelOf('${d['channel'] ?? 'visual'}'),
        form: '${d['form'] ?? 'gesture'}',
        audience: audienceOf('${d['audience'] ?? 'scene'}'),
      ),
      means: '${j['means'] ?? ''}',
      conditions: j['conditions'] is List
          ? <String>[for (final Object? x in j['conditions'] as List) '$x']
          : const <String>[],
      success: '${j['success'] ?? ''}',
      failure: '${j['failure'] ?? ''}',
      perceivableBy: j['perceivable_by'] is List
          ? <String>[for (final Object? x in j['perceivable_by'] as List) '$x']
          : const <String>[],
    );
  }
}

/// 一条意图的结算。结果记进事件，不另开一张表。
class IntentSettlement {
  const IntentSettlement({
    required this.intentId,
    required this.actor,
    required this.result,
    required this.resultText,
    required this.selfText,
    this.observers = const <String, String>{},
    this.stateDelta = const <String, Object?>{},
  });

  final String intentId;
  final String actor;

  /// success / failure / partial / unresolved。
  final String result;

  /// 实际发生的客观结果，给上帝和正文用。
  final String resultText;

  /// 本人感知到的那份。
  final String selfText;

  /// 旁观者各自感知到的那份；没人看得见就为空。
  final Map<String, String> observers;

  /// 实际发生的状态变化（移动、伤势、约束、物品、事实、发现、过程）。
  /// 形状与行动记录的 state_delta 一致，交给现有落账管线应用。
  final Map<String, Object?> stateDelta;

  Map<String, Object?> toJson() => <String, Object?>{
        'intent_id': intentId,
        'actor': actor,
        'result': result,
        'result_text': resultText,
        'self_text': selfText,
        if (observers.isNotEmpty) 'observers': observers,
        if (stateDelta.isNotEmpty) 'state_delta': stateDelta,
      };

  static IntentSettlement fromJson(Map<String, Object?> j) => IntentSettlement(
        intentId: '${j['intent_id'] ?? ''}',
        actor: '${j['actor'] ?? ''}',
        result: '${j['result'] ?? ''}',
        resultText: '${j['result_text'] ?? ''}',
        selfText: '${j['self_text'] ?? ''}',
        observers: j['observers'] is Map
            ? <String, String>{
                for (final MapEntry<Object?, Object?> e
                    in (j['observers'] as Map).entries)
                  '${e.key}': '${e.value}',
              }
            : const <String, String>{},
        stateDelta: j['state_delta'] is Map
            ? Map<String, Object?>.from(j['state_delta'] as Map)
            : const <String, Object?>{},
      );
}

class IntentBeatResult {
  const IntentBeatResult({
    required this.intent,
    required this.claim,
    required this.settlement,
    required this.event,
    required this.memories,
    this.errors = const <String>[],
  });

  final CharacterIntent? intent;
  final PublicClaim? claim;
  final IntentSettlement? settlement;
  final WorldEvent? event;

  /// 这一拍新写入的记忆（行动者 + 目击者）。
  final Map<String, List<CharacterMemory>> memories;

  final List<String> errors;

  bool get ok => errors.isEmpty;
}

/// 一拍里用到的 AI 步骤。生产实现接 LlmAgentRunner；测试用假的。
abstract class IntentBeatAgents {
  /// 意图：一次调用，投递什么就写什么，不做“最在意什么”的中间层。
  Future<CharacterIntent> intend({
    required String actor,
    required String delivered,
    required String recalled,
    required List<String> present,
  });

  /// 立案：私意图 → 公开主张。
  /// [publicScene] 是全知客观场面，只用来理解指称；输出不得替角色扩知。
  Future<PublicClaim> fileClaim({
    required CharacterIntent intent,
    required String publicScene,
    required Map<String, String> aliases,
    required List<String> knownEntities,
  });

  /// 统一裁决：所有主张 + 物理事实 → 每条意图一个结算。
  Future<List<IntentSettlement>> adjudicateBeat({
    required List<PublicClaim> claims,
    required String objectiveWorld,
    required List<String> present,
  });

  /// 出向翻译：客观结算 → 该角色能感知到的那份。
  /// 本人那份可以有第一人称细节；旁观者那份只写他们看得见的。
  Future<Map<String, String>> observeOutcome({
    required IntentSettlement settlement,
    required String objectiveWorld,
    required String observerId,
  });

  /// 记忆：把意图和结果一起写成第一人称笔记。
  Future<List<MemoryOperation>?> rememberOutcome({
    required String actor,
    required CharacterIntent intent,
    required IntentSettlement settlement,
    required List<CharacterMemory> memory,
    required Set<String> allowedEventIds,
  });

  /// 目击者的记忆：只写它看到的那份。没有实现时由程序写一条。
  Future<List<MemoryOperation>?> rememberWitness({
    required String actor,
    required WorldEvent event,
    required String seenText,
    required List<CharacterMemory> memory,
    required Set<String> allowedEventIds,
  }) async =>
      null;
}

/// 可选：召回由记忆 Agent 负责，这里只取要装进投递包的那几条。
typedef IntentRecall = Future<List<String>> Function({
  required String characterId,
  required String delivered,
  required List<CharacterMemory> active,
});

/// 玩家角色的意图来源；不给就走 [IntentBeatAgents.intend]。
typedef PlayerIntentSource = Future<CharacterIntent> Function(String actor);

/// 结算里出现跨地点移动时，按目的地组一份现场，用来问到达者看到了什么。
typedef IntentSceneAt = NarrativeScene Function(
  String place,
  Map<String, Object?> stateDelta,
);

/// 结算状态变化进入世界状态前的硬校验；返回空列表才算通过。
typedef IntentDeltaValidator = List<String> Function(
  String actor,
  Map<String, Object?> stateDelta,
);

class IntentBeat {
  IntentBeat({
    required this.scene,
    required this.agents,
    required this.memory,
    this.perception = const PerceptionEngine(),
    this.recall,
    this.playerIntent,
    this.controlledCharacter = '',
    this.startSeq = 1,
    this.turnIndex = 1,
    this.checkpoints = const <String, Map<String, Object?>>{},
    this.onCheckpoint,
    this.sceneAt,
    this.validateDelta,
  });

  final NarrativeScene scene;
  final IntentBeatAgents agents;
  final MemoryStore memory;
  final PerceptionEngine perception;

  /// 召回：不注入就退回全部活动记忆。
  final IntentRecall? recall;

  /// 玩家角色的意图来源。
  final PlayerIntentSource? playerIntent;
  final String controlledCharacter;

  final int startSeq;

  int _seq = 0;

  final int turnIndex;

  /// 已保存的恢复点：stage -> data。为空就是从头跑。
  final Map<String, Map<String, Object?>> checkpoints;

  /// 每完成一步写回恢复点；恢复时按同一 stage 读取。
  final void Function(String stage, Map<String, Object?> data)? onCheckpoint;

  /// 跨地点移动时按目的地组现场；没有就不问目的地观察者。
  final IntentSceneAt? sceneAt;

  /// 结算状态变化进世界前的硬校验；没有就只做结构校验。
  final IntentDeltaValidator? validateDelta;

  /// 跑一拍：只有一个行动者。
  Future<IntentBeatResult> run({
    required String actor,
    required List<WorldEvent> incoming,
    required String objectiveWorld,
    List<String>? cast,
  }) async {
    _seq = startSeq;
    final List<String> present = cast ??
        <String>[for (final CharacterSnapshot c in scene.cast) c.name];
    final String actorId = 'char:$actor';
    final CharacterSnapshot? observer = scene.byId(actorId);
    if (observer == null) {
      return IntentBeatResult(
        intent: null,
        claim: null,
        settlement: null,
        event: null,
        memories: const <String, List<CharacterMemory>>{},
        errors: <String>['$actor 不在当前场景里'],
      );
    }

    // 1. 意图：有恢复点就直接读，没有才问模型。
    CharacterIntent intent;
    final Map<String, Object?>? savedIntent =
        checkpoints['CH_INTENT:$actor'];
    if (savedIntent != null) {
      intent = CharacterIntent.fromJson(savedIntent);
    } else {
      final String delivered = _delivered(actorId, incoming);
      final List<CharacterMemory> active = memory.activeForCharacter(actorId);
      final List<String> recalledIds = recall == null
          ? <String>[for (final CharacterMemory m in active) m.id]
          : await recall!(
              characterId: actorId, delivered: delivered, active: active);
      final Set<String> selected = recalledIds.toSet();
      final String recalled = active
          .where((CharacterMemory m) => selected.contains(m.id))
          .map((CharacterMemory m) => '- ${m.text}')
          .join('\n');
      intent = playerIntent != null && actor == controlledCharacter
          ? await playerIntent!(actor)
          : await agents.intend(
              actor: actor,
              delivered: delivered,
              recalled: recalled,
              present: present,
            );
      onCheckpoint?.call('CH_INTENT:$actor', intent.toJson());
    }
    if (intent.actor != actorId) {
      return _fail(<String>['$actor：意图 actor 是 ${intent.actor}，应为 $actorId'], intent);
    }
    if (intent.text.trim().isEmpty) {
      return _fail(<String>['$actor：意图为空'], intent);
    }

    // 2. 立案：只处理这一条。
    PublicClaim claim;
    final Map<String, Object?>? savedClaim = checkpoints['GM_FILE_CLAIM'];
    if (savedClaim != null) {
      claim = PublicClaim.fromJson(savedClaim);
    } else {
      claim = await agents.fileClaim(
        intent: intent,
        publicScene: _publicScene(),
        aliases: observer.aliases,
        knownEntities: scene.names.keys.toList(),
      );
      onCheckpoint?.call('GM_FILE_CLAIM', claim.toJson());
    }
    if (claim.intentId != intent.id) {
      return _fail(<String>['$actor：立案的 intent_id 对不上'], intent);
    }
    if (claim.actor != actorId) {
      return _fail(<String>['$actor：立案的 actor 对不上'], intent);
    }
    if (claim.kind != 'speech' && claim.kind != 'action') {
      return _fail(<String>['$actor：立案的 kind 只能是 speech 或 action'], intent);
    }
    if (claim.text.trim().isEmpty) {
      return _fail(<String>['$actor：立案文本为空'], intent);
    }

    // 3. 裁决：这一条主张。
    IntentSettlement settlement;
    final Map<String, Object?>? savedSettlement =
        checkpoints['GM_RESOLVE_BEAT'];
    if (savedSettlement != null) {
      settlement = IntentSettlement.fromJson(savedSettlement);
    } else {
      final List<IntentSettlement> settlements = await agents.adjudicateBeat(
        claims: <PublicClaim>[claim],
        objectiveWorld: objectiveWorld,
        present: present,
      );
      if (settlements.length != 1) {
        return _fail(<String>['$actor：裁决没有给出唯一结算'], intent);
      }
      settlement = settlements.single;
      onCheckpoint?.call('GM_RESOLVE_BEAT', settlement.toJson());
    }
    if (settlement.intentId != intent.id) {
      return _fail(<String>['$actor：结算的 intent_id 对不上'], intent);
    }
    if (!<String>{'success', 'failure', 'partial', 'unresolved'}
        .contains(settlement.result)) {
      return _fail(<String>['$actor：结算结果不合法：${settlement.result}'], intent);
    }
    if (settlement.selfText.trim().isEmpty) {
      return _fail(<String>['$actor：结算缺少本人可见文本'], intent);
    }
    final List<String> deltaErrors = <String>[
      ...StateDelta.proposalErrors(settlement.stateDelta),
      ...?validateDelta?.call(actor, settlement.stateDelta),
    ];
    if (deltaErrors.isNotEmpty) {
      return _fail(<String>['$actor：结算状态变化不合格：${deltaErrors.join('；')}'], intent);
    }
    final StateDelta parsedDelta = StateDelta.fromAction(settlement.stateDelta);
    final List<NarrativeScene> destinations = <NarrativeScene>[
      if (sceneAt != null)
        for (final String place in parsedDelta.moves.values.toSet())
          if (place.trim().isNotEmpty && place.trim() != scene.place.trim())
            sceneAt!(place, settlement.stateDelta),
    ];

    // 4. 一条事件；结果、可见性都记在事件上。
    WorldEvent event;
    final Map<String, Object?>? savedEvent = checkpoints['SYS_RECORD'];
    if (savedEvent != null) {
      event = worldEventFromJson(savedEvent);
    } else {
      final String eventId = _eventId();
      final WorldEvent provisional = WorldEvent(
        id: eventId,
        kind: claim.kind == 'speech'
            ? WorldEventKind.speech
            : WorldEventKind.action,
        content: claim.text,
        actor: claim.actor,
        target: claim.targetId.isEmpty ? null : claim.targetId,
        delivery: claim.delivery,
        outcome: settlement.result,
        result: settlement.resultText,
        observations: settlement.observers,
        observationsResolved: true,
        status: WorldEventStatus.accepted,
        source: claim.actor == 'char:$controlledCharacter' ? 'player' : 'npc',
        placeId: scene.place,
        turnIndex: turnIndex,
        duration: 'brief',
        stateChanges: settlement.stateDelta,
      );
      final Map<String, String> observers = <String, String>{
        ...settlement.observers,
      };
      for (final Witness w in perception.witnesses(provisional, scene)) {
        if (w.characterId == actorId) continue;
        if (observers[w.characterId]?.trim().isNotEmpty == true) continue;
        final String text = await _observeText(
          settlement: settlement,
          objectiveWorld: objectiveWorld,
          observerId: w.characterId,
        );
        if (text.isNotEmpty) observers[w.characterId] = text;
      }
      for (final NarrativeScene destination in destinations) {
        for (final CharacterSnapshot c in destination.cast) {
          if (c.id == actorId) continue;
          if (observers[c.id]?.trim().isNotEmpty == true) continue;
          final String text = await _observeText(
            settlement: settlement,
            objectiveWorld: objectiveWorld,
            observerId: c.id,
          );
          if (text.isNotEmpty) observers[c.id] = text;
        }
      }
      event = provisional.copyWith(
        observations: observers,
        observationsResolved: true,
      );
      onCheckpoint?.call('SYS_RECORD', worldEventToJson(event));
    }
    final Map<String, String> observers = <String, String>{
      ...event.observations,
    };

    // 5. 记忆：行动者写意图 + 结果；目击者写自己看到的那份。
    final Map<String, List<CharacterMemory>> memories =
        <String, List<CharacterMemory>>{};
    final Map<String, Object?>? savedActorMemory =
        checkpoints['CH_MEMORY_WRITE:$actor'];
    if (savedActorMemory != null) {
      final List<CharacterMemory> restored =
          _memoriesFromCheckpoint(savedActorMemory);
      if (restored.isNotEmpty) {
        memory.restoreCharacter(actorId, restored);
        memories[actorId] = restored;
      }
    } else {
      final List<CharacterMemory> actorMemory = memory.forCharacter(actorId);
      final List<MemoryOperation>? actorOps = await agents.rememberOutcome(
        actor: actorId,
        intent: intent,
        settlement: settlement,
        memory: actorMemory,
        allowedEventIds: <String>{event.id},
      );
      final List<MemoryOperation> effectiveActorOps = actorOps ??
          <MemoryOperation>[
            MemoryOperation(
              op: 'encode',
              text: _memoryText(intent, settlement),
              kind: MemoryKind.episodic,
              sourceEvents: <String>[event.id],
            ),
          ];
      final List<CharacterMemory> actorNext = applyMemoryOperations(
        characterId: actorId,
        current: actorMemory,
        operations: effectiveActorOps,
        allowedEventIds: <String>{event.id},
      );
      memory.restoreCharacter(actorId, actorNext);
      memories[actorId] = actorNext;
      onCheckpoint?.call('CH_MEMORY_WRITE:$actor', <String, Object?>{
        'memories': <Object?>[for (final CharacterMemory m in actorNext) m.toJson()],
      });
    }

    for (final MapEntry<String, String> seen in observers.entries) {
      final String witnessId = seen.key;
      final String text = seen.value.trim();
      if (witnessId == actorId || text.isEmpty) continue;
      if (scene.byId(witnessId) == null &&
          !destinations.any((NarrativeScene d) => d.byId(witnessId) != null)) {
        continue;
      }
      final Map<String, Object?>? savedWitnessMemory =
          checkpoints['CH_MEMORY_WRITE:$witnessId'];
      if (savedWitnessMemory != null) {
        final List<CharacterMemory> restored =
            _memoriesFromCheckpoint(savedWitnessMemory);
        if (restored.isNotEmpty) {
          memory.restoreCharacter(witnessId, restored);
          memories[witnessId] = restored;
        }
        continue;
      }
      final List<CharacterMemory> current = memory.forCharacter(witnessId);
      final List<MemoryOperation>? ops = await agents.rememberWitness(
        actor: witnessId,
        event: event,
        seenText: text,
        memory: current,
        allowedEventIds: <String>{event.id},
      );
      final List<MemoryOperation> effective = ops ??
          <MemoryOperation>[
            MemoryOperation(
              op: 'encode',
              text: text,
              kind: MemoryKind.episodic,
              sourceEvents: <String>[event.id],
            ),
          ];
      final List<CharacterMemory> next = applyMemoryOperations(
        characterId: witnessId,
        current: current,
        operations: effective,
        allowedEventIds: <String>{event.id},
      );
      memory.restoreCharacter(witnessId, next);
      memories[witnessId] = next;
      onCheckpoint?.call('CH_MEMORY_WRITE:$witnessId', <String, Object?>{
        'memories': <Object?>[for (final CharacterMemory m in next) m.toJson()],
      });
    }

    return IntentBeatResult(
      intent: intent,
      claim: claim,
      settlement: settlement,
      event: event,
      memories: memories,
    );
  }

  IntentBeatResult _fail(List<String> errors, CharacterIntent intent) =>
      IntentBeatResult(
        intent: intent,
        claim: null,
        settlement: null,
        event: null,
        memories: const <String, List<CharacterMemory>>{},
        errors: errors,
      );

  List<CharacterMemory> _memoriesFromCheckpoint(Map<String, Object?> data) {
    final Object? raw = data['memories'];
    if (raw is! List) return const <CharacterMemory>[];
    return <CharacterMemory>[
      for (final Object? item in raw)
        if (item is Map)
          CharacterMemory.fromJson(Map<String, Object?>.from(item)),
    ];
  }

  Future<String> _observeText({
    required IntentSettlement settlement,
    required String objectiveWorld,
    required String observerId,
  }) async {
    final String stage = 'GM_OUTCOME_VIEW:$observerId';
    final Map<String, Object?>? saved = checkpoints[stage];
    if (saved != null && saved['text'] is String) {
      return '${saved['text']}'.trim();
    }
    final Map<String, String> extra = await agents.observeOutcome(
      settlement: settlement,
      objectiveWorld: objectiveWorld,
      observerId: observerId,
    );
    final String text = (extra[observerId] ?? '').trim();
    onCheckpoint?.call(stage, <String, Object?>{'text': text});
    return text;
  }

  /// 只拿到自己能感知的事件；名字按 observer 的称呼本地化。
  String _delivered(String id, List<WorldEvent> incoming) {
    final CharacterSnapshot? observer = scene.byId(id);
    if (observer == null) return '';
    final List<String> lines = <String>[];
    for (final WorldEvent event in incoming) {
      for (final Witness w in perception.witnesses(event, scene)) {
        if (w.characterId != id) continue;
        if (w.content.trim().isNotEmpty) {
          lines.add('${event.id} ${w.content}');
        }
      }
    }
    final String sceneText = (scene.observations[id] ?? '').trim();
    if (sceneText.isNotEmpty) lines.add('【此刻可感知的现场】$sceneText');
    return lines.join('\n');
  }

  /// 全知客观场面：只给立案官理解指称，不许拿它替角色扩知。
  String _publicScene() => jsonEncode(<String, Object?>{
        'place': scene.place,
        'names': scene.names,
        'cast': <Object?>[
          for (final CharacterSnapshot c in scene.cast)
            <String, Object?>{
              'id': c.id,
              'name': c.name,
              'aliases': c.aliases,
              'distance': c.distanceNote,
            },
        ],
      });

  String _eventId() => 'E${_seq++}';

  String _memoryText(CharacterIntent intent, IntentSettlement s) {
    final String wanted = intent.desired.isEmpty ? intent.text : intent.desired;
    return '我想$wanted；结果：${s.selfText}';
  }
}
