part of 'world_store.dart';

const String mainTimelineId = 'main';

typedef TimelineNarrationInput = ({
  String scope,
  String placeId,
  List<WorldEvent> events,
});

typedef TimelineNarrationJob = ({
  int versionId,
  String? taskId,
  String scope,
  String placeId,
  List<WorldEvent> events,
});

class TimelineBaseChanged extends StateError {
  TimelineBaseChanged() : super('任务的基础版本已不在该时间线末尾。');
}

class TimelineBranch {
  const TimelineBranch({
    required this.worldId,
    required this.id,
    required this.name,
    required this.sourceBranchId,
    required this.forkVersionId,
    required this.headVersionId,
  });

  final String worldId;
  final String id;
  final String name;
  final String? sourceBranchId;
  final int forkVersionId;
  final int headVersionId;
}

class TimelineVersion {
  const TimelineVersion({
    required this.id,
    required this.parentId,
    required this.branchId,
    required this.round,
  });

  final int id;
  final int? parentId;
  final String branchId;

  /// 开场版本没有回合号。
  final int? round;
}

class TimelineSnapshot {
  const TimelineSnapshot({
    required this.version,
    required this.world,
    required this.state,
    required this.steps,
  });

  final TimelineVersion version;
  final World world;
  final TurnState state;
  final Map<String, List<TurnStep>> steps;
}

extension WorldTimelines on WorldStore {
  void _createTimelineTables() {
    _db.execute('''
CREATE TABLE IF NOT EXISTS timeline_version (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  world_id    TEXT NOT NULL,
  parent_id   INTEGER,
  branch_id   TEXT NOT NULL,
  round       INTEGER,
  task_id     TEXT,
  world_json  TEXT NOT NULL,
  steps_json  TEXT NOT NULL,
  state_json  TEXT NOT NULL,
  UNIQUE (world_id, branch_id, task_id)
);
CREATE TABLE IF NOT EXISTS timeline_branch (
  world_id       TEXT NOT NULL,
  id             TEXT NOT NULL,
  name           TEXT NOT NULL,
  source_id      TEXT,
  fork_id        INTEGER NOT NULL,
  head_id        INTEGER NOT NULL,
  request_id     TEXT,
  PRIMARY KEY (world_id, id),
  UNIQUE (world_id, request_id)
);
CREATE TABLE IF NOT EXISTS timeline_session (
  world_id  TEXT NOT NULL,
  branch_id TEXT NOT NULL,
  base_id   INTEGER NOT NULL,
  payload   TEXT NOT NULL,
  PRIMARY KEY (world_id, branch_id)
);
CREATE TABLE IF NOT EXISTS timeline_pending_task (
  world_id  TEXT NOT NULL,
  branch_id TEXT NOT NULL,
  task_id   TEXT NOT NULL,
  payload   TEXT NOT NULL,
  PRIMARY KEY (world_id, branch_id, task_id)
);
CREATE TABLE IF NOT EXISTS timeline_view (
  world_id  TEXT NOT NULL,
  branch_id TEXT NOT NULL,
  place_id  TEXT NOT NULL,
  PRIMARY KEY (world_id, branch_id)
);
CREATE TABLE IF NOT EXISTS timeline_work (
  world_id   TEXT NOT NULL,
  branch_id  TEXT NOT NULL,
  version_id INTEGER NOT NULL,
  payload    TEXT NOT NULL,
  PRIMARY KEY (world_id, branch_id)
);
CREATE TABLE IF NOT EXISTS timeline_round_card (
  world_id    TEXT NOT NULL,
  version_id  INTEGER NOT NULL,
  place_id    TEXT NOT NULL,
  card_index  INTEGER NOT NULL,
  PRIMARY KEY (world_id, place_id, card_index, version_id)
);
CREATE TABLE IF NOT EXISTS timeline_step_revision (
  world_id  TEXT NOT NULL,
  branch_id TEXT NOT NULL,
  task_id   TEXT NOT NULL,
  step_key  TEXT NOT NULL,
  original  TEXT NOT NULL,
  value     TEXT NOT NULL,
  PRIMARY KEY (world_id, branch_id, task_id, step_key)
);
CREATE TABLE IF NOT EXISTS timeline_task (
  version_id INTEGER PRIMARY KEY,
  world_id   TEXT NOT NULL,
  payload    TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS timeline_narration (
  version_id INTEGER PRIMARY KEY,
  world_id   TEXT NOT NULL,
  place_id   TEXT NOT NULL,
  card_index INTEGER NOT NULL,
  scope      TEXT NOT NULL,
  events     TEXT NOT NULL,
  text       TEXT,
  skipped    INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS timeline_narration_audit (
  version_id INTEGER PRIMARY KEY,
  world_id   TEXT NOT NULL,
  journal    TEXT NOT NULL,
  checkpoints TEXT NOT NULL
);
''');
  }

