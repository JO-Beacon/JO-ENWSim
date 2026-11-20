// 认知账本 · 确定性账本
//
// 只做一件事：知道“物品在谁手里 / 哪个容器里”，并把 take / give / drop / consume 落账。
// 不做语义判断；语义映射由 AI 先把名字变成 id。
//
// 三态：contains == null 表示“不知道里面有什么”；[] 表示“已知为空”；
// [id...] 表示“已知有这些”。不知道 ≠ 没有。

enum EntityKind { character, item, container, place }

class LedgerEntity {
  LedgerEntity({
    required this.id,
    required this.kind,
    required this.name,
    this.location,
    Map<String, Object?>? state,
    this.contains,
    List<String>? inventory,
  })  : state = state ?? <String, Object?>{},
        inventory = inventory ?? <String>[];

  final String id;
  final EntityKind kind;
  final String name;

  /// 物品在谁身上 / 哪个容器 / 哪个地点；null = 不在任何地方。
  String? location;

  /// 物品数量、弹药、封印状态等。
  final Map<String, Object?> state;

  /// 容器内容。null = 未知；[] = 已知为空；[id...] = 已知有这些。
  List<String>? contains;

  /// 角色背包。
  final List<String> inventory;
}

enum LedgerStatus { ok, rejected, unknown }

class LedgerResult {
  const LedgerResult(this.status, this.message);

  final LedgerStatus status;
  final String message;

  bool get ok => status == LedgerStatus.ok;
}

class Ledger {
  final Map<String, LedgerEntity> _entities = <String, LedgerEntity>{};

  void add(LedgerEntity e) => _entities[e.id] = e;

  LedgerEntity? byId(String id) => _entities[id];

  /// 移动实体到某个地点/容器/角色。只改 location，不改背包。
  bool moveEntity(String id, String to) {
    final LedgerEntity? e = byId(id);
    if (e == null) return false;
    e.location = to;
    return true;
  }

  LedgerResult take({
    required String actorId,
    required String itemId,
    required String containerId,
  }) {
    final LedgerEntity? actor = byId(actorId);
    if (actor == null || actor.kind != EntityKind.character) {
      return const LedgerResult(LedgerStatus.rejected, '拿取者不存在，或不是角色');
    }
    final LedgerEntity? item = byId(itemId);
    if (item == null || item.kind != EntityKind.item) {
      return const LedgerResult(LedgerStatus.rejected, '物品不存在');
    }
    final LedgerEntity? container = byId(containerId);
    if (container == null || container.kind != EntityKind.container) {
      return const LedgerResult(LedgerStatus.rejected, '容器不存在');
    }
    if (item.location != container.id) {
      return LedgerResult(
        LedgerStatus.rejected,
        '${item.name} 不在 ${container.name} 里（当前位置：${item.location ?? '无'}）',
      );
    }
    if (container.contains == null) {
      return LedgerResult(
        LedgerStatus.unknown,
        '${container.name} 里有什么还不知道；先声明内容，不能猜有，也不能猜没有',
      );
    }
    if (!container.contains!.contains(item.id)) {
      return LedgerResult(
        LedgerStatus.rejected,
        '${container.name} 里没有 ${item.name}；现有：${container.contains!.isEmpty ? '（空）' : container.contains!.join('、')}',
      );
    }
    if (actor.location != container.location) {
      return LedgerResult(
        LedgerStatus.rejected,
        '${actor.name} 不在 ${container.name} 所在的地点（人在 ${actor.location ?? '无'}，容器在 ${container.location ?? '无'}）',
      );
    }

    container.contains!.remove(item.id);
    actor.inventory.add(item.id);
    item.location = actor.id;
    return LedgerResult(
      LedgerStatus.ok,
      '${actor.name} 从 ${container.name} 拿到了 ${item.name}',
    );
  }

  LedgerResult give({
    required String fromId,
    required String toId,
    required String itemId,
  }) {
    final LedgerEntity? from = byId(fromId);
    final LedgerEntity? to = byId(toId);
    final LedgerEntity? item = byId(itemId);
    if (from == null || from.kind != EntityKind.character) {
      return const LedgerResult(LedgerStatus.rejected, '给予者不存在');
    }
    if (to == null || to.kind != EntityKind.character) {
      return const LedgerResult(LedgerStatus.rejected, '接收者不存在');
    }
    if (item == null || item.kind != EntityKind.item) {
      return const LedgerResult(LedgerStatus.rejected, '物品不存在');
    }
    if (!from.inventory.contains(item.id)) {
      return LedgerResult(LedgerStatus.rejected, '${from.name} 身上没有 ${item.name}');
    }
    if (from.location != to.location) {
      return const LedgerResult(LedgerStatus.rejected, '两个人不在同一地点');
    }

    from.inventory.remove(item.id);
    to.inventory.add(item.id);
    item.location = to.id;
    return LedgerResult(
      LedgerStatus.ok,
      '${from.name} 把 ${item.name} 给了 ${to.name}',
    );
  }

  LedgerResult drop({
    required String actorId,
    required String itemId,
    required String placeId,
  }) {
    final LedgerEntity? actor = byId(actorId);
    final LedgerEntity? item = byId(itemId);
    final LedgerEntity? place = byId(placeId);
    if (actor == null || actor.kind != EntityKind.character) {
      return const LedgerResult(LedgerStatus.rejected, '角色不存在');
    }
    if (item == null || item.kind != EntityKind.item) {
      return const LedgerResult(LedgerStatus.rejected, '物品不存在');
    }
    if (place == null || place.kind != EntityKind.place) {
      return const LedgerResult(LedgerStatus.rejected, '地点不存在');
    }
    if (!actor.inventory.contains(item.id)) {
      return LedgerResult(LedgerStatus.rejected, '${actor.name} 身上没有 ${item.name}');
    }
    if (actor.location != place.id) {
      return const LedgerResult(LedgerStatus.rejected, '人不在这个地点');
    }

    actor.inventory.remove(item.id);
    item.location = place.id;
    return LedgerResult(
      LedgerStatus.ok,
      '${actor.name} 把 ${item.name} 放在了 ${place.name}',
    );
  }

  LedgerResult consume({
    required String actorId,
    required String itemId,
    int amount = 1,
  }) {
    final LedgerEntity? actor = byId(actorId);
    final LedgerEntity? item = byId(itemId);
    if (actor == null || actor.kind != EntityKind.character) {
      return const LedgerResult(LedgerStatus.rejected, '角色不存在');
    }
    if (item == null || item.kind != EntityKind.item) {
      return const LedgerResult(LedgerStatus.rejected, '物品不存在');
    }
    if (!actor.inventory.contains(item.id)) {
      return LedgerResult(LedgerStatus.rejected, '${actor.name} 身上没有 ${item.name}');
    }
    if (amount <= 0) {
      return const LedgerResult(LedgerStatus.rejected, '消耗数量必须大于 0');
    }
    final Object? raw = item.state['quantity'];
    if (raw is! int) {
      return LedgerResult(LedgerStatus.rejected, '${item.name} 没有可消耗的数量');
    }
    if (raw < amount) {
      return LedgerResult(LedgerStatus.rejected, '${item.name} 只剩 $raw，不够 $amount');
    }

    item.state['quantity'] = raw - amount;
    if (raw - amount == 0) {
      actor.inventory.remove(item.id);
      item.location = null;
      item.state['consumed'] = true;
    }
    return LedgerResult(
      LedgerStatus.ok,
      '${actor.name} 消耗了 $amount 个 ${item.name}（剩 ${item.state['quantity']}）',
    );
  }
}
