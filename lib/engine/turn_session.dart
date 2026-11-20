// 一回合的可恢复日志。
//
// 这里不保存 Dart 对象，只保存：
//   - 玩家输入；
//   - 每个 AI 步骤实际返回的原始 JSON；
//   - 玩家对 AI 求助问题的回答。
//
// 恢复时优先从最后一个 checkpoint 直接续跑；没有 checkpoint 的旧 session
// 仍按 AI 返回回放，只补跑缺失的那一步。程序步骤（C/R 等）仍只执行一次。

class TurnJournal {
  TurnJournal({
    Map<String, String>? responses,
    Map<String, String>? answers,
    Map<String, String>? questions,
    Map<String, String>? kinds,
    Map<String, String>? codes,
  })  : responses = responses ?? <String, String>{},
        answers = answers ?? <String, String>{},
        questions = questions ?? <String, String>{},
        kinds = kinds ?? <String, String>{},
        codes = codes ?? <String, String>{};

  /// key = step#序号；按角色缓存的步骤是 step#角色#序号。
  /// value = 模型返回的原始文本。
  final Map<String, String> responses;

  /// key = 同一个 step#序号，value = 玩家回答。
  final Map<String, String> answers;
  final Map<String, String> questions;
  final Map<String, String> kinds;
  final Map<String, String> codes;

  bool get isEmpty => responses.isEmpty && answers.isEmpty;

  /// 丢掉某一步的所有回放缓存，让下一次恢复重新请求。
  void clearStep(String step) {
    final String prefix = '$step#';
    responses.removeWhere((String k, String _) => k.startsWith(prefix));
    answers.removeWhere((String k, String _) => k.startsWith(prefix));
    questions.removeWhere((String k, String _) => k.startsWith(prefix));
    kinds.removeWhere((String k, String _) => k.startsWith(prefix));
    codes.removeWhere((String k, String _) => k.startsWith(prefix));
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'responses': responses,
        'answers': answers,
        'questions': questions,
        'kinds': kinds,
        'codes': codes,
      };

  static TurnJournal fromJson(Map<String, Object?> j) {
    Map<String, String> readMap(Object? raw) {
      final Map<String, String> out = <String, String>{};
      if (raw is Map) {
        for (final MapEntry<Object?, Object?> e in raw.entries) {
          out['${e.key}'] = '${e.value}';
        }
      }
      return out;
    }

    return TurnJournal(
      responses: readMap(j['responses']),
      answers: readMap(j['answers']),
      questions: readMap(j['questions']),
      kinds: readMap(j['kinds']),
      codes: readMap(j['codes']),
    );
  }
}

/// 一个 stage 完成后的语义 checkpoint。只存 JSON 可表示的结果，
/// 不序列化 Dart 对象或内存里的临时引用。
class TurnCheckpoint {
  const TurnCheckpoint({required this.stage, required this.data});

  final String stage;
  final Map<String, Object?> data;

  Map<String, Object?> toJson() => <String, Object?>{
        'stage': stage,
        'data': data,
      };

  factory TurnCheckpoint.fromJson(Map<String, Object?> j) =>
      TurnCheckpoint(
        stage: '${j['stage'] ?? ''}',
        data: j['data'] is Map
            ? Map<String, Object?>.from(j['data'] as Map)
            : <String, Object?>{},
      );
}

/// 推演到交互点时的结构化结果。
class StopPoint {
  const StopPoint({
    required this.reason,
    this.question = '',
    this.options = const <String>[],
    this.nextActor,
  });

  final String reason;
  final String question;
  final List<String> options;
  final String? nextActor;

  factory StopPoint.fromJson(Map<String, Object?> j) => StopPoint(
        reason: '${j['reason'] ?? ''}',
        question: '${j['question'] ?? ''}',
        options: <String>[
          for (final Object? o in (j['options'] as List<Object?>? ?? const <Object?>[]))
            '$o',
        ],
        nextActor: j['nextActor'] == null ? null : '${j['nextActor']}',
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'reason': reason,
        'question': question,
        'options': options,
        'nextActor': nextActor,
      };
}

class TurnSession {
  TurnSession({
    required this.worldId,
    required this.parallelPlaceId,
    required this.rawInput,
    required this.journal,
    this.baseVersionId,
    this.localFingerprint,
    this.attachmentIds = const <String>[],
    Map<String, TurnCheckpoint>? checkpoints,
    this.id = '',
    this.stage = '',
    this.status = 'running',
    this.createdAt = '',
    this.updatedAt = '',
  }) : checkpoints = checkpoints ?? <String, TurnCheckpoint>{};

  final String id;
  final String stage;
  final String status;
  final String worldId;
  final String parallelPlaceId;

  /// 任务开始时读取的世界版本，续跑时保留。
  final int? baseVersionId;
  final String? localFingerprint;
  final String rawInput;
  final TurnJournal journal;
  final List<String> attachmentIds;

  /// key = stage id；value = 该 stage 完成后的语义结果。
  final Map<String, TurnCheckpoint> checkpoints;

  final String createdAt;
  final String updatedAt;

