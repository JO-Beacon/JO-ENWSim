import 'character_memory.dart';

/// CH_MEMORY_WRITE Agent 的一条记忆操作。只描述“想做什么”，不直接写存储。
class MemoryOperation {
  const MemoryOperation({
    required this.op,
    this.memoryId = '',
    this.memoryIds = const <String>[],
    this.text = '',
    this.kind = MemoryKind.episodic,
    this.sourceEvents = const <String>[],
    this.sourceMemories = const <String>[],
    this.attention = '',
    this.salience = '',
  });

  final String op;
  final String memoryId;
  final List<String> memoryIds;
  final String text;
  final MemoryKind kind;
  final List<String> sourceEvents;
  final List<String> sourceMemories;
  final String attention;
  final String salience;

  static MemoryOperation? fromJson(Map<String, Object?> j) {
    final String op = '${j['op'] ?? ''}'.trim();
    if (op.isEmpty) return null;
    return MemoryOperation(
      op: op,
      memoryId: '${j['memory_id'] ?? ''}'.trim(),
      memoryIds: _list(j['memory_ids']),
      text: '${j['text'] ?? ''}'.trim(),
      kind: memoryKindByName('${j['kind'] ?? 'episodic'}'),
      sourceEvents: _list(j['source_events']),
      sourceMemories: _list(j['source_memories']),
      attention: '${j['attention'] ?? ''}'.trim(),
      salience: '${j['salience'] ?? ''}'.trim(),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'op': op,
        if (memoryId.isNotEmpty) 'memory_id': memoryId,
        if (memoryIds.isNotEmpty) 'memory_ids': memoryIds,
        if (text.isNotEmpty) 'text': text,
        'kind': kind.name,
        if (sourceEvents.isNotEmpty) 'source_events': sourceEvents,
        if (sourceMemories.isNotEmpty) 'source_memories': sourceMemories,
        if (attention.isNotEmpty) 'attention': attention,
        if (salience.isNotEmpty) 'salience': salience,
      };

  static List<String> _list(Object? raw) => raw is List
      ? <String>[for (final Object? x in raw) '$x'.trim()]
          .where((String x) => x.isNotEmpty)
          .toList()
      : const <String>[];
}

class MemoryAgentException implements Exception {
  const MemoryAgentException(this.errors);

  final List<String> errors;

