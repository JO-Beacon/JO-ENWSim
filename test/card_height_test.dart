// 选中卡片的高度：要按**渲染后的正文**量，不是按纯文字。
//
// 以前正文高度用 TextPainter 数纯文字行数，Markdown 一渲染（列表/表格/标题）
// 就比那个高，卡片不够高 → 最后几项被裁掉。
//
// 这里用一个只有一条序列、一步的世界，正文是十项列表：
// 选中之后，**最后一项必须在卡片里面**。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/data/world_store.dart';
import 'package:joenws/main.dart';
import 'package:joenws/model/demo.dart';
import 'package:joenws/model/pack_rows.dart';
import 'package:joenws/model/turn.dart';
import 'package:joenws/theme/settings_store.dart';
import 'package:joenws/theme/tokens.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('选中的卡会为长列表长高：最后一项不会被裁掉', (WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => t.binding.setSurfaceSize(null));

    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SettingsStore store = await SettingsStore.open();
    final WorldStore worldStore = WorldStore.memory();
    addTearDown(worldStore.close);

    final String text = <String>[
      for (int i = 1; i <= 10; i++) '- 第$i项：这一行是列表里的一项',
    ].join('\n');

    worldStore.saveWorld(
      World(
        id: 'w1',
        name: '测试世界',
        note: '',
        setting: '设定',
        opening: '开场',
        playerName: '人物1',
        characters: const <CharCard>[CharCard(name: '人物1', persona: '守着楼梯口的人')],
        lanes: <SeqLane>[
          SeqLane(
            id: 'l1',
            place: '正厅',
            here: true,
            events: <TurnStep>[
              TurnStep(kind: 'B2', who: '人物1', time: '雨夜', text: text),
            ],
          ),
        ],
        moves: const <MoveLink>[],
      ),
    );

    await t.pumpWidget(
      JoEnwsApp(
        store: store,
        worldStore: worldStore,
        initialWorlds: worldStore.loadWorlds().worlds,
        initial: const JoSettings(),
      ),
    );
    await t.pumpAndSettle();

    // 点开这张卡（正文里第一项那行）。
    await t.tap(find.textContaining('第1项').first);
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);

    final Finder card = find.byKey(const ValueKey<String>('card-l1-0'));
    expect(card, findsOneWidget);

    final Rect cardRect = t.getRect(card);
    final Rect lastRect = t.getRect(find.textContaining('第10项').first);

    // 卡比常规高度大：说明真的为内容长高了。
    expect(cardRect.height, greaterThan(kCardH));
    // 最后一项整个落在卡片内（旧实现里它会掉到卡片外面被裁掉）。
    expect(
      lastRect.bottom,
      lessThanOrEqualTo(cardRect.bottom + 0.5),
      reason: '最后一项被裁掉了：卡高还是按纯文字量出来的',
    );
  });
}
