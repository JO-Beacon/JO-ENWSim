import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/data/world_store.dart';
import 'package:joenws/model/demo.dart';
import 'package:joenws/model/turn.dart';

void main() {
  test('附件落盘、挂到玩家输入、删世界时一起清理', () async {
    final Directory dir = Directory.systemTemp.createTempSync('joenws_asset_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    final WorldStore store = await WorldStore.open(
      path: '${dir.path}${Platform.pathSeparator}joenws.db',
    );
    addTearDown(store.close);

    final World world = DemoData.worlds.first;
    final AssetRecord asset = await store.saveAsset(
      worldId: world.id,
      kind: 'text',
      mime: 'text/plain',
      name: '信.txt',
      bytes: utf8.encode('这是一封信。'),
    );

    expect(store.findAsset(asset.id)?.name, '信.txt');
    expect(store.assetFile(asset).readAsStringSync(), '这是一封信。');
    expect(store.assetFile(asset).existsSync(), isTrue);

    store.saveAssetText(asset.id, '这是一封信。');
    expect(store.loadAssetText(asset.id), '这是一封信。');

    final String inputId = store.savePlayerInput(
      worldId: world.id,
      parallelPlaceId: 'l1',
      rawText: '我把信展开读了起来。',
      assetIds: <String>[asset.id],
    );
    final PlayerInputRecord? input = store.loadPlayerInput(inputId);
    expect(input, isNotNull);
    expect(input!.rawText, '我把信展开读了起来。');
    expect(input.assets.single.id, asset.id);
    expect(input.assets.single.kind, 'text');

    final File file = store.assetFile(asset);
    store.deleteWorld(world.id);
    expect(store.findAsset(asset.id), isNull);
    expect(store.loadPlayerInput(inputId), isNull);
    expect(store.loadAssetText(asset.id), isNull);
    expect(file.existsSync(), isFalse);
  });

  test('附件必须存在且属于当前世界，才允许挂到输入上', () async {
    final Directory dir = Directory.systemTemp.createTempSync('joenws_asset_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    final WorldStore store = await WorldStore.open(
      path: '${dir.path}${Platform.pathSeparator}joenws.db',
    );
    addTearDown(store.close);

    final World a = store.loadWorlds().worlds.first;
    final World b = store.loadWorlds().worlds[1];
    final AssetRecord asset = await store.saveAsset(
      worldId: a.id,
      kind: 'image',
      mime: 'image/png',
      name: 'a.png',
      bytes: const <int>[1, 2, 3],
    );

    expect(
      () => store.savePlayerInput(
        worldId: b.id,
        parallelPlaceId: '',
        rawText: 'x',
        assetIds: <String>[asset.id],
      ),
      throwsStateError,
    );
  });

  test('画布步的附件也能落盘读回', () async {
    final Directory dir = Directory.systemTemp.createTempSync('joenws_asset_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    final WorldStore store = await WorldStore.open(
      path: '${dir.path}${Platform.pathSeparator}joenws.db',
    );
    addTearDown(store.close);

    final World world = DemoData.worlds.first;
    final AssetRecord asset = await store.saveAsset(
      worldId: world.id,
      kind: 'image',
      mime: 'image/png',
      name: 'apple.png',
      bytes: const <int>[1, 2, 3],
    );
    store.appendStep(
      world.id,
      'l1',
      TurnStep(
        kind: 'CH_ACT',
        who: '信标',
        time: '现在',
        text: '拿起一个苹果。',
        attachmentIds: <String>[asset.id],
      ),
    );

    final TurnStep step = store.loadSteps(world.id, 'l1').last;
    expect(step.text, '拿起一个苹果。');
    expect(step.attachmentIds, <String>[asset.id]);
  });
}
