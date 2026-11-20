// 旧库里回合快照表叫 v2_turn；打开时应该被改名成 turn，数据原样保留。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/data/world_store.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('joenws_migrate_');
    path = '${dir.path}${Platform.pathSeparator}joenws.db';
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // Windows 上连接没关干净时删不掉，留给系统清理。
    }
  });

  test('旧库的 v2_turn 打开后被改名成 turn，行还在', () async {
    final Database raw = sqlite3.open(path);
    raw.execute('''
CREATE TABLE v2_turn (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  world_id         TEXT NOT NULL,
  parallel_place_id TEXT NOT NULL,
  turn_no          INTEGER NOT NULL,
  state_json       TEXT NOT NULL,
  created_at       TEXT NOT NULL DEFAULT ''
);
''');
    raw.execute(
      "INSERT INTO v2_turn (world_id, parallel_place_id, turn_no, state_json, created_at) "
      "VALUES ('w1', '', 0, '{\"events\":[]}', '2026-01-01T00:00:00');",
    );
    raw.execute('PRAGMA user_version = 1;');
    raw.close();

    final WorldStore store = await WorldStore.open(path: path);
    store.close();

    final Database check = sqlite3.open(path);
    final Set<String> tables = <String>{
      for (final Row r in check.select(
        "SELECT name FROM sqlite_master WHERE type='table';",
      ))
        '${r['name']}',
    };
    expect(tables, contains('turn'));
    expect(tables, isNot(contains('v2_turn')));
    expect(
      check.select('SELECT state_json FROM turn;').single['state_json'],
      '{"events":[]}',
    );
    check.close();
  });
}
