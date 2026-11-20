// WorldStore → NarrativeScene 适配
//
// 把当前世界的地点、角色卡和已有步骤，变成 TurnLoop 能吃的场景/知识/事件。
//
// 当前地点优先使用权威状态；称呼与见闻按角色隔离，玩家输入交给 GM_PARSE_INPUT。

import '../model/demo.dart';
import '../model/turn.dart';
import 'agents/llm_agent_runner.dart';
import 'character_memory.dart';
import 'engine_state.dart';
import 'perception.dart';
import 'sequence.dart';
import 'state_delta.dart';

class WorldAdapter {
  WorldAdapter({
    required this.world,
    required this.parallelPlaceId,
    this.priorEvents = const <WorldEvent>[],
    this.priorMemory = const <CharacterMemory>[],
    this.priorLocations = const <String, String>{},
    this.priorStates = const <String, String>{},
    this.priorInventories = const <String, List<String>>{},
    this.priorInjuries = const <InjuryFact>[],
    this.priorConstraints = const <FunctionalConstraint>[],
    this.priorAnswers = const <PlayerAnswer>[],
  });

  final World world;
  final String parallelPlaceId;

  /// 上一回合持久化下来的完整事件日志与角色记忆。
  final List<WorldEvent> priorEvents;
  final List<CharacterMemory> priorMemory;

  /// 上一回合结束时每角色的地点/状态/随身物品。
  final Map<String, String> priorLocations;
  final Map<String, String> priorStates;
  final Map<String, List<String>> priorInventories;

  /// 上一回合结束时的伤势事实与功能限制。
  final List<InjuryFact> priorInjuries;
  final List<FunctionalConstraint> priorConstraints;

  /// 玩家之前对 AI 求助问题的回答。
  final List<PlayerAnswer> priorAnswers;

  ParallelPlace? get parallelPlace {
    for (final ParallelPlace l in world.parallelPlaces) {
      if (l.id == parallelPlaceId) return l;
    }
    return null;
  }

  /// 当前由人控制的角色；空 = 全部交给 AI。
  String get controlledCharacterName => world.controlledCharacterName.trim();

  /// 兼容旧调用点；新代码用 [controlledCharacterName]。
  String get playerName => controlledCharacterName;

  List<String> get _knownNames {
    final List<String> out = <String>[
      for (final CharCard c in world.characters)
        if (c.name.trim().isNotEmpty) c.name.trim(),
    ];
    return out;
  }

  /// 世界数据里有没有任何角色填了所在地点。
  bool get hasPlacements =>
      world.characters.any((CharCard c) => c.location.trim().isNotEmpty);

  /// 从世界数据建最小实体表：角色 + 地点。物品/容器后续由事件派生。
  Map<String, EntityRecord> seedEntities() {
    final Map<String, EntityRecord> out = <String, EntityRecord>{};
    for (final CharCard c in world.characters) {
      final String name = c.name.trim();
      if (name.isEmpty) continue;
      final String loc = priorLocations[name] ?? c.location.trim();
      out['char:$name'] = EntityRecord(
        id: 'char:$name',
        kind: 'character',
        name: name,
        location: loc,
      );
    }
    for (final ParallelPlace l in world.parallelPlaces) {
      final String place = l.place.trim();
      if (place.isEmpty) continue;
      out['place:$place'] = EntityRecord(
        id: 'place:$place',
        kind: 'place',
        name: place,
      );
    }
    for (final String place in charactersByPlace.keys) {
      if (place.isEmpty) continue;
      out.putIfAbsent('place:$place', () => EntityRecord(
          id: 'place:$place', kind: 'place', name: place));
    }
    return out;
  }

  /// 只有一条 active 线时，没有任何位置/历史线索也只能把人放这儿。
  bool get _onlyActiveParallelPlace =>
      world.parallelPlaces.where((ParallelPlace l) => l.isActive).length <= 1;

