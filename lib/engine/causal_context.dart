import 'dart:convert';

import 'engine_state.dart';
import 'perception.dart';
import 'state_delta.dart';

/// 上帝读取权威事实，角色读取自己可知的投影。
class CausalContext {
  const CausalContext({required this.state, this.rules = '', this.opening = ''});
  final TurnState state;
  final String rules;
  final String opening;

  /// 客观历史窗口独立于交付队列；同回合的多段事件一起保留。
  List<WorldEvent> recentHistory({
    Iterable<WorldEvent> additional = const <WorldEvent>[],
    int maxTurns = 6,
  }) {
    if (maxTurns <= 0) return <WorldEvent>[];
    final List<WorldEvent> history = historyAfterDelivery(
      events: <WorldEvent>[...state.events, ...additional],
    ).where((WorldEvent e) => e.status == WorldEventStatus.accepted).toList();
    final Set<String> turns = <String>{};
    final List<WorldEvent> recent = <WorldEvent>[];
    for (final WorldEvent event in history.reversed) {
      final String turn = event.turnIndex > 0 ? 'turn:${event.turnIndex}' : 'event:${event.id}';
      if (!turns.contains(turn) && turns.length >= maxTurns) break;
      turns.add(turn);
      recent.add(event);
    }
    return recent.reversed.toList();
  }

  /// 从结构化行动收集相关实体，不用当前地点代替整个裁定范围。
  Set<String> actionEntities(Map<String, Object?> action, {String? target}) {
    final Set<String> ids = <String>{};
    void include(String raw) {
      if (raw.isEmpty) return;
      for (final EntityRecord e in state.entities.values) {
        if (e.id == raw || e.name == raw || e.id == 'char:$raw' || e.id == 'place:$raw') {
          ids.add(e.id);
        }
      }
    }
    if (target != null) include(target);
    final StateDelta delta = StateDelta.fromAction(action['state_delta']);
    for (final MapEntry<String, String> move in delta.moves.entries) {
      include(move.key);
      include(move.value);
    }
    for (final StateItemDelta item in delta.items) {
      for (final String? id in <String?>[item.itemId, item.from, item.to, item.by, item.place]) {
        if (id != null) include(id);
      }
    }
    for (final StateFactDelta fact in delta.facts) { include(fact.subject); }
    for (final ProcessDelta process in delta.processes) {
      for (final String id in <String>[process.id, process.place, process.owner, process.destination]) { include(id); }
    }
    final Object? preconditions = action['preconditions'];
    if (preconditions is List) {
      for (final Object? p in preconditions) {
        if (p is Map) {
          include('${p['subject'] ?? ''}');
          include('${p['object'] ?? ''}');
        }
      }
    }
    final Object? segments = action['segments'];
    if (segments is List) {
      for (final Object? segment in segments) {
        if (segment is Map) include('${segment['target'] ?? ''}');
      }
    }
    return ids;
  }

  Map<String, Object?> forGod(String place, {Iterable<String> involved = const [], bool allEntities = false}) {
    final Set<String> ids = <String>{
      ...involved,
      if (allEntities) ...state.entities.keys,
      'place:$place',
      for (final EntityRecord e in state.entities.values)
        if (e.location == place || e.location == 'place:$place' || e.name == place) e.id,
    };
    // 位置字段允许名称或实体 id，两种写法都要沿着实体关系展开。
    for (final String id in ids.toList()) {
      final EntityRecord? entity = state.entities[id];
      if (entity != null && entity.kind == 'place') ids.add(entity.name);
    }
    // 容器的上下级都属于裁定依据；内层物品不能绕过外层的封闭状态。
    for (int depth = 0; depth < state.entities.length; depth++) {
      final int before = ids.length;
      for (final EntityRecord e in state.entities.values) {
        if (ids.contains(e.location) || ids.contains('char:${e.location}')) ids.add(e.id);
        if (ids.contains(e.id)) {
          ids.addAll(e.contains);
          if (e.kind == 'place') ids.add(e.name);
          for (final String holder in <String>[e.location, 'char:${e.location}', 'place:${e.location}']) {
            if (state.entities.containsKey(holder)) ids.add(holder);
          }
        }
      }
      if (ids.length == before) break;
    }
    return <String, Object?>{
      'world_rules': rules,
      'opening': opening,
      'world_step': state.worldStep,
      'recent_history': <Object?>[
        for (final WorldEvent event in recentHistory()) <String, Object?>{
          'id': event.id, 'turn': event.turnIndex, 'duration': event.duration,
          'place': event.placeId, 'kind': event.kind.name, 'actor': event.actor,
          'target': event.target, 'content': event.content, 'outcome': event.outcome,
          'result': event.result, 'effects': event.effects,
        },
      ],
      'time_rule': 'world_step 只表示共同先后，各动作时长不同；依据 duration 和持续过程判断进度。'
          '未满足完成条件的旅行不能直接到达；其他地点的过程仍在进行，不能因切换地点重置。',
      'entities': <Object?>[
        for (final EntityRecord e in state.entities.values) if (ids.contains(e.id)) e.toJson(),
      ],
      'facts': <Object?>[
        for (final FactRecord f in state.facts)
          if (f.untilEvent.isEmpty && (ids.contains(f.subject) || f.subject == 'player')) f.toJson(),
      ],
      'inventories': state.inventories,
      'locations': state.locations,
      'injuries': <Object?>[for (final i in state.injuries) i.toJson()],
      'constraints': <Object?>[for (final c in state.constraints) c.toJson()],
      'ongoing_processes': <Object?>[
        for (final EntityRecord p in state.ongoingProcesses) p.toJson(),
      ],
    };
  }

