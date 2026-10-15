// 记忆：上帝一份，每个角色各一份。
//
// 现在先做**孤立的**：只是一份数据加一套界面，不接入 A / B 的回合流程。
//
// 两种记忆不共用：
//   - 角色记忆：每个角色一份（含玩家角色），**受信息隔离约束**
//   - 上帝记忆：A 的记忆，**不受信息隔离约束**
// 在数据里两者同构，用 ownerId 区分：空 = 上帝。

/// 一条记忆的来源。
///
/// 现在只有“手动”是真的（用户自己增 / 改 / 删）；
/// 另外两种是留给以后模型接入用的，先摆着，不假装已经能用。
enum MemorySource {
  manual('手动'),
  model('模型写入'),
  digest('后台整理');

  const MemorySource(this.label);

  final String label;

  static MemorySource byName(String s) => MemorySource.values.firstWhere(
        (MemorySource v) => v.name == s,
        orElse: () => MemorySource.manual,
      );
}

/// 一条记忆。
///
/// 内容是一条**自包含的陈述**（第三人称），不依赖上下文也能读懂。
class MemoryEntry {
  const MemoryEntry({
    required this.id,
    required this.content,
    this.kind = '',
    this.source = MemorySource.manual,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;

  /// 内容
  final String content;

  /// 类型。**自由文本**：不预设分类，用的人自己写。
  final String kind;

  /// 来源
  final MemorySource source;

  final DateTime createdAt;
  final DateTime updatedAt;

  MemoryEntry copyWith({
    String? content,
    String? kind,
    MemorySource? source,
    DateTime? updatedAt,
  }) =>
      MemoryEntry(
        id: id,
        content: content ?? this.content,
        kind: kind ?? this.kind,
        source: source ?? this.source,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'content': content,
        'kind': kind,
        'source': source.name,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  static MemoryEntry fromJson(Map<String, Object?> j) {
    final DateTime now = DateTime.now();
    return MemoryEntry(
      id: '${j['id'] ?? ''}',
      content: '${j['content'] ?? ''}',
      kind: '${j['kind'] ?? ''}',
      source: MemorySource.byName('${j['source'] ?? ''}'),
      createdAt: DateTime.tryParse('${j['createdAt'] ?? ''}') ?? now,
      updatedAt: DateTime.tryParse('${j['updatedAt'] ?? ''}') ?? now,
    );
  }
}

/// 一份记忆簿。ownerId 为空 = **上帝记忆**。
class MemoryBook {
  const MemoryBook({
    required this.ownerId,
    this.entries = const <MemoryEntry>[],
  });

  /// 谁的记忆。空 = 上帝（A）。
  final String ownerId;

  final List<MemoryEntry> entries;

  bool get isGod => ownerId.trim().isEmpty;

  MemoryBook copyWith({List<MemoryEntry>? entries}) =>
      MemoryBook(ownerId: ownerId, entries: entries ?? this.entries);

  Map<String, Object?> toJson() => <String, Object?>{
        'ownerId': ownerId,
        'entries': entries.map((MemoryEntry e) => e.toJson()).toList(),
      };

  static MemoryBook fromJson(Map<String, Object?> j) {
    final List<dynamic> raw =
        (j['entries'] as List<dynamic>?) ?? const <dynamic>[];
    return MemoryBook(
      ownerId: '${j['ownerId'] ?? ''}',
      entries: raw
          .whereType<Map<String, dynamic>>()
          .map((Map<String, dynamic> m) =>
              MemoryEntry.fromJson(m.cast<String, Object?>()))
          .toList(),
    );
  }
}

/// 新记忆的 id。
String newMemoryId() => 'm${DateTime.now().microsecondsSinceEpoch}';

/// 新条目（用现在的时间）。
MemoryEntry newMemoryEntry({
  String content = '',
  String kind = '',
  MemorySource source = MemorySource.manual,
}) {
  final DateTime now = DateTime.now();
  return MemoryEntry(
    id: newMemoryId(),
    content: content,
    kind: kind,
    source: source,
    createdAt: now,
    updatedAt: now,
  );
}
