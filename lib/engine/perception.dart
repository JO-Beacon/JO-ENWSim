// 认知账本 · 感知过滤
//
// 只做确定性的事：
//   - 按 place + audience + witnesses 过滤，谁能感知到哪个事件；
//   - 把过滤结果交给 CH_PERCEIVE；记忆由 engine 写，不在这里写。
//
// 不做语义判断；GM_PARSE_INPUT/CH_PERCEIVE 的判断由 AI 给，这里只做过滤、隔离、别名替换。
//
// 注意：audience 是“谁能感知”的功能约束，不是音量/距离的测量。
// 没有 loudness 这种绝对档位；“声音小了一些”是 delivery_note 里的事实。

enum DeliveryChannel { voice, visual, mental, digital, other }

/// 事件类型：计划里的“动作 / 台词”。
/// 事件内容不再和“谁对谁说”混在一个 summary 里。
enum WorldEventKind { action, speech }

enum WorldEventStatus { proposed, accepted, rejected }

/// 计划里的 `segments[]`：一段动作或台词。
class EventSegment {
  const EventSegment({
    required this.kind,
    required this.text,
    this.target,
    required this.delivery,
    this.perceivableBy = const <String>[],
  });

  final WorldEventKind kind;
  final String text;
  final String? target;
  final Delivery delivery;
  final List<String> perceivableBy;
}

/// 谁能在这一回合感知到。
/// 这是功能约束，不是“声音多大”的分数。
enum Audience { target, nearby, scene, link, hidden, unknown }

class Delivery {
  const Delivery({
    required this.channel,
    required this.form,
    required this.audience,
  });

  final DeliveryChannel channel;
  final String form;
  final Audience audience;
}

class WorldEvent {
  const WorldEvent({
    required this.id,
    this.uid = '',
    required this.kind,
    required this.content,
    required this.actor,
    this.target,
    required this.delivery,
    this.linkMembers = const <String>[],
    this.deliveryNote = '',
    this.distanceNote = '',
    this.manner = '',
    this.segments = const <EventSegment>[],
    this.effects = const <Map<String, Object?>>[],
    this.witnesses = const <Witness>[],
    this.publicText = '',
    this.godNote = '',
    this.attachmentIds = const <String>[],
    this.status = WorldEventStatus.accepted,
    this.source = 'unknown',
    this.placeId = '',
    this.timeLabel = '',
    this.branchId = 'main',
    this.outcome = '',
    this.result = '',
    this.observations = const <String, String>{},
    this.observationsResolved = false,
    this.witnessesResolved = false,
    this.receivedBy = const <String>[],
    this.turnIndex = 0,
    this.duration = 'brief',
    this.stateChanges = const <String, Object?>{},
  });

  final String id;

  /// 世界级持久事件 id；旧事件为空。
  final String uid;
  final WorldEventKind kind;

  /// 事件内容：动作是“做了什么”，台词是“说了什么”（引号由内容自己带）。
  final String content;
  final String actor;
  final String? target;
  final Delivery delivery;
  final List<String> linkMembers;

  /// 原文里的传达事实，例如“声音小了一些”。
  final String deliveryNote;

  /// 原文里的距离事实，例如“因为距离近”。
  final String distanceNote;

  /// 已确认的可观察语气或神态。
  final String manner;

  final List<EventSegment> segments;
  final List<Map<String, Object?>> effects;
  final List<Witness> witnesses;
  final String publicText;
  final String godNote;

  /// 这条事件带的附件（asset id）；玩家输入里的图片/文件挂在这里。
  final List<String> attachmentIds;

  final WorldEventStatus status;
  final String source;
  final String placeId;
  final String timeLabel;
  final String branchId;
  final String outcome;
  final String result;
  final Map<String, String> observations;
  final bool observationsResolved;
  final bool witnessesResolved;
  final List<String> receivedBy;
  final int turnIndex;
  final String duration;
  final Map<String, Object?> stateChanges;