  String characterView(String id, NarrativeScene scene) {
    final String name = id.replaceFirst('char:', '');
    final CharacterSnapshot? observer = scene.byId(id);
    if (observer == null) return '';
    final List<String> lines = <String>['当前地点：${state.locations[name] ?? scene.place}'];
    for (final FactRecord f in state.facts) {
      if (f.untilEvent.isNotEmpty) continue;
      final EntityRecord? subject = state.entities[f.subject];
      final bool local = f.subject == 'place:${scene.place}' ||
          subject?.location == scene.place || subject?.location == 'place:${scene.place}';
      final bool known = f.observers.contains(id) || f.observers.contains(name) ||
          (f.visibility == 'self' && f.subject == id) ||
          (f.visibility == 'public' && local);
      if (known) lines.add('${subject?.name ?? f.subject}：${f.predicate}=${f.object}');
    }
    for (final EntityRecord p in state.ongoingProcesses) {
      if (p.state['owner'] == name ||
          (p.state['visibility'] == 'public' && p.location == scene.place)) {
        lines.add('正在进行：${p.name}；完成条件：${p.state['completion_condition']}');
      }
    }
    final Iterable<InnerEntry> ownInner = state.inner.where(
        (InnerEntry entry) => entry.characterId == id || entry.characterId == name);
    for (final InnerEntry inner in ownInner.toList().reversed.take(3).toList().reversed) {
      lines.add('自己的念头：${inner.text}');
    }
    return const PerceptionEngine().localize(lines.join('\n'), observer, scene);
  }

  /// 世界规则和现状在前，逐轮变化的序号和历史在尾部。
  /// 保留原投影的字段顺序，以便旧的现场见闻日志仍能按原键回放。
  static Map<String, Object?> promptOrder(Map<String, Object?> world) =>
      <String, Object?>{
        for (final MapEntry<String, Object?> entry in world.entries)
          if (entry.key != 'world_step' && entry.key != 'recent_history')
            entry.key: entry.value,
        'world_step': world['world_step'],
        'recent_history': world['recent_history'],
      };

  String godText(String place) => jsonEncode(promptOrder(forGod(place)));
}

/// 交付回执独立于记忆；角色可以看过却没有记住。
List<WorldEvent> pendingAfterDelivery({
  required List<WorldEvent> incoming,
  required List<WorldEvent> generated,
  required Map<String, Set<String>> receipts,
}) {
  final List<WorldEvent> result = <WorldEvent>[];
  for (final WorldEvent event in historyAfterDelivery(
      events: <WorldEvent>[...incoming, ...generated], receipts: receipts)) {
    if (event.status != WorldEventStatus.accepted) continue;
    final bool resolved = event.witnessesResolved || event.witnesses.isNotEmpty;
    if (resolved && event.witnesses.every((Witness w) => event.receivedBy.contains(w.characterId))) continue;
    result.add(event);
  }
  return result;
}

/// 历史和待交付队列共享回执，同一事件保留最新字段并合并已交付角色。
List<WorldEvent> historyAfterDelivery({
  required Iterable<WorldEvent> events,
  Map<String, Set<String>> receipts = const <String, Set<String>>{},
}) {
  final Map<String, WorldEvent> result = <String, WorldEvent>{};
  final Map<String, String> identities = <String, String>{};
  for (final WorldEvent event in events) {
    final String identity = '${event.id}|${event.actor}|${event.content}';
    final String key = identities[identity] ?? (event.uid.isEmpty ? identity : event.uid);
    identities[identity] = key;
    final WorldEvent? previous = result[key];
    result[key] = event.copyWith(uid: event.uid.isEmpty ? previous?.uid : event.uid, receivedBy: <String>{
      ...?previous?.receivedBy, ...event.receivedBy,
      ...?receipts[event.id], ...?receipts[event.uid],
    }.toList());
  }
  return result.values.toList();
}
