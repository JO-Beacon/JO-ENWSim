import 'package:flutter_test/flutter_test.dart';
import 'package:joenws/engine/ledger.dart';

void main() {
  group('Ledger', () {
    late Ledger ledger;

    setUp(() {
      ledger = Ledger();
      ledger.add(LedgerEntity(
        id: 'place:gate',
        kind: EntityKind.place,
        name: '东门',
      ));
      ledger.add(LedgerEntity(
        id: 'char:beacon',
        kind: EntityKind.character,
        name: '信标',
        location: 'place:gate',
      ));
      ledger.add(LedgerEntity(
        id: 'char:erin',
        kind: EntityKind.character,
        name: '艾琳',
        location: 'place:gate',
      ));
      ledger.add(LedgerEntity(
        id: 'cont:kit',
        kind: EntityKind.container,
        name: '急救箱',
        location: 'place:gate',
        contains: <String>['item:bandage'],
      ));
      ledger.add(LedgerEntity(
        id: 'item:bandage',
        kind: EntityKind.item,
        name: '绷带',
        location: 'cont:kit',
      ));
      ledger.add(LedgerEntity(
        id: 'item:water',
        kind: EntityKind.item,
        name: '水壶',
        location: 'char:beacon',
        state: <String, Object?>{'quantity': 2},
      ));
      ledger.byId('char:beacon')!.inventory.add('item:water');
    });

    test('从已知容器里拿东西', () {
      final LedgerResult r = ledger.take(
        actorId: 'char:beacon',
        itemId: 'item:bandage',
        containerId: 'cont:kit',
      );
      expect(r.ok, isTrue);
      expect(ledger.byId('char:beacon')!.inventory, contains('item:bandage'));
      expect(ledger.byId('cont:kit')!.contains, isEmpty);
      expect(ledger.byId('item:bandage')!.location, 'char:beacon');
    });

    test('容器内容未知时拒绝，不猜有也不猜没有', () {
      ledger.byId('cont:kit')!.contains = null;
      final LedgerResult r = ledger.take(
        actorId: 'char:beacon',
        itemId: 'item:bandage',
        containerId: 'cont:kit',
      );
      expect(r.status, LedgerStatus.unknown);
      expect(r.ok, isFalse);
    });

    test('已知为空的容器里拿不到东西', () {
      ledger.byId('cont:kit')!.contains = <String>[];
      final LedgerResult r = ledger.take(
        actorId: 'char:beacon',
        itemId: 'item:bandage',
        containerId: 'cont:kit',
      );
      expect(r.status, LedgerStatus.rejected);
    });

    test('给东西会移动背包和 location', () {
      final LedgerResult r = ledger.give(
        fromId: 'char:beacon',
        toId: 'char:erin',
        itemId: 'item:water',
      );
      expect(r.ok, isTrue);
      expect(ledger.byId('char:beacon')!.inventory, isEmpty);
      expect(ledger.byId('char:erin')!.inventory, contains('item:water'));
      expect(ledger.byId('item:water')!.location, 'char:erin');
    });

    test('放东西到地点', () {
      final LedgerResult r = ledger.drop(
        actorId: 'char:beacon',
        itemId: 'item:water',
        placeId: 'place:gate',
      );
      expect(r.ok, isTrue);
      expect(ledger.byId('char:beacon')!.inventory, isEmpty);
      expect(ledger.byId('item:water')!.location, 'place:gate');
    });

    test('消耗数量并归零后移除', () {
      final LedgerResult r = ledger.consume(
        actorId: 'char:beacon',
        itemId: 'item:water',
        amount: 2,
      );
      expect(r.ok, isTrue);
      expect(ledger.byId('item:water')!.state['quantity'], 0);
      expect(ledger.byId('char:beacon')!.inventory, isEmpty);
      expect(ledger.byId('item:water')!.location, isNull);
    });

    test('两个人不在同一地点时不能给', () {
      ledger.byId('char:erin')!.location = 'place:outside';
      final LedgerResult r = ledger.give(
        fromId: 'char:beacon',
        toId: 'char:erin',
        itemId: 'item:water',
      );
      expect(r.status, LedgerStatus.rejected);
    });
  });
}
