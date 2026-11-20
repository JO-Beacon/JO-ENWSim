// 角色记忆：第一人称主观笔记，不是事件副本。
//
// 只做数据与 JSON 编解码；写不写、什么时候写由引擎决定。
// 来源事件必须是真实事件，这一步的校验在程序侧做，不在这个类里。

import 'perception.dart';

enum MemoryKind { episodic, testimony, impression, emotion, summary, note }

enum MemoryState { fresh, reinforced, compressed, reinterpreted, archived }

enum MemoryOrigin { model, program, manual }

class CharacterMemory {
  const CharacterMemory({
    required this.id,
    required this.characterId,
    required this.text,
    this.kind = MemoryKind.episodic,
    this.origin = MemoryOrigin.model,
    this.sourceEvents = const <String>[],
    this.sourceMemories = const <String>[],
    this.attention = '',
    this.salience = '',
    this.state = MemoryState.fresh,
    this.revisionOf = '',
    this.visibility = 'self',
    this.createdAt = '',
    this.updatedAt = '',
    this.version = 1,
    this.archiveRecallable = false,
  });

  final String id;

  /// char:<角色名>。
  final String characterId;

  /// 第一人称主观笔记。
  final String text;
  final MemoryKind kind;
  final MemoryOrigin origin;

  /// 来源事件 id；手动笔记可以为空。
  final List<String> sourceEvents;

  /// 由哪些旧记忆压缩 / 改写而来。
  final List<String> sourceMemories;

  /// 当时为什么注意到；定性文本。
  final String attention;

  /// 这个角色觉得多重要；定性文本。
  final String salience;
  final MemoryState state;

  /// 被改写的旧条目 id；空 = 不是改写来的。
  final String revisionOf;

  /// self；目前只给该角色自己的上下文，不写 self+god。
  final String visibility;
  final String createdAt;
  final String updatedAt;

  /// 同一 memory_id 的版本号；新写入从 1 开始。
  final int version;

  /// 归档原文是否允许由角色主动查阅；缺省停用。
  final bool archiveRecallable;

  CharacterMemory copyWith({
    String? text,
    MemoryKind? kind,
    MemoryOrigin? origin,
    List<String>? sourceEvents,
    List<String>? sourceMemories,
    String? attention,
    String? salience,
    MemoryState? state,
    String? revisionOf,
    String? visibility,
    String? updatedAt,
    int? version,
    bool? archiveRecallable,
  }) => CharacterMemory(
    id: id,
    characterId: characterId,
    text: text ?? this.text,
    kind: kind ?? this.kind,
    origin: origin ?? this.origin,
    sourceEvents: sourceEvents ?? this.sourceEvents,
    sourceMemories: sourceMemories ?? this.sourceMemories,
    attention: attention ?? this.attention,
    salience: salience ?? this.salience,
    state: state ?? this.state,
    revisionOf: revisionOf ?? this.revisionOf,
    visibility: visibility ?? this.visibility,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    version: version ?? this.version,
    archiveRecallable: archiveRecallable ?? this.archiveRecallable,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'characterId': characterId,
    'text': text,
    'kind': kind.name,
    'origin': origin.name,
    'sourceEvents': sourceEvents,
    'sourceMemories': sourceMemories,
    'attention': attention,
    'salience': salience,
    'state': state.name,
    'revisionOf': revisionOf,
    'visibility': visibility,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'version': version,
    if (archiveRecallable) 'archiveRecallable': true,
  };

  static CharacterMemory fromJson(Map<String, Object?> j) => CharacterMemory(
    id: '${j['id'] ?? ''}',
    characterId: '${j['characterId'] ?? ''}',
    text: '${j['text'] ?? ''}',
    kind: memoryKindByName('${j['kind'] ?? ''}'),
    origin: memoryOriginByName('${j['origin'] ?? ''}'),
    sourceEvents: _stringList(j['sourceEvents']),
    sourceMemories: _stringList(j['sourceMemories']),
    attention: '${j['attention'] ?? ''}',
    salience: '${j['salience'] ?? ''}',
    state: memoryStateByName('${j['state'] ?? ''}'),
    revisionOf: '${j['revisionOf'] ?? ''}',
    visibility: '${j['visibility'] ?? 'self'}',
    createdAt: '${j['createdAt'] ?? ''}',
    updatedAt: '${j['updatedAt'] ?? ''}',
    version: (j['version'] is num) ? (j['version'] as num).toInt() : 1,
    archiveRecallable: j['archiveRecallable'] == true,
  );
}