  /// 最近完成的 checkpoint 的 stage；没有 checkpoint 就是 null。
  String? get lastCheckpointStage =>
      checkpoints.isEmpty ? null : checkpoints.keys.last;

  TurnSession touch({String? updatedAt}) => TurnSession(
        id: id,
        stage: stage,
        status: status,
        worldId: worldId,
        parallelPlaceId: parallelPlaceId,
        baseVersionId: baseVersionId,
        localFingerprint: localFingerprint,
        rawInput: rawInput,
        attachmentIds: attachmentIds,
        journal: journal,
        checkpoints: Map<String, TurnCheckpoint>.of(checkpoints),
        createdAt: createdAt,
        updatedAt: updatedAt ?? DateTime.now().toIso8601String(),
      );

  TurnSession withStage(String next, {String? status}) => TurnSession(
        id: id,
        stage: next,
        status: status ?? this.status,
        worldId: worldId,
        parallelPlaceId: parallelPlaceId,
        baseVersionId: baseVersionId,
        localFingerprint: localFingerprint,
        rawInput: rawInput,
        attachmentIds: attachmentIds,
        journal: journal,
        checkpoints: Map<String, TurnCheckpoint>.of(checkpoints),
        createdAt: createdAt,
        updatedAt: DateTime.now().toIso8601String(),
      );

  TurnSession withCheckpoint(String stage, Map<String, Object?> data) {
    final Map<String, TurnCheckpoint> next =
        Map<String, TurnCheckpoint>.of(checkpoints);
    next[stage] = TurnCheckpoint(stage: stage, data: data);
    return TurnSession(
      id: id,
      stage: stage,
      status: status,
      worldId: worldId,
      parallelPlaceId: parallelPlaceId,
      baseVersionId: baseVersionId,
      localFingerprint: localFingerprint,
      rawInput: rawInput,
      attachmentIds: attachmentIds,
      journal: journal,
      checkpoints: next,
      createdAt: createdAt,
      updatedAt: DateTime.now().toIso8601String(),
    );
  }

  TurnSession withStatus(String next) => withStage(stage, status: next);

  /// 玩家处理失败后，使相关阶段重新执行；其它已完成阶段仍可恢复。
  TurnSession withoutCheckpoints(Iterable<String> stages) {
    final TurnSession next = touch();
    for (final String stage in stages) {
      next.checkpoints.remove(stage);
    }
    return next;
  }

  TurnSession withRawInput(String next) => TurnSession(
        id: id,
        stage: stage,
        status: status,
        worldId: worldId,
        parallelPlaceId: parallelPlaceId,
        baseVersionId: baseVersionId,
        localFingerprint: localFingerprint,
        rawInput: next,
        attachmentIds: attachmentIds,
        journal: journal,
        checkpoints: Map<String, TurnCheckpoint>.of(checkpoints),
        createdAt: createdAt,
        updatedAt: DateTime.now().toIso8601String(),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'stage': stage,
        'status': status,
        'worldId': worldId,
        'parallelPlaceId': parallelPlaceId,
        if (baseVersionId != null) 'baseVersionId': baseVersionId,
        if (localFingerprint != null) 'localFingerprint': localFingerprint,
        'rawInput': rawInput,
        'attachmentIds': attachmentIds,
        'journal': journal.toJson(),
        'checkpoints': <String, Object?>{
          for (final MapEntry<String, TurnCheckpoint> e in checkpoints.entries)
            e.key: e.value.toJson(),
        },
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  static TurnSession fromJson(Map<String, Object?> j) {
    final Object? rawJournal = j['journal'];
    return TurnSession(
      id: '${j['id'] ?? ''}',
      stage: '${j['stage'] ?? ''}',
      status: '${j['status'] ?? 'running'}',
      worldId: '${j['worldId'] ?? ''}',
      parallelPlaceId:
          '${j['parallelPlaceId'] ?? ''}',
      baseVersionId: j['baseVersionId'] as int?,
      localFingerprint: j['localFingerprint'] as String?,
      rawInput: '${j['rawInput'] ?? ''}',
      attachmentIds: j['attachmentIds'] is List
          ? (j['attachmentIds'] as List).whereType<String>().toList()
          : const <String>[],
      journal: rawJournal is Map
          ? TurnJournal.fromJson(rawJournal.cast<String, Object?>())
          : TurnJournal(),
      checkpoints: _readCheckpoints(j['checkpoints']),
      createdAt: '${j['createdAt'] ?? ''}',
      updatedAt: '${j['updatedAt'] ?? ''}',
    );
  }

  static Map<String, TurnCheckpoint> _readCheckpoints(Object? raw) {
    final Map<String, TurnCheckpoint> out = <String, TurnCheckpoint>{};
    if (raw is! Map) return out;
    for (final MapEntry<Object?, Object?> e in raw.entries) {
      final String key = '${e.key}';
      final Object? value = e.value;
      if (value is Map) {
        out[key] = TurnCheckpoint.fromJson(
          Map<String, Object?>.from(value),
        );
      }
    }
    return out;
  }
}