  /// 当前地点在场的人。
  ///
  /// 唯一来源是 [charactersByPlace]：先看状态里的地点，再看角色卡地点，
  /// 最后才用当前列最近几步补缺。不要在这里另写一套“只要有人填了地点就
  /// 不再看角色卡”的分支，否则同一批角色在 presentNames 和候选地点里会
  /// 得到不同结果。
  Set<String> get presentNames {
    final String place = parallelPlace?.place.trim() ?? '';
    if (place.isEmpty) return <String>{};
    return (charactersByPlace[place] ?? const <String>[]).toSet();
  }

  /// 本回合能感知的角色：现场所有人，包括当前由人控制的角色。
  ///
  /// 不能行动的人仍然能看见、听见环境变化。
  List<String> get perceptionNames => <String>[
        for (final String n in presentNames)
          if (n.trim().isNotEmpty) n,
      ];

  /// 本回合可行动的 actor：现场所有能行动的角色，包括当前由人控制的角色。
  ///
  /// 这里不再区分“玩家角色 / NPC”；区别只由 TurnLoop 的 controlledCharacter
  /// 决定 CH_ACT 是等人输入还是交给 AI。
  List<String> get actorNames => <String>[
        for (final String n in presentNames)
          if (n.trim().isNotEmpty && !_cannotAct(n)) n,
      ];

  /// 旧调用名：只列不由人控制的角色。新代码用 [actorNames]。
  List<String> get npcNames => <String>[
        for (final String n in presentNames)
          if (n.trim().isNotEmpty &&
              n != controlledCharacterName &&
              !_cannotAct(n))
            n,
      ];

  bool _cannotAct(String name) => priorConstraints.any(
        (FunctionalConstraint c) =>
            c.who == name &&
            c.capability == 'act' &&
            c.state == ConstraintState.cannot,
      );

  /// 角色名 -> 现在在哪个地点。优先状态里的位置，其次角色卡，最后按
  /// 当前列最近几步推断；都没有就只放当前列里能确认的人。
  ///
  /// 多序列之后这是“并行地点候选”和“每角色种子知识”的共同来源：
  /// 不能再用“当前 parallelPlace 的地点”去给所有角色灌种子。
  Map<String, List<String>> get charactersByPlace {
    final Map<String, String> located = <String, String>{
      for (final MapEntry<String, String> e in priorLocations.entries)
        if (e.value.trim().isNotEmpty) e.key: e.value.trim(),
    };
    // 状态里没有的人（新加的角色、旧存档）退回角色卡上的地点。
    for (final CharCard c in world.characters) {
      final String name = c.name.trim();
      final String place = c.location.trim();
      if (name.isNotEmpty &&
          place.isNotEmpty &&
          !located.containsKey(name)) {
        located[name] = place;
      }
    }
    if (located.isEmpty) {
      final ParallelPlace? l = parallelPlace;
      final String place = (l?.place ?? '').trim();
      final Set<String> names = <String>{};
      if (l != null) {
        for (final TurnStep s in l.events.reversed.take(6)) {
          if (_knownNames.contains(s.who)) names.add(s.who);
        }
      }
      if ((l?.here ?? true) && _knownNames.contains(playerName)) {
        names.add(playerName);
      }
      if (_onlyActiveParallelPlace &&
          (names.isEmpty ||
              (playerName.isNotEmpty &&
                  names.length == 1 &&
                  names.contains(playerName)))) {
        names.addAll(_knownNames);
      }
      return <String, List<String>>{
        if (place.isNotEmpty) place: names.toList(),
      };
    }
    // 状态里没写、角色卡也没填的人：用当前列最近几步补一下（只补缺，不覆盖）。
    final ParallelPlace? l = parallelPlace;
    if (l != null) {
      for (final TurnStep s in l.events.reversed.take(6)) {
        final String who = s.who.trim();
        if (_knownNames.contains(who) && !located.containsKey(who)) {
          located[who] = l.place.trim();
        }
      }
    }
    if (playerName.isNotEmpty &&
        _knownNames.contains(playerName) &&
        !located.containsKey(playerName) &&
        (l?.here ?? true)) {
      final String place = (l?.place ?? '').trim();
      if (place.isNotEmpty) located[playerName] = place;
    }
    final Map<String, List<String>> out = <String, List<String>>{};
    for (final MapEntry<String, String> e in located.entries) {
      out.putIfAbsent(e.value, () => <String>[]).add(e.key);
    }
    return out;
  }

