import 'package:joenws/engine/perception.dart';

NarrativeScene buildScene() {
  return NarrativeScene(
    place: '东门内侧',
    names: <String, String>{
      'char:信标': '信标',
      'char:灵梦': '灵梦',
      'char:艾琳': '艾琳',
      'char:魔理沙': '魔理沙',
      'char:慧音': '慧音',
    },
    cast: <CharacterSnapshot>[
      CharacterSnapshot(
        id: 'char:信标',
        name: '信标',
        nearby: true,
        aliases: <String, String>{
          'char:灵梦': '巫女',
          'char:艾琳': '联邦女人',
          'char:魔理沙': '魔理沙',
          'char:慧音': '慧音',
        },
      ),
      CharacterSnapshot(
        id: 'char:灵梦',
        name: '灵梦',
        nearby: true,
        aliases: <String, String>{
          'char:信标': '那个黑铁壳子',
          'char:艾琳': '那个受伤的联邦女人',
          'char:魔理沙': '魔理沙',
          'char:慧音': '慧音',
        },
      ),
      CharacterSnapshot(
        id: 'char:艾琳',
        name: '艾琳',
        nearby: true,
        aliases: <String, String>{
          'char:信标': '探险家',
          'char:灵梦': '巫女',
          'char:魔理沙': '魔理沙',
          'char:慧音': '慧音老师',
        },
      ),
      CharacterSnapshot(
        id: 'char:魔理沙',
        name: '魔理沙',
        nearby: false,
        aliases: <String, String>{
          'char:信标': '黑铁甲',
          'char:灵梦': '灵梦',
          'char:艾琳': '那个联邦女人',
          'char:慧音': '慧音',
        },
      ),
      CharacterSnapshot(
        id: 'char:慧音',
        name: '慧音',
        nearby: false,
        aliases: <String, String>{
          'char:信标': '那个青年',
          'char:灵梦': '灵梦',
          'char:艾琳': '那位姑娘',
          'char:魔理沙': '魔理沙',
        },
      ),
    ],
  );
}
