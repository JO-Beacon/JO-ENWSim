// 发言框上方那一条：模型那块写什么、点开选完会不会真记住。
//
// 以前两个毛病：
//   1. 只读“世界默认”，设置里配了全局默认这里还写“未选择”——明明有模型能用；
//   2. 世界模型配置只在内存里，选完一重启就没了（又是“未选择”）。
//
// 这里钉住：生效模型按 世界 → 全局 落、跟全局时带“全局”标记、选完会落盘。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/data/world_store.dart';
import 'package:joenws/main.dart';
import 'package:joenws/model/model_plan.dart';
import 'package:joenws/model/provider.dart';
import 'package:joenws/theme/settings_store.dart';
import 'package:joenws/theme/tokens.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Provider kProvider = Provider(
  id: 'p1',
  protocol: Protocol.deepseek,
  name: 'DeepSeek',
  models: <ModelRef>[ModelRef(id: 'deepseek-chat')],
);

const String kKey = 'p1\u0000deepseek-chat';

Future<SettingsStore> boot(
  WidgetTester t, {
  ModelPlan global = const ModelPlan(),
  Map<String, ModelPlan> worlds = const <String, ModelPlan>{},
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final SettingsStore store = await SettingsStore.open();
  final WorldStore worldStore = WorldStore.memory()..seedDemo();
  addTearDown(worldStore.close);
  await t.pumpWidget(
    JoEnwsApp(
      store: store,
      worldStore: worldStore,
      initialWorlds: worldStore.loadWorlds().worlds,
      initial: const JoSettings(),
      providers: const <Provider>[kProvider],
      initialGlobalPlan: global,
      initialWorldPlans: worlds,
    ),
  );
  await t.pumpAndSettle();
  return store;
}

void main() {
  testWidgets('什么都没设：写“未选择”，且没有“全局”标记', (WidgetTester t) async {
    await boot(t);
    expect(find.text('未选择'), findsOneWidget);
    expect(find.text('全局'), findsNothing);
  });

  testWidgets('只设了全局默认：写全局那个模型，并标“全局”', (WidgetTester t) async {
    // 以前这条会显示“未选择”—— 界面在骗人。
    await boot(t, global: const ModelPlan(defaultRef: kKey));
    expect(find.text('DeepSeek · deepseek-chat'), findsOneWidget);
    expect(find.text('全局'), findsOneWidget);
    expect(find.text('未选择'), findsNothing);
  });

  testWidgets('世界自己设了：写世界的那个，不再标“全局”', (WidgetTester t) async {
    await boot(
      t,
      global: const ModelPlan(defaultRef: 'p9\u0000other'),
      worlds: <String, ModelPlan>{'w1': const ModelPlan(defaultRef: kKey)},
    );
    expect(find.text('DeepSeek · deepseek-chat'), findsOneWidget);
    expect(find.text('全局'), findsNothing);
  });

  testWidgets('在弹窗里选完并保存：发言框跟着改，而且落盘了', (WidgetTester t) async {
    final SettingsStore store = await boot(t);

    // 点“模型”那一格 → 开模型配置弹窗。
    await t.tap(find.text('未选择'));
    await t.pumpAndSettle();
    expect(find.text('世界默认'), findsOneWidget);

    // 世界默认那一行 → 选择器。
    await t.tap(find.text('不设（交给全局默认）'));
    await t.pumpAndSettle();
    await t.tap(find.text('deepseek-chat'));
    await t.pumpAndSettle();

    // 保存。
    await t.tap(find.text('保存'));
    await t.pumpAndSettle();

    expect(find.text('DeepSeek · deepseek-chat'), findsOneWidget);
    expect(find.text('未选择'), findsNothing);

    // 落盘：重新读一遍存档，世界的模型配置还在。
    final SettingsStore again = await SettingsStore.open();
    final LoadResult<Map<String, ModelPlan>> saved = again.loadWorldPlans();
    expect(saved.clean, isTrue);
    expect(saved.value['w1']?.defaultRef, kKey);
    expect(store, isNotNull);
  });

  testWidgets('存档里有世界模型：启动就直接显示，不用再选', (WidgetTester t) async {
    await boot(
      t,
      worlds: <String, ModelPlan>{'w1': const ModelPlan(defaultRef: kKey)},
    );
    expect(find.text('DeepSeek · deepseek-chat'), findsOneWidget);
  });

  testWidgets('四个工具按钮在最右边，说明紧挨着它们', (WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await boot(t);

    final Rect note = t.getRect(find.text('工具还没接'));
    // 模型那格在左边，工具图标在右边：说明文字落在两者之间。
    final Rect model = t.getRect(find.text('未选择'));
    expect(note.left, greaterThan(model.right));
    expect(t.takeException(), isNull);
  });

  testWidgets('窄窗口不溢出（以前这一条是横向滚动）', (WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await boot(t);
    expect(t.takeException(), isNull);
  });
}
