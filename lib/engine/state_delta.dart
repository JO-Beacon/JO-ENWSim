// 一回合的状态变化（state_delta）
//
// 伤势不做“程度打分”。只记录两类东西：
//   1. 事实：谁、哪个部位、什么伤、怎么来的、处理过没有、还在不在流血；
//   2. 功能限制：这个角色现在能/不能/不确定做哪个动作。
//
// CH_ACT 写非对抗、可观察的变化；GM_RESOLVE_ACTION 写对抗行动的结果。SYS_RECORD 只按 delta 改下一份 TurnState。

enum ConstraintState { can, cannot, uncertain }

class InjuryFact {
  const InjuryFact({
    required this.who,
    required this.part,
    required this.kind,
    this.cause = '',
    this.treatment = '',
    this.note = '',
  });

  final String who;
  final String part;

  /// 刀伤 / 骨折 / 扭伤 / 烧伤 / 擦伤 / 内出血 / 其他
  final String kind;
  final String cause;
  final String treatment;
  final String note;

  String get key => '$who|$part|$kind';

  Map<String, Object?> toJson() => <String, Object?>{
        'who': who,
        'part': part,
        'kind': kind,
        if (cause.isNotEmpty) 'cause': cause,
        if (treatment.isNotEmpty) 'treatment': treatment,
        if (note.isNotEmpty) 'note': note,
      };

  static InjuryFact fromJson(Map<String, Object?> j) {
    final String rawKind =
        '${j['injury_kind'] ?? j['wound_kind'] ?? j['kind'] ?? ''}'.trim();
    return InjuryFact(
      who: _name('${j['who'] ?? j['id'] ?? ''}'),
      part: '${j['part'] ?? ''}'.trim(),
      kind: rawKind == 'injure' ? '' : rawKind,
      cause: '${j['cause'] ?? ''}'.trim(),
      treatment: '${j['treatment'] ?? ''}'.trim(),
      note: '${j['note'] ?? ''}'.trim(),
    );
  }
}

class FunctionalConstraint {
  const FunctionalConstraint({
    required this.who,
    required this.capability,
    required this.state,
    this.reason = '',
  });

  final String who;

  /// use_left_arm / use_right_arm / run / stand / speak / cast / act ...
  final String capability;
  final ConstraintState state;
  final String reason;

  String get key => '$who|$capability';

  Map<String, Object?> toJson() => <String, Object?>{
        'who': who,
        'capability': capability,
        'state': state.name,
        if (reason.isNotEmpty) 'reason': reason,
      };

  static FunctionalConstraint fromJson(Map<String, Object?> j) {
    final String raw = '${j['state'] ?? ''}'.trim();
    final ConstraintState state = switch (raw) {
      'can' => ConstraintState.can,
      'cannot' => ConstraintState.cannot,
      'uncertain' => ConstraintState.uncertain,
      _ => ConstraintState.uncertain,
    };
    return FunctionalConstraint(
      who: _name('${j['who'] ?? j['id'] ?? ''}'),
      capability: '${j['capability'] ?? j['action'] ?? ''}'.trim(),
      state: state,
      reason: '${j['reason'] ?? ''}'.trim(),
    );
  }
}

class StateItemDelta {
  const StateItemDelta({
    required this.kind,
    required this.itemId,
    this.from,
    this.to,
    this.by,
    this.place,
  });

  /// take / give / drop / steal
  final String kind;
  final String itemId;
  final String? from;
  final String? to;
  final String? by;
  final String? place;

  Map<String, Object?> toJson() => <String, Object?>{
        'kind': kind,
        'item_id': itemId,
        if (from != null) 'from': from,
        if (to != null) 'to': to,
        if (by != null) 'by': by,
        if (place != null) 'place': place,
      };

  static StateItemDelta fromJson(Map<String, Object?> j) => StateItemDelta(
        kind: '${j['kind'] ?? ''}',
        itemId: '${j['item_id'] ?? ''}',
        from: _nullableName(j['from']),
        to: _nullableName(j['to']),
        by: _nullableName(j['by']),
        place: _nullableName(j['place']),
      );
}

