import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../model/demo.dart';
import '../model/world_search.dart';
import 'engine_state.dart';
import 'perception.dart';
import 'state_delta.dart';
import 'turn_loop.dart';
import 'world_adapter.dart';

/// 首版只并发明确隔离的地点。全局时间、移动和共享资源走原有串行路径。
class LocalTurnScope {
  LocalTurnScope._(this.world, this.state, this.place, this.actors);

  final World world;
  final TurnState state;
  final ParallelPlace place;
  final Set<String> actors;

  bool ownsActor(String name) => actors.contains(name.replaceFirst('char:', ''));

  bool ownsPlace(String id) => id == place.id || id == place.place ||
      id == 'place:${place.place}';

  static bool _remoteDelivery(Delivery delivery) =>
      delivery.audience == Audience.link || delivery.channel == DeliveryChannel.digital;

  String get fingerprint => sha256.convert(utf8.encode(jsonEncode(<Object?>[
    'local-turn-v1', world.setting, world.opening, world.playerName,
    place.id, place.place,
    for (final CharCard card in world.characters)
      <Object?>[card.name, card.persona, card.location, card.state, card.aliases],
    state.toJson(),
  ]))).toString();

  static LocalTurnScope? capture(World world, TurnState state, String placeId) {
    if (world.searchSource != WorldSearchSource.off || state.ongoingProcesses.isNotEmpty ||
        state.facts.any((f) => f.untilEvent.isEmpty &&
            (f.predicate == 'time_boundary' || f.predicate == 'time_before' ||
             f.predicate == 'shared_access' || f.predicate == 'connected_to'))) {
      return null;
    }
    final List<ParallelPlace> places = world.parallelPlaces.where((p) => p.isActive).toList();
    final Set<String> placeNames = places.map((p) => p.place).toSet();
    final ParallelPlace? place = places.where((p) => p.id == placeId).firstOrNull;
    if (place == null || placeNames.length != places.length || place.place.trim().isEmpty) return null;
    final Map<String, String> locations = <String, String>{};
    for (final CharCard card in world.characters) {
      final String name = card.name.trim();
      final String location = (state.locations[name] ?? card.location).trim();
      if (name.isEmpty || !placeNames.contains(location) || locations.containsKey(name)) return null;
      final String? entityLocation = state.entities['char:$name']?.location;
      if (entityLocation != null && entityLocation != location && entityLocation != 'place:$location') {
        return null;
      }
      locations[name] = location;
    }
    final Set<String> actors = <String>{
      for (final entry in locations.entries) if (entry.value == place.place) entry.key,
    };
    if (actors.isEmpty) return null;
    bool actor(String name) => actors.contains(name.replaceFirst('char:', ''));
    bool here(String id) => id == place.id || id == place.place || id == 'place:${place.place}';
    bool otherActor(String id) => locations.containsKey(id.replaceFirst('char:', '')) && !actor(id);
    bool relevant(WorldEvent e) => here(e.placeId) || actor(e.actor) ||
        actor(e.target ?? '') || e.linkMembers.any(actor) || e.observations.keys.any(actor) ||
        e.witnesses.any((w) => actor(w.characterId)) ||
        e.segments.any((s) => actor(s.target ?? '') || s.perceivableBy.any(actor));
    if (state.pendingEvents.any((e) => e.placeId.isEmpty ||
        (relevant(e) && (!here(e.placeId) ||
            _remoteDelivery(e.delivery) || otherActor(e.target ?? '') ||
            e.linkMembers.any(otherActor) || e.observations.keys.any(otherActor) ||
            e.segments.any((s) => _remoteDelivery(s.delivery) || otherActor(s.target ?? '') ||
                s.perceivableBy.any(otherActor)) ||
            e.witnesses.any((w) => !actor(w.characterId)))))) {
      return null;
    }

    final World localWorld = world.copyWith(
      characters: world.characters.where((c) => actors.contains(c.name.trim())).toList(),
      parallelPlaces: <ParallelPlace>[place],
      moves: const <MoveLink>[],
      playerName: actor(world.playerName) ? world.playerName : '',
    );
    final Map<String, String> localLocations = <String, String>{for (final name in actors) name: place.place};
    final Map<String, EntityRecord> known = <String, EntityRecord>{
      ...WorldAdapter(world: localWorld, parallelPlaceId: place.id, priorLocations: localLocations).seedEntities(),
      ...state.entities,
    };
    final Set<String> ids = <String>{'place:${place.place}', for (final name in actors) 'char:$name'};
    bool grew;
    do {
      final int before = ids.length;
      for (final EntityRecord entity in known.values) {
        if (here(entity.location) || ids.contains(entity.location) || actor(entity.location)) {
          ids.add(entity.id);
        }
      }
      grew = ids.length != before;
    } while (grew);
    if (ids.any((id) => known[id]?.contains.any((child) => !ids.contains(child)) ?? false) ||
        actors.any((name) => (state.inventories[name] ?? const <String>[]).any((id) => !ids.contains(id)))) {
      return null;
    }
    bool localSubject(String subject) => ids.contains(subject) || here(subject) || actor(subject);
    bool foreignRef(String value) => otherActor(value) ||
        ((known.containsKey(value) || places.any((p) => value == p.id ||
            value == p.place || value == 'place:${p.place}')) && !localSubject(value));
    if (state.facts.any((f) => f.untilEvent.isEmpty && f.subject != 'player' &&
        ((localSubject(f.subject) && (foreignRef(f.object) || f.observers.any((id) => !actor(id)))) ||
         (!localSubject(f.subject) && (localSubject(f.object) || f.observers.any(actor)))))) {
      return null;
    }

    return LocalTurnScope._(localWorld, TurnState(
      events: state.events.where(relevant).toList(),
      pendingEvents: state.pendingEvents.where(relevant).toList(),
      memory: state.memory.where((m) => actor(m.characterId)).toList(),
      locations: localLocations,
      states: <String, String>{for (final card in localWorld.characters)
        card.name.trim(): state.states[card.name.trim()] ?? card.state},
      inventories: <String, List<String>>{for (final entry in state.inventories.entries)
        if (actor(entry.key)) entry.key: entry.value},
      injuries: state.injuries.where((i) => actor(i.who)).toList(),
      constraints: state.constraints.where((c) => actor(c.who)).toList(),
      entities: <String, EntityRecord>{for (final entry in known.entries)
        if (ids.contains(entry.key)) entry.key: entry.value},
      facts: state.facts.where((f) => localSubject(f.subject) || f.subject == 'player').toList(),
      inner: state.inner.where((i) => actor(i.characterId)).toList(),
      playerAnswers: state.playerAnswers,
      worldWork: <String, Object?>{for (final entry in state.worldWork.entries)
        if (entry.key == place.id || entry.key == 'served:${place.id}' ||
            (entry.key.startsWith('actor:') && actor(entry.key.substring(6)))) entry.key: entry.value},
    ), place, actors);
  }

