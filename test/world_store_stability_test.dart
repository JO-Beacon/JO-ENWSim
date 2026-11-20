import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/data/world_store.dart';

void main() {
  test('磁盘库启用 WAL，启动完整性检查通过', () async {
    final Directory dir = Directory.systemTemp.createTempSync('joenws_stability_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    final String path = '${dir.path}${Platform.pathSeparator}joenws.db';
    final WorldStore store = await WorldStore.open(path: path);
    addTearDown(store.close);

    expect(store.journalMode(), 'wal');
    expect(store.integrityCheck(), 'ok');
    expect(store.startupNote, isNull);
  });

  test('坏库启动时先备份原文件，再新建可用库', () async {
    final Directory dir = Directory.systemTemp.createTempSync('joenws_corrupt_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    final String path = '${dir.path}${Platform.pathSeparator}joenws.db';
    final WorldStore first = await WorldStore.open(path: path);
    first.close();

    final RandomAccessFile raf = File(path).openSync(mode: FileMode.write);
    raf.writeFromSync(<int>[0, 1, 2, 3, 4, 5, 6, 7]);
    raf.closeSync();

    final WorldStore recovered = await WorldStore.open(path: path);
    addTearDown(recovered.close);
    expect(recovered.startupNote, contains('完整性检查失败'));
    expect(recovered.journalMode(), 'wal');
    expect(recovered.integrityCheck(), 'ok');
    expect(
      dir.listSync().any((FileSystemEntity e) => e.path.contains('.corrupt-')),
      isTrue,
    );
  });
}
