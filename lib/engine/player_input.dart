// 玩家输入解析结果（GM_PARSE_INPUT 的输出）
//
// GM_PARSE_INPUT 只做结构化：原文 → segments + unresolved + warnings。
// 这里负责：
//   · 保存每段的 kind / text / target / delivery / note / evidence；
//   · 校验 text/evidence 是原文连续子串（在 runner 里做）；
//   · 把已确认的 segments 变成 WorldEvent（SYS_RECORD 的输入）。
//
// 注意：audience 还是 unknown 时不能 toEvents；必须先让玩家确认，不静默猜。

import 'perception.dart';
import 'engine_state.dart';

/// 玩家声明的行为类型。
///
/// - action：可观察的动作；
/// - speech：可观察的台词（会写成 [WorldEventKind.speech]）；
/// - inner：内心，不进事件，只进 inner。
enum PlayerSegmentKind { action, speech, inner }

/// GM_PARSE_INPUT 只读的行动上下文：玩家当前状态、背包、现场物品和已知地点。
///
/// 这不是 GM_PARSE_INPUT 自己改的状态，只是给 GM_PARSE_INPUT 把原文解析成规范 id / requires 的参照。
class PlayerInputContext {
  const PlayerInputContext({
    this.playerState = '',
    this.inventory = const <Map<String, String>>[],
    this.placeItems = const <Map<String, String>>[],
    this.knownPlaces = const <String>[],
    this.constraints = const <Map<String, Object?>>[],
    this.clarifications = const <Map<String, String>>[],
  });

  final String playerState;
  final List<Map<String, String>> inventory;
  final List<Map<String, String>> placeItems;
  final List<String> knownPlaces;
  final List<Map<String, Object?>> constraints;

  /// 玩家对上一轮 GM_PARSE_INPUT 未决字段的补充回答；不是 raw 原文。
  final List<Map<String, String>> clarifications;

  PlayerInputContext withClarifications(List<Map<String, String>> next) {
    return PlayerInputContext(
      playerState: playerState,
      inventory: inventory,
      placeItems: placeItems,
      knownPlaces: knownPlaces,
      constraints: constraints,
      clarifications: next,
    );
  }
}

/// GM_PARSE_INPUT 可以声明的物理/对抗动作；普通说话、移动、拿取不填。
const Set<String> playerActionKinds = <String>{
  'attack',
  'dodge',
  'grapple',
  'chase',
  'flee',
  'steal',
  'lockpick',
  'disarm',
  'spell_contest',
};

class PlayerSegment {
  const PlayerSegment({
    required this.id,
    required this.kind,
    required this.text,
    required this.delivery,
    this.target,
    this.deliveryNote,
    this.distanceNote,
    this.manner,
    this.mannerNote,
    this.actionKind,
    this.requires = const <String>[],
    this.evidence = const <String, String>{},
  });

  final String id;
  final PlayerSegmentKind kind;

  /// 原文连续子串，不改写。
  final String text;
  final String? target;
  final Delivery delivery;
  final String? deliveryNote;
  final String? distanceNote;
  final String? manner;
  final String? mannerNote;

  /// 物理/对抗动作的类型；普通说话、移动、拿取为 null。
  final String? actionKind;

  /// 做这个动作需要的能力；说话为 speak，用手为 use_left_arm 等。
  final List<String> requires;
  final Map<String, String> evidence;

  PlayerSegment copyWith({Delivery? delivery}) {
    return PlayerSegment(
      id: id,
      kind: kind,
      text: text,
      target: target,
      delivery: delivery ?? this.delivery,
      deliveryNote: deliveryNote,
      distanceNote: distanceNote,
      manner: manner,
      mannerNote: mannerNote,
      actionKind: actionKind,
      requires: requires,
      evidence: evidence,
    );
  }
}

class PlayerUnresolved {
  const PlayerUnresolved({
    required this.segmentIds,
    required this.field,
    required this.question,
    required this.why,
    required this.options,
  });

  final List<String> segmentIds;
  final String field;
  final String question;
  final String why;
  final List<String> options;

  bool get isAudience =>
      field.contains('audience') ||
      field.contains('range') ||
      question.contains('听见') ||
      question.contains('耳语') ||
      question.contains('范围');
}

