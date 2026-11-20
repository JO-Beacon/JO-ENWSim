// 回合的持久化状态：事件日志 + 角色记忆 + 世界状态。
//
// 只做 JSON 编解码；存哪里由 WorldStore 管。
// 这样下一回合能从完整事件/知识续接，而不是只靠“最近 6 步”。

import 'dart:convert';

import 'character_memory.dart';
import 'perception.dart';
import 'state_delta.dart';
import 'turn_session.dart';

/// 玩家对某个 AI 求助问题的回答。它是作者/玩家给引擎的补充，
/// 不是角色台词；默认仅上帝可见，角色输入按 visibility 过滤。
class PlayerAnswer {
  const PlayerAnswer({
    required this.step,
    required this.question,
    required this.answer,
    this.kind = 'direction',
    this.createdAt = '',
    this.visibility = 'god',
    this.characterId = '',
  });

  final String step;
  final String question;
  final String answer;

  /// fact / direction / choice
  final String kind;
  final String createdAt;
  final String visibility;
  final String characterId;

  Map<String, Object?> toJson() => <String, Object?>{
        'step': step,
        'question': question,
        'answer': answer,
        'kind': kind,
        'createdAt': createdAt,
        'visibility': visibility,
        'characterId': characterId,
      };

  static PlayerAnswer fromJson(Map<String, Object?> j) => PlayerAnswer(
        step: '${j['step'] ?? ''}',
        question: '${j['question'] ?? ''}',
        answer: '${j['answer'] ?? ''}',
        kind: '${j['kind'] ?? 'direction'}',
        createdAt: '${j['createdAt'] ?? ''}',
        visibility: '${j['visibility'] ?? 'god'}',
        characterId: '${j['characterId'] ?? ''}',
      );
}

class TurnState {
  const TurnState({
    required this.events,
    this.pendingEvents = const <WorldEvent>[],
    this.memory = const <CharacterMemory>[],
    this.locations = const <String, String>{},
    this.states = const <String, String>{},
    this.inventories = const <String, List<String>>{},
    this.injuries = const <InjuryFact>[],
    this.constraints = const <FunctionalConstraint>[],
    this.entities = const <String, EntityRecord>{},
    this.facts = const <FactRecord>[],
    this.inner = const <InnerEntry>[],
    this.playerAnswers = const <PlayerAnswer>[],
    this.worldWork = const <String, Object?>{},
    this.turnSessionId = '',
    this.stopPoint,
  });

  final List<WorldEvent> events;

  /// 上一回合产出、还没有被下一回合的 GM_ROUTE/CH_PERCEIVE 处理的事件。
  ///
  /// 存放在状态快照里，手动模式和自动模式共用；CH_PERCEIVE 写记忆时按
  /// `CharacterMemory.sourceEvents` 去重，避免同一事件被记两次。
  final List<WorldEvent> pendingEvents;

  /// 角色记忆：第一人称主观笔记，每回合随状态整本快照。
  final List<CharacterMemory> memory;

  /// 实体表：角色/物品/容器/地点。后两者也在这里，不再只靠地图。
  final Map<String, EntityRecord> entities;

  /// 事实表：subject / predicate / object / since / until / source。
  final List<FactRecord> facts;

  /// 角色内心：只有该角色和上帝可见，不是事件。
  final List<InnerEntry> inner;

  /// 玩家对 AI 求助问题的回答；跨回合保留，后续 AI 可读。
  final List<PlayerAnswer> playerAnswers;
  final Map<String, Object?> worldWork;

  /// 提交这份快照的 TurnSession id；用来判断一次崩溃前是否已经提交。
  final String turnSessionId;

  /// 已提交回合的交互点；只在带问题/选项/需要人处理时保留。
  final StopPoint? stopPoint;

  /// 角色名 -> 这一回合结束时所在地点。
  final Map<String, String> locations;

  /// 角色名 -> 这一回合结束时的通用状态（情绪/装备等）。
  final Map<String, String> states;

  /// 角色名 -> 随身物品 id。
  final Map<String, List<String>> inventories;

  /// 伤势事实：哪个部位、什么伤、怎么来的、处理过没有。
  final List<InjuryFact> injuries;

  /// 功能限制：能/不能/不确定做哪个动作。
  final List<FunctionalConstraint> constraints;

  static const TurnState empty = TurnState(events: <WorldEvent>[]);

  /// 共同顺序只表示因果先后，不把一次说话和一次旅行视为等长。
  int get worldStep => events.fold<int>(0,
      (int n, WorldEvent e) => e.status == WorldEventStatus.accepted && e.turnIndex > n ? e.turnIndex : n);

  Iterable<EntityRecord> get ongoingProcesses => entities.values.where(
      (EntityRecord e) => e.kind == 'process' && e.state['status'] == 'ongoing');

