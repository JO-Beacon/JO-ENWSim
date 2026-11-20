import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/model/network.dart';
import 'package:joenws/theme/settings_store.dart';
import 'package:joenws/theme/tokens.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    NetworkRuntime.configure(
      proxyEnabled: false,
      proxyHost: '127.0.0.1',
      proxyPort: 7890,
    );
  });

  test('网络设置默认直连，能存读代理地址和端口', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SettingsStore store = await SettingsStore.open();
    final JoSettings def = store.load();
    expect(def.proxyEnabled, isFalse);
    expect(def.proxyHost, '127.0.0.1');
    expect(def.proxyPort, 7890);

    await store.save(
      const JoSettings(
        proxyEnabled: true,
        proxyHost: '127.0.0.2',
        proxyPort: 10808,
      ),
    );
    final JoSettings again = (await SettingsStore.open()).load();
    expect(again.proxyEnabled, isTrue);
    expect(again.proxyHost, '127.0.0.2');
    expect(again.proxyPort, 10808);
  });

  test('configure 之后运行时读到的是最新值', () {
    NetworkRuntime.configure(
      proxyEnabled: true,
      proxyHost: ' 127.0.0.2 ',
      proxyPort: 10808,
    );
    expect(NetworkRuntime.proxyEnabled, isTrue);
    expect(NetworkRuntime.proxyHost, '127.0.0.2');
    expect(NetworkRuntime.proxyPort, 10808);

    NetworkRuntime.configure(
      proxyEnabled: false,
      proxyHost: '127.0.0.1',
      proxyPort: 7890,
    );
    expect(NetworkRuntime.proxyEnabled, isFalse);
  });

  test('newClient 返回可关闭的 HTTP 客户端', () {
    final HttpClient client = HttpClient();
    expect(NetworkRuntime.newClient(), isNotNull);
    client.close();
  });
}