MemoryKind memoryKindByName(String name) => MemoryKind.values.firstWhere(
  (MemoryKind v) => v.name == name,
  orElse: () => MemoryKind.episodic,
);

MemoryState memoryStateByName(String name) => MemoryState.values.firstWhere(
  (MemoryState v) => v.name == name,
  orElse: () => MemoryState.fresh,
);

MemoryOrigin memoryOriginByName(String name) => MemoryOrigin.values.firstWhere(
  (MemoryOrigin v) => v.name == name,
  orElse: () => MemoryOrigin.model,
);

List<String> _stringList(Object? raw) {
  if (raw is! List) return const <String>[];
  return <String>[for (final Object? item in raw) '$item'];
}

int _characterMemorySeq = 0;

String newCharacterMemoryId() =>
    'cm-${DateTime.now().microsecondsSinceEpoch}-${_characterMemorySeq++}';

/// 一个世界的角色记忆。按角色分组只是查询视图，存储仍是整本。
class MemoryStore {
  MemoryStore([Iterable<CharacterMemory> initial = const <CharacterMemory>[]]) {
    restore(initial);
  }

  final List<CharacterMemory> _entries = <CharacterMemory>[];

  void restore(Iterable<CharacterMemory> entries) {
    _entries
      ..clear()
      ..addAll(entries);
  }

  List<CharacterMemory> allEntries() =>
      List<CharacterMemory>.unmodifiable(_entries);

  List<CharacterMemory> forCharacter(String characterId) => <CharacterMemory>[
    for (final CharacterMemory m in _entries)
      if (m.characterId == characterId) m,
  ];

  List<CharacterMemory> activeForCharacter(
    String characterId,
  ) => <CharacterMemory>[
    for (final CharacterMemory m in _entries)
      if (m.characterId == characterId && m.state != MemoryState.archived &&
          m.visibility == 'self') m,
  ];

  /// 给 CH_PERCEIVE / CH_ACT 的“你记得的”上下文；只读这个角色自己的记忆。
  /// [onlyIds] 非空时只给这些 id（CH_MEMORY_WRITE 召回结果），但仍强制检查归属。
  String contextFor(
    String characterId,
    NarrativeScene scene, {
    Set<String>? onlyIds,
  }) {
    final CharacterSnapshot? c = scene.byId(characterId);
    if (c == null) return '';
    final StringBuffer b = StringBuffer();
    b.writeln('【${c.name}】');
    if (c.distanceNote.trim().isNotEmpty) {
      b.writeln('【距离】${c.distanceNote.trim()}');
    }
    b.writeln('【我记得】');
    final List<CharacterMemory> entries = <CharacterMemory>[
      for (final CharacterMemory m in activeForCharacter(characterId))
        if (onlyIds == null || onlyIds.contains(m.id)) m,
    ];
    if (entries.isEmpty) b.writeln('- （还没有）');
    for (final CharacterMemory m in entries) {
      b.writeln('- ${m.text}');
      if (m.attention.trim().isNotEmpty) {
        b.writeln('  （当时在意：${m.attention.trim()}）');
      }
    }
    return b.toString();
  }

  CharacterMemory? byId(String id) {
    for (final CharacterMemory m in _entries) {
      if (m.id == id) return m;
    }
    return null;
  }

  void add(CharacterMemory memory) {
    if (memory.id.trim().isEmpty) {
      throw ArgumentError('记忆 id 不能为空');
    }
    if (memory.characterId.trim().isEmpty) {
      throw ArgumentError('记忆 characterId 不能为空');
    }
    if (byId(memory.id) != null) {
      throw ArgumentError('记忆 id 重复：${memory.id}');
    }
    _entries.add(memory);
  }

  void replace(CharacterMemory memory) {
    final int i = _entries.indexWhere((CharacterMemory m) => m.id == memory.id);
    if (i < 0) {
      throw ArgumentError('没有这条记忆：${memory.id}');
    }
    _entries[i] = memory;
  }

  /// 有同 id 就替换成新版本，没有就追加。
  void put(CharacterMemory memory) {
    final int i = _entries.indexWhere((CharacterMemory m) => m.id == memory.id);
    if (i < 0) {
      add(memory);
    } else {
      _entries[i] = memory;
    }
  }

  /// 用某个角色的新条目列表替换该角色旧条目；其他角色不动。
  void restoreCharacter(
    String characterId,
    Iterable<CharacterMemory> entries,
  ) {
    _entries.removeWhere((CharacterMemory m) => m.characterId == characterId);
    _entries.addAll(entries);
  }

  int count(String characterId) => forCharacter(characterId).length;
}