class StateDelta {
  const StateDelta({
    this.moves = const <String, String>{},
    this.injuries = const <InjuryFact>[],
    this.constraints = const <FunctionalConstraint>[],
    this.items = const <StateItemDelta>[],
    this.facts = const <StateFactDelta>[],
    this.discoveries = const <EntityDiscovery>[],
    this.processes = const <ProcessDelta>[],
  });

  final Map<String, String> moves;
  final List<InjuryFact> injuries;
  final List<FunctionalConstraint> constraints;
  final List<StateItemDelta> items;
  final List<StateFactDelta> facts;
  final List<EntityDiscovery> discoveries;
  final List<ProcessDelta> processes;

  bool get isEmpty =>
      moves.isEmpty && injuries.isEmpty && constraints.isEmpty && items.isEmpty &&
      facts.isEmpty && discoveries.isEmpty && processes.isEmpty;

  static StateDelta combine(Iterable<StateDelta> deltas) => StateDelta(
    moves: <String, String>{for (final StateDelta d in deltas) ...d.moves},
    injuries: <InjuryFact>[for (final StateDelta d in deltas) ...d.injuries],
    constraints: <FunctionalConstraint>[for (final StateDelta d in deltas) ...d.constraints],
    items: <StateItemDelta>[for (final StateDelta d in deltas) ...d.items],
    facts: <StateFactDelta>[for (final StateDelta d in deltas) ...d.facts],
    discoveries: <EntityDiscovery>[for (final StateDelta d in deltas) ...d.discoveries],
    processes: <ProcessDelta>[for (final StateDelta d in deltas) ...d.processes],
  );

  List<Map<String, Object?>> get effectRecords => <Map<String, Object?>>[
    for (final MapEntry<String, String> m in moves.entries)
      <String, Object?>{'kind': 'move', 'who': m.key, 'to': m.value},
    for (final InjuryFact i in injuries)
      <String, Object?>{...i.toJson(), 'kind': 'injure', 'injury_kind': i.kind},
    for (final FunctionalConstraint c in constraints)
      <String, Object?>{...c.toJson(), 'kind': 'constraint'},
    for (final StateItemDelta i in items) i.toJson(),
    for (final StateFactDelta f in facts)
      <String, Object?>{...f.toJson(), 'kind': 'fact'},
    for (final ProcessDelta p in processes)
      <String, Object?>{...p.toJson(), 'kind': 'process'},
  ];

  Map<String, Object?> toJson() => <String, Object?>{
        'move': moves,
        'injure': <Object?>[
          for (final InjuryFact i in injuries) i.toJson(),
        ],
        'constraints': <Object?>[
          for (final FunctionalConstraint c in constraints) c.toJson(),
        ],
        'items': <Object?>[
          for (final StateItemDelta i in items) i.toJson(),
        ],
        'facts': <Object?>[for (final StateFactDelta f in facts) f.toJson()],
        'discoveries': <Object?>[
          for (final EntityDiscovery e in discoveries) e.toJson(),
        ],
        'processes': <Object?>[for (final ProcessDelta p in processes) p.toJson()],
      };