  void _recordNarration(
    String worldId, int versionId, TimelineNarrationInput? input,
  ) {
    if (input == null) return;
    final int index = _db.select(
      'SELECT MIN(card_index) AS card_index FROM timeline_round_card '
      'WHERE world_id = ? AND version_id = ? AND place_id = ?;',
      <Object?>[worldId, versionId, input.placeId],
    ).single['card_index'] as int;
    _db.execute(
      'INSERT INTO timeline_narration (version_id, world_id, place_id, card_index, scope, events) '
      'VALUES (?, ?, ?, ?, ?, ?);',
      <Object?>[
        versionId, worldId, input.placeId, index, input.scope,
        jsonEncode(input.events.map(worldEventToJson).toList()),
      ],
    );
  }

  TimelineNarrationJob? loadPendingNarration(String worldId, String branchId, {int? versionId}) {
    final ResultSet rows = _db.select(
      'WITH RECURSIVE history(id) AS ('
      'SELECT head_id FROM timeline_branch WHERE world_id = ? AND id = ? '
      'UNION ALL SELECT v.parent_id FROM timeline_version v JOIN history h ON h.id = v.id '
      'WHERE v.parent_id IS NOT NULL) '
      'SELECT n.*, v.task_id FROM history h JOIN timeline_version v ON v.id = h.id '
      'JOIN timeline_narration n ON n.version_id = h.id '
      'WHERE v.branch_id = ? AND n.text IS NULL AND n.skipped = 0 '
      'AND (? IS NULL OR n.version_id = ?) '
      'ORDER BY n.version_id LIMIT 1;',
      <Object?>[worldId, branchId, branchId, versionId, versionId],
    );
    if (rows.isEmpty) return null;
    final Row row = rows.single;
    return (
      versionId: row['version_id'] as int,
      taskId: row['task_id'] as String?,
      scope: row['scope'] as String,
      placeId: row['place_id'] as String,
      events: <WorldEvent>[
        for (final Object? event in jsonDecode(row['events'] as String) as List)
          worldEventFromJson((event as Map).cast<String, Object?>()),
      ],
    );
  }

  String? lastSettledTimelinePlace(String worldId, String branchId) {
    final ResultSet rows = _db.select(
      'SELECT n.place_id FROM timeline_narration n JOIN timeline_branch b '
      'ON b.world_id = n.world_id AND b.head_id = n.version_id '
      'WHERE b.world_id = ? AND b.id = ?;',
      <Object?>[worldId, branchId],
    );
    return rows.isEmpty ? null : rows.single['place_id'] as String;
  }

  void finishTimelineNarration(String worldId, int versionId, String scope, String? text) {
    _db.execute(
      'UPDATE timeline_narration SET text = ?, skipped = ? '
      'WHERE world_id = ? AND version_id = ? AND scope = ? AND text IS NULL AND skipped = 0;',
      <Object?>[text, text == null ? 1 : 0, worldId, versionId, scope],
    );
  }

  bool editTimelineNarration(String worldId, String branchId, int versionId, String scope, String text) {
    final ResultSet rows = _db.select(
      'SELECT v.task_id, n.text FROM timeline_version v JOIN timeline_narration n '
      'ON n.version_id = v.id WHERE v.world_id = ? AND v.id = ? AND n.scope = ?;',
      <Object?>[worldId, versionId, scope],
    );
    if (rows.isEmpty || rows.single['task_id'] is! String) return false;
    final String original = rows.single['text'] as String? ?? '';
    saveTimelineStepRevision(
      worldId, branchId, rows.single['task_id'] as String, 'checkpoint:GM_NARRATE',
      original: jsonEncode(<String, Object?>{'publicText': original}),
      value: jsonEncode(<String, Object?>{'publicText': joLf(text)}),
    );
    return true;
  }

