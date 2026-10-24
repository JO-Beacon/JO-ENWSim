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
import '../model/text.dart';
import '../model/turn.dart';

/// 库的版本。加表或改列就 +1，并在 [_migrate] 里写清怎么升。
///
/// v1：world / step / memory 三张表。
/// v2：加查表用的索引，加 char_cfg（每个角色自己的模型与选择）。
///     没有改旧表结构，旧库直接补索引、补新表。
/// v3：把库里已有的 `\r`（Windows 的 CRLF）洗成 `\n`。
///     不改结构，只是一条数据清洗。
const int kSchemaVersion = 3;

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
  static Future<WorldStore> open({String? path}) async {
    final String p =
        path ??
        '${(await getApplicationSupportDirectory()).path}'
            '${Platform.pathSeparator}joenws.db';
    final WorldStore s = WorldStore._(sqlite3.open(p));
    final int before = s._migrate();
    // **只有从 0 升上来才算“新建”**。
    // 以前这里看的是“有没有跑过迁移”，于是 v1→v2 也会重播一遍 demo，
    // 把用户改过的 demo 世界覆盖回去。
    if (before == 0) s.seedDemo();
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

  void close() => _db.close();

  /// 库里有哪些索引（给测试用：确认 v2 迁移真的跑了）。
  ///
  /// 不写 `@visibleForTesting` 是因为数据层不想再依赖 flutter；
  /// 这个名字够直白，不会被人顺手拿去当业务接口。
  List<String> indexNames() => _db
      .select(
        "SELECT name FROM sqlite_master WHERE type = 'index' "
        "AND name NOT LIKE 'sqlite_%' ORDER BY name;",
      )
      .map((Row r) => '${r['name']}')
      .toList();

  // ————————————————————————————— 建表与迁移

  /// 建表与迁移。**返回迁移前的版本号**（0 = 全新库）。
  int _migrate() {
    final int v = _db.select('PRAGMA user_version;').first.values.first! as int;
    if (v >= kSchemaVersion) return v;

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
      if (v < 2) {
        // v2：查步、查记忆都是按 (world, lane) / (world, owner) 走的，
        // 没索引就是全表扫；外加一张 char_cfg。
        _db.execute('''
          CREATE INDEX IF NOT EXISTS idx_step_lane
            ON step(world_id, lane_id, seq);
        ''');
        _db.execute('''
          CREATE INDEX IF NOT EXISTS idx_memory_owner
            ON memory(world_id, owner);
        ''');
        _db.execute('''
          CREATE TABLE IF NOT EXISTS char_cfg (
            world_id TEXT NOT NULL,
            name     TEXT NOT NULL,
            plan     TEXT NOT NULL DEFAULT '',
            choices  TEXT NOT NULL DEFAULT '',
            PRIMARY KEY (world_id, name)
          );
        ''');
      }
      if (v < 3) {
        // v3：把库里**已有**的 CRLF 洗成 LF。
        // 以前从网页/聊天窗口粘进来的正文带着 `\r`，界面上会变成豆腐块，
        // 也会把 Markdown 的切块搞乱。新增的写入口已经拦了（joLf），
        // 这一步是把旧数据一次性洗干净。
        void lf(String table, String column) {
          _db.execute(
            'UPDATE $table SET $column = '
            "replace(replace($column, char(13)||char(10), char(10)), char(13), char(10));",
          );
        }

        lf('world', 'name');
        lf('world', 'note');
        lf('world', 'setting');
        lf('world', 'opening');
        lf('step', 'text');
        lf('step', 'judgment');
        lf('step', 'chosen');
        lf('memory', 'content');
      }
      _db.execute('PRAGMA user_version = $kSchemaVersion;');
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
    return v;
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

  /// 存一个世界（有就覆盖）。步表也跟着对齐：内存里没有的步删掉。
  ///
  /// **只用于新世界 / 结构真变了的场合**（列的增删、整份导入）。
  /// 只改名字、设定、角色的场合请用 [saveWorldMeta]：
  /// 以前大家都走这里，于是“改个名字”也会把整张 step 表重写一遍。
  void saveWorld(World w) {
    _db.execute('BEGIN;');
    try {
      _upsertWorld(w);
      _reconcileSteps(w);
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  /// 只写世界那一行（名字 / 副标题 / 设定 / 开场 / 玩家角色 / 角色卡 /
  /// 序列表 / 换地点表），**不动 step 表**。
  ///
  /// 编辑弹窗改的就是这些：它不碰步。以前这里走的是 [saveWorld]，
  /// 等于“拿内存里那份旧快照把库里的步全删了重写”——
  /// 内存一旦落后于库（引擎刚追加了一两步），那几步就没了。
  void saveWorldMeta(World w) {
    _db.execute('BEGIN;');
    try {
      _upsertWorld(w);
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  /// 世界那一行的 upsert。**不碰步**。
  void _upsertWorld(World w) {
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
        joLf(w.name),
        joLf(w.note),
        joLf(w.setting),
        joLf(w.opening),
        joLf(w.playerName),
        jsonEncode(
          w.characters
              .map(
                (CharCard c) => <String, Object?>{
                  'name': joLf(c.name),
                  'persona': joLf(c.persona),
                },
              )
              .toList(),
        ),
        jsonEncode(
          w.lanes
              .map(
                (SeqLane l) => <String, Object?>{
                  'id': l.id,
                  'place': joLf(l.place),
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
  }

  /// 把 step 表对齐到内存里的那份：内存有的 upsert、库里多出来的删掉。
  ///
  /// 不像以前那样“先全删再全插”：那样每一步都要重写一遍，
  /// 而且一旦事务外的追加插进来，就会被这份快照抹掉。
  void _reconcileSteps(World w) {
    final Set<String> keep = <String>{};
    for (final SeqLane l in w.lanes) {
      for (int i = 0; i < l.events.length; i++) {
        _insertStep(w.id, l.id, i, l.events[i]);
        keep.add('${l.id}\u0000$i');
      }
    }
    final ResultSet rs = _db.select(
      'SELECT lane_id, seq FROM step WHERE world_id = ?;',
      <Object?>[w.id],
    );
    final List<(String, int)> gone = <(String, int)>[];
    for (final Row r in rs) {
      final String lane = '${r['lane_id']}';
      final int seq = r['seq']! as int;
      if (!keep.contains('$lane\u0000$seq')) gone.add((lane, seq));
    }
    for (final (String, int) g in gone) {
      _db.execute(
        'DELETE FROM step WHERE world_id = ? AND lane_id = ? AND seq = ?;',
        <Object?>[w.id, g.$1, g.$2],
      );
    }
  }

  void deleteWorld(String id) {
    _db.execute('BEGIN;');
    try {
      _db.execute('DELETE FROM step WHERE world_id = ?;', <Object?>[id]);
      _db.execute('DELETE FROM memory WHERE world_id = ?;', <Object?>[id]);
      _db.execute('DELETE FROM char_cfg WHERE world_id = ?;', <Object?>[id]);
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
    // 取 seq 和插行必须在同一个事务里：分开做，两个写同时来会上同一层。
    _db.execute('BEGIN;');
    try {
      final ResultSet r = _db.select(
        'SELECT COALESCE(MAX(seq), -1) + 1 AS n FROM step '
        'WHERE world_id = ? AND lane_id = ?;',
        <Object?>[worldId, laneId],
      );
      final int seq = r.first['n']! as int;
      _insertStep(worldId, laneId, seq, s);
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
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
        joLf(s.who),
        joLf(s.time),
        joLf(s.text),
        jsonEncode(s.candidates.map(joLf).toList()),
        jsonEncode(
          s.perceptions.map(
            (String k, String v) => MapEntry<String, String>(joLf(k), joLf(v)),
          ),
        ),
        joLf(s.chosen),
        joLf(s.judgment),
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
      <Object?>[joLf(text), worldId, laneId, index],
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
      _writeBook(worldId, book);
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  /// 覆盖**一整个世界**的记忆（多个主人）。
  ///
  /// 弹窗交回来的就是完整一份，所以：没了的主人删掉、有的一条条重写。
  /// 全在一个事务里——中途出错不会剩半本。
  void saveMemories(String worldId, Map<String, MemoryBook> books) {
    _db.execute('BEGIN;');
    try {
      final ResultSet rs = _db.select(
        'SELECT DISTINCT owner FROM memory WHERE world_id = ?;',
        <Object?>[worldId],
      );
      for (final Row r in rs) {
        final String owner = '${r['owner']}';
        if (books.containsKey(owner)) continue;
        _db.execute(
          'DELETE FROM memory WHERE world_id = ? AND owner = ?;',
          <Object?>[worldId, owner],
        );
      }
      for (final MemoryBook b in books.values) {
        _writeBook(worldId, b);
      }
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  /// 写一本（已在外层事务里）。
  void _writeBook(String worldId, MemoryBook book) {
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
          joLf(m.content),
          joLf(m.kind),
          m.source.name,
          m.createdAt.toIso8601String(),
          m.updatedAt.toIso8601String(),
        ],
      );
    }
  }

  // ————————————————————————————— 每个角色自己的配置

  /// 读一个世界里“每个角色自己的模型与选择”。
  ///
  /// 读不出来那一条就跳过（不连累其它角色），跟别处一个规矩。
  ({Map<String, ModelPlan> plans, Map<String, CharChoices> choices})
  loadCharCfg(String worldId) {
    final Map<String, ModelPlan> plans = <String, ModelPlan>{};
    final Map<String, CharChoices> choices = <String, CharChoices>{};
    final ResultSet rs = _db.select(
      'SELECT * FROM char_cfg WHERE world_id = ?;',
      <Object?>[worldId],
    );
    for (final Row r in rs) {
      final String name = '${r['name']}';
      final String plan = '${r['plan'] ?? ''}';
      final String ch = '${r['choices'] ?? ''}';
      if (plan.isNotEmpty) {
        try {
          plans[name] = ModelPlan.fromJson(
            (jsonDecode(plan) as Map).cast<String, Object?>(),
          );
        } catch (_) {
          // 这一条的模型坏了，跳过；选择还能读。
        }
      }
      if (ch.isNotEmpty) {
        try {
          choices[name] = CharChoices.fromJson(
            (jsonDecode(ch) as Map).cast<String, Object?>(),
          );
        } catch (_) {
          // 同上。
        }
      }
    }
    return (plans: plans, choices: choices);
  }

  /// 写一个角色自己的模型（空 = 不设，跟随世界默认）。
  void saveCharPlan(String worldId, String name, ModelPlan plan) {
    _writeCharCfg(
      worldId,
      name,
      plan.defaultRef.isEmpty && plan.byStep.isEmpty
          ? ''
          : jsonEncode(plan.toJson()),
    );
  }

  /// 写一整个世界的“每个角色自己的选择”（弹窗交回来的就是整份）。
  void saveCharChoices(String worldId, Map<String, CharChoices> choices) {
    final ResultSet rs = _db.select(
      'SELECT DISTINCT name FROM char_cfg WHERE world_id = ?;',
      <Object?>[worldId],
    );
    final Set<String> inDb = <String>{for (final Row r in rs) '${r['name']}'};
    _db.execute('BEGIN;');
    try {
      for (final String name in inDb) {
        if (choices.containsKey(name)) continue;
        // 这个角色已经没有自己的选择了：清空那一栏（不删行，模型还在）。
        _setCharField(worldId, name, choicesJson: '');
      }
      for (final MapEntry<String, CharChoices> e in choices.entries) {
        _writeCharCfg(
          worldId,
          e.key,
          null,
          choicesJson: e.value.isEmpty ? '' : jsonEncode(e.value.toJson()),
        );
      }
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  /// 写一整个世界的“每个角色自己的模型”（弹窗交回来的就是整份）。
  void saveCharPlans(String worldId, Map<String, ModelPlan> plans) {
    _db.execute('BEGIN;');
    try {
      final ResultSet rs = _db.select(
        'SELECT DISTINCT name FROM char_cfg WHERE world_id = ?;',
        <Object?>[worldId],
      );
      final Set<String> inDb = <String>{for (final Row r in rs) '${r['name']}'};
      for (final String name in inDb) {
        if (plans.containsKey(name)) continue;
        // 这个角色已经没有自己的模型了：清空那一栏（行留着，选择还在）。
        _writeCharCfg(worldId, name, '');
      }
      for (final MapEntry<String, ModelPlan> e in plans.entries) {
        final ModelPlan p = e.value;
        _writeCharCfg(
          worldId,
          e.key,
          p.defaultRef.isEmpty && p.byStep.isEmpty
              ? ''
              : jsonEncode(p.toJson()),
        );
      }
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  /// 写 char_cfg 一行。`null` = 这一栏不动。
  void _writeCharCfg(
    String worldId,
    String name,
    String? planJson, {
    String? choicesJson,
  }) {
    final ResultSet cur = _db.select(
      'SELECT plan, choices FROM char_cfg WHERE world_id = ? AND name = ?;',
      <Object?>[worldId, name],
    );
    final String plan = planJson ?? (cur.isEmpty ? '' : '${cur.first['plan']}');
    final String ch =
        choicesJson ?? (cur.isEmpty ? '' : '${cur.first['choices']}');
    if (plan.isEmpty && ch.isEmpty) {
      _db.execute(
        'DELETE FROM char_cfg WHERE world_id = ? AND name = ?;',
        <Object?>[worldId, name],
      );
      return;
    }
    _db.execute(
      '''
        INSERT INTO char_cfg (world_id, name, plan, choices)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(world_id, name) DO UPDATE SET
          plan=excluded.plan, choices=excluded.choices;
        ''',
      <Object?>[worldId, name, plan, ch],
    );
  }

  void _setCharField(String worldId, String name, {String? choicesJson}) {
    _writeCharCfg(worldId, name, null, choicesJson: choicesJson);
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