  /// 引擎看的序列列表：默认只给 active 的。
  List<ParallelPlaceInfo> parallelPlaceInfos({bool includeMerged = false}) {
    final Map<String, List<String>> byPlace = charactersByPlace;
    return <ParallelPlaceInfo>[
      for (final ParallelPlace l in world.parallelPlaces)
        if (includeMerged || l.isActive)
          ParallelPlaceInfo(
            id: l.id,
            place: l.place,
            status: l.status,
            parentId: l.parentId,
            mergeInto: l.mergeInto,
            members: List<String>.of(
              byPlace[l.place.trim()] ?? const <String>[],
            ),
          ),
    ];
  }

  /// 还没有 active 序列覆盖的已知地点 = 可以开新列的地方。
  ///
  /// 候选不再要求“现场有人”：火势蔓延、暴雨灌进仓房这类环境变化也可以
  /// 单独开一条线。地点来源限定为世界已出现过的地点（角色卡地点、已有列），
  /// 不允许 GM_OPEN_PLACE 凭空造一个完全没出现过的地名。
  List<ParallelPlaceCandidate> parallelPlaceCandidates() {
    final Set<String> activePlaces = <String>{
      for (final ParallelPlace l in world.parallelPlaces)
        if (l.isActive) l.place.trim(),
    };
    final Map<String, List<String>> byPlace = charactersByPlace;
    final Set<String> knownPlaces = <String>{
      for (final ParallelPlace l in world.parallelPlaces)
        if (l.place.trim().isNotEmpty) l.place.trim(),
      for (final CharCard c in world.characters)
        if (c.location.trim().isNotEmpty) c.location.trim(),
      ...byPlace.keys.where((String p) => p.trim().isNotEmpty),
    };
    final List<ParallelPlaceCandidate> out = <ParallelPlaceCandidate>[];
    for (final String rawPlace in knownPlaces) {
      final String place = rawPlace.trim();
      if (place.isEmpty || activePlaces.contains(place)) continue;
      final List<String> members = <String>[
        for (final String n in byPlace[place] ?? const <String>[])
          if (n.trim().isNotEmpty) n.trim(),
      ];
      out.add(ParallelPlaceCandidate(place: place, members: members));
    }
    out.sort((ParallelPlaceCandidate a, ParallelPlaceCandidate b) => a.place.compareTo(b.place));
    return out;
  }

  /// 新事件从“已有事件/步数 + 1”开始编号，避免和旧事件撞号。
  int get startSeq {
    int base = 0;
    for (final WorldEvent e in priorEvents) {
      final Match? m = RegExp(r'^E(\d+)$').firstMatch(e.id);
      final int? n = m == null ? null : int.tryParse(m.group(1)!);
      if (n != null && n > base) base = n;
    }
    int steps = 0;
    for (final ParallelPlace l in world.parallelPlaces) {
      steps += l.events.length;
    }
    if (steps > base) base = steps;
    return base + 1;
  }

  Map<String, CharacterProfile> get profiles {
    return <String, CharacterProfile>{
      for (final CharCard c in world.characters)
        if (c.name.trim().isNotEmpty)
          c.name.trim(): CharacterProfile(
            persona: c.persona.trim().isEmpty ? c.name.trim() : c.persona.trim(),
            state: _profileState(c.name.trim(), c),
          ),
    };
  }

  String _profileState(String name, CharCard c) {
    final String location = priorLocations[name] ?? c.location.trim();
    final String base = priorStates[name] ?? c.state.trim();
    final String condition = TurnState(
      events: const <WorldEvent>[],
      injuries: priorInjuries,
      constraints: priorConstraints,
    ).conditionText(name);
    return <String>[
      if (location.isNotEmpty) '当前地点：$location',
      if (base.isNotEmpty) base,
      if (priorInventories.containsKey(name))
        '随身物品：${priorInventories[name]!.isEmpty ? '无' : priorInventories[name]!.join('、')}',
      if (condition.isNotEmpty) condition,
    ].join('；');
  }