  void saveTimelineNarrationSteps(
    String worldId, int versionId, TurnJournal journal, Map<String, TurnCheckpoint> checkpoints,
  ) {
    _db.execute(
      'INSERT INTO timeline_narration_audit (version_id, world_id, journal, checkpoints) '
      'VALUES (?, ?, ?, ?) ON CONFLICT(version_id) DO UPDATE '
      'SET journal = excluded.journal, checkpoints = excluded.checkpoints;',
      <Object?>[
        versionId, worldId, jsonEncode(journal.toJson()),
        jsonEncode(<String, Object?>{
          for (final MapEntry<String, TurnCheckpoint> entry in checkpoints.entries)
            entry.key: entry.value.toJson(),
        }),
      ],
    );
  }

  Map<String, TurnCheckpoint> loadTimelineNarrationCheckpoints(String worldId, int versionId) {
    final ResultSet rows = _db.select(
      'SELECT checkpoints FROM timeline_narration_audit WHERE world_id = ? AND version_id = ?;',
      <Object?>[worldId, versionId],
    );
    if (rows.isEmpty) return <String, TurnCheckpoint>{};
    final Map<String, Object?> data =
        (jsonDecode(rows.single['checkpoints'] as String) as Map).cast<String, Object?>();
    return <String, TurnCheckpoint>{
      for (final MapEntry<String, Object?> entry in data.entries)
        entry.key: TurnCheckpoint.fromJson((entry.value as Map).cast<String, Object?>()),
    };
  }

  TurnJournal loadTimelineNarrationJournal(String worldId, int versionId) {
    final ResultSet rows = _db.select(
      'SELECT journal FROM timeline_narration_audit WHERE world_id = ? AND version_id = ?;',
      <Object?>[worldId, versionId],
    );
    if (rows.isEmpty) return TurnJournal();
    return TurnJournal.fromJson(
      (jsonDecode(rows.single['journal'] as String) as Map).cast<String, Object?>(),
    );
  }

  /// 正文按版本与观察者读取；正文不写回世界事件。
  World projectTimelineNarration(
    World world, int versionId, String scope, {
    String? branchId,
  }) {
    final Map<(String, int), Row> narration = <(String, int), Row>{
      for (final Row row in _db.select('''
WITH RECURSIVE history(id, parent_id) AS (
  SELECT id, parent_id FROM timeline_version WHERE world_id = ?1 AND id = ?2
  UNION ALL
  SELECT v.id, v.parent_id FROM timeline_version v JOIN history h ON h.parent_id = v.id
  WHERE v.world_id = ?1
)
SELECT n.*, r.value AS revision, raw.value AS raw_revision FROM timeline_narration n
JOIN history h ON h.id = n.version_id
JOIN timeline_version v ON v.id = n.version_id
LEFT JOIN timeline_narration_audit a ON a.version_id = n.version_id
LEFT JOIN timeline_step_revision r ON r.world_id = v.world_id
  AND r.branch_id = COALESCE(?3, v.branch_id) AND r.task_id = v.task_id
  AND r.step_key = 'checkpoint:GM_NARRATE'
LEFT JOIN timeline_step_revision raw ON raw.world_id = v.world_id
  AND raw.branch_id = COALESCE(?3, v.branch_id) AND raw.task_id = v.task_id
  AND raw.step_key = 'GM_NARRATE#1'
  AND raw.original = json_extract(a.journal, '\$.responses."GM_NARRATE#1"')
ORDER BY n.version_id;
''', <Object?>[world.id, versionId, branchId]))
        (row['place_id'] as String, row['card_index'] as int): row,
    };
    if (narration.isEmpty && scope == 'god') return world;
    String? textOf(Row row) {
      if (row['text'] == null && row['skipped'] == 0) return null;
      if (row['revision'] case final String revision) {
        final Object? edited = jsonDecode(revision);
        if (edited is Map && edited['publicText'] is String) {
          return edited['publicText'] as String;
        }
      }
      if (row['raw_revision'] case final String revision) {
        final Object? edited = jsonDecode(revision);
        if (edited is Map && edited['public_text'] is String) {
          return edited['public_text'] as String;
        }
      }
      return row['text'] as String?;
    }
    TurnStep project(TurnStep card, Row? row) {
      if (scope != 'god') {
        final String? visible = row != null && row['scope'] == scope ? textOf(row) : null;
        return TurnStep(kind: card.kind, text: visible ?? '当前视角没有已生成的正文。');
      }
      if (row == null || row['scope'] != scope) return card;
      final String? text = textOf(row);
      return text == null ? card : TurnStep.fromJson(<String, Object?>{...card.toJson(), 'text': text});
    }
    return world.copyWith(parallelPlaces: <ParallelPlace>[
      for (final ParallelPlace place in world.parallelPlaces)
        place.copyWith(events: <TurnStep>[
          for (final (int index, TurnStep card) in place.events.indexed)
            project(card, narration[(place.id, index)]),
        ]),
    ]);
  }

