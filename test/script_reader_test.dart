import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/engine/perception.dart';
import 'package:joenws/tts/script_reader.dart';

WorldEvent ev(
  WorldEventKind kind,
  String content, {
  String actor = 'char:灵梦',
  DeliveryChannel channel = DeliveryChannel.voice,
  String form = 'spoken',
  WorldEventStatus status = WorldEventStatus.accepted,
  String godNote = '',
  String publicText = '',
}) {
  return WorldEvent(
    id: 'E1',
    kind: kind,
    content: content,
    actor: actor,
    delivery: Delivery(channel: channel, form: form, audience: Audience.scene),
    status: status,
    godNote: godNote,
    publicText: publicText,
  );
}

void main() {
  group('事件流', () {
    test('默认旁白与对白都念，无声台词跳过', () {
      final List<Utterance> out = const ScriptReader().readEvents(<WorldEvent>[
        ev(WorldEventKind.action, '推开门，走进仓房。'),
        ev(WorldEventKind.speech, '“谁在那儿？”'),
        ev(
          WorldEventKind.speech,
          '“别出声。”',
          channel: DeliveryChannel.visual,
          form: 'written',
        ),
      ]);

      expect(out.length, 2);
      expect(out[0].isNarration, isTrue);
      expect(out[0].text, '推开门，走进仓房。');
      expect(out[1].speaker, 'char:灵梦');
      expect(out[1].text, '“谁在那儿？”');
    });

    test('仅对白：旁白整段不念', () {
      final List<Utterance> out =
          const ScriptReader(scope: ReadScope.dialogueOnly).readEvents(
            <WorldEvent>[
              ev(WorldEventKind.action, '推开门，走进仓房。'),
              ev(WorldEventKind.speech, '“谁在那儿？”'),
            ],
          );

      expect(out.length, 1);
      expect(out.single.text, '“谁在那儿？”');
    });

    test('只念 content：上帝标签与公开文字都不念', () {
      final List<Utterance> out = const ScriptReader().readEvents(<WorldEvent>[
        ev(
          WorldEventKind.speech,
          '“我没事。”',
          godNote: '她其实在说谎',
          publicText: '灵梦说自己没事',
        ),
      ]);

      expect(out.single.text, '“我没事。”');
      expect(out.single.text, isNot(contains('说谎')));
      expect(out.single.text, isNot(contains('灵梦说自己没事')));
    });

    test('被拒绝的事件不念', () {
      final List<Utterance> out = const ScriptReader().readEvents(<WorldEvent>[
        ev(WorldEventKind.speech, '“这句不算。”', status: WorldEventStatus.rejected),
      ]);

      expect(out, isEmpty);
    });

    test('口型 / 传讯 / 心灵都不念', () {
      final List<Utterance> out = const ScriptReader().readEvents(<WorldEvent>[
        ev(
          WorldEventKind.speech,
          '口型',
          channel: DeliveryChannel.visual,
          form: 'mouthed',
        ),
        ev(
          WorldEventKind.speech,
          '传讯',
          channel: DeliveryChannel.digital,
          form: 'transmitted',
        ),
        ev(
          WorldEventKind.speech,
          '心声',
          channel: DeliveryChannel.mental,
          form: 'telepathic',
        ),
      ]);

      expect(out, isEmpty);
    });

    test('标点决定停顿；换说话人至少停 400ms', () {
      final List<Utterance> out = const ScriptReader().readEvents(<WorldEvent>[
        ev(WorldEventKind.action, '他抬头看了一眼，'),
        ev(WorldEventKind.speech, '“走吧。”'),
        ev(WorldEventKind.speech, '“好。”', actor: 'char:魔理沙'),
      ]);

      // 逗号 120，但后面换了说话人（旁白 → 灵梦），抬到 400。
      expect(out[0].pauseAfterMs, ScriptReader.pauseSpeakerChange);
      expect(out[1].pauseAfterMs, ScriptReader.pauseSpeakerChange);
      expect(out[2].pauseAfterMs, ScriptReader.pauseSentence);
    });

    test('句末引号不影响句末停顿的判断', () {
      final List<Utterance> out = const ScriptReader().readEvents(<WorldEvent>[
        ev(WorldEventKind.speech, '“我没事。”'),
      ]);

      expect(out.single.pauseAfterMs, ScriptReader.pauseSentence);
    });
  });

  group('Markdown', () {
    const String doc = '''
# 世界观

雨夜，旧宅。
门是锁着的。

- 窗半开
- 桌上有一封信

```dart
final x = 1;
```

| 名字 | 年龄 |
| --- | --- |
| 灵梦 | 17 |

![旧宅](house.png)

[站外链接](https://example.com)
''';

    test('标题 / 段落 / 列表按段念；代码、表格、图片、URL 跳过', () {
      final List<Utterance> out = const ScriptReader().readMarkdown(doc);
      final List<String> texts = out.map((Utterance u) => u.text).toList();

      expect(texts, contains('世界观'));
      expect(texts, contains('雨夜，旧宅。门是锁着的。'));
      expect(texts, contains('窗半开'));
      expect(texts, contains('桌上有一封信'));
      expect(texts, contains('站外链接'));
      expect(texts.join('\n'), isNot(contains('final x')));
      expect(texts.join('\n'), isNot(contains('灵梦')));
      expect(texts.join('\n'), isNot(contains('house.png')));
      expect(texts.join('\n'), isNot(contains('https://')));
    });

    test('段落之间停 600ms，标题 550ms', () {
      final List<Utterance> out = const ScriptReader().readMarkdown(doc);
      final Utterance head = out.firstWhere((Utterance u) => u.text == '世界观');
      final Utterance para = out.firstWhere(
        (Utterance u) => u.text == '雨夜，旧宅。门是锁着的。',
      );

      expect(head.pauseAfterMs, ScriptReader.pauseHeading);
      expect(para.pauseAfterMs, ScriptReader.pauseParagraph);
    });

    test('告警块换成中文小标题', () {
      final List<Utterance> out = const ScriptReader().readMarkdown(
        '> [!NOTE]\n> 这里很冷。',
      );

      expect(out.single.text, '注意：这里很冷。');
    });

    test('空文档与空事件都得到空清单', () {
      expect(const ScriptReader().readMarkdown(''), isEmpty);
      expect(const ScriptReader().readEvents(<WorldEvent>[]), isEmpty);
    });
  });
}
