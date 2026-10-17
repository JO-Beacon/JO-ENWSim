import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/data/world_store.dart';
import 'package:joenws/main.dart';
import 'package:joenws/theme/settings_store.dart';
import 'package:joenws/theme/tokens.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('壳能启动', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SettingsStore store = await SettingsStore.open();
    // 世界从库里来（内存库 + 播种），不再是 DemoData 直接喂。
    final WorldStore worldStore = WorldStore.memory()..seedDemo();
    addTearDown(worldStore.close);
    await tester.pumpWidget(
      JoEnwsApp(
        store: store,
        worldStore: worldStore,
        initialWorlds: worldStore.loadWorlds().worlds,
        initial: const JoSettings(),
      ),
    );
    expect(find.text('＋ 新建世界'), findsOneWidget);
    expect(find.text('你要做什么……'), findsOneWidget);
  });
}