  NarrativeScene scene({String? atPlace}) {
    final String place = atPlace ?? parallelPlace?.place ?? '当前地点';
    final Set<String> present = atPlace == null ? presentNames
        : (charactersByPlace[place] ?? const <String>[]).toSet();
    final List<CharacterSnapshot> cast = <CharacterSnapshot>[];
    for (final String name in present) {
      final String id = 'char:$name';
      final Map<String, String> aliasMap = <String, String>{};
      for (final CharCard c in world.characters) {
        if (c.name.trim() != name) continue;
        for (final MapEntry<String, String> e in c.aliases.entries) {
          final String target = e.key.trim();
          final String alias = e.value.trim();
          if (target.isNotEmpty && alias.isNotEmpty) {
            aliasMap['char:$target'] = alias;
          }
        }
        break;
      }
      for (final String other in _knownNames) {
        if (other == name) continue;
        aliasMap.putIfAbsent('char:$other', () => '陌生人${_knownNames.indexOf(other) + 1}');
      }
      cast.add(CharacterSnapshot(
        id: id,
        name: name,
        nearby: true,
        aliases: aliasMap,
      ));
    }
    return NarrativeScene(
      place: place,
      cast: cast,
      names: <String, String>{
        for (final String name in _knownNames) 'char:$name': name,
      },
      playerNotes: _playerNotes(),
      characterNotes: <String, String>{
        for (final String name in present) 'char:$name': _playerNotes(character: name),
      },
    );
  }

  String _playerNotes({String? character}) {
    if (priorAnswers.isEmpty) return '';
    final List<PlayerAnswer> recent = priorAnswers.length > 20
        ? priorAnswers.sublist(priorAnswers.length - 20)
        : priorAnswers;
    return recent
        .where((PlayerAnswer a) => character == null || a.visibility == 'public' ||
            (a.visibility == 'character' &&
                a.characterId.replaceFirst('char:', '') == character))
        .map((PlayerAnswer a) =>
            '[${a.step}] ${a.question}\n玩家回答：${a.answer}')
        .join('\n');
  }

  /// 记忆只由 CH_PERCEIVE/CH_MEMORY_WRITE 和持久化快照恢复；空记忆可能是主动遗忘，不能从历史重灌。
  List<CharacterMemory> memorySeed() => const <CharacterMemory>[];

  /// 本回合的兜底事件（只取当前地点最后一步）。
  ///
  /// 玩家原文**不能**在这里直接变成 speech；它必须先经过 GM_PARSE_INPUT 解析。
  /// 所以非空 [playerInput] 返回空，防止旧调用把输入框当台词。
  List<WorldEvent> newEvents(String playerInput) {
    final String input = playerInput.trim();
    if (input.isNotEmpty) return const <WorldEvent>[];
    final ParallelPlace? l = parallelPlace;
    if (l == null || l.events.isEmpty) return const <WorldEvent>[];
    final TurnStep last = l.events.last;
    final String who = last.who.trim().isEmpty ? '旁白' : last.who.trim();
    final String rawText =
        last.text.trim().isEmpty ? '（上一步没有正文）' : last.text.trim();
    final String content = who != '旁白' && rawText.startsWith(who)
        ? rawText.substring(who.length)
        : rawText;
    return <WorldEvent>[
      WorldEvent(
        id: 'E$startSeq',
        kind: WorldEventKind.action,
        content: content,
        actor: who == '旁白' ? '' : 'char:$who',
        delivery: const Delivery(
          channel: DeliveryChannel.other,
          form: 'narration',
          audience: Audience.scene,
        ),
        segments: <EventSegment>[
          EventSegment(
            kind: WorldEventKind.action,
            text: content,
            delivery: const Delivery(
              channel: DeliveryChannel.other,
              form: 'narration',
              audience: Audience.scene,
            ),
          ),
        ],
        source: 'narration',
        placeId: parallelPlace?.place ?? '',
        timeLabel: last.time.trim(),
      ),
    ];
  }
}
