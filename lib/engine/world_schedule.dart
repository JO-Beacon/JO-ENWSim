import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../model/demo.dart';
import 'engine_state.dart';
import 'perception.dart';
import 'world_adapter.dart';

class WorldWorkQueue {
  WorldWorkQueue([Map<String, Object?> data = const <String, Object?>{}])
    : _checked = Map<String, Object?>.of(data);

  final Map<String, Object?> _checked;

  Map<String, Object?> toJson() => Map<String, Object?>.of(_checked);

  bool assessedInput(String id, String input) {
    final Object? entry = _checked[id];
    return (entry is Map ? entry['input'] : entry) == input;
  }

  bool isChecked(String id, String input, TurnState state, Set<String> future) {
    final Object? entry = _checked[id];
    if (entry is! Map) return entry == input;
    if (entry['boundary'] case final String boundary) return future.contains(boundary);
    if (entry['fact'] case final String id) {
      return state.facts.any((FactRecord fact) => fact.id == id &&
          fact.untilEvent.isEmpty && fact.object == entry['value']);
    }
    return entry['input'] == input;
  }

  void checked(String id, String input, TurnState state, {Object? wait}) {
    _checked[id] = input;
    if (wait is! Map) return;
    final Object? ref = wait['id'];
    final FactRecord? fact = state.facts.where(
      (FactRecord fact) => fact.id == ref && fact.untilEvent.isEmpty,
    ).firstOrNull;
    if (fact == null) return;
    if (wait['kind'] == 'fact_change') {
      _checked[id] = <String, Object?>{'input': input, 'fact': fact.id, 'value': fact.object};
    } else if (wait['kind'] == 'time_boundary' && fact.predicate == 'time_boundary') {
      _checked[id] = <String, Object?>{'input': input, 'boundary': fact.id};
    }
  }

  bool actorWaiting(String actor, String input, TurnState state, Set<String> future) =>
      isChecked('actor:$actor', input, state, future);

  void actorWaits(String actor, String input, TurnState state, Object? wait) =>
      checked('actor:$actor', input, state, wait: wait);

  List<String> actorsDue(String placeId, List<String> eligible) {
    final Object? stored = _checked['served:$placeId'];
    if (stored is! List) return eligible;
    final List<String> due = eligible.where((String actor) => !stored.contains(actor)).toList();
    return due.isEmpty ? eligible : due;
  }

  void actorsServed(String placeId, List<String> eligible, Set<String> actors) {
    final String key = 'served:$placeId';
    final Object? stored = _checked[key];
    final Set<String> served = <String>{
      if (stored is List) ...stored.whereType<String>(),
      ...actors,
    };
    if (served.containsAll(eligible)) {
      _checked.remove(key);
    } else {
      _checked[key] = served.where(eligible.contains).toList();
    }
  }
}

/// 从同一条时间线的已保存状态选地点，与画布焦点无关。
class WorldSchedule {
  const WorldSchedule();

  static const String timeWork = 'SYS_TIME_SCAN';

  String timeInput(TurnState state) => sha256.convert(utf8.encode(jsonEncode(<Object?>[
    for (final FactRecord fact in state.facts) fact.toJson(),
    for (final EntityRecord process in state.ongoingProcesses) process.toJson(),
    for (final WorldEvent event in state.events) <Object?>[event.id, event.uid, event.source, event.target],
    for (final WorldEvent event in state.pendingEvents) <Object?>[event.id, event.receivedBy],
  ]))).toString();

  /// 无变化的评估只在相关地点、对象、见闻或时间改变后恢复就绪。
  String placeInput(World world, TurnState state, ParallelPlace place) {
    final WorldAdapter adapter = WorldAdapter(
      world: world, parallelPlaceId: place.id, priorLocations: state.locations,
    );
    final Set<String> keys = <String>{
      place.id, place.place, 'place:${place.place}',
      for (final String name in adapter.presentNames) ...<String>[name, 'char:$name'],
    };
    bool grew;
    do {
      grew = false;
      for (final EntityRecord entity in state.entities.values) {
        if (keys.contains(entity.location) && keys.add(entity.id)) grew = true;
      }
    } while (grew);
    bool here(WorldEvent event) => keys.contains(event.placeId) ||
        event.witnesses.any((Witness witness) => keys.contains(witness.characterId));
    final Object input = <Object?>[
      world.setting, world.controlledCharacterName, place.place,
      for (final CharCard character in world.characters)
        if (keys.contains(character.name)) <Object?>[
          character.name, character.persona, character.location, character.state, character.aliases,
        ],
      for (final entry in state.states.entries)
        if (keys.contains(entry.key)) <Object?>[entry.key, entry.value],
      for (final constraint in state.constraints)
        if (keys.contains(constraint.who)) constraint.toJson(),
      for (final EntityRecord entity in state.entities.values)
        if (keys.contains(entity.id)) entity.toJson(),
      for (final FactRecord fact in state.facts)
        if (keys.contains(fact.subject) || keys.contains(fact.object) ||
            fact.predicate == 'time_boundary' || fact.predicate == 'time_before') fact.toJson(),
      for (final event in state.events)
        if (here(event) || event.source == 'world_time') <Object?>[event.uid, event.id, event.receivedBy],
      for (final event in state.pendingEvents)
        if (here(event)) <Object?>[event.uid, event.id, event.receivedBy],
    ];
    return sha256.convert(utf8.encode(jsonEncode(input))).toString();
  }