  /// 在写入前模拟归属变化。任何错误都拒绝整个增量。
  List<String> transitionErrors(StateDelta delta, {
    String? actor, String place = '', bool adjudicated = true, int? atTurn,
  }) {
    final List<String> errors = <String>[];
    String plain(String s) => s.replaceFirst('char:', '').replaceFirst('place:', '');
    bool character(String name) => entities.containsKey('char:${plain(name)}') ||
        locations.containsKey(plain(name));
    final Map<String, EntityRecord> known = <String, EntityRecord>{...entities};
    for (final EntityDiscovery e in delta.discoveries) {
      if (!adjudicated || e.id.isEmpty || e.name.isEmpty || e.evidence.trim().isEmpty ||
          !<String>{'item', 'container', 'place', 'other'}.contains(e.kind) ||
          known.containsKey(e.id) || e.id.startsWith('char:')) {
        errors.add('新实体 ${e.id} 缺少有效的裁定依据，或与已有实体冲突');
      } else {
        known[e.id] = EntityRecord(id: e.id, kind: e.kind, name: e.name,
            location: e.location);
      }
    }
    for (final MapEntry<String, String> move in delta.moves.entries) {
      if (entities.isNotEmpty && !character(move.key)) errors.add('未知角色：${move.key}');
      if (actor != null && !adjudicated && move.key != actor) {
        errors.add('行动者不能直接决定 ${move.key} 的移动');
      }
      if (known.isNotEmpty && !known.values.any((EntityRecord e) =>
          e.kind == 'place' && (plain(e.id) == move.value || e.name == move.value))) {
        errors.add('目标地点尚未确认存在：${move.value}');
      }
      for (final EntityRecord p in ongoingProcesses) {
        if (p.state['owner'] != move.key || p.state['kind'] != 'travel') continue;
        if (!delta.processes.any((ProcessDelta x) => x.id == p.id &&
            x.status == 'completed' && x.destination == move.value)) {
          errors.add('${move.key} 的旅行尚未完成，不能提前到达');
        }
      }
    }
    for (final EntityDiscovery e in delta.discoveries) {
      if (e.kind == 'place' && e.location.isEmpty) continue;
      final String holder = plain(e.location);
      if (holder.isEmpty || holder == e.id || (!character(holder) && !known.values.any(
          (EntityRecord k) => (<String>{'place', 'container'}.contains(k.kind) && plain(k.id) == holder) ||
              (k.kind == 'place' && k.name == holder)))) {
        errors.add('新实体位置尚未确认存在：${e.id}');
      }
    }
    for (final InjuryFact i in delta.injuries) {
      if ((known.isNotEmpty && !character(i.who)) || i.part.isEmpty || i.kind.isEmpty) {
        errors.add('伤势缺少有效角色、部位或类型');
      }
    }
    for (final FunctionalConstraint c in delta.constraints) {
      if ((known.isNotEmpty && !character(c.who)) || c.capability.isEmpty) {
        errors.add('功能限制缺少有效角色或能力');
      }
    }
    if (actor != null && !adjudicated) {
      if (delta.injuries.any((InjuryFact i) => i.who != actor) ||
          delta.constraints.any((FunctionalConstraint c) => c.who != actor)) {
        errors.add('他人的伤势或能力变化需要裁定');
      }
      if (delta.facts.isNotEmpty || delta.processes.isNotEmpty) {
        errors.add('持续事实和过程需要裁定确认');
      }
    }
    final Map<String, String> owners = <String, String>{};
    for (final EntityRecord e in known.values) {
      if (e.kind == 'item') owners[e.id] = plain(e.location);
      for (final String id in e.contains) {
        final String holder = plain(e.id);
        if (owners[id]?.isNotEmpty == true && owners[id] != holder) {
          errors.add('物品 $id 的容器与位置矛盾');
        }
        owners[id] = holder;
      }
    }
    final Set<String> held = <String>{};
    for (final MapEntry<String, List<String>> inv in inventories.entries) {
      for (final String id in inv.value) {
        if (!held.add(id)) errors.add('物品 $id 被重复持有');
        if (owners[id]?.isNotEmpty == true && owners[id] != plain(inv.key)) {
          errors.add('物品 $id 的归属与实体位置矛盾');
        }
        owners[id] = plain(inv.key);
      }
    }
    for (final StateItemDelta item in delta.items) {
      if (!<String>{'take', 'give', 'steal', 'drop'}.contains(item.kind)) {
        errors.add('未知物品变化：${item.kind}');
        continue;
      }
      if (!owners.containsKey(item.itemId)) {
        errors.add('物品尚未确认存在：${item.itemId}');
        continue;
      }
      if (known.containsKey(item.itemId) && known[item.itemId]!.kind != 'item') {
        errors.add('只能转移物品实体：${item.itemId}');
      }
      final String source = plain(item.kind == 'drop'
          ? (item.by ?? item.from ?? '') : (item.from ?? ''));
      if (source.isEmpty || owners[item.itemId] != source) {
        errors.add('物品 ${item.itemId} 不属于声明来源 $source');
      }
      if (actor != null && !adjudicated &&
          (item.kind == 'steal' || (character(source) && source != actor))) {
        errors.add('不能直接从他人处取得 ${item.itemId}');
      }
      final String destination = item.kind == 'drop'
          ? plain(item.place ?? item.to ?? locations[source] ?? place)
          : plain(item.to ?? '');
      if (destination.isEmpty) errors.add('物品变化缺少去向：${item.itemId}');
      if (known.isNotEmpty && !character(destination) &&
          !known.values.any((EntityRecord e) =>
            (<String>{'place', 'container'}.contains(e.kind) && plain(e.id) == destination) ||
            (e.kind == 'place' && e.name == destination))) {
        errors.add('物品目标尚未确认存在：$destination');
      }
      if (actor != null && !adjudicated) {
        String locationOf(String id) {
          final Set<String> visited = <String>{};
          String current = plain(id);
          while (visited.add(current)) {
            if (locations.containsKey(current)) return locations[current]!;
            final EntityRecord? e = known[current] ?? known['char:$current'] ?? known['place:$current'];
            if (e == null) return current;
            if (e.kind == 'place') return e.name;
            current = plain(e.location);
          }
          return '';
        }
        final String actorPlace = locations[actor] ?? place;
        if (locationOf(source) != actorPlace || locationOf(destination) != actorPlace) {
          errors.add('直接物品变化必须在行动者当前可及的地点');
        }
        if (source != actor && destination != actor) {
          errors.add('行动者不能直接转移与自己无关的物品');
        }
        if (item.kind == 'give' && character(destination) && destination != actor) {
          errors.add('交付给他人需要裁定接收条件');
        }
      }
      owners[item.itemId] = destination;
    }
    final Set<String> boundaryIds = <String>{
      for (final FactRecord fact in facts)
        if (fact.predicate == 'time_boundary' && fact.untilEvent.isEmpty) fact.id,
    };
    for (final StateFactDelta f in delta.facts) {
      final bool subjectKnown = f.predicate == 'time_before'
          ? boundaryIds.contains(f.subject) && boundaryIds.contains(f.object)
          : known.containsKey(f.subject);
      if (!subjectKnown || f.predicate.isEmpty ||
          f.evidence.trim().isEmpty ||
          !<String>{'set', 'add', 'remove'}.contains(f.operation) ||
          !<String>{'public', 'hidden', 'self'}.contains(f.visibility) ||
          <String>{'location', 'inventory', 'injury', 'constraint'}.contains(f.predicate)) {
        errors.add('持续事实缺少实体、依据或有效属性：${f.subject}/${f.predicate}');
      }
    }
    if (delta.facts.any((StateFactDelta fact) => fact.predicate == 'time_before')) {
      final Map<String, Set<String>> successors = <String, Set<String>>{};
      for (final FactRecord fact in facts) {
        if (fact.predicate != 'time_before' || fact.untilEvent.isNotEmpty) continue;
        successors.putIfAbsent(fact.subject, () => <String>{}).add(fact.object);
      }
      for (final StateFactDelta fact in delta.facts) {
        if (fact.predicate != 'time_before') continue;
        final Set<String> targets = successors.putIfAbsent(fact.subject, () => <String>{});
        if (fact.operation == 'set') targets.clear();
        if (fact.operation == 'remove') {
          targets.remove(fact.object);
        } else {
          targets.add(fact.object);
        }
      }
      for (final String boundary in successors.keys) {
        final Set<String> checked = <String>{};
        final List<String> pending = <String>[...?successors[boundary]];
        while (pending.isNotEmpty) {
          final String check = pending.removeLast();
          if (check == boundary) {
            errors.add('时间边界的先后关系形成循环：$boundary');
            break;
          }
          if (checked.add(check)) pending.addAll(successors[check] ?? const <String>{});
        }
      }
    }
    final Set<String> processIds = <String>{};
    // 校验增量后的整张位置图，防止间接循环破坏地点与可及性判断。
    final Map<String, String> parent = <String, String>{
      for (final EntityRecord e in known.values) e.id: e.location,
      for (final MapEntry<String, String> e in delta.moves.entries) 'char:${e.key}': e.value,
    };
    for (final StateItemDelta item in delta.items) {
      parent[item.itemId] = item.kind == 'drop'
          ? item.place ?? item.to ?? place : item.to ?? '';
    }
    String? entityId(String raw) {
      if (known.containsKey(raw)) return raw;
      if (known.containsKey('char:$raw')) return 'char:$raw';
      if (known.containsKey('place:$raw')) return 'place:$raw';
      return null;
    }
    final Set<String> checked = <String>{};
    for (final String root in parent.keys) {
      final Set<String> path = <String>{};
      String? current = root;
      while (current != null && !checked.contains(current)) {
        if (!path.add(current)) { errors.add('实体位置存在循环包含：$current'); break; }
        current = entityId(parent[current] ?? '');
      }
      checked.addAll(path);
    }
    for (final ProcessDelta p in delta.processes) {
      final EntityRecord? old = known[p.id];
      if (!processIds.add(p.id)) errors.add('同一增量不能重复更新过程：${p.id}');
      if (p.id.isEmpty || p.description.trim().isEmpty || p.completionCondition.trim().isEmpty ||
          !<String>{'ongoing', 'completed', 'cancelled'}.contains(p.status) ||
          !<String>{'travel', 'action', 'environment'}.contains(p.kind) ||
          !<String>{'public', 'hidden'}.contains(p.visibility) ||
          !known.values.any((EntityRecord e) => e.kind == 'place' &&
              (plain(e.id) == p.place || e.name == p.place)) ||
          (old != null && old.kind != 'process') ||
          (p.owner.isNotEmpty && !character(p.owner))) {
        errors.add('持续过程不完整或角色不存在：${p.id}');
      }
      if (old != null && (old.state['status'] != 'ongoing' ||
          old.state['kind'] != p.kind || old.state['owner'] != p.owner ||
          old.state['destination'] != p.destination)) {
        errors.add('不能重启已结束过程或改写过程身份：${p.id}');
      }
      if (p.kind == 'travel' && (p.owner.isEmpty || !known.values.any(
          (EntityRecord e) => e.kind == 'place' &&
              (plain(e.id) == p.destination || e.name == p.destination)))) {
        errors.add('旅行需要角色与已确认目的地');
      }
      if (p.kind == 'travel' && p.status == 'ongoing' && delta.moves.containsKey(p.owner)) {
        errors.add('进行中的旅行不能同时完成位置变更');
      }
      if (p.status != 'ongoing' && old == null) errors.add('不能结束尚未开始的过程：${p.id}');
      final String storedBoundary = '${old?.state['completion_boundary'] ?? ''}';
      final String boundary = storedBoundary.isEmpty ? p.completionBoundary : storedBoundary;
      if (storedBoundary.isNotEmpty && p.completionBoundary.isNotEmpty &&
          p.completionBoundary != storedBoundary) {
        errors.add('不能改写已绑定的完成边界：${p.id}');
      }
      if (boundary.isNotEmpty) {
        if (!facts.any((FactRecord fact) => fact.id == boundary && fact.predicate == 'time_boundary')) {
          errors.add('完成边界必须引用已记录的时间安排：${p.id}');
        }
        if (p.status == 'completed' && !events.any((WorldEvent event) =>
            event.status == WorldEventStatus.accepted && event.source == 'world_time' &&
            event.target == boundary)) {
          errors.add('尚未到达过程的完成边界：${p.id}');
        }
      }
      final String? nextCheck = p.nextCheckBoundary;
      if (nextCheck != null && nextCheck.isNotEmpty && !facts.any((FactRecord fact) =>
          fact.id == nextCheck && fact.predicate == 'time_boundary' && fact.untilEvent.isEmpty &&
          fact.evidence.trim().isNotEmpty && fact.object.trim().isNotEmpty)) {
        errors.add('下次检查边界必须引用有效的已知时间安排：${p.id}');
      }
      final String? nextFact = p.nextCheckFact;
      if (nextFact != null && nextFact.isNotEmpty &&
          !facts.any((FactRecord fact) => fact.id == nextFact && fact.untilEvent.isEmpty)) {
        errors.add('下次检查条件必须引用当前有效的事实：${p.id}');
      }
      if (nextCheck?.isNotEmpty == true && nextFact?.isNotEmpty == true) {
        errors.add('同一个过程只能选择一种等待条件：${p.id}');
      }
      if (p.status == 'completed' && old?.state['started_turn'] is int &&
          (old!.state['started_turn'] as int) >= (atTurn ?? worldStep + 1)) {
        errors.add('持续过程不能在开始的同一世界顺序内完成：${p.id}');
      }
      if (p.kind == 'travel' && p.status == 'completed' && delta.moves[p.owner] != p.destination) {
        errors.add('旅行完成必须明确到达地点');
      }
    }
    return errors;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'events': <Object?>[
          for (final WorldEvent e in events) worldEventToJson(e),
        ],
        'pendingEvents': <Object?>[
          for (final WorldEvent e in pendingEvents) worldEventToJson(e),
        ],
        'memory': <Object?>[
          for (final CharacterMemory m in memory) m.toJson(),
        ],
        'locations': locations,
        'states': states,
        'inventories': <String, Object?>{
          for (final MapEntry<String, List<String>> e in inventories.entries)
            e.key: e.value,
        },
        'injuries': <Object?>[
          for (final InjuryFact i in injuries) i.toJson(),
        ],
        'constraints': <Object?>[
          for (final FunctionalConstraint c in constraints) c.toJson(),
        ],
        'entities': <String, Object?>{
          for (final MapEntry<String, EntityRecord> e in entities.entries)
            e.key: e.value.toJson(),
        },
        'facts': <Object?>[
          for (final FactRecord f in facts) f.toJson(),
        ],
        'inner': <Object?>[
          for (final InnerEntry i in inner) i.toJson(),
        ],
        'playerAnswers': <Object?>[
          for (final PlayerAnswer a in playerAnswers) a.toJson(),
        ],
        if (worldWork.isNotEmpty) 'worldWork': worldWork,
        'turnSessionId': turnSessionId,
        'stopPoint': stopPoint?.toJson(),
      };