  /// 这条路径只落独立的本地事件、记忆和回执；结构变化需要串行结算。
  bool accepts(TurnTrace trace) {
    final Object? search = trace.action?['search'];
    if (trace.openPlace.allOpenings.isNotEmpty || trace.mergePlace.merge ||
        trace.orderedDeltas.isNotEmpty || trace.stateDelta?.isEmpty == false ||
        (search is String && search.trim().isNotEmpty)) {
      return false;
    }
    bool acceptsTarget(String? target) => target == null || target.isEmpty ||
        ownsActor(target) || ownsPlace(target) || state.entities.containsKey(target);
    for (final WorldEvent event in <WorldEvent>[
      ...trace.events, ...trace.environmentEvents, ...trace.rejectedEvents,
    ]) {
      if (!ownsPlace(event.placeId) || event.source == 'world_time' ||
          _remoteDelivery(event.delivery) || !acceptsTarget(event.target) ||
          event.linkMembers.any((id) => !ownsActor(id)) ||
          event.segments.any((s) => _remoteDelivery(s.delivery) || !acceptsTarget(s.target) ||
              s.perceivableBy.any((id) => !ownsActor(id))) ||
          event.witnesses.any((w) => !ownsActor(w.characterId)) ||
          event.observations.keys.any((id) => !ownsActor(id)) ||
          !StateDelta.fromAction(event.stateChanges).isEmpty) {
        return false;
      }
    }
    return true;
  }
}
