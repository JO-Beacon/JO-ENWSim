// 行尾：库里只许有 LF（`\n`）。
//
// 从 Windows 的网页 / 聊天窗口粘贴过来的多行文字是 CRLF（`\r\n`）。
// `\r` 没有字形，画出来是豆腐块（☒），还会把 Markdown 的切块搅乱。
//
// 三道：
//   1. 输入框入口清（`JoTextField._sanitize`）；
//   2. 写库前清（`joLf`，WorldStore 各写入口）。

import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/data/world_store.dart';
import 'package:joenws/engine/character_memory.dart';
import 'package:joenws/model/demo.dart';
import 'package:joenws/model/text.dart';
import 'package:joenws/model/turn.dart';

World worldWith(String text) => World(
  id: 'w1',
  name: '测试\r\n世界',
  note: '一行\r\n两行',
  setting: '民国，\r\n南方小城',
  opening: '雨落在瓦上。\r\n门没有锁。',
  playerName: '人物1',
  characters: const <CharCard>[CharCard(name: '人物1', persona: '守着门')],
  parallelPlaces: <ParallelPlace>[
    ParallelPlace(id: 'l1', place: '正厅', here: true, events: <TurnStep>[]),
  ],
  moves: const <MoveLink>[],
);

void main() {
  test('joLf：CRLF / CR 都变 LF，别的字符不动', () {
    expect(joLf('a\r\nb'), 'a\nb');
    expect(joLf('a\rb'), 'a\nb');
    expect(joLf('a\nb'), 'a\nb');
    expect(joLf('a\r\nb\rc\nd'), 'a\nb\nc\nd');
    // 全角标点、空格、缩进都原样
    expect(joLf('　甲　\r\n    乙'), '　甲　\n    乙');
    // 没有 \r 时是同一个对象（不白造字符串）
    const String s = 'no cr here';
    expect(identical(joLf(s), s), isTrue);
  });

  test('写库：世界 / 步骤 / 记忆都不留回车符', () {
    final WorldStore s = WorldStore.memory();
    addTearDown(s.close);

    s.saveWorld(worldWith('x'));
    s.appendStep(
      'w1',
      'l1',
      const TurnStep(
        kind: 'CH_ACT',
        who: '人物1',
        time: '雨\r\n夜',
        text: '第一行\r\n第二行\r第三行',
        chosen: '人物1\r\n',
        judgment: '判断\r\n',
      ),
    );
    s.saveWorldMemory('w1', const <CharacterMemory>[
      CharacterMemory(
        id: 'm1',
        characterId: 'char:人物1',
        text: '记得\r\n门是插着的。',
        kind: MemoryKind.note,
        origin: MemoryOrigin.manual,
      ),
    ]);

    final World back = s.loadWorlds().worlds.first;
    expect(back.name.contains('\r'), isFalse);
    expect(back.setting.contains('\r'), isFalse);
    expect(back.opening.contains('\r'), isFalse);
    expect(back.opening, contains('\n'));

    final TurnStep step = s.loadSteps('w1', 'l1').first;
    expect(step.text, '第一行\n第二行\n第三行');
    expect(step.time.contains('\r'), isFalse);
    expect(step.judgment.contains('\r'), isFalse);

    final CharacterMemory m = s.loadWorldMemory('w1').single;
    expect(m.text, '记得\n门是插着的。');
  });

}