  String encode() => jsonEncode(toJson());

  /// 检查点：历史和记忆分别进 event / memory_version 表。
  Map<String, Object?> toCheckpointJson() {
    final Map<String, Object?> j = toJson();
    // 事件正文不可变，交付进度随快照回退，不覆盖历史事件行。
    j['eventReceipts'] = <String, Object?>{
      for (final WorldEvent e in events) e.uid.isEmpty ? e.id : e.uid: e.receivedBy,
    };
    j.remove('events');
    j.remove('memory');
    return j;
  }

  String encodeCheckpoint() => jsonEncode(toCheckpointJson());

  /// 替换运行时事件列表，其他字段不动。
  TurnState withEvents(List<WorldEvent> next) => TurnState(
        events: next,
        pendingEvents: pendingEvents,
        memory: memory,
        locations: locations,
        states: states,
        inventories: inventories,
        injuries: injuries,
        constraints: constraints,
        entities: entities,
        facts: facts,
        inner: inner,
        playerAnswers: playerAnswers,
        worldWork: worldWork,
        turnSessionId: turnSessionId,
        stopPoint: stopPoint,
      );

  TurnState withWorldWork(Map<String, Object?> next) => TurnState(
        events: events,
        pendingEvents: pendingEvents,
        memory: memory,
        locations: locations,
        states: states,
        inventories: inventories,
        injuries: injuries,
        constraints: constraints,
        entities: entities,
        facts: facts,
        inner: inner,
        playerAnswers: playerAnswers,
        worldWork: next,
        turnSessionId: turnSessionId,
        stopPoint: stopPoint,
      );

