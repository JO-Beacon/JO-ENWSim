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
//   step    一步一行。按 (world, 并行地点, 步序) 追加。
//   memory  旧版记忆表；已删除，记忆改存 turn 里的 TurnState.memory。

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../engine/character_memory.dart';
import '../engine/engine_state.dart';
import '../engine/perception.dart';
import '../engine/turn_session.dart';
import '../model/char_choices.dart';
import '../model/demo.dart';
import '../model/llm_client.dart';
import '../model/model_plan.dart';
import '../model/text.dart';
import '../model/turn.dart';
import '../model/world_search.dart';

part 'world_timeline.dart';

/// 库的版本。
///
/// 当前还没有发布过版本，v1 就是第一个、也是唯一 baseline。
/// 改结构直接改 [_createSchemaV1]，不需要保留历史迁移分支。
const int kSchemaVersion = 1;

/// 读一整个世界的结果：读出来多少、坏了几条。
///
/// 跟 `LoadResult` 一个意思，只是这里的单位是“世界”。
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

/// 数据页用的只读统计。
///
/// 所有数字都是**当前库的实际值**：SQLite 的 `LENGTH(CAST(x AS BLOB))`
/// 按 UTF-8 字节算，不能用 `LENGTH(x)`（那个数的是字符）。
class DatabaseStats {
  const DatabaseStats({
    required this.filePath,
    required this.fileBytes,
    required this.walBytes,
    required this.pageSize,
    required this.pageCount,
    required this.freelistCount,
    required this.worldCount,
    required this.worldSettingBytes,
    required this.assetRows,
    required this.assetBytes,
    required this.turnRows,
    required this.turnBytes,
    required this.maxTurnBytes,
    required this.stepRows,
    required this.stepBytes,
    required this.worlds,
  });

  /// 主库文件路径；内存库为空串。
  final String filePath;

  /// 主库文件 `joenws.db` 的字节数；内存库为 0。
  final int fileBytes;

  bool get isMemory => filePath.isEmpty;

  /// `joenws.db-wal` 的字节数；没开 WAL 时为 0。
  final int walBytes;

  final int pageSize;
  final int pageCount;
  final int freelistCount;
  final int worldCount;

  /// 世界设定 / 开场 / 角色 / 序列这些 JSON 字段的字节数。
  final int worldSettingBytes;

  /// 附件个数与文件字节数（文件本体在 assets/，不在库文件里）。
  final int assetRows;
  final int assetBytes;

  /// 世界级单份状态（`parallel_place_id = ''`）的快照行数。
  final int turnRows;

  /// 这些快照的 `state_json` 总字节数。
  final int turnBytes;

  /// 其中最大的一份。
  final int maxTurnBytes;

  final int stepRows;

  /// 画布步正文的字节数（只算 `step.text`）。
  final int stepBytes;

  /// 按世界拆开的快照统计，占用大的排前面。
  final List<WorldSnapshotStat> worlds;

  double get averageTurnBytes => turnRows == 0 ? 0 : turnBytes / turnRows;
  int get totalFileBytes => fileBytes + walBytes;
}

class WorldSnapshotStat {
  const WorldSnapshotStat({
    required this.id,
    required this.name,
    required this.turnRows,
    required this.turnBytes,
    required this.maxTurnBytes,
  });

  final String id;
  final String name;
  final int turnRows;
  final int turnBytes;
  final int maxTurnBytes;
}

/// 一份玩家输入附件。文件本体在 `rel_path`，这里只有元数据。
class AssetRecord {
  const AssetRecord({
    required this.id,
    required this.worldId,
    required this.kind,
    required this.mime,
    required this.name,
    required this.relPath,
    required this.bytes,
    required this.createdAt,
  });

  final String id;
  final String worldId;

  /// image / pdf / text
  final String kind;
  final String mime;
  final String name;
  final String relPath;
  final int bytes;
  final String createdAt;

  static AssetRecord fromRow(Row r) => AssetRecord(
    id: '${r['id']}',
    worldId: '${r['world_id']}',
    kind: '${r['kind']}',
    mime: '${r['mime']}',
    name: '${r['name']}',
    relPath: '${r['rel_path']}',
    bytes: r['bytes']! as int,
    createdAt: '${r['created_at']}',
  );
}

/// 一次玩家输入：原文 + 挂在这条输入上的附件。
class PlayerInputRecord {
  const PlayerInputRecord({
    required this.id,
    required this.worldId,
    required this.parallelPlaceId,
    required this.rawText,
    required this.createdAt,
    required this.assets,
  });

  final String id;
  final String worldId;
  final String parallelPlaceId;
  final String rawText;
  final String createdAt;
  final List<AssetRecord> assets;
}

class WorldStore {
  WorldStore._(this._db, this._baseDir);

  Database _db;

  /// 当前打开数据库的启动提示；完整性检查失败并恢复时非空。
  String? _startupNote;

  String? get startupNote => _startupNote;