  TurnSession? loadCompletedTimelineTask(String worldId, int versionId) {
    final ResultSet rows = _db.select(
      'SELECT payload FROM timeline_task WHERE world_id = ? AND version_id = ?;',
      <Object?>[worldId, versionId],
    );
    if (rows.isEmpty) return null;
    final TurnSession original = _decodeTimelineTask(rows.single);
    final ResultSet audit = _db.select(
      'SELECT journal, checkpoints FROM timeline_narration_audit WHERE world_id = ? AND version_id = ?;',
      <Object?>[worldId, versionId],
    );
    if (audit.isEmpty) return original;
    final Row row = audit.single;
    final TurnJournal narration = TurnJournal.fromJson(
      (jsonDecode(row['journal'] as String) as Map).cast<String, Object?>(),
    );
    original.journal.responses.addAll(narration.responses);
    return TurnSession.fromJson(<String, Object?>{
      ...original.toJson(),
      'checkpoints': <String, Object?>{
        for (final TurnCheckpoint checkpoint in original.checkpoints.values)
          checkpoint.stage: checkpoint.toJson(),
        ...(jsonDecode(row['checkpoints'] as String) as Map).cast<String, Object?>(),
      },
    });
  }

  TurnSession _decodeTimelineTask(Row row) => TurnSession.fromJson(
    (jsonDecode(row['payload'] as String) as Map).cast<String, Object?>(),
  );

  Map<String, String> timelineStepRevisions(
    String worldId, String branchId, String taskId,
  ) => <String, String>{
    for (final Row row in _db.select(
      'SELECT step_key, value FROM timeline_step_revision '
      'WHERE world_id = ? AND branch_id = ? AND task_id = ?;',
      <Object?>[worldId, branchId, taskId],
    )) row['step_key'] as String: row['value'] as String,
  };

  Map<String, String> timelineStepOriginals(
    String worldId, String branchId, String taskId,
  ) => <String, String>{
    for (final Row row in _db.select(
      'SELECT step_key, original FROM timeline_step_revision '
      'WHERE world_id = ? AND branch_id = ? AND task_id = ?;',
      <Object?>[worldId, branchId, taskId],
    )) row['step_key'] as String: row['original'] as String,
  };

  void saveTimelineStepRevision(
    String worldId, String branchId, String taskId, String key, {
    required String original,
    required String value,
  }) {
    _requireBranch(worldId, branchId);
    _db.execute(
      'INSERT INTO timeline_step_revision '
      '(world_id, branch_id, task_id, step_key, original, value) '
      'VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(world_id, branch_id, task_id, step_key) '
      'DO UPDATE SET value = excluded.value;',
      <Object?>[worldId, branchId, taskId, key, original, value],
    );
  }

  void _recordTimelineTask(String worldId, int versionId, TurnSession? session) {
    if (session == null) return;
    _db.execute(
      'INSERT INTO timeline_task (version_id, world_id, payload) VALUES (?, ?, ?);',
      <Object?>[versionId, worldId, jsonEncode(session.toJson())],
    );
  }

  TurnSession? loadTimelineSession(String worldId, String branchId) {
    final List<TurnSession> tasks = loadTimelineSessions(worldId, branchId);
    return tasks.where((task) => task.status == 'waiting_player').firstOrNull ??
        tasks.firstOrNull;
  }

  List<TurnSession> loadTimelineSessions(String worldId, String branchId) {
    final List<TurnSession> tasks = <TurnSession>[
      for (final Row row in _db.select(
        'SELECT payload FROM timeline_pending_task WHERE world_id = ? AND branch_id = ? '
        'ORDER BY task_id;', <Object?>[worldId, branchId],
      )) _decodeTimelineTask(row),
    ];
    if (tasks.isNotEmpty) return tasks;
    final TurnSession? legacy = _loadLegacyTimelineSession(worldId, branchId);
    return <TurnSession>[?legacy];
  }

