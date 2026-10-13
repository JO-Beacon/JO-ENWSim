import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/main.dart';
import 'package:joenws/theme/settings_store.dart';
import 'package:joenws/theme/tokens.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('壳能启动', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SettingsStore store = await SettingsStore.open();
    await tester.pumpWidget(
      JoEnwsApp(store: store, initial: const JoSettings()),
    );
    expect(find.text('＋ 新建世界'), findsOneWidget);
    expect(find.text('你要做什么……'), findsOneWidget);
  });
}
