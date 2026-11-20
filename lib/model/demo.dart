import 'turn.dart';
import 'world_search.dart';

// 序列 / 事件的数据模型，以及 demo 世界。
// 序列 = 地点；每一步是“谁”做的一件事：人物（B）或旁白（A）。
//
// 一步一步的类型就是 [TurnStep]（在 turn.dart）—— 回合数据只有那一套，
// 这里不再另立一个。

/// 一条序列 = **一个地点**。
class ParallelPlace {
  const ParallelPlace({
    required this.id,
    required this.place,
    required this.here,
    required this.events,
    this.status = 'active',
    this.parentId = '',
    this.mergeInto = '',
  });

  final String id;

  /// 地点名（= 序列名）
  final String place;

  /// 玩家角色是否在此地点
  final bool here;

  /// 紧跟的每一步；下标 = 该地点的步序
  final List<TurnStep> events;

  /// active = 还在推进；merged = 已并入别的序列，只留历史。
  final String status;

  /// 开启并行地点时从哪条序列分出来；空 = 不是并行地点产生的。
  final String parentId;

  /// 合并目标序列 id；空 = 没合并。
  final String mergeInto;

  bool get isActive => status == 'active';

  ParallelPlace copyWith({
    String? id,
    String? place,
    bool? here,
    List<TurnStep>? events,
    String? status,
    String? parentId,
    String? mergeInto,
  }) {
    return ParallelPlace(
      id: id ?? this.id,
      place: place ?? this.place,
      here: here ?? this.here,
      events: events ?? this.events,
      status: status ?? this.status,
      parentId: parentId ?? this.parentId,
      mergeInto: mergeInto ?? this.mergeInto,
    );
  }
}

/// 换地点：人物从 fromParallelPlace 的第 fromStep 步，走到 toParallelPlace 的第 toStep 步。
/// 连线固定两折：源卡下方 → 横穿（走空隙）→ 落到目标卡上方。
class MoveLink {
  const MoveLink({
    required this.fromParallelPlace,
    required this.fromStep,
    required this.toParallelPlace,
    required this.toStep,
  });

  final String fromParallelPlace;
  final int fromStep;
  final String toParallelPlace;
  final int toStep;
}

/// 一个角色（人设卡）。
class CharCard {
  const CharCard({
    required this.name,
    required this.persona,
    this.location = '',
    this.state = '',
    this.aliases = const <String, String>{},
    this.ttsKey = '',
  });

  final String name;
  final String persona;

  /// 角色当前所在地点（地点名）。空 = 未指定，由最近步骤推断。
  final String location;

  /// 角色当前状态：伤势、装备、情绪等，给 GM_RESOLVE_ACTION 裁定用。
  final String state;

  /// 这个角色对其他角色的称呼：目标角色名 -> 他嘴里的叫法。
  /// 空 = 用规范名兜底。
  final Map<String, String> aliases;

  /// 这个角色自己的 TTS（TtsPick.key）；空 = 继承世界。
  final String ttsKey;

  CharCard copyWith({
    String? name,
    String? persona,
    String? location,
    String? state,
    Map<String, String>? aliases,
    String? ttsKey,
  }) {
    return CharCard(
      name: name ?? this.name,
      persona: persona ?? this.persona,
      location: location ?? this.location,
      state: state ?? this.state,
      aliases: aliases ?? this.aliases,
      ttsKey: ttsKey ?? this.ttsKey,
    );
  }
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
    required this.parallelPlaces,
    required this.moves,
    this.playerName = '',
    this.ttsKey = '',
    this.narratorTtsKey = '',
    this.searchSource = WorldSearchSource.off,
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

  /// 当前由人控制的角色名。空 = 没有角色由人控制，全部交给 AI。
  ///
  /// 字段名是历史包袱；语义上这是**控制绑定**，不是角色身份。所有角色都是
  /// 标准角色；换控制权只改这个值，不搬角色状态或记忆。
  final String playerName;

  /// 语义更准确的名字；新代码优先用它。
  String get controlledCharacterName => playerName;

  /// 这个世界的默认 TTS（TtsPick.key）；空 = 继承全局。
  final String ttsKey;

  /// 旁白专属 TTS（TtsPick.key）；空 = 继承世界默认。
  final String narratorTtsKey;

  /// 这个世界使用哪个搜索源；世界级设置，不按回合变。
  final WorldSearchSource searchSource;