  /// 把从 event / memory_version 表读出的历史装回运行时对象。
  TurnState withHistory({
    required List<WorldEvent> events,
    required List<CharacterMemory> memory,
  }) => TurnState(
        events: events,
        pendingEvents: pendingEvents,
        memory: memory,
        locations: locations,
        states: states,
        inventories: inventories,
        injuries: injuries,
        constraints: constraints,
        entities: entities,
        facts: facts,
        inner: inner,
        playerAnswers: playerAnswers,
        worldWork: worldWork,
        turnSessionId: turnSessionId,
        stopPoint: stopPoint,
      );

  /// 只换待感知事件，其他状态原样带过去；给旧检查点兼容用。
  TurnState withPendingEvents(List<WorldEvent> next) => TurnState(
        events: events,
        pendingEvents: next,
        memory: memory,
        locations: locations,
        states: states,
        inventories: inventories,
        injuries: injuries,
        constraints: constraints,
        entities: entities,
        facts: facts,
        inner: inner,
        playerAnswers: playerAnswers,
        worldWork: worldWork,
        turnSessionId: turnSessionId,
        stopPoint: stopPoint,
      );

  /// 只换记忆，其他状态原样带过去；给记忆面板保存用。
  TurnState withMemory(List<CharacterMemory> next) => TurnState(
        events: events,
        pendingEvents: pendingEvents,
        memory: next,
        locations: locations,
        states: states,
        inventories: inventories,
        injuries: injuries,
        constraints: constraints,
        entities: entities,
        facts: facts,
        inner: inner,
        playerAnswers: playerAnswers,
        worldWork: worldWork,
        turnSessionId: turnSessionId,
        stopPoint: stopPoint,
      );

  List<InjuryFact> injuriesFor(String who) =>
      <InjuryFact>[for (final InjuryFact i in injuries) if (i.who == who) i];

  FunctionalConstraint? constraintFor(String who, String capability) {
    for (final FunctionalConstraint c in constraints) {
      if (c.who == who && c.capability == capability) return c;
    }
    return null;
  }

  bool blocks(String who, String capability) =>
      constraintFor(who, capability)?.state == ConstraintState.cannot;

  /// 给 GM_RESOLVE_ACTION / 角色卡读的“事实 + 功能限制”文本。
  String conditionText(String who) {
    final List<String> lines = <String>[];
    for (final InjuryFact i in injuriesFor(who)) {
      final String detail = <String>[
        '${i.part}${i.kind}',
        if (i.cause.isNotEmpty) '原因：${i.cause}',
        if (i.treatment.isNotEmpty) '处理：${i.treatment}',
        if (i.note.isNotEmpty) i.note,
      ].join('，');
      lines.add('伤势事实：$detail');
    }
    for (final FunctionalConstraint c in constraints) {
      if (c.who != who) continue;
      lines.add(
        '功能限制：${c.capability}=${c.state.name}'
        '${c.reason.isEmpty ? '' : '（${c.reason}）'}',
      );
    }
    return lines.join('；');
  }

