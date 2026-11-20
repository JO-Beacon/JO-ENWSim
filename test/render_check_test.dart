import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/engine/perception.dart';
import 'package:joenws/engine/render_check.dart';

NarrativeScene buildScene() {
  return NarrativeScene(
    place: '东门内侧',
    names: <String, String>{
      'char:信标': '信标',
      'char:艾琳': '艾琳',
      'char:灵梦': '灵梦',
      'char:妹红': '妹红',
    },
    cast: <CharacterSnapshot>[
      CharacterSnapshot(
        id: 'char:信标',
        name: '信标',
        nearby: true,
        aliases: <String, String>{'char:灵梦': '巫女'},
      ),
      CharacterSnapshot(
        id: 'char:艾琳',
        name: '艾琳',
        nearby: true,
      ),
    ],
  );
}

WorldEvent speechEvent({
  String content = '你没事吧？',
  String? target = 'char:艾琳',
}) {
  return WorldEvent(
    id: 'E1',
    kind: WorldEventKind.speech,
    content: content,
    actor: 'char:信标',
    target: target,
    delivery: const Delivery(
      channel: DeliveryChannel.voice,
      form: 'spoken',
      audience: Audience.scene,
    ),
  );
}

void main() {
  const RenderChecker checker = RenderChecker();

  test('合格正文：引号/名字/数字都有事件依据', () {
    final RenderCheckResult r = checker.check(
      publicText: '信标对艾琳说：“你没事吧？”',
      godNote: '',
      events: <WorldEvent>[speechEvent()],
      scene: buildScene(),
    );
    expect(r.ok, isTrue);
  });

  test('引号台词必须是事件里的逐字子串', () {
    final RenderCheckResult r = checker.check(
      publicText: '信标对艾琳说：“我没听见。”',
      godNote: '',
      events: <WorldEvent>[speechEvent()],
      scene: buildScene(),
    );
    expect(r.violations.single.code, 'invented_quote');
  });

  test('引号没配对要报', () {
    final RenderCheckResult r = checker.check(
      publicText: '信标对艾琳说：“你没事吧？',
      godNote: '',
      events: <WorldEvent>[speechEvent()],
      scene: buildScene(),
    );
    expect(r.violations.any((v) => v.code == 'unmatched_quote'), isTrue);
  });

  test('嵌套引号换风格不算编', () {
    final RenderCheckResult r = checker.check(
      publicText: '信标说：“他说‘别动’。”',
      godNote: '',
      events: <WorldEvent>[
        speechEvent(content: '他说“别动”。', target: null),
      ],
      scene: buildScene(),
    );
    expect(r.ok, isTrue);
  });

  test('不在场、不在事件里的名字要报', () {
    final RenderCheckResult r = checker.check(
      publicText: '灵梦站在门边。',
      godNote: '',
      events: <WorldEvent>[speechEvent()],
      scene: buildScene(),
    );
    expect(r.violations.single.code, 'unknown_name');
    expect(r.violations.single.message, contains('灵梦'));
  });

  test('事件里提到的已知名字可以用', () {
    final RenderCheckResult r = checker.check(
      publicText: '信标想起妹红还在村外。',
      godNote: '',
      events: <WorldEvent>[
        speechEvent(content: '想起妹红还在村外。', target: null),
      ],
      scene: buildScene(),
    );
    expect(r.ok, isTrue);
  });

  test('数字必须有事件依据', () {
    final RenderCheckResult r = checker.check(
      publicText: '三个人往东门去了。',
      godNote: '',
      events: <WorldEvent>[
        speechEvent(content: '两个人往东门去了。', target: null),
      ],
      scene: buildScene(),
    );
    expect(r.violations.single.code, 'invented_number');
    expect(r.violations.single.message, contains('3'));
  });

  test('事件里有同样数字就放行', () {
    final RenderCheckResult r = checker.check(
      publicText: '三个人往东门去了。',
      godNote: '',
      events: <WorldEvent>[
        speechEvent(content: '三个人往东门去了。', target: null),
      ],
      scene: buildScene(),
    );
    expect(r.ok, isTrue);
  });

  test('“一声不吭”不当作数字违规', () {
    final RenderCheckResult r = checker.check(
      publicText: '她一声不吭。',
      godNote: '',
      events: <WorldEvent>[speechEvent()],
      scene: buildScene(),
    );
    expect(r.ok, isTrue);
  });

  test('public_text 不能为空', () {
    final RenderCheckResult r = checker.check(
      publicText: '   ',
      godNote: '上帝注',
      events: <WorldEvent>[speechEvent()],
      scene: buildScene(),
    );
    expect(r.violations.single.code, 'empty_public_text');
  });

  test('实体名不在事件里要报', () {
    final RenderCheckResult r = checker.check(
      publicText: '急救包在架子上。',
      godNote: '',
      events: <WorldEvent>[speechEvent()],
      scene: buildScene(),
      entityNames: <String>['急救包'],
    );
    expect(r.violations.single.code, 'unknown_entity');
  });

  test('实体名在事件里就放行', () {
    final RenderCheckResult r = checker.check(
      publicText: '急救包在架子上。',
      godNote: '',
      events: <WorldEvent>[
        speechEvent(content: '急救包在架子上。', target: null),
      ],
      scene: buildScene(),
      entityNames: <String>['急救包'],
    );
    expect(r.ok, isTrue);
  });
}