  TurnSession? _loadLegacyTimelineSession(String worldId, String branchId) {
    if (branchId == mainTimelineId) return _loadLegacyTurnSession(worldId);
    final ResultSet rows = _db.select(
      'SELECT payload FROM timeline_session WHERE world_id = ? AND branch_id = ?;',
      <Object?>[worldId, branchId],
    );
    if (rows.isEmpty) return null;
    return _decodeTimelineTask(rows.single);
  }

  void saveTimelineSession(String branchId, TurnSession session) {
    _db.execute(
      'INSERT INTO timeline_pending_task (world_id, branch_id, task_id, payload) '
      'VALUES (?, ?, ?, ?) ON CONFLICT(world_id, branch_id, task_id) DO UPDATE '
      'SET payload = excluded.payload;',
      <Object?>[
        session.worldId, branchId, session.id,
        jsonEncode(session.touch().toJson()),
      ],
    );
  }

  void clearTimelineSession(String worldId, String branchId, {String? taskId}) {
    _db.execute(
      'DELETE FROM timeline_pending_task WHERE world_id = ? AND branch_id = ?'
      '${taskId == null ? '' : ' AND task_id = ?'};',
      <Object?>[worldId, branchId, ?taskId],
    );
    if (taskId != null && _loadLegacyTimelineSession(worldId, branchId)?.id != taskId) return;
    if (branchId == mainTimelineId) {
      _clearLegacyTurnSession(worldId);
      return;
    }
    _db.execute(
      'DELETE FROM timeline_session WHERE world_id = ? AND branch_id = ?;',
      <Object?>[worldId, branchId],
    );
  }

  List<TimelineBranch> listTimelineBranches(String worldId) => <TimelineBranch>[
    for (final Row row in _db.select(
      'SELECT * FROM timeline_branch WHERE world_id = ? ORDER BY rowid;',
      <Object?>[worldId],
    ))
      _branchOf(row),
  ];

  TimelineBranch? loadTimelineBranch(String worldId, String branchId) {
    final ResultSet rows = _db.select(
      'SELECT * FROM timeline_branch WHERE world_id = ? AND id = ?;',
      <Object?>[worldId, branchId],
    );
    return rows.isEmpty ? null : _branchOf(rows.single);
  }

  int? timelineHeadRound(String worldId, String branchId) {
    final ResultSet rows = _db.select(
      'SELECT v.round FROM timeline_branch b JOIN timeline_version v ON v.id = b.head_id '
      'WHERE b.world_id = ? AND b.id = ?;',
      <Object?>[worldId, branchId],
    );
    return rows.isEmpty ? null : rows.single['round'] as int?;
  }

  String? loadTimelinePlace(String worldId, String branchId) {
    final ResultSet rows = _db.select(
      'SELECT place_id FROM timeline_view WHERE world_id = ? AND branch_id = ?;',
      <Object?>[worldId, branchId],
    );
    return rows.isEmpty ? null : rows.single['place_id'] as String;
  }

  Map<String, Object?>? loadTimelineWork(String worldId, String branchId) {
    final ResultSet rows = _db.select(
      'SELECT w.payload FROM timeline_work w JOIN timeline_branch b '
      'ON b.world_id = w.world_id AND b.id = w.branch_id AND b.head_id = w.version_id '
      'WHERE w.world_id = ? AND w.branch_id = ?;',
      <Object?>[worldId, branchId],
    );
    return rows.isEmpty ? null :
        (jsonDecode(rows.single['payload'] as String) as Map).cast<String, Object?>();
  }

  void saveTimelineWork(String worldId, String branchId, int baseId, Map<String, Object?> work) {
    _db.execute(
      'INSERT INTO timeline_work (world_id, branch_id, version_id, payload) '
      'SELECT world_id, id, head_id, ? FROM timeline_branch '
      'WHERE world_id = ? AND id = ? AND head_id = ? '
      'ON CONFLICT(world_id, branch_id) DO UPDATE SET '
      'version_id = excluded.version_id, payload = excluded.payload;',
      <Object?>[jsonEncode(work), worldId, branchId, baseId],
    );
  }

  void saveTimelinePlace(String worldId, String branchId, String placeId) {
    _db.execute(
      'INSERT INTO timeline_view (world_id, branch_id, place_id) VALUES (?, ?, ?) '
      'ON CONFLICT(world_id, branch_id) DO UPDATE SET place_id = excluded.place_id;',
      <Object?>[worldId, branchId, placeId],
    );
  }

