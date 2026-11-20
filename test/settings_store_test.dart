import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/theme/settings_store.dart';
import 'package:joenws/theme/tokens.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('自动推演上限有默认值，也能存读', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SettingsStore first = await SettingsStore.open();
    expect(first.load().autoRunMaxTurns, 100);

    await first.save(const JoSettings(autoRunMaxTurns: 200));

    final SettingsStore second = await SettingsStore.open();
    expect(second.load().autoRunMaxTurns, 200);

    await second.save(const JoSettings(autoRunMaxTurns: 0));
    final SettingsStore third = await SettingsStore.open();
    expect(third.load().autoRunMaxTurns, 0);
  });

  test('模型并发上限默认 1，可以存读正整数', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SettingsStore store = await SettingsStore.open();
    final JoSettings initial = store.load();
    expect(initial.modelRequestConcurrency, 1);

    await store.save(initial.copyWith(modelRequestConcurrency: 4));
    expect((await SettingsStore.open()).load().modelRequestConcurrency, 4);

    await store.save(initial.copyWith(modelRequestConcurrency: 0));
    expect((await SettingsStore.open()).load().modelRequestConcurrency, 1);
  });

  test('每回合搜索上限默认 10，读写时夹在 1–100', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SettingsStore first = await SettingsStore.open();
    expect(first.load().searchMaxQueriesPerTurn, 10);

    await first.save(const JoSettings(searchMaxQueriesPerTurn: 37));
    final SettingsStore second = await SettingsStore.open();
    expect(second.load().searchMaxQueriesPerTurn, 37);

    await second.save(const JoSettings(searchMaxQueriesPerTurn: 0));
    final SettingsStore third = await SettingsStore.open();
    expect(third.load().searchMaxQueriesPerTurn, 1);

    await third.save(const JoSettings(searchMaxQueriesPerTurn: 1000));
    final SettingsStore fourth = await SettingsStore.open();
    expect(fourth.load().searchMaxQueriesPerTurn, 100);
  });

  test('右栏流程图展开状态是全局设置，能存读', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SettingsStore first = await SettingsStore.open();
    expect(first.load().flowOpen, isFalse);

    await first.save(const JoSettings(flowOpen: true));
    final SettingsStore second = await SettingsStore.open();
    expect(second.load().flowOpen, isTrue);

    await second.save(const JoSettings(flowOpen: false));
    final SettingsStore third = await SettingsStore.open();
    expect(third.load().flowOpen, isFalse);
  });
}