  @override
  String toString() => 'CH_MEMORY_WRITE 记忆操作不合格：${errors.join('；')}';
}

/// 校验并应用一批 CH_MEMORY_WRITE 操作。任何一条不合格时整批不写。
List<CharacterMemory> applyMemoryOperations({
  required String characterId,
  required List<CharacterMemory> current,
  required List<MemoryOperation> operations,
  required Set<String> allowedEventIds,
}) {
  final List<String> errors = <String>[];
  if (current.any((CharacterMemory m) => m.characterId != characterId)) {
    throw const MemoryAgentException(<String>['记忆集合包含其他角色的条目']);
  }
  final Map<String, CharacterMemory> working = <String, CharacterMemory>{
    for (final CharacterMemory m in current) m.id: m,
  };
  final Set<String> touched = <String>{};

  for (int i = 0; i < operations.length; i++) {
    final MemoryOperation op = operations[i];
    final String prefix = '第 ${i + 1} 条 ${op.op}';
    final List<String> targets = <String>[
      if (op.op != 'encode' && op.op != 'compress') op.memoryId,
      if (op.op == 'compress') ...op.memoryIds,
      ...op.sourceMemories,
    ];
    if (targets.any((String id) => working[id] == null ||
        working[id]!.state == MemoryState.archived ||
        working[id]!.visibility != 'self')) {
      errors.add('$prefix：目标不存在或不在允许写入的活动记忆中');
      continue;
    }
    switch (op.op) {
      case 'encode':
        if (op.text.isEmpty) errors.add('$prefix：text 为空');
        final bool needsEvents =
            op.kind == MemoryKind.episodic ||
                op.kind == MemoryKind.testimony;
        if (needsEvents && op.sourceEvents.isEmpty) {
          errors.add('$prefix：缺少 source_events');
        }
        for (final String id in op.sourceEvents) {
          if (!allowedEventIds.contains(id)) {
            errors.add('$prefix：事件 $id 不在本轮 CH_PERCEIVE 允许范围');
          }
        }
        if (op.sourceMemories.any((String id) => !working.containsKey(id))) {
          errors.add('$prefix：source_memories 不属于该角色');
        }
        if (errors.isNotEmpty) break;
        final CharacterMemory created = CharacterMemory(
          id: newCharacterMemoryId(),
          characterId: characterId,
          text: op.text,
          kind: op.kind,
          origin: MemoryOrigin.model,
          sourceEvents: op.sourceEvents,
          sourceMemories: op.sourceMemories,
          attention: op.attention,
          salience: op.salience,
          state: MemoryState.fresh,
          createdAt: DateTime.now().toIso8601String(),
          updatedAt: DateTime.now().toIso8601String(),
        );
        working[created.id] = created;
        touched.add(created.id);
        break;
      case 'reinforce':
        final CharacterMemory? old = working[op.memoryId];
        if (old == null) {
          errors.add('$prefix：memory_id 不存在或不属于该角色');
          break;
        }
        if (old.state == MemoryState.archived) {
          errors.add('$prefix：不能 reinforce 已归档记忆');
          break;
        }
        for (final String id in op.sourceEvents) {
          if (!allowedEventIds.contains(id)) {
            errors.add('$prefix：事件 $id 不在本轮 CH_PERCEIVE 允许范围');
          }
        }
        if (errors.isNotEmpty) break;
        working[old.id] = old.copyWith(
          text: op.text.isEmpty ? old.text : op.text,
          sourceEvents: <String>{
            ...old.sourceEvents,
            ...op.sourceEvents,
          }.toList(),
          state: MemoryState.reinforced,
          updatedAt: DateTime.now().toIso8601String(),
          version: old.version + 1,
        );
        touched.add(old.id);
        break;
      case 'compress':
        if (op.memoryIds.toSet().length < 2 ||
            op.memoryIds.toSet().length != op.memoryIds.length) {
          errors.add('$prefix：至少需要两条来源记忆');
          break;
        }
        final List<CharacterMemory> sources = <CharacterMemory>[];
        for (final String id in op.memoryIds) {
          final CharacterMemory? m = working[id];
          if (m == null) {
            errors.add('$prefix：memory_id $id 不存在或不属于该角色');
          } else {
            sources.add(m);
          }
        }
        if (op.text.isEmpty) errors.add('$prefix：text 为空');
        if (errors.isNotEmpty) break;
        final Set<String> events = <String>{
          for (final CharacterMemory m in sources) ...m.sourceEvents,
        };
        final CharacterMemory summary = CharacterMemory(
          id: newCharacterMemoryId(),
          characterId: characterId,
          text: op.text,
          kind: MemoryKind.summary,
          origin: MemoryOrigin.model,
          sourceEvents: events.toList(),
          sourceMemories: op.memoryIds,
          attention: op.attention,
          salience: op.salience,
          state: MemoryState.compressed,
          createdAt: DateTime.now().toIso8601String(),
          updatedAt: DateTime.now().toIso8601String(),
        );
        for (final CharacterMemory m in sources) {
          working[m.id] = m.copyWith(
            state: MemoryState.archived,
            archiveRecallable: true,
            updatedAt: DateTime.now().toIso8601String(),
            version: m.version + 1,
          );
        }
        working[summary.id] = summary;
        touched.add(summary.id);
        for (final CharacterMemory m in sources) {
          touched.add(m.id);
        }
        break;
      case 'reinterpret':
        final CharacterMemory? old = working[op.memoryId];
        if (old == null) {
          errors.add('$prefix：memory_id 不存在或不属于该角色');
          break;
        }
        if (op.text.isEmpty) errors.add('$prefix：text 为空');
        if (errors.isNotEmpty) break;
        working[old.id] = old.copyWith(
          text: op.text,
          state: MemoryState.reinterpreted,
          updatedAt: DateTime.now().toIso8601String(),
          version: old.version + 1,
        );
        touched.add(old.id);
        break;
      case 'archive':
        final CharacterMemory? old = working[op.memoryId];
        if (old == null) {
          errors.add('$prefix：memory_id 不存在或不属于该角色');
          break;
        }
        working[old.id] = old.copyWith(
          state: MemoryState.archived,
          archiveRecallable: false,
          updatedAt: DateTime.now().toIso8601String(),
          version: old.version + 1,
        );
        touched.add(old.id);
        break;
      default:
        errors.add('$prefix：不支持的 op');
    }
  }

  if (errors.isNotEmpty) throw MemoryAgentException(errors);
  // 保持原有顺序；新条目追加到末尾。
  final List<CharacterMemory> out = <CharacterMemory>[];
  final Set<String> emitted = <String>{};
  for (final CharacterMemory m in current) {
    final CharacterMemory? next = working[m.id];
    if (next != null && emitted.add(m.id)) out.add(next);
  }
  for (final MapEntry<String, CharacterMemory> e in working.entries) {
    if (emitted.add(e.key)) out.add(e.value);
  }
  return out;
}