  final List<ParallelPlace> parallelPlaces;
  final List<MoveLink> moves;

  /// 下一条序列的 id（l1 / l2 …）。按现有最大编号往后排，不复用。
  String nextParallelPlaceId() {
    int max = 0;
    for (final ParallelPlace l in parallelPlaces) {
      final Match? m = RegExp(r'^l(\d+)$').firstMatch(l.id);
      final int? n = m == null ? null : int.tryParse(m.group(1)!);
      if (n != null && n > max) max = n;
    }
    return 'l${max + 1}';
  }

  /// 没有序列时自动建第一条（地点名空 = “开场”）。
  /// 有序列就原样返回。
  World withInitialParallelPlace({String place = ''}) {
    if (parallelPlaces.isNotEmpty) return this;
    final String p = place.trim().isEmpty ? '开场' : place.trim();
    return copyWith(
      parallelPlaces: <ParallelPlace>[
        ParallelPlace(
          id: 'l1',
          place: p,
          here: controlledCharacterName.trim().isNotEmpty,
          events: const <TurnStep>[],
        ),
      ],
    );
  }

  /// 设置当前由人控制的角色；空 = 全部交给 AI。
  World withControlledCharacter(String name) =>
      copyWith(playerName: name.trim());

  /// 把“当前操控角色在此”标记按实际地点刷新。
  World withPlayerAt(String place) {
    final String p = place.trim();
    return copyWith(
      parallelPlaces: <ParallelPlace>[
        for (final ParallelPlace l in parallelPlaces)
          l.copyWith(here: l.isActive && p.isNotEmpty && l.place.trim() == p),
      ],
    );
  }

  /// 在某个地点开一条新线；同地点已有 active 线就不重复开。
  World addParallelPlaceAt(
    String place, {
    String parentId = '',
    bool here = false,
  }) {
    final String p = place.trim();
    if (p.isEmpty) return this;
    if (parallelPlaces.any(
      (ParallelPlace l) => l.isActive && l.place.trim() == p,
    )) {
      return this;
    }
    return copyWith(
      parallelPlaces: <ParallelPlace>[
        ...parallelPlaces,
        ParallelPlace(
          id: nextParallelPlaceId(),
          place: p,
          here: here,
          events: const <TurnStep>[],
          parentId: parentId,
        ),
      ],
    );
  }

  /// 把 [parallelPlaceId] 标成已并入 [into]；目标不存在 / 自己并自己就不动。
  World mergeParallelPlace(String parallelPlaceId, String into) {
    if (parallelPlaceId.isEmpty || into.isEmpty || parallelPlaceId == into)
      return this;
    final bool sourceExists = parallelPlaces.any(
      (ParallelPlace l) => l.id == parallelPlaceId && l.isActive,
    );
    final bool targetExists = parallelPlaces.any(
      (ParallelPlace l) => l.id == into && l.isActive,
    );
    if (!sourceExists || !targetExists) return this;
    return copyWith(
      parallelPlaces: <ParallelPlace>[
        for (final ParallelPlace l in parallelPlaces)
          if (l.id == parallelPlaceId)
            l.copyWith(status: 'merged', mergeInto: into, here: false)
          else
            l,
      ],
    );
  }

  World copyWith({
    String? id,
    String? name,
    String? note,
    String? setting,
    String? opening,
    List<CharCard>? characters,
    List<ParallelPlace>? parallelPlaces,
    List<MoveLink>? moves,
    String? playerName,
    String? ttsKey,
    String? narratorTtsKey,
    WorldSearchSource? searchSource,
  }) {
    return World(
      id: id ?? this.id,
      name: name ?? this.name,
      note: note ?? this.note,
      setting: setting ?? this.setting,
      opening: opening ?? this.opening,
      characters: characters ?? this.characters,
      parallelPlaces: parallelPlaces ?? this.parallelPlaces,
      moves: moves ?? this.moves,
      playerName: playerName ?? this.playerName,
      ttsKey: ttsKey ?? this.ttsKey,
      narratorTtsKey: narratorTtsKey ?? this.narratorTtsKey,
      searchSource: searchSource ?? this.searchSource,
    );
  }
}

