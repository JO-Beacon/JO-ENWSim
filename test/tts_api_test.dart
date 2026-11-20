import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:joenws/model/provider.dart';
import 'package:joenws/model/tts_api.dart';
import 'package:joenws/model/tts_http.dart';
import 'package:joenws/tts/tts_file.dart';

Provider voiceProvider({
  required Protocol protocol,
  required String baseUrl,
  String name = 'TTS 服务',
}) {
  return Provider(
    id: 'p1',
    protocol: protocol,
    name: name,
    baseUrl: baseUrl,
    apiKey: 'sk-test',
    kind: ServiceKind.tts,
  );
}

void main() {
  group('Chat Completions 形状', () {
    test('请求发到 /audio/speech，字段与鉴权都对', () async {
      late http.Request captured;
      final MockClient client = MockClient((http.Request req) async {
        captured = req;
        return http.Response.bytes(
          <int>[1, 2, 3, 4],
          200,
          headers: <String, String>{'content-type': 'audio/mpeg'},
        );
      });

      final TtsResult r = await TtsService(
        voiceProvider(
          protocol: Protocol.openai,
          baseUrl: 'https://api.openai.com/v1',
        ),
      ).synthesize('“你好。”', client: client);

      expect(r.ok, isTrue);
      expect(r.bytes, <int>[1, 2, 3, 4]);
      expect(r.mimeType, 'audio/mpeg');
      expect(r.extension, 'mp3');
      expect(captured.url.toString(), 'https://api.openai.com/v1/audio/speech');
      expect(captured.headers['Authorization'], 'Bearer sk-test');
      final Map<String, Object?> body = (jsonDecode(captured.body) as Map)
          .cast<String, Object?>();
      expect(body['model'], 'tts-1');
      expect(body['voice'], 'alloy');
      expect(body['input'], '“你好。”');
      expect(body['response_format'], 'mp3');
    });

    test('401 时把厂商的原话带出来', () async {
      final MockClient client = MockClient(
        (http.Request req) async => http.Response(
          '{"error":{"message":"Invalid API key"}}',
          401,
          headers: <String, String>{'content-type': 'application/json'},
        ),
      );

      final TtsResult r = await TtsService(
        voiceProvider(
          protocol: Protocol.openai,
          baseUrl: 'https://api.openai.com/v1',
        ),
      ).synthesize('你好', client: client);

      expect(r.ok, isFalse);
      expect(r.message, contains('401'));
      expect(r.message, contains('Invalid API key'));
    });

    test('200 但回 JSON（代理出错）时不把 JSON 当音频', () async {
      final MockClient client = MockClient(
        (http.Request req) async => http.Response(
          '{"error":{"message":"quota"}}',
          200,
          headers: <String, String>{'content-type': 'application/json'},
        ),
      );

      final TtsResult r = await TtsService(
        voiceProvider(
          protocol: Protocol.openai,
          baseUrl: 'https://api.openai.com/v1',
        ),
      ).synthesize('你好', client: client);

      expect(r.ok, isFalse);
      expect(r.message, contains('JSON'));
    });
  });

  group('MiMo 形状', () {
    test('走 chat/completions，文本在 assistant，audio 参数对', () async {
      late http.Request captured;
      final Uint8List audio = Uint8List.fromList(<int>[9, 8, 7, 6]);
      final MockClient client = MockClient((http.Request req) async {
        captured = req;
        return http.Response(
          jsonEncode(<String, Object?>{
            'choices': <Object?>[
              <String, Object?>{
                'message': <String, Object?>{
                  'audio': <String, Object?>{'data': base64Encode(audio)},
                },
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });

      final TtsResult r = await TtsService(
        voiceProvider(
          protocol: Protocol.openaiCompatible,
          baseUrl: 'https://api.xiaomimimo.com/v1',
          name: 'MiMo TTS',
        ),
      ).synthesize('“谁在那儿？”', client: client);

      expect(r.ok, isTrue);
      expect(r.bytes, audio);
      expect(r.extension, 'wav');
      expect(
        captured.url.toString(),
        'https://api.xiaomimimo.com/v1/chat/completions',
      );
      final Map<String, Object?> body = (jsonDecode(captured.body) as Map)
          .cast<String, Object?>();
      expect(body['model'], 'mimo-v2.5-tts');
      final List<dynamic> messages = body['messages']! as List<dynamic>;
      expect(messages.length, 1);
      final Map<String, Object?> msg = (messages.first as Map)
          .cast<String, Object?>();
      expect(msg['role'], 'assistant');
      expect(msg['content'], '“谁在那儿？”');
      final Map<String, Object?> audioBody = (body['audio']! as Map)
          .cast<String, Object?>();
      expect(audioBody['format'], 'wav');
      expect(audioBody['voice'], 'mimo_default');
    });

    test('没有 audio.data 时如实报错', () async {
      final MockClient client = MockClient(
        (http.Request req) async => http.Response(
          '{"choices":[{"message":{}}]}',
          200,
          headers: <String, String>{'content-type': 'application/json'},
        ),
      );

      final TtsResult r = await TtsService(
        voiceProvider(
          protocol: Protocol.openaiCompatible,
          baseUrl: 'https://api.xiaomimimo.com/v1',
          name: 'MiMo TTS',
        ),
      ).synthesize('你好', client: client);

      expect(r.ok, isFalse);
      expect(r.message, contains('audio.data'));
    });
  });

  group('没接的服务商', () {
    test('如实说没接，不发请求', () async {
      bool called = false;
      final MockClient client = MockClient((http.Request req) async {
        called = true;
        return http.Response('{}', 200);
      });

      final TtsService service = TtsService(
        voiceProvider(
          protocol: Protocol.openaiCompatible,
          baseUrl: 'https://api.elevenlabs.io/v1',
          name: 'ElevenLabs',
        ),
      );
      final TtsResult r = await service.synthesize('你好', client: client);

      expect(service.vendor, TtsVendor.unknown);
      expect(service.voices, isEmpty);
      expect(r.ok, isFalse);
      expect(r.message, contains('还没接'));
      expect(called, isFalse);
    });

    test('空文本直接拒绝，不发请求', () async {
      bool called = false;
      final MockClient client = MockClient((http.Request req) async {
        called = true;
        return http.Response('{}', 200);
      });

      final TtsResult r = await TtsService(
        voiceProvider(
          protocol: Protocol.openai,
          baseUrl: 'https://api.openai.com/v1',
        ),
      ).synthesize('   ', client: client);

      expect(r.ok, isFalse);
      expect(r.message, contains('空的'));
      expect(called, isFalse);
    });
  });

  group('音色清单与保存', () {
    test('OpenAI / MiMo 的音色清单与默认值', () {
      final TtsService openai = TtsService(
        voiceProvider(
          protocol: Protocol.openai,
          baseUrl: 'https://api.openai.com/v1',
        ),
      );
      expect(openai.voices.length, 6);
      expect(openai.defaultModel, 'tts-1');
      expect(openai.defaultVoice, 'alloy');
      expect(openai.defaultFormat, 'mp3');

      final TtsService mimo = TtsService(
        voiceProvider(
          protocol: Protocol.openaiCompatible,
          baseUrl: 'https://api.xiaomimimo.com/v1',
        ),
      );
      expect(mimo.voices.length, 9);
      expect(mimo.voices.map((TtsVoice v) => v.id), contains('冰糖'));
      expect(mimo.defaultModel, 'mimo-v2.5-tts');
      expect(mimo.defaultVoice, 'mimo_default');
      expect(mimo.defaultFormat, 'wav');
    });

    test('Provider 的音色清单能存能读', () {
      final Provider p = voiceProvider(
        protocol: Protocol.openai,
        baseUrl: 'https://api.openai.com/v1',
      ).copyWith(
        voices: const <TtsVoice>[
          TtsVoice(id: 'custom-1', name: '自定义', language: '中文', gender: '女'),
        ],
      );
      final Provider back = Provider.fromJson(p.toJson());
      expect(back.voices.length, 1);
      expect(back.voices.first.id, 'custom-1');
      expect(back.voices.first.name, '自定义');
      expect(back.voices.first.language, '中文');
    });

    test('保存时自动补扩展名，内容原样写入', () async {
      final Directory dir = await Directory.systemTemp.createTemp(
        'joenws_tts_test',
      );
      addTearDown(() => dir.delete(recursive: true));

      final TtsResult r = TtsResult(
        ok: true,
        message: 'ok',
        bytes: Uint8List.fromList(<int>[1, 2, 3]),
        mimeType: 'audio/mpeg',
        extension: 'mp3',
      );
      final String path = await saveTtsAudio(r, directory: dir, fileName: '试听');

      expect(path.endsWith('试听.mp3'), isTrue);
      expect(await File(path).readAsBytes(), <int>[1, 2, 3]);
    });

    test('没有音频时保存会抛错，不写空文件', () async {
      final Directory dir = await Directory.systemTemp.createTemp(
        'joenws_tts_test',
      );
      addTearDown(() => dir.delete(recursive: true));

      await expectLater(
        saveTtsAudio(
          const TtsResult(ok: false, message: '失败了'),
          directory: dir,
        ),
        throwsArgumentError,
      );
    });
  });

  group('参数与重试', () {
    test('OpenAI 带 speed 和 instructions', () async {
      late http.Request captured;
      final MockClient client = MockClient((http.Request req) async {
        captured = req;
        return http.Response.bytes(
          <int>[1, 2, 3],
          200,
          headers: <String, String>{'content-type': 'audio/mpeg'},
        );
      });

      final TtsResult r = await TtsService(
        voiceProvider(
          protocol: Protocol.openai,
          baseUrl: 'https://api.openai.com/v1',
        ),
      ).synthesize(
        '你好',
        model: 'gpt-4o-mini-tts',
        speed: 1.25,
        style: '温柔一点',
        client: client,
      );

      expect(r.ok, isTrue);
      final Map<String, Object?> body = (jsonDecode(captured.body) as Map)
          .cast<String, Object?>();
      expect(body['speed'], 1.25);
      expect(body['instructions'], '温柔一点');
    });

    test('MiMo 的风格指令放进 user 消息', () async {
      late http.Request captured;
      final MockClient client = MockClient((http.Request req) async {
        captured = req;
        return http.Response(
          jsonEncode(<String, Object?>{
            'choices': <Object?>[
              <String, Object?>{
                'message': <String, Object?>{
                  'audio': <String, Object?>{
                    'data': base64Encode(<int>[1, 2, 3]),
                  },
                },
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });

      final TtsResult r = await TtsService(
        voiceProvider(
          protocol: Protocol.openaiCompatible,
          baseUrl: 'https://api.xiaomimimo.com/v1',
        ),
      ).synthesize('你好', style: '低沉、缓慢', client: client);

      expect(r.ok, isTrue);
      final Map<String, Object?> body = (jsonDecode(captured.body) as Map)
          .cast<String, Object?>();
      final List<Object?> messages = body['messages']! as List<Object?>;
      expect((messages[0] as Map)['role'], 'user');
      expect((messages[0] as Map)['content'], '低沉、缓慢');
      expect((messages[1] as Map)['role'], 'assistant');
    });

    test('429 后重试一次', () async {
      final int oldMax = TtsHttp.maxAttempts;
      TtsHttp.maxAttempts = 2;
      addTearDown(() => TtsHttp.maxAttempts = oldMax);
      int calls = 0;
      final MockClient client = MockClient((http.Request req) async {
        calls++;
        if (calls == 1) {
          return http.Response(
            '{"error":{"message":"rate limited"}}',
            429,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }
        return http.Response.bytes(
          <int>[1, 2, 3],
          200,
          headers: <String, String>{'content-type': 'audio/mpeg'},
        );
      });

      final TtsResult r = await TtsService(
        voiceProvider(
          protocol: Protocol.openai,
          baseUrl: 'https://api.openai.com/v1',
        ),
      ).synthesize('你好', client: client);

      expect(r.ok, isTrue);
      expect(calls, 2);
    });
    test('同一服务商的并发请求会串行化', () async {
      int active = 0;
      int maxActive = 0;
      final MockClient client = MockClient((http.Request req) async {
        active++;
        if (active > maxActive) maxActive = active;
        await Future<void>.delayed(const Duration(milliseconds: 40));
        active--;
        return http.Response.bytes(
          <int>[1, 2, 3],
          200,
          headers: <String, String>{'content-type': 'audio/mpeg'},
        );
      });
      final TtsService service = TtsService(
        voiceProvider(
          protocol: Protocol.openai,
          baseUrl: 'https://api.openai.com/v1',
        ),
      );
      await Future.wait(<Future<TtsResult>>[
        service.synthesize('a', client: client),
        service.synthesize('b', client: client),
      ]);
      expect(maxActive, 1);
    });
  });
}