class PlayerParseResult {
  const PlayerParseResult({
    required this.raw,
    required this.segments,
    required this.unresolved,
    required this.warnings,
    this.stateDelta = const <String, Object?>{},
    this.stateDeltaEvidence = const <String, String>{},
    this.timeLabel = '',
  });

  final String raw;
  final List<PlayerSegment> segments;
  final List<PlayerUnresolved> unresolved;
  final List<String> warnings;

  /// 玩家行动的状态变化提案，形状与 CH_ACT 的 state_delta 相同。
  /// 这里不是世界结果；TurnLoop / SYS_RECORD 仍会校验并决定是否落账。
  final Map<String, Object?> stateDelta;

  /// state_delta 每一项对应的原文依据，key 是 move.<角色> / items.<序号> 等。
  final Map<String, String> stateDeltaEvidence;

  /// 这一步发生的时间标记：文本，不是时间戳。GM_PARSE_INPUT 写，缺失为空。
  final String timeLabel;

  /// 还有 audience 没定：UI 必须问玩家，不能默认。
  bool get needsConfirmation =>
      unresolved.any((PlayerUnresolved u) => u.isAudience) ||
      segments.any((PlayerSegment s) => s.delivery.audience == Audience.unknown);

  List<PlayerUnresolved> get audienceQuestions {
    final List<PlayerUnresolved> list =
        unresolved.where((PlayerUnresolved u) => u.isAudience).toList();
    if (list.isNotEmpty) return list;
    final List<String> ids = <String>[
      for (final PlayerSegment s in segments)
        if (s.delivery.audience == Audience.unknown) s.id,
    ];
    if (ids.isEmpty) return const <PlayerUnresolved>[];
    return <PlayerUnresolved>[
      PlayerUnresolved(
        segmentIds: ids,
        field: 'delivery.audience',
        question: '这段话是只让某个人听见，还是附近/全场也能听见？',
        why: 'GM_PARSE_INPUT 没有确定 audience。',
        options: const <String>[
          'target（只给目标）',
          'nearby（附近可闻）',
          'scene（全场可闻）',
        ],
      ),
    ];
  }

  /// 把指定 segment 的 audience 定下来，并移除对应的未决。
  PlayerParseResult resolveAudience(
    Audience audience, {
    Set<String>? segmentIds,
  }) {
    final Set<String>? ids = segmentIds;
    final List<PlayerSegment> updated = <PlayerSegment>[
      for (final PlayerSegment s in segments)
        if (ids == null || ids.contains(s.id))
          s.copyWith(
            delivery: Delivery(
              channel: s.delivery.channel,
              form: s.delivery.form,
              audience: audience,
            ),
          )
        else
          s,
    ];
    final List<PlayerUnresolved> remaining = <PlayerUnresolved>[
      for (final PlayerUnresolved u in unresolved)
        if (!(u.isAudience &&
            (ids == null || u.segmentIds.any(ids.contains))))
          u,
    ];
    return PlayerParseResult(
      raw: raw,
      segments: updated,
      unresolved: remaining,
      warnings: warnings,
      stateDelta: stateDelta,
      stateDeltaEvidence: stateDeltaEvidence,
      timeLabel: timeLabel,
    );
  }

  /// 变成事件。inner 不进事件（只给玩家自己 + 上帝）。
  List<WorldEvent> toEvents({
    required String playerName,
    required int startSeq,
    required NarrativeScene scene,
  }) {
    final List<WorldEvent> out = <WorldEvent>[];
    int n = startSeq;
    for (final PlayerSegment s in segments) {
      if (s.kind == PlayerSegmentKind.inner) continue;
      if (s.delivery.audience == Audience.unknown) {
        throw StateError('玩家输入还有未确认的 audience：${s.id}');
      }
      final String target = _targetName(s.target, playerName, scene);
      final WorldEventKind kind;
      final String content;
      if (s.kind == PlayerSegmentKind.speech) {
        kind = WorldEventKind.speech;
        content = s.text;
      } else {
        kind = WorldEventKind.action;
        final String action =
            s.text.startsWith('我') ? s.text.substring(1) : s.text;
        content = canonicalize(action, scene, speakerId: 'char:$playerName');
      }
      out.add(WorldEvent(
        id: 'E${n++}',
        kind: kind,
        content: content,
        actor: 'char:$playerName',
        target: target.isEmpty ? null : 'char:$target',
        delivery: s.delivery,
        linkMembers: _linkMembers(
          delivery: s.delivery,
          actor: 'char:$playerName',
          target: target.isEmpty ? null : 'char:$target',
        ),
        deliveryNote: s.deliveryNote ?? '',
        distanceNote: s.distanceNote ?? '',
        manner: s.mannerNote ?? s.manner ?? '',
        segments: <EventSegment>[
          EventSegment(
            kind: kind,
            text: content,
            target: target.isEmpty ? null : 'char:$target',
            delivery: s.delivery,
          ),
        ],
        source: 'player',
        placeId: scene.place,
        timeLabel: timeLabel,
      ));
    }
    return out;
  }