  /// 新提案先严格校验；历史存档仍使用下方的兼容解码。
  static List<String> proposalErrors(Object? raw) {
    if (raw == null) return <String>[];
    if (raw is! Map) return <String>['state_delta 必须是对象或 null'];
    final List<String> errors = <String>[];
    const Map<String, List<String>> required = <String, List<String>>{
      'injure': <String>['who', 'part', 'kind'],
      'constraints': <String>['who', 'capability', 'state'],
      'limits': <String>['who', 'capability', 'state'],
      'items': <String>['kind', 'item_id'],
      'inventory': <String>['kind', 'item_id'],
      'facts': <String>['subject', 'predicate', 'object', 'evidence'],
      'discoveries': <String>['id', 'kind', 'name', 'evidence'],
      'processes': <String>['id', 'place', 'description', 'completion_condition'],
    };
    const Map<String, Set<String>> optional = <String, Set<String>>{
      'injure': <String>{'cause', 'treatment', 'note', 'injury_kind', 'wound_kind'},
      'constraints': <String>{'reason'}, 'limits': <String>{'reason'},
      'items': <String>{'from', 'to', 'by', 'place'},
      'inventory': <String>{'from', 'to', 'by', 'place'},
      'facts': <String>{'visibility', 'observers', 'op'},
      'discoveries': <String>{'location'},
      'processes': <String>{
        'owner', 'kind', 'status', 'destination', 'visibility', 'completion_boundary',
        'next_check_boundary', 'next_check_fact',
      },
    };
    for (final MapEntry<Object?, Object?> entry in raw.entries) {
      final Object? field = entry.key;
      final Object? value = entry.value;
      if (field == 'move') {
        if (value is! Map || value.entries.any((e) =>
            e.key is! String || (e.key as String).trim().isEmpty ||
            e.value is! String || (e.value as String).trim().isEmpty)) {
          errors.add('move 必须是非空角色名到地点名的对象');
        }
        continue;
      }
      final List<String>? keys = required[field];
      if (keys == null) { errors.add('未知状态字段：$field'); continue; }
      if (value is! List) { errors.add('$field 必须是对象数组'); continue; }
      for (int i = 0; i < value.length; i++) {
        final Object? item = value[i];
        if (item is! Map) { errors.add('$field[$i] 必须是对象'); continue; }
        for (final String key in keys) {
          if (item[key] is! String || (item[key] as String).trim().isEmpty) {
            errors.add('$field[$i].$key 必须是非空文本');
          }
        }
        for (final Object? key in item.keys) {
          if (!keys.contains(key) && !optional[field]!.contains(key)) errors.add('未知字段：$field[$i].$key');
          if (key == 'observers') {
            final Object? list = item[key];
            if (list is! List || list.any((x) => x is! String || x.trim().isEmpty)) {
              errors.add('$field[$i].observers 必须是文本数组');
            }
          } else if (item[key] != null && item[key] is! String) {
            errors.add('$field[$i].$key 必须是文本');
          }
        }
        if (<String>{'constraints', 'limits'}.contains(field) &&
            !<String>{'can', 'cannot', 'uncertain'}.contains(item['state'])) {
          errors.add('$field[$i].state 非法');
        }
        if (<String>{'items', 'inventory'}.contains(field) &&
            !<String>{'take', 'give', 'drop', 'steal'}.contains(item['kind'])) {
          errors.add('$field[$i].kind 非法');
        }
        if (field == 'facts' && item.containsKey('op') &&
            !<String>{'set', 'add', 'remove'}.contains(item['op'])) {
          errors.add('$field[$i].op 非法');
        }
      }
    }
    if (raw.containsKey('constraints') && raw.containsKey('limits')) errors.add('constraints 和 limits 不能同时声明');
    if (raw.containsKey('items') && raw.containsKey('inventory')) errors.add('items 和 inventory 不能同时声明');
    return errors;
  }