  /// 按一回合的 delta 改下一份状态；不在 delta 里的字段不动。
  TurnState applyDelta(StateDelta delta, {int? atTurn}) {
    final List<String> errors = transitionErrors(delta, atTurn: atTurn);
    if (errors.isNotEmpty) throw StateError(errors.join('；'));
    final Map<String, String> nextLocations = <String, String>{...locations};
    for (final MapEntry<String, String> e in delta.moves.entries) {
      nextLocations[e.key] = e.value;
    }
    final Map<String, String> nextStates = <String, String>{...states};
    final List<InjuryFact> nextInjuries = <InjuryFact>[...injuries];
    for (final InjuryFact inj in delta.injuries) {
      final int i = nextInjuries.indexWhere(
        (InjuryFact x) => x.key == inj.key,
      );
      if (i < 0) {
        nextInjuries.add(inj);
      } else {
        final InjuryFact old = nextInjuries[i];
        nextInjuries[i] = InjuryFact(
          who: old.who,
          part: old.part,
          kind: old.kind,
          cause: inj.cause.isNotEmpty ? inj.cause : old.cause,
          treatment: inj.treatment.isNotEmpty ? inj.treatment : old.treatment,
          note: inj.note.isNotEmpty ? inj.note : old.note,
        );
      }
    }
    final List<FunctionalConstraint> nextConstraints =
        <FunctionalConstraint>[...constraints];
    for (final FunctionalConstraint c in delta.constraints) {
      final int i = nextConstraints.indexWhere(
        (FunctionalConstraint x) =>
            x.who == c.who && x.capability == c.capability,
      );
      if (i >= 0) {
        nextConstraints[i] = c;
      } else {
        nextConstraints.add(c);
      }
    }
    final Map<String, List<String>> nextInventories =
        <String, List<String>>{
      for (final MapEntry<String, List<String>> e in inventories.entries)
        e.key: List<String>.of(e.value),
    };
    final Map<String, EntityRecord> nextEntities =
        <String, EntityRecord>{...entities};
    for (final EntityDiscovery e in delta.discoveries) {
      nextEntities[e.id] = EntityRecord(id: e.id, kind: e.kind,
          name: e.name, location: e.location, state: <String, Object?>{'discovery_evidence': e.evidence});
    }
    for (final EntityDiscovery e in delta.discoveries) {
      if (e.kind == 'item') {
        final String holder = e.location.replaceFirst('char:', '');
        if (nextEntities['char:$holder']?.kind == 'character' || locations.containsKey(holder)) {
          nextInventories.putIfAbsent(holder, () => <String>[]).add(e.id);
        }
        final EntityRecord? container = nextEntities[e.location];
        if (container?.kind == 'container') {
          nextEntities[e.location] = container!.copyWith(contains: <String>[...container.contains, e.id]);
        }
      }
    }
    for (final MapEntry<String, String> move in delta.moves.entries) {
      final String id = 'char:${move.key}';
      final EntityRecord? old = nextEntities[id];
      nextEntities[id] = (old ??
              EntityRecord(
                id: id,
                kind: 'character',
                name: move.key,
              ))
          .copyWith(location: move.value);
    }
    final List<FactRecord> nextFacts = <FactRecord>[...facts];
    for (final StateFactDelta f in delta.facts) {
      bool sameProperty(FactRecord old) => old.subject == f.subject && old.predicate == f.predicate;
      if (f.operation == 'remove') {
        nextFacts.removeWhere((FactRecord old) => sameProperty(old) && old.object == f.object);
        continue;
      }
      if (f.operation == 'set') {
        nextFacts.removeWhere(sameProperty);
      } else {
        nextFacts.removeWhere((FactRecord old) => sameProperty(old) && old.object == f.object);
      }
      _upsertFact(nextFacts, FactRecord(
        id: 'fact:${f.subject}:${f.predicate}${f.operation == 'add' ? ':${jsonEncode(f.object)}' : ''}', subject: f.subject,
        predicate: f.predicate, object: f.object, visibility: f.visibility,
        observers: f.observers, evidence: f.evidence,
      ));
    }
    for (final ProcessDelta p in delta.processes) {
      final EntityRecord? old = nextEntities[p.id];
      final String? nextFact = p.nextCheckFact;
      final FactRecord? factAtStart = nextFact == null || nextFact.isEmpty ? null :
          facts.where((FactRecord fact) => fact.id == nextFact && fact.untilEvent.isEmpty).firstOrNull;
      final bool keepWaiting = p.status == 'ongoing' && p.nextCheckBoundary == null && nextFact == null;
      nextEntities[p.id] = EntityRecord(id: p.id, kind: 'process',
        name: p.description, location: p.place, state: <String, Object?>{
          ...p.toJson(),
          if (p.completionBoundary.isEmpty && old?.state['completion_boundary'] != null)
            'completion_boundary': old!.state['completion_boundary'],
          if (keepWaiting && old?.state['next_check_boundary'] != null)
            'next_check_boundary': old!.state['next_check_boundary'],
          if (keepWaiting && old?.state['next_check_fact'] != null) ...<String, Object?>{
            'next_check_fact': old!.state['next_check_fact'],
            'next_check_fact_value': old.state['next_check_fact_value'],
          },
          if (factAtStart != null) 'next_check_fact_value': factAtStart.object,
          'started_turn': old?.state['started_turn'] ?? atTurn ?? worldStep + 1,
          'updated_turn': atTurn ?? worldStep + 1,
        });
    }
    for (final MapEntry<String, String> move in delta.moves.entries) {
      _upsertFact(
        nextFacts,
        FactRecord(
          id: 'fact:location:${move.key}',
          subject: 'char:${move.key}',
          predicate: 'location',
          object: move.value,
        ),
      );
    }
    for (final InjuryFact inj in delta.injuries) {
      _upsertFact(
        nextFacts,
        FactRecord(
          id: 'fact:injury:${inj.who}:${inj.part}:${inj.kind}',
          subject: 'char:${inj.who}',
          predicate: 'injury',
          object: '${inj.part}:${inj.kind}',
        ),
      );
    }
    for (final FunctionalConstraint c in delta.constraints) {
      _upsertFact(
        nextFacts,
        FactRecord(
          id: 'fact:constraint:${c.who}:${c.capability}',
          subject: 'char:${c.who}',
          predicate: 'constraint',
          object: c.state.name,
        ),
      );
    }
    final List<InnerEntry> nextInner = <InnerEntry>[...inner];
    for (final StateItemDelta item in delta.items) {
      final String? from = item.kind == 'drop' ? (item.by ?? item.from) : item.from;
      final String? to = item.to;
      final String location;
      if (item.kind == 'drop') {
        final String? by = item.by ?? item.from;
        location = item.place ??
            item.to ??
            (by == null ? null : nextLocations[by.replaceFirst('char:', '')]) ??
            '';
      } else {
        location = to ?? item.by ?? from ?? item.place ?? '';
      }
      // 背包与容器统一使用同一组实际来源和去向。
      if (from != null) {
        nextInventories[from.replaceFirst('char:', '')]?.remove(item.itemId);
      }
      final String holder = location.replaceFirst('char:', '');
      if (nextEntities['char:$holder']?.kind == 'character' ||
          nextLocations.containsKey(holder) || (entities.isEmpty && item.kind != 'drop')) {
        final List<String> inventory = nextInventories.putIfAbsent(holder, () => <String>[]);
        if (!inventory.contains(item.itemId)) inventory.add(item.itemId);
      }
      final EntityRecord? oldItem = nextEntities[item.itemId];
      nextEntities[item.itemId] = (oldItem ??
              EntityRecord(
                id: item.itemId,
                kind: 'item',
                name: item.itemId,
              ))
          .copyWith(location: location);
      if (from != null) {
        final EntityRecord? container = nextEntities[from];
        if (container != null && container.kind == 'container') {
          nextEntities[from] = container.copyWith(
            contains: container.contains
                .where((String id) => id != item.itemId)
                .toList(),
          );
        }
      }
      final EntityRecord? container = nextEntities[location];
      if (container != null && container.kind == 'container') {
        if (!container.contains.contains(item.itemId)) {
          nextEntities[location] = container.copyWith(
            contains: <String>[...container.contains, item.itemId],
          );
        }
      }
    }
    return TurnState(
      events: events,
      pendingEvents: pendingEvents,
      memory: memory,
      locations: nextLocations,
      states: nextStates,
      inventories: nextInventories,
      injuries: nextInjuries,
      constraints: nextConstraints,
      entities: nextEntities,
      facts: nextFacts,
      inner: nextInner,
      playerAnswers: playerAnswers,
      worldWork: worldWork,
      turnSessionId: turnSessionId,
      stopPoint: stopPoint,
    );
  }

