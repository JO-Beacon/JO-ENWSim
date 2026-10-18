// 搜索服务面板。
//
// 这一页以前**整个是错的**：搜索服务商下面挂的是聊天接口那一套东西
// （chat/completions、Use Responses API、端点格式、缓存计价、峰谷价目）。
// 现在只留搜索真正用得上的：地址、API Key、试搜。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/model/model_plan.dart';
import 'package:joenws/model/provider.dart';
import 'package:joenws/theme/tokens.dart';
import 'package:joenws/ui/settings_page.dart';

Widget host(List<Provider> providers) => MaterialApp(
  home: JoTheme(
    settings: const JoSettings(),
    palette: JoPalette.dark,
    child: SettingsPage(
      settings: const JoSettings(),
      onChanged: (JoSettings _) {},
      providers: providers,
      onProvidersChanged: (List<Provider> _) {},
      globalPlan: const ModelPlan(),
      onGlobalPlanChanged: (ModelPlan _) {},
      keys: const <String, String>{},
      onKeysChanged: (Map<String, String> _) {},
      onBack: () {},
    ),
  ),
);

Future<void> openSearch(WidgetTester t, List<Provider> providers) async {
  await t.binding.setSurfaceSize(const Size(1200, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(host(providers));
  await t.pumpAndSettle();
  await t.tap(find.text('搜索服务').first);
  await t.pumpAndSettle();
}

const Provider deepseekSearch = Provider(
  id: 's1',
  protocol: Protocol.deepseek,
  name: 'DeepSeek',
  apiKey: 'sk-test',
  baseUrl: 'https://api.deepseek.com',
  kind: ServiceKind.search,
);

const Provider tavilySearch = Provider(
  id: 's2',
  protocol: Protocol.openaiCompatible,
  name: 'Tavily',
  apiKey: 'tvly-test',
  baseUrl: 'https://api.tavily.com',
  kind: ServiceKind.search,
);

/// 真没接的一家（Exa）。用它验“如实说没接”。
const Provider exaSearch = Provider(
  id: 's3',
  protocol: Protocol.openaiCompatible,
  name: 'Exa',
  apiKey: 'exa-test',
  baseUrl: 'https://api.exa.ai',
  kind: ServiceKind.search,
);

void main() {
  testWidgets('DeepSeek 搜索：接口显示的就是那两个端点，没有聊天那套', (WidgetTester t) async {
    await openSearch(t, <Provider>[deepseekSearch]);

    expect(t.takeException(), isNull);
    expect(
      find.text('POST https://api.deepseek.com/v1/tools/search'),
      findsOneWidget,
    );
    expect(
      find.text('POST https://api.deepseek.com/v1/tools/fetch'),
      findsOneWidget,
    );
    expect(find.text('试搜一下'), findsOneWidget);

    // 聊天接口那一套不该出现在搜索服务里。
    expect(find.textContaining('chat/completions'), findsNothing);
    expect(find.textContaining('Use Responses API'), findsNothing);
    expect(find.text('端点格式'), findsNothing);
    expect(find.textContaining('缓存命中'), findsNothing);
  });

  testWidgets('Tavily 搜索：接口是 /search 和 /extract，计费按 credit', (
    WidgetTester t,
  ) async {
    await openSearch(t, <Provider>[tavilySearch]);

    expect(t.takeException(), isNull);
    expect(find.text('POST https://api.tavily.com/search'), findsOneWidget);
    expect(find.text('POST https://api.tavily.com/extract'), findsOneWidget);
    expect(find.textContaining('API Credit'), findsWidgets);
    // 不再是“还没接”。
    expect(find.textContaining('这家搜索接口还没接'), findsNothing);
    expect(find.text('试搜一下'), findsOneWidget);
  });

  testWidgets('没接的搜索厂商：只给地址，并如实说明', (WidgetTester t) async {
    await openSearch(t, <Provider>[exaSearch]);

    expect(t.takeException(), isNull);
    expect(find.textContaining('这家搜索接口还没接'), findsOneWidget);
    // 也还是不该出现聊天那套。
    expect(find.textContaining('chat/completions'), findsNothing);
    expect(find.text('端点格式'), findsNothing);
  });

  testWidgets('模型服务：内置搜索开关按厂商出现（MiMo 也支持）', (WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => t.binding.setSurfaceSize(null));

    Future<void> open(List<Provider> providers) async {
      await t.pumpWidget(host(providers));
      await t.pumpAndSettle();
      await t.tap(find.text('模型服务').first);
      await t.pumpAndSettle();
    }

    // Anthropic 形状：有。（前面那条测已经验过，这里不重复）
    // MiMo（OpenAI 形状）：也有，且用 MiMo 自己的说法。
    await open(<Provider>[
      const Provider(
        id: 'mimo',
        protocol: Protocol.openaiCompatible,
        name: '小米 MiMo',
        apiKey: 'sk-mimo',
        baseUrl: 'https://api.xiaomimimo.com/v1',
        apiPath: '/chat/completions',
      ),
    ]);
    expect(find.textContaining('内置搜索'), findsOneWidget);
    expect(find.textContaining('联网服务插件'), findsOneWidget);

    // 普通的 OpenAI 兼容（不支持内置搜索）：没有这个开关。
    await open(<Provider>[
      const Provider(
        id: 'sf',
        protocol: Protocol.openaiCompatible,
        name: '硅基流动',
        apiKey: 'sk-x',
        baseUrl: 'https://api.siliconflow.cn/v1',
        apiPath: '/chat/completions',
      ),
    ]);
    expect(find.textContaining('内置搜索'), findsNothing);
  });

  testWidgets('模型服务：Anthropic 格式才有“内置搜索”开关', (WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => t.binding.setSurfaceSize(null));

    Future<void> open(List<Provider> providers) async {
      await t.pumpWidget(host(providers));
      await t.pumpAndSettle();
      await t.tap(find.text('模型服务').first);
      await t.pumpAndSettle();
    }

    // Anthropic 形状：有内置搜索。
    await open(<Provider>[
      const Provider(
        id: 'm1',
        protocol: Protocol.deepseekAnthropic,
        name: 'DeepSeek · Anthropic',
        apiKey: 'sk-test',
        baseUrl: 'https://api.deepseek.com/anthropic',
      ),
    ]);
    expect(find.textContaining('内置搜索'), findsOneWidget);

    // OpenAI 形状：没有这个开关（chat 的 tools 只收 function）。
    await open(<Provider>[
      const Provider(
        id: 'm2',
        protocol: Protocol.deepseek,
        name: 'DeepSeek',
        apiKey: 'sk-test',
        baseUrl: 'https://api.deepseek.com',
      ),
    ]);
    expect(find.textContaining('内置搜索'), findsNothing);
  });

  testWidgets('模型服务里那套东西还在（没被误删）', (WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      host(<Provider>[
        const Provider(
          id: 'm1',
          protocol: Protocol.deepseek,
          name: 'DeepSeek',
          apiKey: 'sk-test',
          baseUrl: 'https://api.deepseek.com',
        ),
      ]),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('模型服务').first);
    await t.pumpAndSettle();

    expect(find.text('端点格式'), findsOneWidget);
    expect(find.textContaining('chat/completions'), findsWidgets);
  });
}