  /// 玩家输入转成 CH_ACT 行动记录。
  ///
  /// 人控角色的 CH_ACT 由玩家自己写意图和段落；这里只把 GM_PARSE_INPUT 已经确认过的
  /// segments 转成和 NPC 相同的 CH_ACT 契约，后面的 SYS_RECORD / GM_RESOLVE_ACTION 不再区分是谁行动。
  Map<String, Object?> toActionRecord({
    required String actorName,
    required NarrativeScene scene,
  }) {
    final List<Map<String, Object?>> actionSegments = <Map<String, Object?>>[];
    for (final PlayerSegment s in segments) {
      if (s.kind == PlayerSegmentKind.inner) continue;
      if (s.delivery.audience == Audience.unknown) {
        throw StateError('玩家输入还有未确认的 audience：${s.id}');
      }
      final String target = _targetName(s.target, actorName, scene);
      final List<String> perceivableBy = switch (s.delivery.audience) {
        Audience.target => target.isEmpty ? const <String>[] : <String>[target],
        Audience.scene ||
        Audience.nearby =>
          <String>[for (final CharacterSnapshot c in scene.cast) c.name],
        _ => const <String>[],
      };
      actionSegments.add(<String, Object?>{
        'kind': s.kind == PlayerSegmentKind.speech ? 'speech' : 'action',
        'text': s.text,
        'target': target.isEmpty ? null : target,
        'delivery': <String, Object?>{
          'channel': s.delivery.channel.name,
          'form': s.delivery.form,
          'audience': s.delivery.audience.name,
        },
        'action_kind': s.actionKind,
        'delivery_note': s.deliveryNote,
        'distance_note': s.distanceNote,
        'manner': s.mannerNote ?? s.manner,
        'requires': s.requires.isNotEmpty
            ? s.requires
            : (s.kind == PlayerSegmentKind.speech &&
                    s.delivery.channel == DeliveryChannel.voice
                ? <String>['speak']
                : const <String>[]),
        'perceivable_by': perceivableBy,
      });
    }
    return <String, Object?>{
      'intent': raw,
      'segments': actionSegments,
      'state_delta': stateDelta,
      'time_label': timeLabel,
    };
  }

  /// 内心段只进 inner 表，不进事件。
  List<InnerEntry> innerEntries(String playerName) {
    return <InnerEntry>[
      for (final PlayerSegment s in segments)
        if (s.kind == PlayerSegmentKind.inner)
          InnerEntry(
            id: 'inner:${s.id}',
            characterId: 'char:$playerName',
            text: s.text,
            sourceEvent: '',
          ),
    ];
  }

  List<String> _linkMembers({
    required Delivery delivery,
    required String actor,
    required String? target,
  }) {
    if (delivery.channel != DeliveryChannel.mental &&
        delivery.channel != DeliveryChannel.digital &&
        delivery.audience != Audience.link) {
      return const <String>[];
    }
    final Set<String> members = <String>{actor};
    if (target != null) members.add(target);
    return members.toList();
  }

  String _targetName(String? raw, String playerName, NarrativeScene scene) {
    final String t = (raw ?? '').trim();
    if (t.isEmpty) return '';
    if (scene.names.containsValue(t)) return t;
    final CharacterSnapshot? c = scene.byId('char:$playerName');
    if (c != null) {
      for (final MapEntry<String, String> e in c.aliases.entries) {
        if (e.value == t) return e.key.replaceFirst('char:', '');
      }
    }
    return t;
  }
}