  /// CH_ACT 的 state_delta：非对抗、可观察的变化。
  static StateDelta fromAction(Object? raw) {
    if (raw is! Map) return const StateDelta();
    final Map<String, Object?> j = raw.cast<String, Object?>();
    final Map<String, String> moves = <String, String>{};
    final Object? rawMoves = j['move'];
    if (rawMoves is Map) {
      for (final MapEntry<Object?, Object?> e in rawMoves.entries) {
        final String who = _name('${e.key}');
        final String place = _name('${e.value}');
        if (who.isNotEmpty && place.isNotEmpty) moves[who] = place;
      }
    }
    final List<InjuryFact> injuries = <InjuryFact>[];
    final Object? rawInjure = j['injure'];
    if (rawInjure is List) {
      for (final Object? item in rawInjure) {
        if (item is Map) {
          final InjuryFact inj =
              InjuryFact.fromJson(item.cast<String, Object?>());
          if (inj.who.isNotEmpty && inj.part.isNotEmpty && inj.kind.isNotEmpty) {
            injuries.add(inj);
          }
        }
      }
    }
    final List<FunctionalConstraint> constraints = <FunctionalConstraint>[];
    final Object? rawConstraints = j['constraints'] ?? j['limits'];
    if (rawConstraints is List) {
      for (final Object? item in rawConstraints) {
        if (item is Map) {
          final FunctionalConstraint c =
              FunctionalConstraint.fromJson(item.cast<String, Object?>());
          if (c.who.isNotEmpty && c.capability.isNotEmpty) constraints.add(c);
        }
      }
    }
    final List<StateItemDelta> items = <StateItemDelta>[];
    final Object? rawItems = j['items'] ?? j['inventory'];
    if (rawItems is List) {
      for (final Object? item in rawItems) {
        if (item is Map) {
          final StateItemDelta d =
              StateItemDelta.fromJson(item.cast<String, Object?>());
          if (d.itemId.isNotEmpty) items.add(d);
        }
      }
    }
    return StateDelta(
      moves: moves,
      injuries: injuries,
      constraints: constraints,
      items: items,
      facts: _objects(j['facts']).map(StateFactDelta.fromJson).toList(),
      discoveries: _objects(j['discoveries']).map(EntityDiscovery.fromJson).toList(),
      processes: _objects(j['processes']).map(ProcessDelta.fromJson).toList(),
    );
  }

  /// GM_RESOLVE_ACTION 的 deltas：对抗行动的结果。
  static StateDelta fromArbiter(Map<String, Object?>? arbitration) {
    if (arbitration == null) return const StateDelta();
    final Object? raw = arbitration['deltas'];
    if (raw is! List) return const StateDelta();
    final Map<String, String> moves = <String, String>{};
    final List<InjuryFact> injuries = <InjuryFact>[];
    final List<FunctionalConstraint> constraints = <FunctionalConstraint>[];
    final List<StateItemDelta> items = <StateItemDelta>[];
    for (final Object? item in raw) {
      if (item is! Map) continue;
      final Map<String, Object?> d = item.cast<String, Object?>();
      final String kind = '${d['kind'] ?? ''}';
      if (kind == 'move') {
        final String who = _name('${d['id'] ?? d['actor'] ?? d['who'] ?? ''}');
        final String to = _name('${d['to'] ?? ''}');
        if (who.isNotEmpty && to.isNotEmpty) moves[who] = to;
      } else if (kind == 'injure') {
        final InjuryFact inj = InjuryFact.fromJson(d);
        if (inj.who.isNotEmpty && inj.part.isNotEmpty && inj.kind.isNotEmpty) {
          injuries.add(inj);
        }
      } else if (kind == 'constraint' || kind == 'limit') {
        final FunctionalConstraint c = FunctionalConstraint.fromJson(d);
        if (c.who.isNotEmpty && c.capability.isNotEmpty) constraints.add(c);
      } else if (kind == 'steal' ||
          kind == 'drop' ||
          kind == 'take' ||
          kind == 'give') {
        final StateItemDelta delta = StateItemDelta.fromJson(d);
        if (delta.itemId.isNotEmpty) items.add(delta);
      }
    }
    return StateDelta(
      moves: moves,
      injuries: injuries,
      constraints: constraints,
      items: items,
      facts: _objects(arbitration['facts']).map(StateFactDelta.fromJson).toList(),
      discoveries: _objects(arbitration['discoveries'])
          .map(EntityDiscovery.fromJson).toList(),
      processes: _objects(arbitration['processes']).map(ProcessDelta.fromJson).toList(),
    );
  }
}

Iterable<Map<String, Object?>> _objects(Object? raw) sync* {
  if (raw is List) {
    for (final Object? item in raw) {
      if (item is Map) yield Map<String, Object?>.from(item);
    }
  }
}

/// 持续有效的世界事实；可知范围与客观成立分开保存。
class StateFactDelta {
  const StateFactDelta({
    required this.subject,
    required this.predicate,
    required this.object,
    required this.evidence,
    this.visibility = 'hidden',
    this.observers = const <String>[],
    this.op = '',
  });