class DemoData {
  static const List<World> worlds = <World>[
    World(
      id: 'w1',
      name: '旧宅 · 雨夜',
      // 默认由人操控人物1，所以这个世界有输入框。
      playerName: '人物1',
      note: '三个地点 · 一场雨',
      setting: '民国，南方小城，连日阴雨。\n旧宅“听雨楼”的主人三天前失踪，屋里的灯还亮着。',
      opening: '雨敲在瓦上。你站在旧宅的门廊下，衣角在滴水。\n门没有锁。',
      characters: <CharCard>[
        CharCard(name: '人物1', persona: '守着楼梯口的人，话很少。'),
        CharCard(name: '人物2', persona: '从后门进来的，认得人物1。'),
        CharCard(name: '人物3', persona: '在仓房翻东西，手上带着煤油味。'),
        CharCard(name: '人物4', persona: '冒雨从外面赶回来的。'),
      ],
      parallelPlaces: <ParallelPlace>[
        ParallelPlace(
          id: 'l1',
          place: '地点1 · 正厅',
          here: true,
          events: <TurnStep>[
            TurnStep(
              kind: 'CH_ACT',
              who: '人物1',
              time: '雨夜',
              text: '正厅的灯亮着。人物1站在楼梯口，没有动。',
            ),
            TurnStep(
              kind: 'CH_ACT',
              who: '人物2',
              time: '雨夜',
              text: '人物2从后门进来，凑到人物1耳边说了句什么。',
            ),
            TurnStep(
              kind: 'CH_ACT',
              who: '人物4',
              time: '雨还在下',
              text: '门被推开。人物4进来，肩上全是雨。',
            ),
            TurnStep(
              kind: 'CH_ACT',
              who: '人物3',
              time: '雨还在下',
              text: '人物3跟进来，把门带上，反手插了闩。',
            ),
            TurnStep(
              kind: 'GM_ENV_UPDATE',
              who: '旁白',
              time: '雨还在下',
              text: '正厅里安静下来，只剩雨声。',
            ),
          ],
        ),
        ParallelPlace(
          id: 'l2',
          place: '地点2 · 仓房',
          here: false,
          events: <TurnStep>[
            TurnStep(
              kind: 'CH_ACT',
              who: '人物3',
              time: '入夜',
              text: '人物3在货架之间翻东西，翻得很轻，什么也没找到。他从后门出去，往后巷走了。',
            ),
            TurnStep(
              kind: 'CH_ACT',
              who: '人物4',
              time: '入夜',
              text: '人物4推门进来说：我去正厅看看。',
            ),
            TurnStep(
              kind: 'GM_ENV_UPDATE',
              who: '旁白',
              time: '入夜之后',
              text: '仓房又静下来。煤油味还在，比刚才重一点。',
            ),
          ],
        ),
        ParallelPlace(
          id: 'l3',
          place: '地点3 · 后巷',
          here: false,
          events: <TurnStep>[
            TurnStep(
              kind: 'GM_ENV_UPDATE',
              who: '旁白',
              time: '夜半',
              text: '后巷已经空了，只剩墙根下一堆没点着的东西。',
            ),
            TurnStep(
              kind: 'CH_ACT',
              who: '人物3',
              time: '夜半',
              text: '人物3从仓房后门绕到后巷，把墙根下的东西点着，转身往正厅去了。',
            ),
            TurnStep(
              kind: 'GM_ENV_UPDATE',
              who: '旁白',
              time: '夜半之后',
              text: '火顺着墙往上爬。后巷开始亮起来。',
            ),
          ],
        ),
      ],
      moves: <MoveLink>[
        MoveLink(
          fromParallelPlace: 'l2',
          fromStep: 0,
          toParallelPlace: 'l3',
          toStep: 1,
        ),
        MoveLink(
          fromParallelPlace: 'l3',
          fromStep: 1,
          toParallelPlace: 'l1',
          toStep: 3,
        ),
        MoveLink(
          fromParallelPlace: 'l2',
          fromStep: 1,
          toParallelPlace: 'l1',
          toStep: 2,
        ),
      ],
    ),
    World(
      id: 'w2',
      name: '海边小镇',
      note: '还没开始',
      setting: '',
      opening: '',
      characters: <CharCard>[],
      parallelPlaces: <ParallelPlace>[],
      moves: <MoveLink>[],
    ),
    World(
      id: 'w3',
      name: '夜行列车',
      note: '还没开始',
      setting: '',
      opening: '',
      characters: <CharCard>[],
      parallelPlaces: <ParallelPlace>[],
      moves: <MoveLink>[],
    ),
  ];
}