  List<ParallelPlace> readyPlaces(
    World world,
    TurnState state, {
    String? afterPlaceId,
    bool hasPlayerInput = false,
    Set<String> alreadyChecked = const <String>{},
    WorldWorkQueue? queue,
  }) {
    final List<ParallelPlace> places = world.parallelPlaces
        .where((ParallelPlace place) => place.isActive)
        .toList()..sort((ParallelPlace a, ParallelPlace b) => a.id.compareTo(b.id));
    if (places.isEmpty) return places;

    final int previous = places.indexWhere((ParallelPlace place) => place.id == afterPlaceId);
    final List<ParallelPlace> ordered = <ParallelPlace>[
      ...places.skip(previous + 1),
      ...places.take(previous + 1),
    ];
    final List<ParallelPlace> ready = <ParallelPlace>[];
    final List<ParallelPlace> deliveries = <ParallelPlace>[];
    final Set<String> future = futureBoundaries(state).map((FactRecord fact) => fact.id).toSet();
    final Map<String, String> currentFacts = <String, String>{
      for (final FactRecord fact in state.facts)
        if (fact.untilEvent.isEmpty) fact.id: fact.object,
    };
    bool isWaiting(EntityRecord process) {
      if (future.contains(process.state['next_check_boundary'])) return true;
      final Object? fact = process.state['next_check_fact'];
      return currentFacts.containsKey(fact) && currentFacts[fact] == process.state['next_check_fact_value'];
    }
    ParallelPlace? playerPlace;
    for (final ParallelPlace place in ordered) {
      if (alreadyChecked.contains(place.id)) continue;
      final WorldAdapter adapter = WorldAdapter(
        world: world,
        parallelPlaceId: place.id,
        priorLocations: state.locations,
      );
      final String name = place.place.trim();
      bool atPlace(String value) => value == name || value == place.id || value == 'place:$name';
      final Set<String> occupants = adapter.presentNames.map((String name) => 'char:$name').toSet();
      final bool readyDelivery = state.pendingEvents.any((WorldEvent event) =>
          event.witnesses.any((Witness witness) =>
              occupants.contains(witness.characterId) && !event.receivedBy.contains(witness.characterId)) ||
          (!event.witnessesResolved && atPlace(event.placeId) && occupants.isNotEmpty));
      final Iterable<EntityRecord> processes = state.ongoingProcesses.where(
        (EntityRecord process) => atPlace(process.location),
      );
      final String input = queue == null ? '' : placeInput(world, state, place);
      final bool waiting = queue?.isChecked(place.id, input, state, future) ?? false;
      if (readyDelivery && (!waiting || !queue!.assessedInput(place.id, input))) {
        deliveries.add(place);
      } else if (hasPlayerInput && adapter.presentNames.contains(adapter.controlledCharacterName)) {
        playerPlace = place;
      } else if (!waiting &&
          (adapter.presentNames.isNotEmpty ||
          processes.any((EntityRecord process) => !isWaiting(process)) ||
          (places.length == 1 && processes.isEmpty))) {
        ready.add(place);
      }
    }
    return <ParallelPlace>[...deliveries, ?playerPlace, ...ready];
  }

  List<FactRecord> futureBoundaries(TurnState state) {
    final Set<String?> reached = <String?>{
      for (final WorldEvent event in state.events)
        if (event.status == WorldEventStatus.accepted && event.source == 'world_time')
          event.target,
    };
    return state.facts.where((FactRecord fact) =>
        fact.untilEvent.isEmpty && fact.predicate == 'time_boundary' &&
        fact.evidence.trim().isNotEmpty && fact.object.trim().isNotEmpty &&
        !reached.contains(fact.id)).toList();
  }

  List<String> timeAdvanceErrors(TurnState state, Map<String, Object?> proposal) {
    final String mode = '${proposal['decision'] ?? ''}';
    if (mode == 'wait' || mode == 'ambiguous') {
      return '${proposal['reason'] ?? ''}'.trim().isEmpty ? <String>['缺少等待或冲突原因。'] : <String>[];
    }
    final List<String> errors = <String>[];
    if (mode != 'advance') errors.add('decision 必须是 advance、wait 或 ambiguous。');
    final List<FactRecord> future = futureBoundaries(state);
    final Set<String> futureIds = future.map((FactRecord fact) => fact.id).toSet();
    if (!futureIds.contains(proposal['boundary_id'])) {
      errors.add('推进必须引用尚未到达的已知时间边界。');
    }
    final Set<Object?> previous = <Object?>{proposal['boundary_id']};
    bool changed = true;
    while (changed) {
      changed = false;
      for (final FactRecord relation in state.facts) {
        if (relation.untilEvent.isEmpty && relation.predicate == 'time_before' &&
            previous.contains(relation.object)) {
          if (previous.add(relation.subject)) changed = true;
        }
      }
    }
    previous.remove(proposal['boundary_id']);
    if (previous.any(futureIds.contains)) {
      errors.add('还有已知的较早边界，不能越过。');
    }
    final Object? raw = proposal['process_order'];
    final Set<String> processIds = state.ongoingProcesses.map((EntityRecord process) => process.id).toSet();
    if (raw is! Map || !processIds.containsAll(raw.keys) || !raw.keys.toSet().containsAll(processIds)) {
      errors.add('必须逐一说明所有进行中过程相对边界的先后。');
    } else if (raw.values.any((Object? value) => value != 'after' && value != 'at')) {
      errors.add('存在更早或先后不明的过程时必须等待或交给玩家。');
    }
    if (state.ongoingProcesses.any((EntityRecord process) =>
        previous.contains(process.state['completion_boundary']))) {
      errors.add('有过程在更早的边界到期，必须先评估该过程。');
    }
    if ('${proposal['reason'] ?? ''}'.trim().isEmpty) errors.add('缺少推进的语义依据。');
    return errors;
  }
}