  List<TimelineVersion> timelineHistory(String worldId, String branchId) {
    final int head = _requireBranch(worldId, branchId).headVersionId;
    return <TimelineVersion>[
      for (final Row row in _db.select('''
WITH RECURSIVE history(id, parent_id, branch_id, round) AS (
  SELECT id, parent_id, branch_id, round FROM timeline_version WHERE world_id = ?1 AND id = ?2
  UNION ALL
  SELECT v.id, v.parent_id, v.branch_id, v.round FROM timeline_version v
  JOIN history h ON h.parent_id = v.id WHERE v.world_id = ?1
)
SELECT * FROM history ORDER BY id;
''', <Object?>[worldId, head]))
        _versionOf(row),
    ];
  }

  TimelineVersion? timelineVersionForCard(
    String worldId, String branchId, String placeId, int cardIndex,
  ) {
    if (loadTimelineBranch(worldId, branchId) == null) return null;
    final Set<int> candidates = <int>{
      for (final Row row in _db.select(
        'SELECT version_id FROM timeline_round_card '
        'WHERE world_id = ? AND place_id = ? AND card_index = ?;',
        <Object?>[worldId, placeId, cardIndex],
      )) row['version_id'] as int,
    };
    if (candidates.isEmpty) return null;
    for (final TimelineVersion version in timelineHistory(worldId, branchId).reversed) {
      if (candidates.contains(version.id)) return version;
    }
    return null;
  }

  TimelineSnapshot loadTimelineSnapshot(String worldId, int versionId) {
    final Row row = _timelineVersionRow(worldId, versionId);
    final Map<String, Object?> meta =
        (jsonDecode(row['world_json'] as String) as Map).cast<String, Object?>();
    final Map<String, Object?> rawSteps =
        (jsonDecode(row['steps_json'] as String) as Map).cast<String, Object?>();
    final Map<String, List<TurnStep>> steps = <String, List<TurnStep>>{
      for (final MapEntry<String, Object?> entry in rawSteps.entries)
        entry.key: <TurnStep>[
          for (final Object? data in entry.value as List)
            TurnStep.fromJson((data as Map).cast<String, Object?>()),
        ],
    };
    return TimelineSnapshot(
      version: _versionOf(row),
      world: _worldOf(meta, snapshotSteps: (String placeId) => <TurnStep>[
        for (final TurnStep step in steps[placeId] ?? const <TurnStep>[])
          if (step.showsOnCanvas) step,
      ]),
      state: TurnState.decode(row['state_json'] as String),
      steps: steps,
    );
  }

  TimelineBranch createTimelineBranch({
    required String worldId,
    required String sourceBranchId,
    required int versionId,
    required String requestId,
    String name = '',
  }) => _timelineTransaction(() {
    if (requestId.isEmpty) throw ArgumentError.value(requestId, 'requestId');
    final ResultSet existing = _db.select(
      'SELECT * FROM timeline_branch WHERE world_id = ? AND request_id = ?;',
      <Object?>[worldId, requestId],
    );
    if (existing.isNotEmpty) return _branchOf(existing.single);
    if (!timelineHistory(worldId, sourceBranchId).any(
      (TimelineVersion version) => version.id == versionId && version.round != null,
    )) {
      throw StateError('只能从来源时间线的已完成回合开分支。');
    }
    loadTimelineSnapshot(worldId, versionId);
    final String id = _db.select(
      'SELECT lower(hex(randomblob(16))) AS id;',
    ).single['id'] as String;
    final String label = name.trim();
    final TimelineBranch branch = TimelineBranch(
      worldId: worldId,
      id: id,
      name: label.isEmpty ? '支线 ${listTimelineBranches(worldId).length}' : label,
      sourceBranchId: sourceBranchId,
      forkVersionId: versionId,
      headVersionId: versionId,
    );
    _insertTimelineBranch(branch, requestId: requestId);
    return branch;
  });

