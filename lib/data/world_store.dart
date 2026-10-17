// 世界 / 回合 / 记忆的落盘。
//
// 设置那些零散的小东西（主题、快捷键、服务商、模型层级）仍留在
// `shared_preferences`，不进这里——它们小、且没有查询的需要。
//
// **规矩沿用 SettingsStore**：逐条解析，坏的那条跳过、如实报出来；
// 不静默丢弃、不备份、不静默降级。
//
// 表结构（v1）：
//   world   一个世界一行。标量字段单列，结构复杂的整块 JSON。
//   step    一步一行。按 (world, lane, 步序) 追加。
//   memory  一条记忆一行。owner 为空 = 上帝记忆。

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../model/char_choices.dart';
import '../model/demo.dart';
import '../model/llm_client.dart';
import '../model/memory.dart';
import '../model/model_plan.dart';
import '../model/turn.dart';

/// 库的版本。加表或改列就 +1，并在 [_migrate] 里写清怎么升。
const int kSchemaVersion = 1;

/// 读一整个世界的结果：读出来多少、坏了几条。
///
/// 跟 `LoadResult` 一个意思，只是这里的单位是"世界"。
class WorldsLoad {
  const WorldsLoad({required this.worlds, this.unreadable = 0, this.openError});

  final List<World> worlds;

  /// 有几个世界读不出来（那几条跳过，其余照常）。
  final int unreadable;

  /// 库打不开时的一句话。有它就别指望 [worlds] 有东西。
  final String? openError;

  bool get broken => openError != null;

  bool get clean => !broken && unreadable == 0;

  /// 给界面用的一句话；没什么可说的就返回 null。
  String? get note {
    if (openError != null) return '世界存档打不开：$openError';
    if (unreadable > 0) return '还有 $unreadable 个世界读不出来。';
    return null;
  }
}

class WorldStore {
  WorldStore._(this._db);

  final Database _db;

  /// 打开磁盘上的库（应用数据目录下的 `joenws.db`）。
  ///
  /// **第一次建库时自带几个世界**（就 `DemoData` 里那三个），
  /// 让空应用打开就有东西看。
  /// 注意这是“建库那一次”，不是“库空了就补”——
  /// 不然用户把世界全删了，下次开又会冒出来。
  static Future<WorldStore> open() async {
    final Directory dir = await getApplicationSupportDirectory();
    final String path = '${dir.path}${Platform.pathSeparator}joenws.db';
    final WorldStore s = WorldStore._(sqlite3.open(path));
    final bool fresh = s._migrate();
    if (fresh) s.seedDemo();
    return s;
  }

  /// 内存库。给测试用（跑完就没了）。**不播种**。
  static WorldStore memory() =>
      WorldStore._(sqlite3.openInMemory()).._migrate();

  /// 把 `DemoData` 那几个世界写进去。
  ///
  /// 公开是为了能单独测——磁盘库不是哪里都跑得起来。
  void seedDemo() {
    for (final World w in DemoData.worlds) {
      saveWorld(w);
    }
  }

  void close() => _db.dispose();

  // ————————————————————————————— 建表与迁移

