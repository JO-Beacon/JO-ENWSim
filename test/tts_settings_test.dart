import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/model/model_plan.dart';
import 'package:joenws/model/provider.dart';
import 'package:joenws/model/tts_types.dart';
import 'package:joenws/theme/settings_store.dart';
import 'package:joenws/theme/tokens.dart';
import 'package:joenws/ui/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget host(Widget child) {
  return MaterialApp(
    home: JoTheme(
      settings: const JoSettings(),
      palette: JoPalette.dark,
      child: child,
    ),
  );
}

void main() {
  testWidgets('TTS 服务 → 朗读与缓存：念稿范围默认旁白也念，可切到仅对白', (
    WidgetTester t,
  ) async {
    await t.binding.setSurfaceSize(const Size(1100, 760));
    addTearDown(() => t.binding.setSurfaceSize(null));

    JoSettings? latest;
    await t.pumpWidget(
      host(
        SettingsPage(
          settings: const JoSettings(),
          onChanged: (JoSettings s) => latest = s,
          providers: const <Provider>[],
          onProvidersChanged: (List<Provider> _) {},
          globalPlan: const ModelPlan(),
          onGlobalPlanChanged: (ModelPlan _) {},
          keys: const <String, String>{},
          onKeysChanged: (Map<String, String> _) {},
          onBack: () {},
        ),
      ),
    );
    await t.tap(find.text('TTS 服务').first);
    await t.pumpAndSettle();
    await t.tap(find.text('朗读与缓存').first);
    await t.pumpAndSettle();

    expect(t.takeException(), isNull);
    expect(find.text('念稿范围'), findsOneWidget);
    expect(find.text('旁白也念'), findsOneWidget);
    expect(find.text('仅对白'), findsOneWidget);
    expect(find.text('内置模型生命周期'), findsOneWidget);
    expect(find.text('语速'), findsOneWidget);
    expect(find.text('风格 / 情绪'), findsOneWidget);
    expect(find.text('完全冷启动'), findsOneWidget);
    expect(find.text('空闲卸载'), findsOneWidget);
    expect(find.text('常驻'), findsOneWidget);
    expect(find.text('内置模型目录'), findsNothing);
    expect(find.text('安装模型'), findsNothing);
    expect(find.text('下载 Melo'), findsNothing);
    expect(find.text('TTS 缓存'), findsOneWidget);
    expect(find.text('导出全部'), findsOneWidget);
    expect(find.text('系统 TTS'), findsOneWidget);
    expect(find.text('试听一句'), findsOneWidget);
    expect(find.text('内置 TTS（Melo）'), findsOneWidget);
    expect(find.text('试听 Melo'), findsOneWidget);
    expect(find.textContaining('内置 TTS = 客户端捆模型'), findsNothing);

    await t.tap(find.text('仅对白'));
    await t.pumpAndSettle();
    expect(latest?.readNarration, isFalse);
  });

  testWidgets('网络页：代理开关、测试连接和恢复默认都在', (WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1100, 760));
    addTearDown(() => t.binding.setSurfaceSize(null));

    JoSettings? latest;
    await t.pumpWidget(
      host(
        SettingsPage(
          settings: const JoSettings(),
          onChanged: (JoSettings s) => latest = s,
          providers: const <Provider>[],
          onProvidersChanged: (List<Provider> _) {},
          globalPlan: const ModelPlan(),
          onGlobalPlanChanged: (ModelPlan _) {},
          keys: const <String, String>{},
          onKeysChanged: (Map<String, String> _) {},
          onBack: () {},
        ),
      ),
    );
    await t.tap(find.text('网络').first);
    await t.pumpAndSettle();

    expect(t.takeException(), isNull);
    expect(find.text('代理'), findsOneWidget);
    expect(find.text('启用代理'), findsWidgets);
    expect(find.text('测试连接'), findsOneWidget);
    expect(find.text('恢复默认'), findsOneWidget);

    await t.tap(find.text('启用代理').last);
    await t.pumpAndSettle();
    expect(latest?.proxyEnabled, isTrue);
  });

  testWidgets('TTS 服务：Melo 默认，内置 / 可下载 / 本地三块都在', (
    WidgetTester t,
  ) async {
    await t.binding.setSurfaceSize(const Size(1100, 760));
    addTearDown(() => t.binding.setSurfaceSize(null));

    await t.pumpWidget(
      host(
        SettingsPage(
          settings: const JoSettings(),
          onChanged: (JoSettings _) {},
          providers: const <Provider>[],
          onProvidersChanged: (List<Provider> _) {},
          globalPlan: const ModelPlan(),
          onGlobalPlanChanged: (ModelPlan _) {},
          keys: const <String, String>{},
          onKeysChanged: (Map<String, String> _) {},
          onBack: () {},
        ),
      ),
    );
    await t.tap(find.text('TTS 服务').first);
    await t.pumpAndSettle();

    expect(t.takeException(), isNull);
    expect(find.text('默认 TTS'), findsOneWidget);
    expect(find.text('MeloTTS 中文 · 中文'), findsOneWidget);
    expect(find.text('Kokoro 多语言 · 中文 / 英文'), findsOneWidget);
    expect(find.text('已内置'), findsNothing);
    expect(find.text('设为默认'), findsNothing);
    expect(find.text('可下载模型'), findsOneWidget);
    expect(find.text('AISHELL-3 中文 · 中文'), findsOneWidget);
    expect(find.text('LJSpeech 英文（标准） · 英文'), findsOneWidget);
    expect(find.text('下载'), findsWidgets);
    expect(find.text('本地模型'), findsOneWidget);
    expect(find.text('选择目录…'), findsOneWidget);
  });

  testWidgets('ASR 服务是独立空页，排在 TTS 服务下面', (WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1100, 760));
    addTearDown(() => t.binding.setSurfaceSize(null));

    await t.pumpWidget(
      host(
        SettingsPage(
          settings: const JoSettings(),
          onChanged: (JoSettings _) {},
          providers: const <Provider>[],
          onProvidersChanged: (List<Provider> _) {},
          globalPlan: const ModelPlan(),
          onGlobalPlanChanged: (ModelPlan _) {},
          keys: const <String, String>{},
          onKeysChanged: (Map<String, String> _) {},
          onBack: () {},
        ),
      ),
    );
    await t.tap(find.text('ASR 服务').first);
    await t.pumpAndSettle();

    expect(t.takeException(), isNull);
    expect(find.text('ASR 服务'), findsOneWidget);
    expect(find.text('TTS 朗读'), findsNothing);
  });

  testWidgets('TTS 服务：OpenAI 音色清单和试合成入口都在', (WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1100, 760));
    addTearDown(() => t.binding.setSurfaceSize(null));

    await t.pumpWidget(
      host(
        SettingsPage(
          settings: const JoSettings(),
          onChanged: (JoSettings _) {},
          providers: <Provider>[
            Provider(
              id: 'v1',
              protocol: Protocol.openai,
              name: 'OpenAI TTS',
              baseUrl: 'https://api.openai.com/v1',
              kind: ServiceKind.tts,
            ),
          ],
          onProvidersChanged: (List<Provider> _) {},
          globalPlan: const ModelPlan(),
          onGlobalPlanChanged: (ModelPlan _) {},
          keys: const <String, String>{},
          onKeysChanged: (Map<String, String> _) {},
          onBack: () {},
        ),
      ),
    );
    await t.tap(find.text('TTS 服务').first);
    await t.pumpAndSettle();
    await t.tap(find.text('云服务').first);
    await t.pumpAndSettle();

    expect(t.takeException(), isNull);
    expect(find.text('音色 6'), findsOneWidget);
    expect(find.text('Alloy'), findsOneWidget);
    expect(find.text('合成并保存'), findsOneWidget);
    expect(find.textContaining('TTS 服务商共用同一套面板'), findsNothing);
    expect(
      find.text('在此配置 TTS 服务商与音色；默认值可在“TTS 服务 → 模型”中选择。'),
      findsOneWidget,
    );
    await t.tap(find.text('编辑音色'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text('音色清单'), findsOneWidget);
  });

  test('念稿范围与内置模型生命周期都会存下来；默认完全冷启动', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SettingsStore store = await SettingsStore.open();
    expect(store.load().readNarration, isTrue);
    expect(store.load().ttsLifecycle, TtsLifecycle.coldStart);
    expect(store.load().ttsSource, TtsSource.builtin);
    expect(store.load().ttsSpeed, 1.0);
    expect(store.load().ttsStyle, '');

    await store.save(
      const JoSettings(
        readNarration: false,
        ttsLifecycle: TtsLifecycle.idleUnload,
        ttsSource: TtsSource.system,
        ttsProviderId: 'p1',
        ttsVoiceId: 'voice-1',
        ttsModelId: 'tts-1',
        ttsSpeed: 1.25,
        ttsStyle: '温柔',
        builtinModelRoot: r'D:\models',
      ),
    );
    final SettingsStore again = await SettingsStore.open();
    expect(again.load().readNarration, isFalse);
    expect(again.load().ttsLifecycle, TtsLifecycle.idleUnload);
    expect(again.load().ttsSource, TtsSource.system);
    expect(again.load().ttsProviderId, 'p1');
    expect(again.load().ttsVoiceId, 'voice-1');
    expect(again.load().ttsModelId, 'tts-1');
    expect(again.load().ttsSpeed, 1.25);
    expect(again.load().ttsStyle, '温柔');
    expect(again.load().builtinModelRoot, r'D:\models');
  });
}