  /// 支线结果只写到所属支线，来源版本继续供各条线共享。
  int commitTimelineTurn({
    required String worldId,
    required String branchId,
    required int baseVersionId,
    required String taskId,
    required World world,
    required TurnState state,
    required List<({String placeId, TurnStep step})> newSteps,
    TurnSession? session,
    TimelineNarrationInput? narration,
  }) => _timelineTransaction(() {
    if (branchId == mainTimelineId || world.id != worldId || taskId.isEmpty) {
      throw ArgumentError('支线提交需要匹配的世界、支线和任务。');
    }
    final TimelineBranch branch = _requireBranch(worldId, branchId);
    final int? committed = _committedTimelineTask(worldId, branchId, taskId);
    if (committed != null) return committed;
    if (branch.headVersionId != baseVersionId) {
      throw TimelineBaseChanged();
    }
    final TimelineSnapshot base = loadTimelineSnapshot(worldId, baseVersionId);
    final Map<String, List<TurnStep>> steps = base.steps;
    final Map<String, int> newCards = <String, int>{};
    for (final entry in newSteps) {
      (steps[entry.placeId] ??= <TurnStep>[]).add(entry.step);
      if (entry.step.showsOnCanvas) {
        newCards.update(entry.placeId, (int count) => count + 1, ifAbsent: () => 1);
      }
    }
    final int versionId = _insertTimelineVersion(
      worldId: worldId,
      branchId: branchId,
      parentId: baseVersionId,
      round: (base.version.round ?? 0) + 1,
      taskId: taskId,
      world: _timelineWorldData(world),
      steps: steps,
      state: state,
    );
    _recordRoundCards(worldId, versionId, steps, newCards);
    _recordNarration(worldId, versionId, narration);
    _recordTimelineTask(worldId, versionId, session);
    _advanceTimeline(branch, versionId);
    clearTimelineSession(worldId, branchId, taskId: taskId);
    return versionId;
  });

