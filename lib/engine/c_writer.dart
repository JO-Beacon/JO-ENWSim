import 'perception.dart';
import 'state_delta.dart';

class CExtracted {
  const CExtracted({required this.segments, required this.delta});

  final List<Map<String, Object?>> segments;
  final StateDelta delta;
}

/// SYS_RECORD 的校验结果。SYS_RECORD 只做确定性检查，不改语义。
class CValidationError {
  const CValidationError({required this.code, required this.message});

  final String code;
  final String message;

  Map<String, Object?> toJson() => <String, Object?>{
        'code': code,
        'message': message,
      };
}

/// SYS_RECORD 的写入阶段：把 proposed event 变成 accepted event，并写 witnesses。
/// 抽取阶段由 CH_ACT 行动记录提供；这里不再让 AI 改事件内容。
class CWriter {
  const CWriter();

  /// SYS_RECORD-抽取：从行动记录里取 segments 和 state_delta。
  /// 语义抽取由 CH_ACT 完成；这里只做结构提取，避免再让程序猜语义。
  CExtracted extract(Map<String, Object?> action) {
    final List<Map<String, Object?>> segments = <Map<String, Object?>>[];
    final Object? raw = action['segments'];
    if (raw is List) {
      for (final Object? item in raw) {
        if (item is Map) segments.add(item.cast<String, Object?>());
      }
    }
    return CExtracted(
      segments: segments,
      delta: StateDelta.fromAction(action['state_delta']),
    );
  }

  List<CValidationError> validate(
    WorldEvent event,
    NarrativeScene scene,
  ) {
    final List<CValidationError> errors = <CValidationError>[];
    if (event.content.trim().isEmpty) {
      errors.add(const CValidationError(
        code: 'empty_content',
        message: '事件内容不能为空',
      ));
    }
    final bool timeBoundary = event.source == 'world_time' &&
        event.kind == WorldEventKind.action &&
        event.delivery.audience == Audience.hidden &&
        (event.target?.trim().isNotEmpty ?? false) &&
        event.stateChanges.isEmpty &&
        event.effects.isEmpty &&
        event.segments.isEmpty;
    if (event.source == 'world_time' && !timeBoundary) {
      errors.add(const CValidationError(
        code: 'invalid_time_boundary',
        message: '世界时间记录只能标记边界，不能附带行动或状态变化。',
      ));
    }
    if (event.actor.trim().isEmpty &&
        event.source != 'environment' &&
        event.source != 'narration' &&
        !timeBoundary) {
      errors.add(const CValidationError(
        code: 'empty_actor',
        message: '事件 actor 不能为空',
      ));
    }
    final String? target = event.target;
    if (target != null &&
        target.trim().isNotEmpty &&
        target.startsWith('char:') &&
        scene.byId(target) == null) {
      errors.add(CValidationError(
        code: 'unknown_target',
        message: 'target 不在当前 cast：$target',
      ));
    }
    if (event.delivery.audience == Audience.unknown) {
      errors.add(const CValidationError(
        code: 'unknown_audience',
        message: '事件 audience 还是 unknown，不能落账',
      ));
    }
    if (event.effects.isNotEmpty &&
        !(event.source == 'environment' && event.kind == WorldEventKind.action) &&
        !event.segments.any(
          (EventSegment s) => s.kind == WorldEventKind.action,
        )) {
      errors.add(const CValidationError(
        code: 'effects_without_action',
        message: '事件有 effects，但没有 action segment；不能只有台词却改状态',
      ));
    }
    return errors;
  }

  WorldEvent commit({
    required WorldEvent event,
    required NarrativeScene scene,
    required PerceptionEngine engine,
  }) {
    final List<Witness> witnesses = engine.witnesses(event, scene);
    return event.copyWith(
      witnesses: witnesses,
      witnessesResolved: true,
      status: WorldEventStatus.accepted,
    );
  }

  /// 先跑 SYS_RECORD 校验，再 commit；校验失败抛 FormatException，交给 UI 捕获。
  WorldEvent commitValidated({
    required WorldEvent event,
    required NarrativeScene scene,
    required PerceptionEngine engine,
  }) {
    final List<CValidationError> errors = validate(event, scene);
    if (errors.isNotEmpty) {
      throw FormatException(
        'SYS_RECORD 校验失败：${errors.map((e) => '${e.code}：${e.message}').join('；')}',
      );
    }
    return commit(event: event, scene: scene, engine: engine);
  }
}