  static TurnState decode(String raw) {
    if (raw.trim().isEmpty) return empty;
    final Object? j = jsonDecode(raw);
    if (j is! Map) return empty;
    return fromJson(j.cast<String, Object?>());
  }

  static TurnState fromJson(Map<String, Object?> j) {
    final List<WorldEvent> events = <WorldEvent>[];
    final Object? rawEvents = j['events'];
    if (rawEvents is List) {
      for (final Object? item in rawEvents) {
        if (item is Map) {
          events.add(worldEventFromJson(item.cast<String, Object?>()));
        }
      }
    }
    final List<WorldEvent> pendingEvents = <WorldEvent>[];
    final Object? rawPending = j['pendingEvents'];
    if (rawPending is List) {
      for (final Object? item in rawPending) {
        if (item is Map) {
          pendingEvents.add(
            worldEventFromJson(item.cast<String, Object?>()),
          );
        }
      }
    }
    final List<CharacterMemory> memory = <CharacterMemory>[];
    final Object? rawMemory = j['memory'];
    if (rawMemory is List) {
      for (final Object? item in rawMemory) {
        if (item is Map) {
          memory.add(
            CharacterMemory.fromJson(item.cast<String, Object?>()),
          );
        }
      }
    }
    final Map<String, String> locations = <String, String>{};
    final Object? rawLocations = j['locations'];
    if (rawLocations is Map) {
      for (final MapEntry<Object?, Object?> e in rawLocations.entries) {
        locations['${e.key}'] = '${e.value}';
      }
    }
    final Map<String, String> states = <String, String>{};
    final Object? rawStates = j['states'];
    if (rawStates is Map) {
      for (final MapEntry<Object?, Object?> e in rawStates.entries) {
        states['${e.key}'] = '${e.value}';
      }
    }
    final Map<String, List<String>> inventories = <String, List<String>>{};
    final Object? rawInventories = j['inventories'];
    if (rawInventories is Map) {
      for (final MapEntry<Object?, Object?> e in rawInventories.entries) {
        final Object? v = e.value;
        if (v is List) {
          inventories['${e.key}'] = v.map((Object? x) => '$x').toList();
        }
      }
    }
    final List<InjuryFact> injuries = <InjuryFact>[];
    final Object? rawInjuries = j['injuries'];
    if (rawInjuries is List) {
      for (final Object? item in rawInjuries) {
        if (item is Map) {
          final InjuryFact inj =
              InjuryFact.fromJson(item.cast<String, Object?>());
          if (inj.who.isNotEmpty && inj.part.isNotEmpty) injuries.add(inj);
        }
      }
    }
    final List<FunctionalConstraint> constraints = <FunctionalConstraint>[];
    final Object? rawConstraints = j['constraints'];
    if (rawConstraints is List) {
      for (final Object? item in rawConstraints) {
        if (item is Map) {
          final FunctionalConstraint c =
              FunctionalConstraint.fromJson(item.cast<String, Object?>());
          if (c.who.isNotEmpty && c.capability.isNotEmpty) constraints.add(c);
        }
      }
    }
    final Map<String, EntityRecord> entities = <String, EntityRecord>{};
    final Object? rawEntities = j['entities'];
    if (rawEntities is Map) {
      for (final MapEntry<Object?, Object?> e in rawEntities.entries) {
        if (e.value is Map) {
          entities['${e.key}'] = EntityRecord.fromJson(
            (e.value! as Map).cast<String, Object?>(),
          );
        }
      }
    }
    final List<FactRecord> facts = <FactRecord>[];
    final Object? rawFacts = j['facts'];
    if (rawFacts is List) {
      for (final Object? item in rawFacts) {
        if (item is Map) {
          facts.add(FactRecord.fromJson(item.cast<String, Object?>()));
        }
      }
    }
    final List<InnerEntry> inner = <InnerEntry>[];
    final Object? rawInner = j['inner'];
    if (rawInner is List) {
      for (final Object? item in rawInner) {
        if (item is Map) {
          inner.add(InnerEntry.fromJson(item.cast<String, Object?>()));
        }
      }
    }
    final List<PlayerAnswer> playerAnswers = <PlayerAnswer>[];
    final Object? rawAnswers = j['playerAnswers'];
    if (rawAnswers is List) {
      for (final Object? item in rawAnswers) {
        if (item is Map) {
          playerAnswers.add(
            PlayerAnswer.fromJson(item.cast<String, Object?>()),
          );
        }
      }
    }
    return TurnState(
      events: events,
      pendingEvents: pendingEvents,
      memory: memory,
      locations: locations,
      states: states,
      inventories: inventories,
      injuries: injuries,
      constraints: constraints,
      entities: entities,
      facts: facts,
      inner: inner,
      playerAnswers: playerAnswers,
      worldWork: j['worldWork'] is Map
          ? Map<String, Object?>.from(j['worldWork'] as Map) : const <String, Object?>{},
      turnSessionId: '${j['turnSessionId'] ?? ''}',
      stopPoint: j['stopPoint'] is Map
          ? StopPoint.fromJson(Map<String, Object?>.from(j['stopPoint'] as Map))
          : null,
    );
  }
}