  /// 建表与迁移。**返回是否是新建的库**（第一次跑）。
  bool _migrate() {
    final int v = _db.select('PRAGMA user_version;').first.values.first! as int;
    if (v >= kSchemaVersion) return false;

    _db.execute('BEGIN;');
    try {
      if (v < 1) {
        _db.execute('''
          CREATE TABLE world (
            id          TEXT PRIMARY KEY,
            name        TEXT NOT NULL DEFAULT '',
            note        TEXT NOT NULL DEFAULT '',
            setting     TEXT NOT NULL DEFAULT '',
            opening     TEXT NOT NULL DEFAULT '',
            player_name TEXT NOT NULL DEFAULT '',
            characters  TEXT NOT NULL DEFAULT '[]',
            lanes       TEXT NOT NULL DEFAULT '[]',
            moves       TEXT NOT NULL DEFAULT '[]'
          );
        ''');
        _db.execute('''
          CREATE TABLE step (
            world_id    TEXT NOT NULL,
            lane_id     TEXT NOT NULL,
            seq         INTEGER NOT NULL,
            kind        TEXT NOT NULL,
            who         TEXT NOT NULL DEFAULT '',
            time        TEXT NOT NULL DEFAULT '',
            text        TEXT NOT NULL DEFAULT '',
            candidates  TEXT NOT NULL DEFAULT '[]',
            perceptions TEXT NOT NULL DEFAULT '{}',
            chosen      TEXT NOT NULL DEFAULT '',
            judgment    TEXT NOT NULL DEFAULT '',
            error       TEXT,
            model       TEXT,
            choices     TEXT,
            usage       TEXT,
            PRIMARY KEY (world_id, lane_id, seq)
          );
        ''');
        _db.execute('''
          CREATE TABLE memory (
            world_id   TEXT NOT NULL,
            owner      TEXT NOT NULL DEFAULT '',
            id         TEXT NOT NULL,
            content    TEXT NOT NULL DEFAULT '',
            kind       TEXT NOT NULL DEFAULT '',
            source     TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL DEFAULT '',
            updated_at TEXT NOT NULL DEFAULT '',
            PRIMARY KEY (world_id, owner, id)
          );
        ''');
      }
      _db.execute('PRAGMA user_version = $kSchemaVersion;');
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
    return true;
  }

  // ————————————————————————————— 世界

  /// 读所有世界。一条坏掉不影响其余。
  WorldsLoad loadWorlds() {
    final List<World> out = <World>[];
    int bad = 0;
    try {
      final ResultSet rs = _db.select('SELECT * FROM world ORDER BY rowid;');
      for (final Row r in rs) {
        try {
          out.add(_worldOf(r));
        } catch (_) {
          bad++;
        }
      }
    } catch (e) {
      return WorldsLoad(worlds: const <World>[], openError: '$e');
    }
    return WorldsLoad(worlds: out, unreadable: bad);
  }

  /// 存一个世界（有就覆盖）。回合表也跟着对齐：多出来的步删掉。
  void saveWorld(World w) {
    _db.execute('BEGIN;');
    try {
      _db.execute(
        '''
        INSERT INTO world
          (id, name, note, setting, opening, player_name, characters, lanes, moves)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          name=excluded.name, note=excluded.note, setting=excluded.setting,
          opening=excluded.opening, player_name=excluded.player_name,
          characters=excluded.characters, lanes=excluded.lanes,
          moves=excluded.moves;
        ''',
        <Object?>[
          w.id,
          w.name,
          w.note,
          w.setting,
          w.opening,
          w.playerName,
          jsonEncode(
            w.characters
                .map(
                  (CharCard c) => <String, Object?>{
                    'name': c.name,
                    'persona': c.persona,
                  },
                )
                .toList(),
          ),
          jsonEncode(
            w.lanes
                .map(
                  (SeqLane l) => <String, Object?>{
                    'id': l.id,
                    'place': l.place,
                    'here': l.here,
                    // steps 不写在这儿 —— 它们进 step 表（那份才是权威）。
                    // 两份都写就会对不上：appendStep 只写表，JSON 那份会越来越旧。
                  },
                )
                .toList(),
          ),
          jsonEncode(
            w.moves
                .map(
                  (MoveLink m) => <String, Object?>{
                    'fromLane': m.fromLane,
                    'fromStep': m.fromStep,
                    'toLane': m.toLane,
                    'toStep': m.toStep,
                  },
                )
                .toList(),
          ),
        ],
      );
      // 步单独存一份，方便以后按步查、也方便一步一步追加。
      _db.execute('DELETE FROM step WHERE world_id = ?;', <Object?>[w.id]);
      for (final SeqLane l in w.lanes) {
        for (int i = 0; i < l.events.length; i++) {
          _insertStep(w.id, l.id, i, l.events[i]);
        }
      }
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  void deleteWorld(String id) {
    _db.execute('BEGIN;');
    try {
      _db.execute('DELETE FROM step WHERE world_id = ?;', <Object?>[id]);
      _db.execute('DELETE FROM memory WHERE world_id = ?;', <Object?>[id]);
      _db.execute('DELETE FROM world WHERE id = ?;', <Object?>[id]);
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  // ————————————————————————————— 回合

  /// 追加一步到某条序列末尾。
  void appendStep(String worldId, String laneId, TurnStep s) {
    final ResultSet r = _db.select(
      'SELECT COALESCE(MAX(seq), -1) + 1 AS n FROM step '
      'WHERE world_id = ? AND lane_id = ?;',
      <Object?>[worldId, laneId],
    );
    final int seq = r.first['n']! as int;
    _insertStep(worldId, laneId, seq, s);
  }

  void _insertStep(String worldId, String laneId, int seq, TurnStep s) {
    _db.execute(
      '''
      INSERT INTO step
        (world_id, lane_id, seq, kind, who, time, text,
         candidates, perceptions, chosen, judgment, error, model, choices, usage)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(world_id, lane_id, seq) DO UPDATE SET
        kind=excluded.kind, who=excluded.who, time=excluded.time,
        text=excluded.text, candidates=excluded.candidates,
        perceptions=excluded.perceptions, chosen=excluded.chosen,
        judgment=excluded.judgment, error=excluded.error,
        model=excluded.model, choices=excluded.choices, usage=excluded.usage;
      ''',
      <Object?>[
        worldId,
        laneId,
        seq,
        s.kind,
        s.who,
        s.time,
        s.text,
        jsonEncode(s.candidates),
        jsonEncode(s.perceptions),
        s.chosen,
        s.judgment,
        s.error,
        s.model?.key,
        s.choices == null ? null : jsonEncode(s.choices!.toJson()),
        s.usage == null
            ? null
            : jsonEncode(<String, Object?>{
                'input': s.usage!.input,
                'output': s.usage!.output,
                'cacheHit': s.usage!.cacheHit,
                'cacheMiss': s.usage!.cacheMiss,
              }),
      ],
    );
  }

  /// 改某一步的正文。
  ///
  /// [index] 是**画布上的步序**（只有 A1 / B2 上画布），从 0 开始。
  /// 用子查询按同样的顺序取 rowid 改，不碰判断与感知。
  void updateStepText(String worldId, String laneId, int index, String text) {
    _db.execute(
      '''
      UPDATE step SET text = ? WHERE rowid = (
        SELECT rowid FROM step
        WHERE world_id = ? AND lane_id = ? AND kind IN ('A1', 'B2')
        ORDER BY seq LIMIT 1 OFFSET ?
      );
      ''',
      <Object?>[text, worldId, laneId, index],
    );
  }

  /// 读某条序列的步。
  List<TurnStep> loadSteps(String worldId, String laneId) {
    final List<TurnStep> out = <TurnStep>[];
    final ResultSet rs = _db.select(
      'SELECT * FROM step WHERE world_id = ? AND lane_id = ? ORDER BY seq;',
      <Object?>[worldId, laneId],
    );
    for (final Row r in rs) {
      out.add(_stepOf(r));
    }
    return out;
  }

  // ————————————————————————————— 记忆

  /// 读一个世界的全部记忆（含上帝那一本）。
  List<MemoryBook> loadMemories(String worldId) {
    final Map<String, List<MemoryEntry>> byOwner =
        <String, List<MemoryEntry>>{};
    final ResultSet rs = _db.select(
      'SELECT * FROM memory WHERE world_id = ? ORDER BY created_at;',
      <Object?>[worldId],
    );
    for (final Row r in rs) {
      final String owner = '${r['owner']}';
      byOwner
          .putIfAbsent(owner, () => <MemoryEntry>[])
          .add(
            MemoryEntry(
              id: '${r['id']}',
              content: '${r['content']}',
              kind: '${r['kind']}',
              source: _sourceOf('${r['source']}'),
              createdAt: _dateOf('${r['created_at']}'),
              updatedAt: _dateOf('${r['updated_at']}'),
            ),
          );
    }
    return byOwner.entries
        .map(
          (MapEntry<String, List<MemoryEntry>> e) =>
              MemoryBook(ownerId: e.key, entries: e.value),
        )
        .toList();
  }

  /// 覆盖一个主人的整本记忆。
  void saveMemory(String worldId, MemoryBook book) {
    _db.execute('BEGIN;');
    try {
      _db.execute(
        'DELETE FROM memory WHERE world_id = ? AND owner = ?;',
        <Object?>[worldId, book.ownerId],
      );
      for (final MemoryEntry m in book.entries) {
        _db.execute(
          '''
          INSERT INTO memory
            (world_id, owner, id, content, kind, source, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?);
          ''',
          <Object?>[
            worldId,
            book.ownerId,
            m.id,
            m.content,
            m.kind,
            m.source.name,
            m.createdAt.toIso8601String(),
            m.updatedAt.toIso8601String(),
          ],
        );
      }
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  // ————————————————————————————— 行 → 对象

  World _worldOf(Row r) => World(
    id: '${r['id']}',
    name: '${r['name']}',
    note: '${r['note']}',
    setting: '${r['setting']}',
    opening: '${r['opening']}',
    playerName: '${r['player_name']}',
    characters: _cardsOf('${r['characters']}'),
    lanes: _lanesOf('${r['lanes']}', '${r['id']}'),
    moves: _movesOf('${r['moves']}'),
  );

  List<CharCard> _cardsOf(String raw) {
    final Object? j = jsonDecode(raw);
    if (j is! List) return const <CharCard>[];
    return j.whereType<Map<Object?, Object?>>().map((Map<Object?, Object?> m) {
      return CharCard(
        name: '${m['name'] ?? ''}',
        persona: '${m['persona'] ?? ''}',
      );
    }).toList();
  }

  /// 读序列。
  ///
  /// **地点元信息来自 JSON，步一律来自 step 表** —— step 表才是权威。
  /// 以前这里读 JSON 里那份，而 `appendStep` 只写 step 表，
  /// 于是引擎跑完、重新读库，画布上永远看不到新步。
  List<SeqLane> _lanesOf(String raw, String worldId) {
    final Object? j = jsonDecode(raw);
    if (j is! List) return const <SeqLane>[];
    return j.whereType<Map<Object?, Object?>>().map((Map<Object?, Object?> m) {
      final String laneId = '${m['id'] ?? ''}';
      return SeqLane(
        id: laneId,
        place: '${m['place'] ?? ''}',
        here: m['here'] == true,
        events: _stepsOf(worldId, laneId),
      );
    }).toList();
  }

  /// 某条序列的步，按步序。坏的那一步跳过，不把整条序列废掉。
  List<TurnStep> _stepsOf(String worldId, String laneId) {
    final List<TurnStep> out = <TurnStep>[];
    final ResultSet rs = _db.select(
      'SELECT * FROM step WHERE world_id = ? AND lane_id = ? ORDER BY seq;',
      <Object?>[worldId, laneId],
    );
    for (final Row r in rs) {
      try {
        final TurnStep s = _stepOf(r);
        // 画布上一步 = 一次行为。判断（A0/AD/A2/A3/A4）和感知（B1）
        // 都在 step 表里，但不上画布 —— 要看得用 loadSteps。
        if (s.showsOnCanvas) out.add(s);
      } catch (_) {
        // 跳过
      }
    }
    return out;
  }

  List<MoveLink> _movesOf(String raw) {
    final Object? j = jsonDecode(raw);
    if (j is! List) return const <MoveLink>[];
    return j.whereType<Map<Object?, Object?>>().map((Map<Object?, Object?> m) {
      int n(Object? v) => v is num ? v.toInt() : 0;
      return MoveLink(
        fromLane: '${m['fromLane'] ?? ''}',
        fromStep: n(m['fromStep']),
        toLane: '${m['toLane'] ?? ''}',
        toStep: n(m['toStep']),
      );
    }).toList();
  }

  TurnStep _stepOf(Row r) {
    final Object? m = r['model'];
    final Object? c = r['choices'];
    final Object? u = r['usage'];
    final Object? cands = jsonDecode('${r['candidates']}');
    final Object? perc = jsonDecode('${r['perceptions']}');
    return TurnStep(
      kind: _kindOf('${r['kind']}'),
      who: '${r['who']}',
      time: '${r['time']}',
      text: '${r['text']}',
      candidates: cands is List
          ? cands.whereType<String>().toList()
          : const <String>[],
      perceptions: perc is Map
          ? perc.map(
              (Object? a, Object? b) => MapEntry<String, String>('$a', '$b'),
            )
          : const <String, String>{},
      chosen: '${r['chosen']}',
      judgment: '${r['judgment']}',
      error: r['error'] is String ? r['error']! as String : null,
      model: m is String && m.isNotEmpty ? _modelOf(m) : null,
      choices: c is String && c.isNotEmpty ? _choicesOf(c) : null,
      usage: u is String && u.isNotEmpty ? _usageOf(u) : null,
    );
  }

  String _kindOf(String id) {
    if (!isKnownStep(id)) {
      throw FormatException('认不出的步骤类型：$id');
    }
    return id;
  }

  MemorySource _sourceOf(String name) {
    for (final MemorySource s in MemorySource.values) {
      if (s.name == name) return s;
    }
    throw FormatException('认不出的记忆来源：$name');
  }

  DateTime _dateOf(String s) {
    final DateTime? d = DateTime.tryParse(s);
    if (d == null) throw FormatException('认不出的时间：$s');
    return d;
  }

  ModelPick? _modelOf(String key) => ModelPick.of(key);

  CharChoices _choicesOf(String raw) =>
      CharChoices.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());

  LlmUsage _usageOf(String raw) {
    final Map<String, Object?> m = (jsonDecode(raw) as Map)
        .cast<String, Object?>();
    int n(Object? v) => v is num ? v.toInt() : 0;
    return LlmUsage(
      input: n(m['input']),
      output: n(m['output']),
      cacheHit: n(m['cacheHit']),
      cacheMiss: n(m['cacheMiss']),
    );
  }
}
