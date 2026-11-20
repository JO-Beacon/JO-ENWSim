import 'perception.dart';

/// 正文、硬校验和语义复核共用的角色投影；不修改权威事件。
List<WorldEvent> renderView(List<WorldEvent> events, NarrativeScene scene, String observerId) {
  if (observerId.isEmpty) throw const FormatException('角色视角需要先选择操控角色');
  final List<WorldEvent> visible = <WorldEvent>[];
  for (final WorldEvent event in events) {
    if (event.status != WorldEventStatus.accepted) continue;
    final List<Witness> witnesses = event.witnessesResolved || event.witnesses.isNotEmpty
        ? event.witnesses : const PerceptionEngine().witnesses(event, scene);
    for (final Witness witness in witnesses) {
      if (witness.characterId != observerId || witness.content.trim().isEmpty) continue;
      visible.add(WorldEvent(
        id: event.id, kind: WorldEventKind.action, content: witness.content, actor: '',
        delivery: Delivery(channel: event.delivery.channel, form: 'observation', audience: Audience.hidden),
        source: 'observation', placeId: event.placeId, turnIndex: event.turnIndex,
        duration: event.duration, witnesses: <Witness>[witness], witnessesResolved: true,
        attachmentIds: witness.modality == 'sight' ? event.attachmentIds : const <String>[],
      ));
      break;
    }
  }
  return visible;
}

NarrativeScene renderScene(NarrativeScene scene, String observerId) => NarrativeScene(
  place: scene.place, names: scene.names,
  cast: <CharacterSnapshot>[for (final CharacterSnapshot c in scene.cast) if (c.id == observerId) c],
);