void _upsertFact(List<FactRecord> facts, FactRecord fact) {
  final int i = facts.indexWhere((FactRecord f) => f.id == fact.id);
  if (i >= 0) {
    facts[i] = fact;
  } else {
    facts.add(fact);
  }
}

class EntityRecord {  const EntityRecord({
    required this.id,
    required this.kind,
    required this.name,
    this.location = '',
    this.state = const <String, Object?>{},
    this.contains = const <String>[],
    this.relations = const <String, String>{},
  });

  final String id;

  /// character / item / container / place / other
  final String kind;
  final String name;
  final String location;
  final Map<String, Object?> state;
  final List<String> contains;
  final Map<String, String> relations;

  EntityRecord copyWith({
    String? location,
    Map<String, Object?>? state,
    List<String>? contains,
    Map<String, String>? relations,
  }) {
    return EntityRecord(
      id: id,
      kind: kind,
      name: name,
      location: location ?? this.location,
      state: state ?? this.state,
      contains: contains ?? this.contains,
      relations: relations ?? this.relations,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'kind': kind,
        'name': name,
        'location': location,
        'state': state,
        'contains': contains,
        'relations': relations,
      };

  static EntityRecord fromJson(Map<String, Object?> j) {
    final Map<String, Object?> state = <String, Object?>{};
    if (j['state'] is Map) {
      state.addAll((j['state']! as Map).cast<String, Object?>());
    }
    final Map<String, String> relations = <String, String>{};
    if (j['relations'] is Map) {
      for (final MapEntry<Object?, Object?> e
          in (j['relations']! as Map).entries) {
        relations['${e.key}'] = '${e.value}';
      }
    }
    return EntityRecord(
      id: '${j['id'] ?? ''}',
      kind: '${j['kind'] ?? 'other'}',
      name: '${j['name'] ?? ''}',
      location: '${j['location'] ?? ''}',
      state: state,
      contains: j['contains'] is List
          ? (j['contains']! as List).map((Object? x) => '$x').toList()
          : const <String>[],
      relations: relations,
    );
  }
}

class FactRecord {
  const FactRecord({
    required this.id,
    required this.subject,
    required this.predicate,
    required this.object,
    this.sinceEvent = '',
    this.untilEvent = '',
    this.sourceEvent = '',
    this.visibility = 'hidden',
    this.observers = const <String>[],
    this.evidence = '',
  });

  final String id;
  final String subject;
  final String predicate;
  final String object;
  final String sinceEvent;
  final String untilEvent;
  final String sourceEvent;
  final String visibility;
  final List<String> observers;
  final String evidence;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'subject': subject,
        'predicate': predicate,
        'object': object,
        'sinceEvent': sinceEvent,
        'untilEvent': untilEvent,
        'sourceEvent': sourceEvent,
        'visibility': visibility,
        'observers': observers,
        'evidence': evidence,
      };

  static FactRecord fromJson(Map<String, Object?> j) => FactRecord(
        id: '${j['id'] ?? ''}',
        subject: '${j['subject'] ?? ''}',
        predicate: '${j['predicate'] ?? ''}',
        object: '${j['object'] ?? ''}',
        sinceEvent: '${j['sinceEvent'] ?? ''}',
        untilEvent: '${j['untilEvent'] ?? ''}',
        sourceEvent: '${j['sourceEvent'] ?? ''}',
        visibility: '${j['visibility'] ?? 'hidden'}',
        observers: j['observers'] is List
            ? (j['observers'] as List).map((Object? x) => '$x').toList() : const [],
        evidence: '${j['evidence'] ?? ''}',
      );
}

class InnerEntry {
  const InnerEntry({
    required this.id,
    required this.characterId,
    required this.text,
    this.sourceEvent = '',
    this.visibility = 'self+god',
    this.createdAt = '',
  });

  final String id;
  final String characterId;
  final String text;
  final String sourceEvent;
  final String visibility;
  final String createdAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'characterId': characterId,
        'text': text,
        'sourceEvent': sourceEvent,
        'visibility': visibility,
        'createdAt': createdAt,
      };

  static InnerEntry fromJson(Map<String, Object?> j) => InnerEntry(
        id: '${j['id'] ?? ''}',
        characterId: '${j['characterId'] ?? ''}',
        text: '${j['text'] ?? ''}',
        sourceEvent: '${j['sourceEvent'] ?? ''}',
        visibility: '${j['visibility'] ?? 'self+god'}',
        createdAt: '${j['createdAt'] ?? ''}',
      );
}

Map<String, Object?> worldEventToJson(WorldEvent e) => <String, Object?>{
      'id': e.id,
      'uid': e.uid,
      'kind': e.kind.name,
      'content': e.content,
      'actor': e.actor,
      'target': e.target,
      'channel': e.delivery.channel.name,
      'form': e.delivery.form,
      'audience': e.delivery.audience.name,
      'linkMembers': e.linkMembers,
      'deliveryNote': e.deliveryNote,
      'distanceNote': e.distanceNote,
      'manner': e.manner,
      'segments': <Object?>[
        for (final EventSegment s in e.segments) _eventSegmentToJson(s),
      ],
      'effects': e.effects,
      'witnesses': <Object?>[
        for (final Witness w in e.witnesses) _witnessToJson(w),
      ],
      'publicText': e.publicText,
      'godNote': e.godNote,
      'attachments': e.attachmentIds,
      'status': e.status.name,
      'source': e.source,
      'placeId': e.placeId,
      'timeLabel': e.timeLabel,
      'branchId': e.branchId,
      'outcome': e.outcome,
      'result': e.result,
      'observations': e.observations,
      'observationsResolved': e.observationsResolved,
      'witnessesResolved': e.witnessesResolved,
      'receivedBy': e.receivedBy,
      'turnIndex': e.turnIndex,
      'duration': e.duration,
      'stateChanges': e.stateChanges,
    };