  /// 给 CH_PERCEIVE / GM_NARRATE / 画布用的事件行。
  /// 这是从 kind + content + actor/target 生成的，不是另一个存储字段。
  String get summary {
    final String who = _plainName(actor);
    final String to = _plainName(target);
    if (kind == WorldEventKind.speech) {
      return to.isEmpty ? '$who说：$content' : '$who对$to说：$content';
    }
    return who.isEmpty ? content : '$who$content';
  }

  WorldEvent copyWith({
    List<EventSegment>? segments,
    List<Map<String, Object?>>? effects,
    List<Witness>? witnesses,
    String? publicText,
    String? godNote,
    List<String>? attachmentIds,
    WorldEventStatus? status,
    String? source,
    String? placeId,
    String? timeLabel,
    String? uid,
    String? outcome,
    String? result,
    Map<String, String>? observations,
    bool? observationsResolved,
    bool? witnessesResolved,
    List<String>? receivedBy,
    int? turnIndex,
    String? duration,
    Map<String, Object?>? stateChanges,
  }) {
    return WorldEvent(
      id: id,
      uid: uid ?? this.uid,
      kind: kind,
      content: content,
      actor: actor,
      target: target,
      delivery: delivery,
      linkMembers: linkMembers,
      deliveryNote: deliveryNote,
      distanceNote: distanceNote,
      manner: manner,
      segments: segments ?? this.segments,
      effects: effects ?? this.effects,
      witnesses: witnesses ?? this.witnesses,
      publicText: publicText ?? this.publicText,
      godNote: godNote ?? this.godNote,
      attachmentIds: attachmentIds ?? this.attachmentIds,
      status: status ?? this.status,
      source: source ?? this.source,
      placeId: placeId ?? this.placeId,
      timeLabel: timeLabel ?? this.timeLabel,
      branchId: branchId,
      outcome: outcome ?? this.outcome,
      result: result ?? this.result,
      observations: observations ?? this.observations,
      observationsResolved: observationsResolved ?? this.observationsResolved,
      witnessesResolved: witnessesResolved ?? this.witnessesResolved,
      receivedBy: receivedBy ?? this.receivedBy,
      turnIndex: turnIndex ?? this.turnIndex,
      duration: duration ?? this.duration,
      stateChanges: stateChanges ?? this.stateChanges,
    );
  }
}

String _plainName(String? raw) =>
    (raw ?? '').trim().replaceFirst('char:', '');

class CharacterSnapshot {
  CharacterSnapshot({
    required this.id,
    required this.name,
    required this.nearby,
    this.distanceNote = '',
    Map<String, String>? aliases,
  }) : aliases = aliases ?? <String, String>{};

  final String id;
  final String name;

  /// 功能约束：他是否近到能听见 nearby 的事件。
  /// 不是距离分数；具体距离写 distanceNote。
  final bool nearby;
  final String distanceNote;

  /// 这个角色对其他实体的称呼：实体 id -> 他嘴里的名字。
  /// 没列进来的，程序会替换成“某人”，不会把系统名字漏出去。
  final Map<String, String> aliases;
}

class NarrativeScene {
  NarrativeScene({
    required this.place,
    required this.cast,
    required this.names,
    this.playerNotes = '',
    this.characterNotes = const <String, String>{},
    this.observations = const <String, String>{},
  });

  final String place;
  final List<CharacterSnapshot> cast;

  /// 所有实体的规范名：id -> name。用于本地化替换。
  final Map<String, String> names;

  /// 作者给上帝层的补充，不能直接进入角色上下文。
  final String playerNotes;
  final Map<String, String> characterNotes;
  final Map<String, String> observations;

  CharacterSnapshot? byId(String id) {
    for (final CharacterSnapshot c in cast) {
      if (c.id == id) return c;
    }
    return null;
  }
}