  final String subject;
  final String predicate;
  final String object;
  final String evidence;
  final String visibility;
  final List<String> observers;
  final String op;

  /// 既有连通关系是多值关系；其他属性保持原来的单值设置语义。
  String get operation => op.isEmpty ? (predicate == 'connected_to' ? 'add' : 'set') : op;

  Map<String, Object?> toJson() => <String, Object?>{
    'subject': subject, 'predicate': predicate, 'object': object,
    'evidence': evidence, 'visibility': visibility, 'observers': observers,
    'op': operation,
  };

  static StateFactDelta fromJson(Map<String, Object?> j) => StateFactDelta(
    subject: '${j['subject'] ?? ''}', predicate: '${j['predicate'] ?? ''}',
    object: '${j['object'] ?? ''}', evidence: '${j['evidence'] ?? ''}',
    visibility: '${j['visibility'] ?? 'hidden'}',
    op: '${j['op'] ?? ''}',
    observers: j['observers'] is List
        ? (j['observers'] as List).map((Object? x) => '$x').toList() : const [],
  );
}

/// 新实体须由裁定或环境阶段确认存在，拿取提案不自动创建物品。
class EntityDiscovery {
  const EntityDiscovery({required this.id, required this.kind,
    required this.name, required this.location, required this.evidence});
  final String id;
  final String kind;
  final String name;
  final String location;
  final String evidence;
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id, 'kind': kind, 'name': name, 'location': location, 'evidence': evidence,
  };
  static EntityDiscovery fromJson(Map<String, Object?> j) => EntityDiscovery(
    id: '${j['id'] ?? ''}', kind: '${j['kind'] ?? ''}', name: '${j['name'] ?? ''}',
    location: '${j['location'] ?? ''}', evidence: '${j['evidence'] ?? ''}',
  );
}

/// 世界顺序用回合序号，过程进度用定性状态；未完成的旅行不提前移动。
class ProcessDelta {
  const ProcessDelta({required this.id, required this.place,
    required this.description, required this.completionCondition,
    this.owner = '', this.kind = 'environment', this.status = 'ongoing',
    this.destination = '', this.visibility = 'public', this.completionBoundary = '',
    this.nextCheckBoundary, this.nextCheckFact});
  final String id;
  final String place;
  final String owner;
  final String kind;
  final String status;
  final String description;
  final String completionCondition;
  final String completionBoundary;
  final String? nextCheckBoundary;
  final String? nextCheckFact;
  final String destination;
  final String visibility;
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id, 'place': place, 'owner': owner, 'kind': kind, 'status': status,
    'description': description, 'completion_condition': completionCondition,
    if (completionBoundary.isNotEmpty) 'completion_boundary': completionBoundary,
    if (nextCheckBoundary != null) 'next_check_boundary': nextCheckBoundary,
    if (nextCheckFact != null) 'next_check_fact': nextCheckFact,
    'destination': destination, 'visibility': visibility,
  };
  static ProcessDelta fromJson(Map<String, Object?> j) => ProcessDelta(
    id: '${j['id'] ?? ''}', place: '${j['place'] ?? ''}',
    owner: _name('${j['owner'] ?? ''}'), kind: '${j['kind'] ?? 'environment'}',
    status: '${j['status'] ?? 'ongoing'}', description: '${j['description'] ?? ''}',
    completionCondition: '${j['completion_condition'] ?? ''}',
    completionBoundary: '${j['completion_boundary'] ?? ''}',
    nextCheckBoundary: j['next_check_boundary'] as String?,
    nextCheckFact: j['next_check_fact'] as String?,
    destination: _name('${j['destination'] ?? ''}'),
    visibility: '${j['visibility'] ?? 'public'}',
  );
}

String _name(String raw) {
  return raw.trim().replaceFirst('char:', '').replaceFirst('place:', '');
}

String? _nullableName(Object? raw) {
  final String s = _name('${raw ?? ''}');
  return s.isEmpty ? null : s;
}