Map<String, Object?> _eventSegmentToJson(EventSegment s) => <String, Object?>{
      'kind': s.kind.name,
      'text': s.text,
      'target': s.target,
      'channel': s.delivery.channel.name,
      'form': s.delivery.form,
      'audience': s.delivery.audience.name,
      'perceivable_by': s.perceivableBy,
    };

EventSegment _eventSegmentFromJson(Map<String, Object?> j) => EventSegment(
      kind: '${j['kind']}' == 'speech'
          ? WorldEventKind.speech
          : WorldEventKind.action,
      text: '${j['text'] ?? ''}',
      target: '${j['target'] ?? ''}'.trim().isEmpty
          ? null
          : '${j['target']}'.trim(),
      delivery: Delivery(
        channel: deliveryChannelOf('${j['channel'] ?? 'other'}'),
        form: '${j['form'] ?? 'other'}',
        audience: audienceOf('${j['audience'] ?? 'unknown'}'),
      ),
      perceivableBy: j['perceivable_by'] is List
          ? (j['perceivable_by']! as List)
              .map((Object? x) => '$x')
              .toList()
          : const <String>[],
    );

Map<String, Object?> _witnessToJson(Witness w) => <String, Object?>{
      'characterId': w.characterId,
      'modality': w.modality,
      'content': w.content,
    };

Witness _witnessFromJson(Map<String, Object?> j) => Witness(
      characterId: '${j['characterId'] ?? ''}',
      modality: '${j['modality'] ?? ''}',
      content: '${j['content'] ?? ''}',
    );

WorldEvent worldEventFromJson(Map<String, Object?> j) {
  final String target = '${j['target'] ?? ''}'.trim();
  final Object? rawLinks = j['linkMembers'];
  final String actor = '${j['actor'] ?? ''}';
  final String rawKind = '${j['kind'] ?? ''}'.trim();
  final String rawContent = '${j['content'] ?? ''}';
  WorldEventKind kind;
  String content;
  if (rawKind == 'speech' || rawKind == 'action') {
    kind = rawKind == 'speech'
        ? WorldEventKind.speech
        : WorldEventKind.action;
    content = rawContent;
  } else {
    // 旧快照只存了 summary；这里兼容读回。
    final String summary = '${j['summary'] ?? ''}'.trim();
    final int speechAt = summary.indexOf('说：');
    if (speechAt >= 0) {
      kind = WorldEventKind.speech;
      content = summary.substring(speechAt + 2);
    } else {
      kind = WorldEventKind.action;
      final String who = actor.replaceFirst('char:', '');
      content = who.isNotEmpty && summary.startsWith(who)
          ? summary.substring(who.length)
          : summary;
    }
  }
  final String rawStatus = '${j['status'] ?? 'accepted'}';
  final WorldEventStatus status = switch (rawStatus) {
    'proposed' => WorldEventStatus.proposed,
    'rejected' => WorldEventStatus.rejected,
    _ => WorldEventStatus.accepted,
  };
  final List<EventSegment> segments = <EventSegment>[];
  if (j['segments'] is List) {
    for (final Object? item in j['segments']! as List) {
      if (item is Map) {
        segments.add(_eventSegmentFromJson(item.cast<String, Object?>()));
      }
    }
  }
  final List<Witness> witnesses = <Witness>[];
  if (j['witnesses'] is List) {
    for (final Object? item in j['witnesses']! as List) {
      if (item is Map) {
        witnesses.add(_witnessFromJson(item.cast<String, Object?>()));
      }
    }
  }
  final List<Map<String, Object?>> effects = <Map<String, Object?>>[];
  if (j['effects'] is List) {
    for (final Object? item in j['effects']! as List) {
      if (item is Map) effects.add(item.cast<String, Object?>());
    }
  }
  return WorldEvent(
    id: '${j['id'] ?? ''}',
    uid: '${j['uid'] ?? ''}',
    kind: kind,
    content: content,
    actor: actor,
    target: target.isEmpty ? null : target,
    delivery: Delivery(
      channel: deliveryChannelOf('${j['channel'] ?? 'other'}'),
      form: '${j['form'] ?? 'other'}',
      audience: audienceOf('${j['audience'] ?? j['range'] ?? 'unknown'}'),
    ),
    linkMembers: rawLinks is List
        ? rawLinks.map((Object? x) => '$x').toList()
        : const <String>[],
    deliveryNote: '${j['deliveryNote'] ?? j['delivery_note'] ?? ''}',
    distanceNote: '${j['distanceNote'] ?? j['distance_note'] ?? ''}',
    manner: '${j['manner'] ?? ''}',
    segments: segments,
    effects: effects,
    witnesses: witnesses,
    publicText: '${j['publicText'] ?? ''}',
    godNote: '${j['godNote'] ?? ''}',
    attachmentIds: j['attachments'] is List
        ? (j['attachments']! as List).map((Object? x) => '$x').toList()
        : const <String>[],
    status: status,
    source: '${j['source'] ?? 'unknown'}',
    placeId: '${j['placeId'] ?? ''}',
    timeLabel: '${j['timeLabel'] ?? ''}',
    branchId: '${j['branchId'] ?? 'main'}',
    outcome: '${j['outcome'] ?? ''}',
    observationsResolved: j['observationsResolved'] == true,
    result: '${j['result'] ?? ''}',
    observations: j['observations'] is Map
        ? (j['observations'] as Map).map((Object? k, Object? v) => MapEntry('$k', '$v'))
        : const <String, String>{},
    witnessesResolved: j['witnessesResolved'] == true ||
        (j['witnesses'] is List && (j['witnesses'] as List).isNotEmpty),
    receivedBy: j['receivedBy'] is List
        ? (j['receivedBy'] as List).map((Object? x) => '$x').toList() : const [],
    turnIndex: (j['turnIndex'] as num?)?.toInt() ?? 0,
    duration: '${j['duration'] ?? 'brief'}',
    stateChanges: j['stateChanges'] is Map
        ? Map<String, Object?>.from(j['stateChanges'] as Map) : const {},
  );
}