  T _timelineTransaction<T>(T Function() operation) {
    _db.execute('BEGIN IMMEDIATE;');
    try {
      final T result = operation();
      _db.execute('COMMIT;');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  void _recordOpeningVersion(String worldId) {
    final Row row = _db.select(
      'SELECT * FROM world WHERE id = ?;', <Object?>[worldId],
    ).single;
    final int version = _insertTimelineVersion(
      worldId: worldId,
      branchId: mainTimelineId,
      world: row,
      steps: _readTimelineSteps(worldId),
      state: TurnState.empty,
    );
    _insertTimelineBranch(TimelineBranch(
      worldId: worldId,
      id: mainTimelineId,
      name: '主线',
      sourceBranchId: null,
      forkVersionId: version,
      headVersionId: version,
    ));
  }

  void _recordMainTurn(
    TimelineBranch main, String sessionId, int turnNo, Map<String, int> newCards,
    TurnSession? session,
    TimelineNarrationInput? narration,
  ) {
    final Row world = _db.select(
      'SELECT * FROM world WHERE id = ?;', <Object?>[main.worldId],
    ).single;
    final Row turn = _db.select(
      'SELECT state_json, event_ids, memory_refs FROM turn '
      "WHERE world_id = ? AND parallel_place_id = '' AND turn_no = ?;",
      <Object?>[main.worldId, turnNo],
    ).single;
    final TimelineVersion previous = _versionOf(
      _timelineVersionRow(main.worldId, main.headVersionId),
    );
    final Map<String, List<TurnStep>> steps = _readTimelineSteps(main.worldId);
    final int version = _insertTimelineVersion(
      worldId: main.worldId,
      branchId: main.id,
      parentId: main.headVersionId,
      round: (previous.round ?? 0) + 1,
      taskId: sessionId.isEmpty ? null : sessionId,
      world: world,
      steps: steps,
      state: _turnStateOf(main.worldId, turn),
    );
    _recordRoundCards(main.worldId, version, steps, newCards);
    _recordNarration(main.worldId, version, narration);
    _recordTimelineTask(main.worldId, version, session);
    _advanceTimeline(main, version);
  }

  void _recordRoundCards(
    String worldId, int versionId, Map<String, List<TurnStep>> steps, Map<String, int> added,
  ) {
    for (final MapEntry<String, int> entry in added.entries) {
      final int count = steps[entry.key]!.where((TurnStep step) => step.showsOnCanvas).length;
      for (int index = count - entry.value; index < count; index++) {
        _db.execute(
          'INSERT INTO timeline_round_card (world_id, version_id, place_id, card_index) '
          'VALUES (?, ?, ?, ?);',
          <Object?>[worldId, versionId, entry.key, index],
        );
      }
    }
  }

  Map<String, List<TurnStep>> _readTimelineSteps(String worldId) {
    final Map<String, List<TurnStep>> steps = <String, List<TurnStep>>{};
    for (final Row row in _db.select(
      'SELECT * FROM step WHERE world_id = ? ORDER BY parallel_place_id, seq;',
      <Object?>[worldId],
    )) {
      (steps[row['parallel_place_id'] as String] ??= <TurnStep>[]).add(_stepOf(row));
    }
    return steps;
  }

  Row _timelineVersionRow(String worldId, int versionId) {
    final ResultSet rows = _db.select(
      'SELECT * FROM timeline_version WHERE world_id = ? AND id = ?;',
      <Object?>[worldId, versionId],
    );
    if (rows.isEmpty) throw StateError('该世界中没有版本 $versionId。');
    return rows.single;
  }

  int? _committedTimelineTask(String worldId, String branchId, String taskId) {
    final ResultSet rows = _db.select(
      'SELECT id FROM timeline_version '
      'WHERE world_id = ? AND branch_id = ? AND task_id = ?;',
      <Object?>[worldId, branchId, taskId],
    );
    return rows.isEmpty ? null : rows.single['id'] as int;
  }

  int _insertTimelineVersion({
    required String worldId,
    required String branchId,
    int? parentId,
    int? round,
    String? taskId,
    required Map<String, Object?> world,
    required Map<String, List<TurnStep>> steps,
    required TurnState state,
  }) {
    _db.execute(
      'INSERT INTO timeline_version '
      '(world_id, parent_id, branch_id, round, task_id, world_json, steps_json, state_json) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?);',
      <Object?>[
        worldId, parentId, branchId, round, taskId, jsonEncode(world),
        jsonEncode(<String, Object?>{
          for (final MapEntry<String, List<TurnStep>> entry in steps.entries)
            entry.key: entry.value.map((TurnStep step) => step.toJson()).toList(),
        }),
        state.encode(),
      ],
    );
    return _db.lastInsertRowId;
  }

  void _insertTimelineBranch(TimelineBranch branch, {String? requestId}) {
    _db.execute(
      'INSERT INTO timeline_branch '
      '(world_id, id, name, source_id, fork_id, head_id, request_id) '
      'VALUES (?, ?, ?, ?, ?, ?, ?);',
      <Object?>[
        branch.worldId, branch.id, branch.name, branch.sourceBranchId,
        branch.forkVersionId, branch.headVersionId, requestId,
      ],
    );
  }

  void _advanceTimeline(TimelineBranch branch, int versionId) {
    _db.execute(
      'UPDATE timeline_branch SET head_id = ? '
      'WHERE world_id = ? AND id = ? AND head_id = ?;',
      <Object?>[versionId, branch.worldId, branch.id, branch.headVersionId],
    );
    if (_db.updatedRows != 1) throw StateError('时间线末尾已改变。');
  }

  TimelineBranch _requireBranch(String worldId, String branchId) =>
      loadTimelineBranch(worldId, branchId) ??
      (throw StateError('该世界中没有时间线 $branchId。'));

  TimelineBranch _branchOf(Row row) => TimelineBranch(
    worldId: row['world_id'] as String,
    id: row['id'] as String,
    name: row['name'] as String,
    sourceBranchId: row['source_id'] as String?,
    forkVersionId: row['fork_id'] as int,
    headVersionId: row['head_id'] as int,
  );

  TimelineVersion _versionOf(Row row) => TimelineVersion(
    id: row['id'] as int,
    parentId: row['parent_id'] as int?,
    branchId: row['branch_id'] as String,
    round: row['round'] as int?,
  );

  void _deleteTimelineData(String worldId) {
    _db.execute('DELETE FROM timeline_narration_audit WHERE world_id = ?;', <Object?>[worldId]);
    _db.execute('DELETE FROM timeline_narration WHERE world_id = ?;', <Object?>[worldId]);
    _db.execute('DELETE FROM timeline_step_revision WHERE world_id = ?;', <Object?>[worldId]);
    _db.execute('DELETE FROM timeline_task WHERE world_id = ?;', <Object?>[worldId]);
    _db.execute('DELETE FROM timeline_round_card WHERE world_id = ?;', <Object?>[worldId]);
    _db.execute('DELETE FROM timeline_session WHERE world_id = ?;', <Object?>[worldId]);
    _db.execute('DELETE FROM timeline_pending_task WHERE world_id = ?;', <Object?>[worldId]);
    _db.execute('DELETE FROM timeline_view WHERE world_id = ?;', <Object?>[worldId]);
    _db.execute('DELETE FROM timeline_work WHERE world_id = ?;', <Object?>[worldId]);
    _db.execute('DELETE FROM timeline_branch WHERE world_id = ?;', <Object?>[worldId]);
    _db.execute('DELETE FROM timeline_version WHERE world_id = ?;', <Object?>[worldId]);
  }
}
