import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/model/tts_types.dart';
import 'package:joenws/tts/system_tts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('把系统返回的声音收成 TtsVoice；缺字段不猜', () {
    final List<TtsVoice> voices = SystemTts.parseVoices(<Object?>[
      <String, Object?>{
        'name': 'Microsoft Huihui',
        'locale': 'zh-CN',
        'gender': 'Female',
        'identifier': 'HKEY_LOCAL_MACHINE\\...\\MSTTS_V110_zhCN_HuihuiM',
      },
      <String, Object?>{
        'name': 'Microsoft Zira',
        'locale': 'en-US',
        'gender': 'male',
      },
      <String, Object?>{'name': 'Microsoft Huihui', 'locale': 'zh-CN'},
      <String, Object?>{'name': ''},
      'not a map',
    ]);

    expect(voices.length, 2);
    expect(voices[0].name, 'Microsoft Huihui');
    expect(voices[0].language, 'zh-CN');
    expect(voices[0].gender, '女性');
    expect(voices[0].id, contains('MSTTS_V110_zhCN_HuihuiM'));

    expect(voices[1].name, 'Microsoft Zira');
    expect(voices[1].gender, '男性');
    // 没有 identifier 时用 name|locale 当 id。
    expect(voices[1].id, 'Microsoft Zira|en-US');
  });

  test('Android 的 notInstalled 声音不列，network_required 如实保留', () {
    final List<TtsVoice> voices = SystemTts.parseVoices(<Object?>[
      <String, Object?>{
        'name': '已装的中文声音',
        'locale': 'zh-CN',
        'network_required': '0',
      },
      <String, Object?>{
        'name': '联网中文声音',
        'locale': 'zh-CN',
        'network_required': '1',
      },
      <String, Object?>{
        'name': '没装的语言包',
        'locale': 'ja-JP',
        'features': 'notInstalled\tfoo',
      },
    ]);

    expect(voices.length, 2);
    expect(voices[0].networkRequired, isFalse);
    expect(voices[1].networkRequired, isTrue);
    expect(voices.map((TtsVoice v) => v.name), isNot(contains('没装的语言包')));
  });

  test('列声音、选声音、朗读都走 flutter_tts 的通道', () async {
    const MethodChannel channel = MethodChannel('flutter_tts');
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          switch (call.method) {
            case 'getVoices':
              return <Map<String, Object?>>[
                <String, Object?>{
                  'name': 'Microsoft Huihui',
                  'locale': 'zh-CN',
                  'gender': 'Female',
                  'identifier': 'huihui',
                },
              ];
            case 'setVoice':
              return 1;
            case 'speak':
              return 1;
            default:
              return 1;
          }
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final SystemTts tts = SystemTts();
    final List<TtsVoice> voices = await tts.voices();
    expect(voices.single.name, 'Microsoft Huihui');

    final SystemSpeakResult r = await tts.speak(
      '你好，这是系统语音试听。',
      voice: voices.single,
    );
    expect(r.ok, isTrue);

    final List<String> names = calls.map((MethodCall c) => c.method).toList();
    expect(names, contains('getVoices'));
    expect(names, contains('setSpeechRate'));
    expect(names, contains('setPitch'));
    expect(names, contains('setVolume'));
    expect(names, contains('setVoice'));
    expect(names, contains('awaitSpeakCompletion'));
    expect(names, contains('speak'));

    final MethodCall setVoice = calls.firstWhere(
      (MethodCall c) => c.method == 'setVoice',
    );
    expect(setVoice.arguments, <String, String>{
      'name': 'Microsoft Huihui',
      'locale': 'zh-CN',
    });
    final MethodCall speak = calls.firstWhere(
      (MethodCall c) => c.method == 'speak',
    );
    expect(speak.arguments, '你好，这是系统语音试听。');
  });

  test('系统里找不到指定的声音时如实报错', () async {
    const MethodChannel channel = MethodChannel('flutter_tts');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'setVoice') return 0;
          return 1;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final SystemSpeakResult r = await SystemTts().speak(
      '你好',
      voice: const TtsVoice(id: 'x', name: '不存在的音色', language: 'zh-CN'),
    );

    expect(r.ok, isFalse);
    expect(r.message, contains('找不到'));
  });

  test('空文本直接拒绝，不发通道调用', () async {
    const MethodChannel channel = MethodChannel('flutter_tts');
    bool called = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          called = true;
          return 1;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final SystemSpeakResult r = await SystemTts().speak('   ');
    expect(r.ok, isFalse);
    expect(r.message, contains('空的'));
    expect(called, isFalse);
  });
}