class Witness {
  const Witness({
    required this.characterId,
    required this.modality,
    required this.content,
  });

  final String characterId;
  final String modality;
  final String content;
}

class PerceptionEngine {
  const PerceptionEngine();

  /// 这个事件会被谁感知到。返回的 content 已经按每个角色的 alias 本地化。
  List<Witness> witnesses(WorldEvent e, NarrativeScene s) {
    if (e.placeId.isNotEmpty && e.placeId != s.place) return <Witness>[];
    if (e.status == WorldEventStatus.rejected) return <Witness>[];
    final Set<String> candidates = <String>{};

    switch (e.delivery.audience) {
      case Audience.scene:
        for (final CharacterSnapshot c in s.cast) {
          candidates.add(c.id);
        }
      case Audience.nearby:
        for (final CharacterSnapshot c in s.cast) {
          if (c.nearby) candidates.add(c.id);
        }
      case Audience.target:
        final CharacterSnapshot? t =
            e.target == null ? null : s.byId(e.target!);
        if (t != null) candidates.add(t.id);
      case Audience.link:
        for (final String id in e.linkMembers) {
          final CharacterSnapshot? c = s.byId(id);
          if (c != null) candidates.add(id);
        }
      case Audience.hidden:
      case Audience.unknown:
        break;
    }

    if (e.delivery.channel == DeliveryChannel.mental ||
        e.delivery.channel == DeliveryChannel.digital) {
      candidates.retainWhere((String id) => e.linkMembers.contains(id));
    }

    final Set<String> explicit = <String>{
      for (final EventSegment segment in e.segments)
        for (final String id in segment.perceivableBy)
          id.trim().startsWith('char:') ? id.trim() : 'char:${id.trim()}',
    };
    if (explicit.isNotEmpty) {
      candidates.retainWhere(explicit.contains);
    }
    // 行动者知道自己的尝试；裁定观察者也可能只看到结果，没看见尝试。
    if (<String>{'npc', 'player'}.contains(e.source) && s.byId(e.actor) != null) {
      candidates.add(e.actor);
    }
    final Set<String> attemptWitnesses = <String>{...candidates};
    for (final MapEntry<String, String> observation in e.observations.entries) {
      final String id = observation.key.startsWith('char:') ? observation.key : 'char:${observation.key}';
      if (observation.value.trim().isNotEmpty && s.byId(id) != null) candidates.add(id);
    }

    final List<Witness> out = <Witness>[];
    for (final String id in candidates) {
      final CharacterSnapshot c = s.byId(id)!;
      final String modality = switch (e.delivery.channel) {
        DeliveryChannel.voice => 'hearing',
        DeliveryChannel.visual => 'sight',
        DeliveryChannel.mental => 'mental',
        DeliveryChannel.digital => 'digital',
        DeliveryChannel.other => 'other',
      };
      out.add(Witness(
        characterId: id,
        modality: modality,
        content: <String>[
          if (attemptWitnesses.contains(id))
            e.kind == WorldEventKind.speech
                ? '${localize(e.summary.substring(0, e.summary.length - e.content.length), c, s)}${e.content}'
                : localize(e.outcome.isNotEmpty ? '尝试：${e.summary}' : e.summary, c, s),
          if (e.observationsResolved || e.observations.isNotEmpty)
            localize(e.observations[id] ?? e.observations[_plainName(id)] ?? '', c, s)
          else if (attemptWitnesses.contains(id)) ...<String>[
            if (e.result.isNotEmpty) localize(e.result, c, s),
            for (final Map<String, Object?> effect in e.effects)
              if (_visibleEffect(effect, id)) localize(effectDescription(effect), c, s),
          ],
          if (attemptWitnesses.contains(id) && e.manner.isNotEmpty)
            localize(e.manner, c, s),
        ].where((String t) => t.isNotEmpty).join('；'),
      ));
    }
    return out;
  }