  /// 库文件所在目录；附件文件放它下面的 `assets/`。
  /// 内存库为空串（不支持附件）。
  final String _baseDir;

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
    WorldStore s = WorldStore._(sqlite3.open(p), File(p).parent.path);
    String integrity;
    try {
      s._configureConnection();
      integrity = s.integrityCheck();
    } catch (err) {
      integrity = '打开检查失败：$err';
    }
    if (integrity != 'ok') {
      // 先把损坏的连接关掉，Windows 才允许重命名数据库文件。
      try {
        s._db.close();
      } catch (_) {
        // 连接已经坏了；继续尝试备份，备份成功后再新建。
      }
      final String? backup = s._backupCorruptDatabase(p);
      s._db = sqlite3.open(p);
      s._configureConnection();
      s._startupNote =
          '数据库完整性检查失败（$integrity）。'
          '${backup == null ? '原库无法备份' : '原库已备份为 $backup'}，'
          '已新建空库。';
    }
    s._ensureWorldSearchColumn();
    final int before = s._migrate();
    // **只有从 0 升上来才算“新建”**。
    // 以前这里看的是“有没有跑过迁移”，于是每次升版都会重播一遍 demo，
    // 把用户改过的 demo 世界覆盖回去。
    if (before == 0) s.seedDemo();
    return s;
  }

  /// 内存库。给测试用（跑完就没了）。**不播种**。
  static WorldStore memory() {
    final WorldStore s = WorldStore._(sqlite3.openInMemory(), '');
    s._configureConnection();
    return s.._migrate();
  }

  /// SQLite 连接级设置：WAL 只对磁盘库有意义。
  void _configureConnection() {
    _db.execute('PRAGMA busy_timeout = 5000;');
    if (_baseDir.isNotEmpty) {
      _db.execute('PRAGMA journal_mode = WAL;');
      _db.execute('PRAGMA synchronous = NORMAL;');
      _db.execute('PRAGMA wal_autocheckpoint = 1000;');
    }
  }

  /// 返回 `ok` 或 SQLite 的完整检查结果。给启动检查和诊断共用。
  String integrityCheck() {
    try {
      final ResultSet rs = _db.select('PRAGMA integrity_check;');
      final List<String> rows = <String>[
        for (final Row r in rs)
          if (r.values.isNotEmpty) '${r.values.first}',
      ];
      if (rows.isEmpty) return 'ok';
      return rows.join('；');
    } catch (err) {
      return '检查失败：$err';
    }
  }

  /// 当前 journal mode，给测试和诊断看；内存库通常是 memory。
  String journalMode() {
    try {
      final ResultSet rs = _db.select('PRAGMA journal_mode;');
      if (rs.isEmpty || rs.first.values.isEmpty) return '';
      return '${rs.first.values.first}';
    } catch (_) {
      return '';
    }
  }

  /// 备份坏库和它的 WAL/SHM 边车文件；返回备份主路径，失败返回 null。
  String? _backupCorruptDatabase(String path) {
    final String stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(RegExp(r'[^0-9A-Za-z]+'), '-');
    final String backup = '$path.corrupt-$stamp';
    try {
      final File main = File(path);
      if (main.existsSync()) main.renameSync(backup);
      final File wal = File('$path-wal');
      if (wal.existsSync()) wal.renameSync('$backup-wal');
      final File shm = File('$path-shm');
      if (shm.existsSync()) shm.renameSync('$backup-shm');
      return main.existsSync() || File(backup).existsSync() ? backup : null;
    } catch (_) {
      return null;
    }
  }

  /// 把 `DemoData` 那几个世界写进去。
  ///
  /// 公开是为了能单独测——磁盘库不是哪里都跑得起来。
  void seedDemo() {
    for (final World w in DemoData.worlds) {
      saveWorld(w);
    }
  }

  void close() {
    try {
      _db.execute('PRAGMA wal_checkpoint(TRUNCATE);');
    } catch (_) {
      // 内存库或已经失效的连接没有 WAL 可 checkpoint；照常关闭。
    }
    _db.close();
  }

  /// 库里有哪些索引（给测试用：确认索引真的建了）。
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

  // ————————————————————————————— 玩家输入附件

  int _idSeq = 0;
  String _newId(String prefix) =>
      '$prefix${DateTime.now().microsecondsSinceEpoch}_${_idSeq++}';

  String _newEventUid() => _newId('evt_');

  String _absolute(String relPath) =>
      '$_baseDir${Platform.pathSeparator}'
      '${relPath.replaceAll('/', Platform.pathSeparator)}';

  String _extOf(String name) {
    final int i = name.lastIndexOf('.');
    if (i <= 0 || i == name.length - 1) return '';
    final String ext = name.substring(i).toLowerCase();
    return RegExp(r'^\.[a-z0-9]{1,10}$').hasMatch(ext) ? ext : '';
  }

  File assetFile(AssetRecord a) => File(_absolute(a.relPath));

  AssetRecord? findAsset(String id) {
    final ResultSet rs = _db.select(
      'SELECT * FROM asset WHERE id = ?;',
      <Object?>[id],
    );
    if (rs.isEmpty) return null;
    return AssetRecord.fromRow(rs.first);
  }

  /// 缓存附件的抽取文本（PDF 文本层 / 文本文件）。
  void saveAssetText(String assetId, String text) {
    _db.execute(
      'INSERT INTO asset_text (asset_id, text, created_at) VALUES (?, ?, ?) '
      'ON CONFLICT(asset_id) DO UPDATE SET '
      'text=excluded.text, created_at=excluded.created_at;',
      <Object?>[assetId, text, DateTime.now().toIso8601String()],
    );
  }

  String? loadAssetText(String assetId) {
    final ResultSet rs = _db.select(
      'SELECT text FROM asset_text WHERE asset_id = ?;',
      <Object?>[assetId],
    );
    if (rs.isEmpty) return null;
    return '${rs.first['text']}';
  }

  /// 删一份还没被任何输入引用的附件（输入框里点 × 时用）。
  void deleteAsset(String id) {
    final AssetRecord? a = findAsset(id);
    if (a == null) return;
    _db.execute('DELETE FROM input_asset WHERE asset_id = ?;', <Object?>[id]);
    _db.execute('DELETE FROM asset_text WHERE asset_id = ?;', <Object?>[id]);
    _db.execute('DELETE FROM asset WHERE id = ?;', <Object?>[id]);
    try {
      final File f = assetFile(a);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {
      // 文件删不掉就留个孤儿；库里已经没有它了。
    }
  }

  /// 存一份附件：文件写进应用数据目录，库只记元数据。
  Future<AssetRecord> saveAsset({
    required String worldId,
    required String kind,
    required String mime,
    required String name,
    required List<int> bytes,
    String ext = '',
  }) async {
    if (_baseDir.isEmpty) {
      throw StateError('内存库不支持附件');
    }
    final String id = _newId('a_');
    final String safeWorld = worldId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final String suffix = ext.trim().isEmpty ? _extOf(name) : ext.trim();
    final String rel =
        'assets/$safeWorld/$id${suffix.startsWith('.') ? suffix : '.$suffix'}';
    final File file = File(_absolute(rel));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    final String now = DateTime.now().toIso8601String();
    try {
      _db.execute(
        'INSERT INTO asset '
        '(id, world_id, kind, mime, name, rel_path, bytes, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?);',
        <Object?>[id, worldId, kind, mime, name, rel, bytes.length, now],
      );
    } catch (_) {
      try {
        await file.delete();
      } catch (_) {
        // 文件删不掉就算了，别把原始异常盖住。
      }
      rethrow;
    }
    return AssetRecord(
      id: id,
      worldId: worldId,
      kind: kind,
      mime: mime,
      name: name,
      relPath: rel,
      bytes: bytes.length,
      createdAt: now,
    );
  }

  List<AssetRecord> assetsOfInput(String inputId) {
    final ResultSet rs = _db.select(
      'SELECT a.* FROM asset a '
      'JOIN input_asset ia ON ia.asset_id = a.id '
      'WHERE ia.input_id = ? ORDER BY ia.ordinal;',
      <Object?>[inputId],
    );
    return <AssetRecord>[for (final Row r in rs) AssetRecord.fromRow(r)];
  }

  /// 存一次玩家输入；返回 input id。附件必须已经属于这个世界。
  String savePlayerInput({
    required String worldId,
    required String parallelPlaceId,
    required String rawText,
    List<String> assetIds = const <String>[],
  }) {
    final String id = _newId('input_');
    _db.execute('BEGIN;');
    try {
      _db.execute(
        'INSERT INTO player_input '
        '(id, world_id, parallel_place_id, raw_text, created_at) '
        'VALUES (?, ?, ?, ?, ?);',
        <Object?>[
          id,
          worldId,
          parallelPlaceId,
          joLf(rawText),
          DateTime.now().toIso8601String(),
        ],
      );
      for (int i = 0; i < assetIds.length; i++) {
        final ResultSet found = _db.select(
          'SELECT 1 FROM asset WHERE id = ? AND world_id = ?;',
          <Object?>[assetIds[i], worldId],
        );
        if (found.isEmpty) {
          throw StateError('附件不存在或不属于这个世界：${assetIds[i]}');
        }
        _db.execute(
          'INSERT INTO input_asset (input_id, asset_id, ordinal) '
          'VALUES (?, ?, ?);',
          <Object?>[id, assetIds[i], i],
        );
      }
      _db.execute('COMMIT;');
      return id;
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  PlayerInputRecord? loadPlayerInput(String id) {
    final ResultSet rs = _db.select(
      'SELECT * FROM player_input WHERE id = ?;',
      <Object?>[id],
    );
    if (rs.isEmpty) return null;
    final Row r = rs.first;
    return PlayerInputRecord(
      id: '${r['id']}',
      worldId: '${r['world_id']}',
      parallelPlaceId: '${r['parallel_place_id']}',
      rawText: '${r['raw_text']}',
      createdAt: '${r['created_at']}',
      assets: assetsOfInput(id),
    );
  }

  /// 搜索账本：只记事实，不参与正文生成。
  void saveSearchLog({
    required String worldId,
    required String source,
    required String query,
    required bool ok,
    required String message,
    List<Map<String, Object?>> hits = const <Map<String, Object?>>[],
  }) {
    _db.execute(
      'INSERT INTO search_log '
      '(world_id, source, query, ok, message, hits, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?);',
      <Object?>[
        worldId,
        source,
        query,
        ok ? 1 : 0,
        message,
        jsonEncode(hits),
        DateTime.now().toIso8601String(),
      ],
    );
  }

  List<Map<String, Object?>> loadSearchLogs(
    String worldId, {
    int limit = 20,
  }) {
    final ResultSet rs = _db.select(
      'SELECT source, query, ok, message, hits, created_at '
      'FROM search_log WHERE world_id = ? ORDER BY id DESC LIMIT ?;',
      <Object?>[worldId, limit],
    );
    return <Map<String, Object?>>[
      for (final Row r in rs)
        <String, Object?>{
          'source': '${r['source']}',
          'query': '${r['query']}',
          'ok': r['ok'] == 1,
          'message': '${r['message']}',
          'hits': jsonDecode('${r['hits']}'),
          'createdAt': '${r['created_at']}',
        },
    ];
  }

  /// 这个世界最后一次落下一回合快照的时间；没有回合就是 null。
  String? lastPlayedAt(String worldId) {
    final ResultSet rs = _db.select(
      'SELECT MAX(created_at) AS t FROM turn WHERE world_id = ?;',
      <Object?>[worldId],
    );
    final Object? raw = rs.first['t'];
    if (raw == null) return null;
    final String text = '$raw'.trim();
    return text.isEmpty ? null : text;
  }

  /// 数据页的只读统计。**不改任何数据。**
  ///
  /// 只统计 `parallel_place_id = ''` 的世界级快照；旧的按地点分份的
  /// `turn` 行不再写入、也不再读，不能算进“当前世界状态”。
  DatabaseStats databaseStats() {
    int one(String sql) => _db.select(sql).first.values.first! as int;

    final int pageSize = one('PRAGMA page_size;');
    final int pageCount = one('PRAGMA page_count;');
    final int freelistCount = one('PRAGMA freelist_count;');

    String mainPath = '';
    for (final Row r in _db.select('PRAGMA database_list;')) {
      if ('${r['name']}' != 'main') continue;
      final Object? raw = r['file'];
      mainPath = raw == null ? '' : '$raw';
      break;
    }
    final int fileBytes = _lengthOf(mainPath);
    final int walBytes = _lengthOf(mainPath.isEmpty ? '' : '$mainPath-wal');

    final Row world = _db
        .select(
          'SELECT COUNT(*) AS rows, '
          'COALESCE(SUM('
          'LENGTH(CAST(setting AS BLOB)) + '
          'LENGTH(CAST(opening AS BLOB)) + '
          'LENGTH(CAST(characters AS BLOB)) + '
          'LENGTH(CAST(parallel_places AS BLOB)) + '
          'LENGTH(CAST(moves AS BLOB))'
          '), 0) AS bytes FROM world;',
        )
        .first;

    final Row turn = _db
        .select(
          'SELECT COUNT(*) AS rows, '
          'COALESCE(SUM(LENGTH(CAST(state_json AS BLOB))), 0) AS bytes, '
          'COALESCE(MAX(LENGTH(CAST(state_json AS BLOB))), 0) AS max_bytes '
          "FROM turn WHERE parallel_place_id = '';",
        )
        .first;

    final Row step = _db
        .select(
          'SELECT COUNT(*) AS rows, '
          'COALESCE(SUM(LENGTH(CAST(text AS BLOB))), 0) AS bytes FROM step;',
        )
        .first;

    final Row asset = _db
        .select(
          'SELECT COUNT(*) AS rows, COALESCE(SUM(bytes), 0) AS bytes FROM asset;',
        )
        .first;

    final List<WorldSnapshotStat> worlds = <WorldSnapshotStat>[
      for (final Row r in _db.select(
        'SELECT w.id AS id, w.name AS name, '
        'COUNT(t.turn_no) AS turns, '
        'COALESCE(SUM(LENGTH(CAST(t.state_json AS BLOB))), 0) AS bytes, '
        'COALESCE(MAX(LENGTH(CAST(t.state_json AS BLOB))), 0) AS max_bytes '
        'FROM world w '
        "LEFT JOIN turn t ON t.world_id = w.id AND t.parallel_place_id = '' "
        'GROUP BY w.id '
        'ORDER BY bytes DESC, w.rowid;',
      ))
        WorldSnapshotStat(
          id: '${r['id']}',
          name: '${r['name']}',
          turnRows: r['turns']! as int,
          turnBytes: r['bytes']! as int,
          maxTurnBytes: r['max_bytes']! as int,
        ),
    ];

    return DatabaseStats(
      filePath: mainPath,
      fileBytes: fileBytes,
      walBytes: walBytes,
      pageSize: pageSize,
      pageCount: pageCount,
      freelistCount: freelistCount,
      worldCount: world['rows']! as int,
      worldSettingBytes: world['bytes']! as int,
      assetRows: asset['rows']! as int,
      assetBytes: asset['bytes']! as int,
      turnRows: turn['rows']! as int,
      turnBytes: turn['bytes']! as int,
      maxTurnBytes: turn['max_bytes']! as int,
      stepRows: step['rows']! as int,
      stepBytes: step['bytes']! as int,
      worlds: worlds,
    );
  }

  static int _lengthOf(String path) {
    if (path.isEmpty) return 0;
    try {
      final File f = File(path);
      return f.existsSync() ? f.lengthSync() : 0;
    } catch (_) {
      return 0;
    }
  }

  // ————————————————————————————— 建表与迁移

  /// 建表与迁移。**返回迁移前的版本号**（0 = 全新库）。
  int _migrate() {
    final int v = _db.select('PRAGMA user_version;').first.values.first! as int;
    if (v > kSchemaVersion) {
      throw StateError('数据库版本 $v 高于当前 schema $kSchemaVersion，拒绝打开。');
    }
    if (v == kSchemaVersion) {
      _ensureTtsColumn();
      _ensureTurnTable();
      _createTimelineTables();
      return v;
    }
    if (v > 0) {
      throw StateError('旧数据库版本 $v 不再兼容；当前只支持新建数据库。');
    }

    // 没有发布过版本，不存在需要兼容的旧库；v1 直接建完整结构。
    _db.execute('BEGIN;');
    try {
      _createSchemaV1();
      _createTimelineTables();
      _ensureTtsColumn();
      _ensureTurnTable();
      _db.execute('PRAGMA user_version = $kSchemaVersion;');
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
    return 0;
  }

  /// 旧 v1 库没有 tts_key；本地开发库直接补列，不影响已有数据。
  void _ensureTtsColumn() {
    try {
      _db.execute(
        "ALTER TABLE world ADD COLUMN tts_key TEXT NOT NULL DEFAULT '';",
      );
    } catch (_) {
      // 新库在 CREATE TABLE 里已经有这一列。
    }
    try {
      _db.execute(
        "ALTER TABLE world ADD COLUMN narrator_tts_key TEXT NOT NULL DEFAULT '';",
      );
    } catch (_) {
      // 同上。
    }
  }

  /// 回合快照表以前叫 `v2_turn`；旧库里的那张表在这里改名成 `turn`，数据原样保留。
  ///
  /// **这是全库唯一还写着旧表名的地方，不能删** —— 删掉之后，改名之前建的
  /// 开发库一打开就会找不到表。
  void _ensureTurnTable() {
    if (_tableExists('v2_turn')) {
      if (!_tableExists('turn')) {
        _db.execute('ALTER TABLE v2_turn RENAME TO turn;');
      }
    }
  }

  bool _tableExists(String name) => _db
      .select(
        "SELECT name FROM sqlite_master WHERE type='table' AND name = ?;",
        <Object?>[name],
      )
      .isNotEmpty;

  void _ensureWorldSearchColumn() {
    final bool tableExists = _db
        .select("SELECT name FROM sqlite_master WHERE type='table' AND name='world';")
        .isNotEmpty;
    if (!tableExists) return;
    final bool exists = _db
        .select('PRAGMA table_info(world);')
        .any((Row r) => '${r['name']}' == 'search_source');
    if (!exists) {
      _db.execute(
        "ALTER TABLE world ADD COLUMN search_source TEXT NOT NULL DEFAULT 'off';",
      );
    }
    _db.execute('''
CREATE TABLE IF NOT EXISTS search_log (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  world_id   TEXT NOT NULL,
  source     TEXT NOT NULL,
  query      TEXT NOT NULL,
  ok         INTEGER NOT NULL DEFAULT 0,
  message    TEXT NOT NULL DEFAULT '',
  hits       TEXT NOT NULL DEFAULT '[]',
  created_at TEXT NOT NULL DEFAULT ''
);
''');
    _db.execute('''
CREATE INDEX IF NOT EXISTS idx_search_log_world
  ON search_log(world_id, created_at);
''');
  }

  /// 当前 v1 的完整表结构（不再保留历史迁移分支）。
  void _createSchemaV1() {
    _db.execute('''
CREATE TABLE world (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL DEFAULT '',
  note        TEXT NOT NULL DEFAULT '',
  setting     TEXT NOT NULL DEFAULT '',
  opening     TEXT NOT NULL DEFAULT '',
  controlled_character_name TEXT NOT NULL DEFAULT '',
  tts_key   TEXT NOT NULL DEFAULT '',
  narrator_tts_key TEXT NOT NULL DEFAULT '',
  search_source TEXT NOT NULL DEFAULT 'off',
  characters  TEXT NOT NULL DEFAULT '[]',
  parallel_places TEXT NOT NULL DEFAULT '[]',
  moves       TEXT NOT NULL DEFAULT '[]'
);
''');
    _db.execute('''
CREATE TABLE step (
  world_id    TEXT NOT NULL,
  parallel_place_id TEXT NOT NULL,
  seq         INTEGER NOT NULL,
  kind        TEXT NOT NULL,
  who         TEXT NOT NULL DEFAULT '',
  time        TEXT NOT NULL DEFAULT '',
  text        TEXT NOT NULL DEFAULT '',
  candidates  TEXT NOT NULL DEFAULT '[]',
  perceptions TEXT NOT NULL DEFAULT '{}',
  chosen      TEXT NOT NULL DEFAULT '',
  judgment    TEXT NOT NULL DEFAULT '',
  attachments TEXT NOT NULL DEFAULT '[]',
  error       TEXT,
  model       TEXT,
  choices     TEXT,
  usage       TEXT,
  PRIMARY KEY (world_id, parallel_place_id, seq)
);
''');
    _db.execute('''
CREATE INDEX IF NOT EXISTS idx_step_lane
  ON step(world_id, parallel_place_id, seq);
''');
    _db.execute('''
CREATE TABLE char_cfg (
  world_id TEXT NOT NULL,
  name     TEXT NOT NULL,
  plan     TEXT NOT NULL DEFAULT '',
  choices  TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (world_id, name)
);
''');
    _db.execute('''
CREATE TABLE turn (
  world_id   TEXT NOT NULL,
  parallel_place_id TEXT NOT NULL,
  turn_no    INTEGER NOT NULL,
  state_json TEXT NOT NULL DEFAULT '{}',
  event_ids  TEXT NOT NULL DEFAULT '[]',
  memory_refs TEXT NOT NULL DEFAULT '[]',
  created_at TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (world_id, parallel_place_id, turn_no)
);
''');
    _db.execute('''
CREATE TABLE turn_session (
  world_id   TEXT PRIMARY KEY,
  parallel_place_id TEXT NOT NULL DEFAULT '',
  payload    TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL DEFAULT '',
  updated_at TEXT NOT NULL DEFAULT ''
);
''');
    _db.execute('''
CREATE TABLE asset (
  id         TEXT PRIMARY KEY,
  world_id   TEXT NOT NULL,
  kind       TEXT NOT NULL DEFAULT '',
  mime       TEXT NOT NULL DEFAULT '',
  name       TEXT NOT NULL DEFAULT '',
  rel_path   TEXT NOT NULL DEFAULT '',
  bytes      INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT ''
);
''');
    _db.execute('''
CREATE INDEX IF NOT EXISTS idx_asset_world
  ON asset(world_id, created_at);
''');
    _db.execute('''
CREATE TABLE asset_text (
  asset_id   TEXT PRIMARY KEY,
  text       TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT ''
);
''');
    _db.execute('''
CREATE TABLE search_log (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  world_id   TEXT NOT NULL,
  source     TEXT NOT NULL,
  query      TEXT NOT NULL,
  ok         INTEGER NOT NULL DEFAULT 0,
  message    TEXT NOT NULL DEFAULT '',
  hits       TEXT NOT NULL DEFAULT '[]',
  created_at TEXT NOT NULL DEFAULT ''
);
''');
    _db.execute('''
CREATE INDEX IF NOT EXISTS idx_search_log_world
  ON search_log(world_id, created_at);
''');
    _db.execute('''
CREATE TABLE player_input (
  id         TEXT PRIMARY KEY,
  world_id   TEXT NOT NULL,
  parallel_place_id TEXT NOT NULL DEFAULT '',
  raw_text   TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT ''
);
''');
    _db.execute('''
CREATE INDEX IF NOT EXISTS idx_player_input_world
  ON player_input(world_id, created_at);
''');
    _db.execute('''
CREATE TABLE input_asset (
  input_id TEXT NOT NULL,
  asset_id TEXT NOT NULL,
  ordinal  INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (input_id, asset_id)
);
''');
    _db.execute('''
CREATE TABLE event (
  world_id   TEXT NOT NULL,
  event_uid  TEXT NOT NULL,
  event_id   TEXT NOT NULL DEFAULT '',
  parallel_place_id TEXT NOT NULL DEFAULT '',
  turn_no    INTEGER NOT NULL,
  seq        INTEGER NOT NULL,
  payload    TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (world_id, event_uid)
);
''');
    _db.execute('''
CREATE INDEX IF NOT EXISTS idx_event_turn
  ON event(world_id, turn_no, seq);
''');
    _db.execute('''
CREATE TABLE memory_version (
  world_id     TEXT NOT NULL,
  memory_id    TEXT NOT NULL,
  version      INTEGER NOT NULL,
  character_id TEXT NOT NULL,
  turn_no      INTEGER NOT NULL,
  session_id   TEXT NOT NULL DEFAULT '',
  op_id        TEXT NOT NULL DEFAULT '',
  payload      TEXT NOT NULL,
  created_at   TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (world_id, memory_id, version)
);
''');
    _db.execute('''
CREATE UNIQUE INDEX IF NOT EXISTS idx_memory_op
  ON memory_version(world_id, session_id, op_id)
  WHERE op_id <> '';
''');
    _db.execute('''
CREATE INDEX IF NOT EXISTS idx_memory_character
  ON memory_version(world_id, character_id);
''');
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
      final bool isNew = _db.select(
        'SELECT 1 FROM world WHERE id = ?;',
        <Object?>[w.id],
      ).isEmpty;
      _upsertWorld(w);
      _reconcileSteps(w);
      if (isNew) _recordOpeningVersion(w.id);
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  /// 只写世界那一行（名字 / 副标题 / 设定 / 开场 / 当前操控角色 / 角色卡 /
  /// 序列表 / 换地点表），**不动 step 表**。
  ///
  /// 编辑弹窗改的就是这些：它不碰步。以前这里走的是 [saveWorld]，
  /// 等于“拿内存里那份旧快照把库里的步全删了重写”——
  /// 内存一旦落后于库（引擎刚追加了一两步），那几步就没了。
  void saveWorldMeta(World w) {
    _db.execute('BEGIN;');
    try {
      final bool isNew = _db.select(
        'SELECT 1 FROM world WHERE id = ?;',
        <Object?>[w.id],
      ).isEmpty;
      _upsertWorld(w);
      if (isNew) _recordOpeningVersion(w.id);
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  /// 世界那一行的 upsert。**不碰步**。
  void _upsertWorld(World w) {
    final Map<String, Object?> data = _timelineWorldData(w);
    _db.execute(
      '''
        INSERT INTO world
          (id, name, note, setting, opening, controlled_character_name, tts_key,
           narrator_tts_key, search_source, characters, parallel_places, moves)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          name=excluded.name, note=excluded.note, setting=excluded.setting,
          opening=excluded.opening, controlled_character_name=excluded.controlled_character_name,
          tts_key=excluded.tts_key,
          narrator_tts_key=excluded.narrator_tts_key,
          search_source=excluded.search_source,
          characters=excluded.characters, parallel_places=excluded.parallel_places,
          moves=excluded.moves;
        ''',
      <Object?>[
        for (final String key in const <String>[
          'id', 'name', 'note', 'setting', 'opening', 'controlled_character_name',
          'tts_key', 'narrator_tts_key', 'search_source', 'characters',
          'parallel_places', 'moves',
        ]) data[key],
      ],
    );
  }

  Map<String, Object?> _timelineWorldData(World w) => <String, Object?>{
        'id': w.id,
        'name': joLf(w.name),
        'note': joLf(w.note),
        'setting': joLf(w.setting),
        'opening': joLf(w.opening),
        'controlled_character_name': joLf(w.controlledCharacterName),
        'tts_key': joLf(w.ttsKey),
        'narrator_tts_key': joLf(w.narratorTtsKey),
        'search_source': w.searchSource.id,
        'characters': jsonEncode(
          w.characters
              .map(
                (CharCard c) => <String, Object?>{
                  'name': joLf(c.name),
                  'persona': joLf(c.persona),
                  'location': joLf(c.location),
                  'state': joLf(c.state),
                  'aliases': c.aliases,
                  'tts': joLf(c.ttsKey),
                },
              )
              .toList(),
        ),
        'parallel_places': jsonEncode(
          w.parallelPlaces
              .map(
                (ParallelPlace l) => <String, Object?>{
                  'id': l.id,
                  'place': joLf(l.place),
                  'here': l.here,
                  'status': l.status,
                  'parentId': l.parentId,
                  'mergeInto': l.mergeInto,
                  // steps 不写在这儿 —— 它们进 step 表（那份才是权威）。
                  // 两份都写就会对不上：appendStep 只写表，JSON 那份会越来越旧。
                },
              )
              .toList(),
        ),
        'moves': jsonEncode(
          w.moves
              .map(
                (MoveLink m) => <String, Object?>{
                  'fromParallelPlace': m.fromParallelPlace,
                  'fromStep': m.fromStep,
                  'toParallelPlace': m.toParallelPlace,
                  'toStep': m.toStep,
                },
              )
              .toList(),
        ),
      };

  /// 把 step 表对齐到内存里的那份：内存有的 upsert、库里多出来的删掉。
  ///
  /// 不像以前那样“先全删再全插”：那样每一步都要重写一遍，
  /// 而且一旦事务外的追加插进来，就会被这份快照抹掉。
  void _reconcileSteps(World w) {
    final Set<String> keep = <String>{};
    for (final ParallelPlace l in w.parallelPlaces) {
      for (int i = 0; i < l.events.length; i++) {
        _insertStep(w.id, l.id, i, l.events[i]);
        keep.add('${l.id}\u0000$i');
      }
    }
    final ResultSet rs = _db.select(
      'SELECT parallel_place_id, seq FROM step WHERE world_id = ?;',
      <Object?>[w.id],
    );
    final List<(String, int)> gone = <(String, int)>[];
    for (final Row r in rs) {
      final String parallelPlace = '${r['parallel_place_id']}';
      final int seq = r['seq']! as int;
      if (!keep.contains('$parallelPlace\u0000$seq')) {
        gone.add((parallelPlace, seq));
      }
    }
    for (final (String, int) g in gone) {
      _db.execute(
        'DELETE FROM step WHERE world_id = ? AND parallel_place_id = ? AND seq = ?;',
        <Object?>[w.id, g.$1, g.$2],
      );
    }
  }

  void deleteWorld(String id) {
    final List<String> assetPaths = <String>[
      for (final Row r in _db.select(
        'SELECT rel_path FROM asset WHERE world_id = ?;',
        <Object?>[id],
      ))
        '${r['rel_path']}',
    ];
    _db.execute('BEGIN;');
    try {
      _deleteTimelineData(id);
      _db.execute('DELETE FROM step WHERE world_id = ?;', <Object?>[id]);
      _db.execute('DELETE FROM char_cfg WHERE world_id = ?;', <Object?>[id]);
      _db.execute('DELETE FROM event WHERE world_id = ?;', <Object?>[id]);
      _db.execute('DELETE FROM memory_version WHERE world_id = ?;', <Object?>[
        id,
      ]);
      _db.execute('DELETE FROM turn WHERE world_id = ?;', <Object?>[id]);
      _db.execute('DELETE FROM turn_session WHERE world_id = ?;', <Object?>[
        id,
      ]);
      _db.execute(
        'DELETE FROM input_asset WHERE input_id IN '
        '(SELECT id FROM player_input WHERE world_id = ?);',
        <Object?>[id],
      );
      _db.execute('DELETE FROM player_input WHERE world_id = ?;', <Object?>[
        id,
      ]);
      _db.execute(
        'DELETE FROM asset_text WHERE asset_id IN '
        '(SELECT id FROM asset WHERE world_id = ?);',
        <Object?>[id],
      );
      _db.execute('DELETE FROM asset WHERE world_id = ?;', <Object?>[id]);
      _db.execute('DELETE FROM world WHERE id = ?;', <Object?>[id]);
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
    // 库已经删干净了，文件删不掉也不回滚，最多留个孤儿文件。
    final Set<String> dirs = <String>{};
    for (final String rel in assetPaths) {
      try {
        final File f = File(_absolute(rel));
        dirs.add(f.parent.path);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {
        // 同上。
      }
    }
    for (final String dir in dirs) {
      try {
        Directory(dir).deleteSync(recursive: true);
      } catch (_) {
        // 目录里还有别的世界的东西就留着。
      }
    }
  }

  // ————————————————————————————— 回合

  /// 最新一回合的状态 JSON。没有就 null。
  String? loadLatestState(String worldId, String parallelPlaceId) {
    final ResultSet rs = _db.select(
      'SELECT state_json FROM turn '
      'WHERE world_id = ? AND parallel_place_id = ? '
      'ORDER BY turn_no DESC LIMIT 1;',
      <Object?>[worldId, parallelPlaceId],
    );
    if (rs.isEmpty) return null;
    return '${rs.first['state_json']}';
  }

  // ——— 世界级单份状态 ———
  //
  // 序列（地点）只是世界状态上的一列：事件、知识、位置、物品都不再按
  // 地点各存一份。`parallel_place_id = ''` 是旧存储列名，语义上是世界级唯一检查点；旧的按并行地点存的行
  // 不再写入，也不再读（未发版，不做迁移）。

  String? loadLatestWorldState(String worldId) =>
      loadLatestState(worldId, '');

  /// 读最新世界状态，并把 event / memory_version 组装回 TurnState。
  TurnState? loadTurnState(String worldId) {
    final ResultSet rs = _db.select(
      'SELECT state_json, event_ids, memory_refs FROM turn '
      "WHERE world_id = ? AND parallel_place_id = '' "
      'ORDER BY turn_no DESC LIMIT 1;',
      <Object?>[worldId],
    );
    if (rs.isEmpty) return null;
    return _turnStateOf(worldId, rs.first);
  }

  TurnState _turnStateOf(String worldId, Row row) {
    final String raw = '${row['state_json'] ?? '{}'}';
    final TurnState base = TurnState.decode(raw);
    final Object? checkpoint = jsonDecode(raw);
    final Object? rawReceipts = checkpoint is Map ? checkpoint['eventReceipts'] : null;
    final Map<String, Object?> receipts = rawReceipts is Map
        ? Map<String, Object?>.from(rawReceipts) : const <String, Object?>{};
    final List<String> eventIds = _jsonStringList(row['event_ids']);
    final List<Map<String, Object?>> refs = _jsonMapList(row['memory_refs']);
    final List<WorldEvent> events = <WorldEvent>[];
    for (final String uid in eventIds) {
      final ResultSet er = _db.select(
        'SELECT payload FROM event WHERE world_id = ? AND event_uid = ?;',
        <Object?>[worldId, uid],
      );
      if (er.isEmpty) {
        throw StateError('存档缺事件：$worldId / $uid');
      }
      final Object? payload = jsonDecode('${er.first['payload']}');
      if (payload is! Map) throw StateError('事件 payload 坏了：$uid');
      WorldEvent event = worldEventFromJson(Map<String, Object?>.from(payload));
      final Object? received = receipts[uid] ?? receipts[event.id];
      if (received is List) {
        event = event.copyWith(receivedBy: received.map((Object? id) => '$id').toList());
      }
      events.add(event);
    }
    final List<CharacterMemory> memory = <CharacterMemory>[];
    for (final Map<String, Object?> ref in refs) {
      final String id = '${ref['id'] ?? ''}';
      final int version = ref['version'] is num
          ? (ref['version'] as num).toInt()
          : 1;
      final ResultSet mr = _db.select(
        'SELECT payload FROM memory_version '
        'WHERE world_id = ? AND memory_id = ? AND version = ?;',
        <Object?>[worldId, id, version],
      );
      if (mr.isEmpty) {
        throw StateError('存档缺记忆：$worldId / $id / v$version');
      }
      final Object? payload = jsonDecode('${mr.first['payload']}');
      if (payload is! Map) throw StateError('记忆 payload 坏了：$id');
      memory.add(CharacterMemory.fromJson(Map<String, Object?>.from(payload)));
    }
    return base.withHistory(events: events, memory: memory);
  }

  List<String> _jsonStringList(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return const <String>[];
    final Object? decoded = jsonDecode(raw);
    if (decoded is! List) return const <String>[];
    return <String>[for (final Object? x in decoded) '$x'];
  }

  List<Map<String, Object?>> _jsonMapList(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) {
      return const <Map<String, Object?>>[];
    }
    final Object? decoded = jsonDecode(raw);
    if (decoded is! List) return const <Map<String, Object?>>[];
    return <Map<String, Object?>>[
      for (final Object? x in decoded)
        if (x is Map) Map<String, Object?>.from(x),
    ];
  }

  int appendWorldTurn(String worldId, String stateJson) =>
      appendTurnState(worldId, '', stateJson);

  /// 把世界快照、main step 和额外 step 放在同一个事务里提交。
  ///
  /// 这是 TurnSession 的最终落账口：要么全写进去，要么全回滚，
  /// 不允许出现“状态写了、step 没写”的半截回合。
  void commitTurn({
    required String worldId,
    int? baseVersionId,
    required String stateJson,
    required String parallelPlaceId,
    required TurnStep mainStep,
    List<({String parallelPlaceId, TurnStep step})> extraSteps =
        const <({String parallelPlaceId, TurnStep step})>[],
    List<WorldEvent> events = const <WorldEvent>[],
    List<CharacterMemory> memory = const <CharacterMemory>[],
    String sessionId = '',
    World? world,
    TurnSession? session,
    TimelineNarrationInput? narration,
  }) {
    _db.execute('BEGIN;');
    try {
      final TimelineBranch? main = loadTimelineBranch(worldId, mainTimelineId);
      if (main != null && sessionId.isNotEmpty &&
          _committedTimelineTask(worldId, mainTimelineId, sessionId) != null) {
        _db.execute('COMMIT;');
        return;
      }
      final int? expectedBase = baseVersionId ?? session?.baseVersionId;
      if (expectedBase != null && main?.headVersionId != expectedBase) {
        throw TimelineBaseChanged();
      }
      if (world != null) _upsertWorld(world);

      final ResultSet turnRs = _db.select(
        'SELECT COALESCE(MAX(turn_no), -1) + 1 AS n FROM turn '
        "WHERE world_id = ? AND parallel_place_id = '';",
        <Object?>[worldId],
      );
      final int turnNo = turnRs.first['n']! as int;
      final List<String> eventIds = <String>[];
      for (final WorldEvent e in events) {
        final String uid = e.uid.trim().isEmpty ? _newEventUid() : e.uid;
        eventIds.add(uid);
        final String payload = jsonEncode(
          worldEventToJson(e.copyWith(uid: uid, receivedBy: const <String>[])),
        );
        final ResultSet existing = _db.select(
          'SELECT payload FROM event WHERE world_id = ? AND event_uid = ?;',
          <Object?>[worldId, uid],
        );
        if (existing.isNotEmpty) {
          final Object? stored = jsonDecode('${existing.first['payload']}');
          final String normalized = stored is Map ? jsonEncode(worldEventToJson(
              worldEventFromJson(Map<String, Object?>.from(stored)).copyWith(receivedBy: const <String>[]))) : '';
          if (normalized != payload) {
            throw StateError('事件 uid 冲突且内容不同：$worldId / $uid');
          }
          continue;
        }
        _db.execute(
          '''
          INSERT INTO event
            (world_id, event_uid, event_id, parallel_place_id, turn_no, seq, payload, created_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?);
          ''',
          <Object?>[
            worldId,
            uid,
            e.id,
            parallelPlaceId,
            turnNo,
            eventIds.length - 1,
            payload,
            DateTime.now().toIso8601String(),
          ],
        );
      }
      final List<Map<String, Object?>> memoryRefs = <Map<String, Object?>>[];
      for (final CharacterMemory m in memory) {
        final int version = m.version <= 0 ? 1 : m.version;
        memoryRefs.add(<String, Object?>{'id': m.id, 'version': version});
        final String payload = jsonEncode(m.toJson());
        final ResultSet existing = _db.select(
          'SELECT payload FROM memory_version '
          'WHERE world_id = ? AND memory_id = ? AND version = ?;',
          <Object?>[worldId, m.id, version],
        );
        if (existing.isNotEmpty) {
          if ('${existing.first['payload']}' != payload) {
            throw StateError('记忆版本冲突：$worldId / ${m.id} / v$version');
          }
          continue;
        }
        _db.execute(
          '''
          INSERT INTO memory_version
            (world_id, memory_id, version, character_id, turn_no,
             session_id, op_id, payload, created_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
          ''',
          <Object?>[
            worldId,
            m.id,
            version,
            m.characterId,
            turnNo,
            sessionId,
            '${m.id}:v$version',
            payload,
            DateTime.now().toIso8601String(),
          ],
        );
      }
      _db.execute(
        'INSERT INTO turn '
        '(world_id, parallel_place_id, turn_no, state_json, event_ids, memory_refs, '
        'created_at) '
        "VALUES (?, '', ?, ?, ?, ?, ?);",
        <Object?>[
          worldId,
          turnNo,
          stateJson,
          jsonEncode(eventIds),
          jsonEncode(memoryRefs),
          DateTime.now().toIso8601String(),
        ],
      );

      final Map<String, int> newCards = <String, int>{};
      void addStep(String stepParallelPlaceId, TurnStep s) {
        final ResultSet seqRs = _db.select(
          'SELECT COALESCE(MAX(seq), -1) + 1 AS n FROM step '
          'WHERE world_id = ? AND parallel_place_id = ?;',
          <Object?>[worldId, stepParallelPlaceId],
        );
        final int seq = seqRs.first['n']! as int;
        _insertStep(worldId, stepParallelPlaceId, seq, s);
        if (s.showsOnCanvas) {
          newCards.update(stepParallelPlaceId, (int count) => count + 1, ifAbsent: () => 1);
        }
      }

      addStep(parallelPlaceId, mainStep);
      for (final ({String parallelPlaceId, TurnStep step}) extra
          in extraSteps) {
        addStep(extra.parallelPlaceId, extra.step);
      }
      if (main != null) {
        _recordMainTurn(main, sessionId, turnNo, newCards, session, narration);
        if (sessionId.isNotEmpty) {
          clearTimelineSession(worldId, mainTimelineId, taskId: sessionId);
        }
      }
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  bool deleteLatestWorldTurn(String worldId) => deleteLatestTurnState(worldId, '');

  /// 删掉最近一条“引擎”写下的画布步，返回它属于哪条序列。
  ///
  /// 退回上一回合时，世界状态删的是最后一份；画布步不一定是当前聚焦
  /// 的那条线（多线之后可能是别的列），所以按 rowid 找最近一条。
  String? deleteLatestEngineStep(String worldId) {
    final ResultSet rs = _db.select(
      "SELECT rowid AS rid, parallel_place_id FROM step "
      "WHERE world_id = ? AND judgment LIKE '引擎：%' "
      'ORDER BY rowid DESC LIMIT 1;',
      <Object?>[worldId],
    );
    if (rs.isEmpty) return null;
    final String parallelPlaceId = '${rs.first['parallel_place_id']}';
    final int rid = rs.first['rid']! as int;
    _db.execute('DELETE FROM step WHERE rowid = ?;', <Object?>[rid]);
    return parallelPlaceId;
  }

  /// 这个地点已经存了哪些回合号（给回滚/未来分支用）。
  List<int> turnNumbers(String worldId, String parallelPlaceId) {
    final ResultSet rs = _db.select(
      'SELECT turn_no FROM turn '
      'WHERE world_id = ? AND parallel_place_id = ? ORDER BY turn_no;',
      <Object?>[worldId, parallelPlaceId],
    );
    return <int>[for (final Row r in rs) r['turn_no']! as int];
  }

  /// 追加一回合状态；返回 turn_no。只 insert，不覆盖。
  int appendTurnState(String worldId, String parallelPlaceId, String stateJson) {
    _db.execute('BEGIN;');
    try {
      final ResultSet r = _db.select(
        'SELECT COALESCE(MAX(turn_no), -1) + 1 AS n FROM turn '
        'WHERE world_id = ? AND parallel_place_id = ?;',
        <Object?>[worldId, parallelPlaceId],
      );
      final int n = r.first['n']! as int;
      _db.execute(
        '''
        INSERT INTO turn
          (world_id, parallel_place_id, turn_no, state_json, created_at)
        VALUES (?, ?, ?, ?, ?);
        ''',
        <Object?>[
          worldId,
          parallelPlaceId,
          n,
          stateJson,
          DateTime.now().toIso8601String(),
        ],
      );
      _db.execute('COMMIT;');
      return n;
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  /// 删掉最新一回合；返回是否删了。
  bool deleteLatestTurnState(String worldId, String parallelPlaceId) {
    _db.execute('BEGIN;');
    try {
      final ResultSet r = _db.select(
        'SELECT MAX(turn_no) AS n FROM turn '
        'WHERE world_id = ? AND parallel_place_id = ?;',
        <Object?>[worldId, parallelPlaceId],
      );
      final Object? raw = r.first['n'];
      if (raw == null) {
        _db.execute('COMMIT;');
        return false;
      }
      final int n = raw as int;
      _db.execute(
        'DELETE FROM turn '
        'WHERE world_id = ? AND parallel_place_id = ? AND turn_no = ?;',
        <Object?>[worldId, parallelPlaceId, n],
      );
      _db.execute('COMMIT;');
      return true;
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  /// 删掉最新一回合的画布步（只删“引擎”写的那一步）。
  bool deleteLatestTurnStep(String worldId, String parallelPlaceId) {
    final ResultSet rs = _db.select(
      'SELECT seq, judgment FROM step '
      'WHERE world_id = ? AND parallel_place_id = ? ORDER BY seq DESC LIMIT 1;',
      <Object?>[worldId, parallelPlaceId],
    );
    if (rs.isEmpty) return false;
    if (!'${rs.first['judgment']}'.startsWith('引擎：')) return false;
    final int seq = rs.first['seq']! as int;
    _db.execute(
      'DELETE FROM step WHERE world_id = ? AND parallel_place_id = ? AND seq = ?;',
      <Object?>[worldId, parallelPlaceId, seq],
    );
    return true;
  }

  /// 追加一步到某条序列末尾。
  void appendStep(String worldId, String parallelPlaceId, TurnStep s) {
    // 取 seq 和插行必须在同一个事务里：分开做，两个写同时来会上同一层。
    _db.execute('BEGIN;');
    try {
      final ResultSet r = _db.select(
        'SELECT COALESCE(MAX(seq), -1) + 1 AS n FROM step '
        'WHERE world_id = ? AND parallel_place_id = ?;',
        <Object?>[worldId, parallelPlaceId],
      );
      final int seq = r.first['n']! as int;
      _insertStep(worldId, parallelPlaceId, seq, s);
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  void _insertStep(
    String worldId,
    String parallelPlaceId,
    int seq,
    TurnStep s,
  ) {
    _db.execute(
      '''
      INSERT INTO step
        (world_id, parallel_place_id, seq, kind, who, time, text,
         candidates, perceptions, chosen, judgment, attachments,
         error, model, choices, usage)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(world_id, parallel_place_id, seq) DO UPDATE SET
        kind=excluded.kind, who=excluded.who, time=excluded.time,
        text=excluded.text, candidates=excluded.candidates,
        perceptions=excluded.perceptions, chosen=excluded.chosen,
        judgment=excluded.judgment, attachments=excluded.attachments,
        error=excluded.error,
        model=excluded.model, choices=excluded.choices, usage=excluded.usage;
      ''',
      <Object?>[
        worldId,
        parallelPlaceId,
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
        jsonEncode(s.attachmentIds),
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
  /// [index] 是**画布上的步序**（只有 GM_ENV_UPDATE / CH_ACT 上画布），从 0 开始。
  /// 用子查询按同样的顺序取 rowid 改，不碰判断与感知。
  void updateStepText(
    String worldId,
    String parallelPlaceId,
    int index,
    String text,
  ) {
    _db.execute(
      '''
      UPDATE step SET text = ? WHERE rowid = (
        SELECT rowid FROM step
        WHERE world_id = ? AND parallel_place_id = ? AND kind IN ('GM_ENV_UPDATE', 'CH_ACT')
        ORDER BY seq LIMIT 1 OFFSET ?
      );
      ''',
      <Object?>[joLf(text), worldId, parallelPlaceId, index],
    );
  }

  /// 读某条序列的步。
  List<TurnStep> loadSteps(String worldId, String parallelPlaceId) {
    final List<TurnStep> out = <TurnStep>[];
    final ResultSet rs = _db.select(
      'SELECT * FROM step WHERE world_id = ? AND parallel_place_id = ? ORDER BY seq;',
      <Object?>[worldId, parallelPlaceId],
    );
    for (final Row r in rs) {
      out.add(_stepOf(r));
    }
    return out;
  }

  // ————————————————————————————— 记忆

  /// 记忆从最新检查点的 memory_refs 组装。
  List<CharacterMemory> loadWorldMemory(String worldId) =>
      (loadTurnState(worldId) ?? TurnState.empty).memory;

  /// 读一条记忆的版本历史，最新的在前。
  ///
  /// 旧格式还没有 memory_version 时，退回当前活动条目，保证面板不空白。
  List<CharacterMemory> loadMemoryVersions(String worldId, String memoryId) {
    final ResultSet rs = _db.select(
      'SELECT payload FROM memory_version '
      'WHERE world_id = ? AND memory_id = ? ORDER BY version DESC;',
      <Object?>[worldId, memoryId],
    );
    final List<CharacterMemory> out = <CharacterMemory>[];
    for (final Row row in rs) {
      try {
        final Object? raw = jsonDecode('${row['payload']}');
        if (raw is Map) {
          out.add(CharacterMemory.fromJson(Map<String, Object?>.from(raw)));
        }
      } catch (_) {
        // 单条坏掉不拖垮整条链；下面还有别的版本。
      }
    }
    if (out.isNotEmpty) return out;
    for (final CharacterMemory m in loadWorldMemory(worldId)) {
      if (m.id == memoryId) return <CharacterMemory>[m];
    }
    return const <CharacterMemory>[];
  }

  static bool _sameMemoryContent(CharacterMemory a, CharacterMemory b) {
    final Map<String, Object?> ja = a.toJson()
      ..remove('version')
      ..remove('updatedAt');
    final Map<String, Object?> jb = b.toJson()
      ..remove('version')
      ..remove('updatedAt');
    return jsonEncode(ja) == jsonEncode(jb);
  }

  /// 保存手动编辑后的记忆。
  ///
  /// 记忆正文追加进 memory_version，turn 只更新 memory_refs。
  void saveWorldMemory(String worldId, List<CharacterMemory> memory) {
    final TurnState state = loadTurnState(worldId) ?? TurnState.empty;
    final List<CharacterMemory> normalized = <CharacterMemory>[
      for (final CharacterMemory m in memory) m.copyWith(text: joLf(m.text)),
    ];
    final ResultSet rs = _db.select(
      'SELECT turn_no FROM turn '
      "WHERE world_id = ? AND parallel_place_id = '' "
      'ORDER BY turn_no DESC LIMIT 1;',
      <Object?>[worldId],
    );
    final int turnNo = rs.isEmpty ? 0 : rs.first['turn_no']! as int;
    final Map<String, CharacterMemory> oldById = <String, CharacterMemory>{
      for (final CharacterMemory m in state.memory) m.id: m,
    };
    final List<CharacterMemory> versioned = <CharacterMemory>[];
    for (final CharacterMemory m in normalized) {
      final CharacterMemory? old = oldById[m.id];
      final bool changed = old == null || !_sameMemoryContent(old, m);
      final int version = old == null
          ? (m.version <= 0 ? 1 : m.version)
          : changed
          ? (m.version > old.version ? m.version : old.version + 1)
          : old.version;
      versioned.add(m.copyWith(version: version));
    }

    _db.execute('BEGIN;');
    try {
      for (final CharacterMemory m in versioned) {
        final CharacterMemory? old = oldById[m.id];
        if (old != null && old.version == m.version) continue;
        _db.execute(
          '''
          INSERT INTO memory_version
            (world_id, memory_id, version, character_id, turn_no,
             session_id, op_id, payload, created_at)
          VALUES (?, ?, ?, ?, ?, 'manual', ?, ?, ?);
          ''',
          <Object?>[
            worldId,
            m.id,
            m.version,
            m.characterId,
            turnNo,
            '${m.id}:v${m.version}',
            jsonEncode(m.toJson()),
            DateTime.now().toIso8601String(),
          ],
        );
      }
      final TurnState next = state.withMemory(versioned);
      final String refs = jsonEncode(<Object?>[
        for (final CharacterMemory m in versioned)
          <String, Object?>{'id': m.id, 'version': m.version},
      ]);
      if (rs.isEmpty) {
        _db.execute(
          'INSERT INTO turn '
          '(world_id, parallel_place_id, turn_no, state_json, event_ids, '
          'memory_refs, created_at) '
          "VALUES (?, '', 0, ?, '[]', ?, ?);",
          <Object?>[
            worldId,
            next.encodeCheckpoint(),
            refs,
            DateTime.now().toIso8601String(),
          ],
        );
      } else {
        _db.execute(
          'UPDATE turn SET state_json = ?, memory_refs = ? '
          "WHERE world_id = ? AND parallel_place_id = '' AND turn_no = ?;",
          <Object?>[next.encodeCheckpoint(), refs, worldId, turnNo],
        );
      }
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  /// 保存未完成回合的恢复日志；成功提交后调用 clear。
  void saveTurnSession(TurnSession session) {
    final TurnSession touched = session.touch();
    _db.execute(
      'INSERT OR REPLACE INTO turn_session '
      '(world_id, parallel_place_id, payload, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?);',
      <Object?>[
        session.worldId,
        session.parallelPlaceId,
        jsonEncode(touched.toJson()),
        touched.createdAt,
        touched.updatedAt,
      ],
    );
  }

  /// 读未完成回合；没有或坏掉就返回 null。
  TurnSession? loadTurnSession(String worldId) =>
      loadTimelineSession(worldId, mainTimelineId);

  TurnSession? _loadLegacyTurnSession(String worldId) {
    final ResultSet rs = _db.select(
      'SELECT payload FROM turn_session WHERE world_id = ? LIMIT 1;',
      <Object?>[worldId],
    );
    if (rs.isEmpty) return null;
    try {
      final Object? raw = jsonDecode('${rs.first['payload'] ?? '{}'}');
      if (raw is! Map) return null;
      return TurnSession.fromJson(raw.cast<String, Object?>());
    } catch (_) {
      return null;
    }
  }

  void clearTurnSession(String worldId) => clearTimelineSession(worldId, mainTimelineId);

  void _clearLegacyTurnSession(String worldId) {
    _db.execute('DELETE FROM turn_session WHERE world_id = ?;', <Object?>[
      worldId,
    ]);
  }

  /// 改最新一回合的状态；没有就返回 false。
  bool updateLatestWorldTurn(String worldId, String stateJson) {
    final ResultSet rs = _db.select(
      "SELECT MAX(turn_no) AS n FROM turn WHERE world_id = ? AND parallel_place_id = '';",
      <Object?>[worldId],
    );
    final Object? raw = rs.first['n'];
    if (raw == null) return false;
    final int n = raw as int;
    _db.execute(
      "UPDATE turn SET state_json = ? "
      "WHERE world_id = ? AND parallel_place_id = '' AND turn_no = ?;",
      <Object?>[stateJson, worldId, n],
    );
    return true;
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

  World _worldOf(
    Map<String, Object?> r, {
    List<TurnStep> Function(String placeId)? snapshotSteps,
  }) => World(
    id: '${r['id']}',
    name: '${r['name']}',
    note: '${r['note']}',
    setting: '${r['setting']}',
    opening: '${r['opening']}',
    playerName: '${r['controlled_character_name']}',
    ttsKey: '${r['tts_key'] ?? ''}',
    narratorTtsKey: '${r['narrator_tts_key'] ?? ''}',
    searchSource: WorldSearchSource.byId('${r['search_source'] ?? 'off'}'),
    characters: _cardsOf('${r['characters']}'),
    parallelPlaces: _parallelPlacesOf(
      '${r['parallel_places']}', '${r['id']}', snapshotSteps: snapshotSteps,
    ),
    moves: _movesOf('${r['moves']}'),
  );

  List<CharCard> _cardsOf(String raw) {
    final Object? j = jsonDecode(raw);
    if (j is! List) return const <CharCard>[];
    return j.whereType<Map<Object?, Object?>>().map((Map<Object?, Object?> m) {
      final Map<String, String> aliases = <String, String>{};
      final Object? rawAliases = m['aliases'];
      if (rawAliases is Map) {
        for (final MapEntry<Object?, Object?> e in rawAliases.entries) {
          aliases['${e.key}'] = '${e.value}';
        }
      }
      return CharCard(
        name: '${m['name'] ?? ''}',
        persona: '${m['persona'] ?? ''}',
        location: '${m['location'] ?? ''}',
        state: '${m['state'] ?? ''}',
        aliases: aliases,
        ttsKey: '${m['tts'] ?? ''}',
      );
    }).toList();
  }

  /// 读序列。
  ///
  /// **地点元信息来自 JSON，步一律来自 step 表** —— step 表才是权威。
  /// 以前这里读 JSON 里那份，而 `appendStep` 只写 step 表，
  /// 于是引擎跑完、重新读库，画布上永远看不到新步。
  List<ParallelPlace> _parallelPlacesOf(
    String raw,
    String worldId, {
    List<TurnStep> Function(String placeId)? snapshotSteps,
  }) {
    final Object? j = jsonDecode(raw);
    if (j is! List) return const <ParallelPlace>[];
    return j.whereType<Map<Object?, Object?>>().map((Map<Object?, Object?> m) {
      final String parallelPlaceId = '${m['id'] ?? ''}';
      return ParallelPlace(
        id: parallelPlaceId,
        place: '${m['place'] ?? ''}',
        here: m['here'] == true,
        events: snapshotSteps == null
            ? _stepsOf(worldId, parallelPlaceId)
            : snapshotSteps(parallelPlaceId),
        status: '${m['status'] ?? 'active'}',
        parentId: '${m['parentId'] ?? ''}',
        mergeInto: '${m['mergeInto'] ?? ''}',
      );
    }).toList();
  }

  /// 某条序列的步，按步序。坏的那一步跳过，不把整条序列废掉。
  List<TurnStep> _stepsOf(String worldId, String parallelPlaceId) {
    final List<TurnStep> out = <TurnStep>[];
    final ResultSet rs = _db.select(
      'SELECT * FROM step WHERE world_id = ? AND parallel_place_id = ? ORDER BY seq;',
      <Object?>[worldId, parallelPlaceId],
    );
    for (final Row r in rs) {
      try {
        final TurnStep s = _stepOf(r);
        // 画布上一步 = 一次行为。判断（GM_OPEN_PLACE/GM_ROUTE/GM_ELIGIBILITY/GM_SELECT_ACTOR/GM_MERGE_PLACE）和感知（CH_PERCEIVE）
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
        fromParallelPlace: '${m['fromParallelPlace'] ?? ''}',
        fromStep: n(m['fromStep']),
        toParallelPlace: '${m['toParallelPlace'] ?? ''}',
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
    final Object? atts = r['attachments'] == null
        ? null
        : jsonDecode('${r['attachments']}');
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
      attachmentIds: atts is List
          ? atts.whereType<String>().toList()
          : const <String>[],
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
