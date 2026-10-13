// 序列 / 事件的数据模型，以及 demo 世界。
// 序列 = 地点；每一步是“谁”做的一件事：人物（B）或旁白（A）。

class SeqEvent {
  const SeqEvent({
    required this.who,
    required this.time,
    required this.text,
  });

  /// 谁：人物名（B）或“旁白”（A）
  final String who;

  /// 时间标签（**文本**，不是时间戳；只显示，不参与排版）
  final String time;

  /// 正文
  final String text;

  bool get isNarration => who == '旁白';
}

/// 一条序列 = **一个地点**。
class SeqLane {
  const SeqLane({
    required this.id,
    required this.place,
    required this.here,
    required this.events,
  });

  final String id;

  /// 地点名（= 序列名）
  final String place;

  /// 玩家角色是否在此地点
  final bool here;

  /// 紧跟的每一步；下标 = 该地点的步序
  final List<SeqEvent> events;
}

/// 换地点：人物从 fromLane 的第 fromStep 步，走到 toLane 的第 toStep 步。
/// 连线固定两折：源卡下方 → 横穿（走空隙）→ 落到目标卡上方。
class MoveLink {
  const MoveLink({
    required this.fromLane,
    required this.fromStep,
    required this.toLane,
    required this.toStep,
  });

  final String fromLane;
  final int fromStep;
  final String toLane;
  final int toStep;
}

/// 一个角色（人设卡）。
class CharCard {
  const CharCard({required this.name, required this.persona});

  final String name;
  final String persona;
}

/// 一个世界。
class World {
  const World({
    required this.id,
    required this.name,
    required this.note,
    required this.setting,
    required this.opening,
    required this.characters,
    required this.lanes,
    required this.moves,
  });

  final String id;
  final String name;

  /// 一行副标题（地点数 / 步数之类）
  final String note;

  /// 世界观设定
  final String setting;

  /// 开场
  final String opening;

  /// 已知角色（手写的 + AI 分析的）
  final List<CharCard> characters;

  final List<SeqLane> lanes;
  final List<MoveLink> moves;
}

class DemoData {
  static const List<World> worlds = <World>[
    World(
      id: 'w1',
      name: '旧宅 · 雨夜',
      note: '三个地点 · 一场雨',
      setting: '民国，南方小城，连日阴雨。\n旧宅“听雨楼”的主人三天前失踪，屋里的灯还亮着。',
      opening: '雨敲在瓦上。你站在旧宅的门廊下，衣角在滴水。\n门没有锁。',
      characters: <CharCard>[
        CharCard(name: '人物1', persona: '守着楼梯口的人，话很少。'),
        CharCard(name: '人物2', persona: '从后门进来的，认得人物1。'),
        CharCard(name: '人物3', persona: '在仓房翻东西，手上带着煤油味。'),
        CharCard(name: '人物4', persona: '冒雨从外面赶回来的。'),
      ],
      lanes: <SeqLane>[
        SeqLane(
          id: 'l1',
          place: '地点1 · 正厅',
          here: true,
          events: <SeqEvent>[
            SeqEvent(who: '人物1', time: '雨夜', text: '正厅的灯亮着。人物1站在楼梯口，没有动。'),
            SeqEvent(who: '人物2', time: '雨夜', text: '人物2从后门进来，凑到人物1耳边说了句什么。'),
            SeqEvent(who: '人物4', time: '雨还在下', text: '门被推开。人物4进来，肩上全是雨。'),
            SeqEvent(who: '人物3', time: '雨还在下', text: '人物3跟进来，把门带上，反手插了闩。'),
            SeqEvent(who: '旁白', time: '雨还在下', text: '正厅里安静下来，只剩雨声。'),
          ],
        ),
        SeqLane(
          id: 'l2',
          place: '地点2 · 仓房',
          here: false,
          events: <SeqEvent>[
            SeqEvent(who: '人物3', time: '入夜', text: '人物3在货架之间翻东西，翻得很轻，什么也没找到。他从后门出去，往后巷走了。'),
            SeqEvent(who: '人物4', time: '入夜', text: '人物4推门进来说：我去正厅看看。'),
            SeqEvent(who: '旁白', time: '入夜之后', text: '仓房又静下来。煤油味还在，比刚才重一点。'),
          ],
        ),
        SeqLane(
          id: 'l3',
          place: '地点3 · 后巷',
          here: false,
          events: <SeqEvent>[
            SeqEvent(who: '旁白', time: '夜半', text: '后巷已经空了，只剩墙根下一堆没点着的东西。'),
            SeqEvent(who: '人物3', time: '夜半', text: '人物3从仓房后门绕到后巷，把墙根下的东西点着，转身往正厅去了。'),
            SeqEvent(who: '旁白', time: '夜半之后', text: '火顺着墙往上爬。后巷开始亮起来。'),
          ],
        ),
      ],
      moves: <MoveLink>[
        MoveLink(fromLane: 'l2', fromStep: 0, toLane: 'l3', toStep: 1),
        MoveLink(fromLane: 'l3', fromStep: 1, toLane: 'l1', toStep: 3),
        MoveLink(fromLane: 'l2', fromStep: 1, toLane: 'l1', toStep: 2),
      ],
    ),
    World(
      id: 'w2',
      name: '海边小镇',
      note: '还没开始',
      setting: '',
      opening: '',
      characters: <CharCard>[],
      lanes: <SeqLane>[],
      moves: <MoveLink>[],
    ),
    World(
      id: 'w3',
      name: '夜行列车',
      note: '还没开始',
      setting: '',
      opening: '',
      characters: <CharCard>[],
      lanes: <SeqLane>[],
      moves: <MoveLink>[],
    ),
  ];
}