  bool _visibleEffect(Map<String, Object?> e, String observer) {
    final Object? raw = e['observers'];
    if (raw is List && raw.isNotEmpty) {
      return raw.any((Object? id) => _plainName('$id') == _plainName(observer));
    }
    final String visibility = '${e['visibility'] ?? 'public'}';
    if (visibility == 'hidden') return false;
    if (visibility == 'self') return _plainName('${e['who'] ?? ''}') == _plainName(observer);
    return visibility == 'public';
  }

  /// 把规范名换成这个角色自己的称呼；不知道的名字换成“某人”，不泄系统名。
  String localize(String text, CharacterSnapshot observer, NarrativeScene s) {
    String out = text;
    s.names.forEach((String id, String name) {
      if (id == observer.id) return;
      final String alias = observer.aliases[id] ?? '某人';
      out = out.replaceAll(name, alias);
    });
    return out;
  }
}

String effectDescription(Map<String, Object?> e) => switch ('${e['kind']}') {
  'move' => '${e['who'] ?? e['id'] ?? ''}移动到${e['to'] ?? ''}',
  'injure' => '${e['who'] ?? ''}的${e['part'] ?? ''}受伤'
      '（${e['injury_kind'] ?? ''}）${e['treatment'] ?? ''} ${e['note'] ?? ''}',
  'constraint' => '${e['who'] ?? ''}的${e['capability'] ?? ''}：${e['state'] ?? ''}',
  'take' || 'give' || 'steal' || 'drop' =>
      '${e['kind']} ${e['item_id']}（${e['from'] ?? e['by'] ?? ''} → ${e['to'] ?? e['place'] ?? ''}）',
  'fact' => '${e['op'] == 'remove' ? '不再成立：' : ''}${e['subject']}：${e['predicate']}=${e['object']}',
  'process' => '${e['description']}（${e['status']}）',
  _ => '',
};

/// 只还原说话者自己的称呼；旧调用没有提供说话者时，歧义必须拒绝。
String canonicalize(String text, NarrativeScene s, {String? speakerId}) {
  final List<MapEntry<String, String>> aliases = <MapEntry<String, String>>[];
  for (final CharacterSnapshot c in s.cast) {
    if (speakerId != null && c.id != speakerId) continue;
    for (final MapEntry<String, String> e in c.aliases.entries) {
      if (e.value.isEmpty) continue;
      aliases.add(MapEntry<String, String>(e.value, s.names[e.key] ?? e.key));
    }
  }
  aliases.sort((MapEntry<String, String> a, MapEntry<String, String> b) =>
      b.key.length.compareTo(a.key.length));
  final Map<String, Set<String>> targets = <String, Set<String>>{};
  for (final MapEntry<String, String> alias in aliases) {
    targets.putIfAbsent(alias.key, () => <String>{}).add(alias.value);
  }
  if (targets.isEmpty) return text;
  // 一次替换，避免替换结果又被较短的别名改写。
  final RegExp pattern = RegExp(targets.keys.map(RegExp.escape).join('|'));
  return text.replaceAllMapped(pattern, (Match match) {
    final Set<String> names = targets[match[0]]!;
    if (names.length != 1) throw FormatException('称呼存在歧义：${match[0]}');
    return names.single;
  });
}

DeliveryChannel deliveryChannelOf(String s) => switch (s) {
      'voice' => DeliveryChannel.voice,
      'visual' => DeliveryChannel.visual,
      'mental' => DeliveryChannel.mental,
      'digital' => DeliveryChannel.digital,
      'other' => DeliveryChannel.other,
      _ => DeliveryChannel.other,
    };

Audience audienceOf(String s) => switch (s) {
      'target' => Audience.target,
      'nearby' => Audience.nearby,
      'scene' => Audience.scene,
      'link' => Audience.link,
      'hidden' => Audience.hidden,
      _ => Audience.unknown,
    };


