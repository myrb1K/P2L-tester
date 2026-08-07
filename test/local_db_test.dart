// Testy lokální DB jednotek (PRD-DB/03-PRD-sync.md, milestone DB10).
//
// Lokální SQLite v appce = offline evidence (EXE i APK). Testy běží nad
// `:memory:` přes sqflite_common_ffi, takže nepotřebují zařízení ani soubory.
//
// Pozn.: `sqlite3` je v pubspec.yaml držený na řadě 2.x — 3.x staví native
// knihovnu přes Dart build hooks, které na Windows profilu s mezerou v cestě
// spadnou (viz komentář v pubspec.yaml).

import 'package:flutter_test/flutter_test.dart';
import 'package:p2l_tester/services/local_unit_db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    // FFI backend pro testy (na zařízení jde sqflite přes platform kanál).
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  final db = LocalUnitDb.instance;

  setUp(() async {
    await db.close();
    await db.init(path: inMemoryDatabasePath);
    expect(db.isAvailable, isTrue, reason: 'lokální DB se musí otevřít');
  });

  tearDown(() async => db.close());

  group('lokální zápisy', () {
    test('observed zápis založí kartu a naplní seznam', () async {
      await db.writeObserved('1209', {
        'firmware': 'P2L_26071501NT',
        'ip': '192.168.1.50',
        'battery': 87.5,
        'seenOnBroker': 'dev.smartbox.cz',
      });

      final list = await db.listUnits();
      expect(list.length, 1);
      expect(list.single.id, '1209');
      expect(list.single.firmware, 'P2L_26071501NT');
      expect(list.single.generation, 'new'); // ID ≥ 1000
      expect(list.single.broker, 'dev.smartbox.cz');

      final card = await db.getCard('1209');
      expect(card!.ip, '192.168.1.50');
      expect(card.battery, 87.5);
    });

    test('observed je partial update — nemaže dřív dodaná pole', () async {
      await db.writeObserved('1209', {'firmware': 'FW1', 'ip': '10.0.0.1'});
      await db.writeObserved('1209', {'battery': 50.0});

      final card = await db.getCard('1209');
      expect(card!.firmware, 'FW1');
      expect(card.ip, '10.0.0.1');
      expect(card.battery, 50.0);
    });

    test('desired se merguje hloubkově — fragment nepřemaže podpole', () async {
      await db.writeDesired('1209', {
        'broker': {'address': 'a.cz', 'port': 1883, 'password': 'tajne'},
      }, username: 'radek');
      // Jen adresa: port ani heslo se nesmí ztratit (stejně jako na serveru).
      await db.writeDesired('1209', {
        'broker': {'address': 'b.cz'},
      }, username: 'radek');

      final card = await db.getCard('1209');
      expect(card!.desired!['broker']['address'], 'b.cz');
      expect(card.desired!['broker']['port'], 1883);
      expect(card.desired!['broker']['password'], 'tajne');
    });

    test('meta zápis mění jen dodaná pole', () async {
      await db.writeMeta('1209', {'name': 'Sklad B', 'status': 'faulty'},
          username: 'radek');
      await db.writeMeta('1209', {'location': 'Hala A'}, username: 'radek');

      final card = await db.getCard('1209');
      expect(card!.name, 'Sklad B');
      expect(card.status, 'faulty');
      expect(card.location, 'Hala A');
    });

    test('smazání kartu skryje ze seznamu i z detailu', () async {
      await db.writeMeta('1209', {'name': 'Ke smazání'});
      await db.writeDelete('1209', username: 'admin');

      expect(await db.listUnits(), isEmpty);
      expect(await db.getCard('1209'), isNull);
    });
  });

  group('outbox', () {
    test('každý ruční zápis vytvoří operaci k odeslání', () async {
      await db.writeDesired('1209', {'brightness': 40});
      await db.writeMeta('1209', {'name': 'X'});

      final ops = await db.pendingOps();
      expect(ops.length, 2);
      expect(ops.map((o) => o.layer),
          containsAll([UnitLayer.desired, UnitLayer.meta]));
      expect(await db.outboxCount(), 2);
    });

    test('observed operace se ve frontě slučují (ALIVE chodí často)', () async {
      // Tři pozorování téže jednotky → jedna operace s posledním stavem,
      // jinak by fronta po dni offline měla tisíce položek.
      await db.writeObserved('1209', {'firmware': 'FW1'});
      await db.writeObserved('1209', {'battery': 90.0});
      await db.writeObserved('1209', {'battery': 80.0});

      final ops = await db.pendingOps();
      expect(ops.length, 1);
      expect(ops.single.payload['firmware'], 'FW1');
      expect(ops.single.payload['battery'], 80.0);
    });

    test('observed různých jednotek se neslévají', () async {
      await db.writeObserved('1209', {'firmware': 'A'});
      await db.writeObserved('1300', {'firmware': 'B'});
      expect((await db.pendingOps()).length, 2);
    });

    test('operace nese opId (UUID) a wire tvar pro /units/sync', () async {
      await db.writeMeta('1209', {'name': 'X'});
      final op = (await db.pendingOps()).single;
      expect(op.opId, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-')));

      final wire = op.toWire();
      expect(wire['layer'], 'meta');
      expect(wire['unitId'], '1209');
      expect(wire['payload'], {'name': 'X'});
      expect(DateTime.tryParse(wire['at'] as String), isNotNull);
    });

    test('dropOp odebere z fronty, markOpFailed počítá pokusy', () async {
      await db.writeMeta('1209', {'name': 'X'});
      final op = (await db.pendingOps()).single;

      await db.markOpFailed(op.opId, 'server neodpověděl');
      final failed = (await db.pendingOps()).single;
      expect(failed.tries, 1);
      expect(failed.lastError, 'server neodpověděl');

      await db.dropOp(op.opId);
      expect(await db.outboxCount(), 0);
    });
  });

  group('historie', () {
    test('ruční zápisy se zapisují, hesla maskovaná', () async {
      await db.writeDesired('1209', {
        'wifi': {'ssid': 'HALA', 'password': 'tajne'},
      }, username: 'radek');

      final hist = await db.history('1209');
      expect(hist.length, 1);
      expect(hist.single.action, 'desired');
      expect(hist.single.username, 'radek');
      expect(hist.single.detail!['wifi']['ssid'], 'HALA');
      expect(hist.single.detail!['wifi']['password'], '•••');
    });

    test('observed historii negeneruje (ALIVE by byl šum)', () async {
      await db.writeObserved('1209', {'firmware': 'FW1'});
      expect(await db.history('1209'), isEmpty);
    });
  });

  group('pull ze serveru', () {
    test('serverová karta přepíše lokální a posune last_rev', () async {
      await db.writeMeta('1209', {'name': 'lokální'});

      await db.applyServerChanges(
        units: [
          {
            'id': '1209',
            'rev': 42,
            'generation': 'new',
            'name': 'ze serveru',
            'status': 'active',
            'firmware': 'FW9',
            'desired': {
              'broker': {'address': 'server.cz', 'password': 'p'},
            },
          },
        ],
        deleted: const [],
        maxRev: 42,
      );

      final card = await db.getCard('1209');
      expect(card!.name, 'ze serveru');
      expect(card.firmware, 'FW9');
      // Sync endpoint vrací desired vč. hesel — lokál je potřebuje pro offline.
      expect(card.desired!['broker']['password'], 'p');
      expect((await db.syncState()).lastRev, 42);
    });

    test('tombstone smaže lokální kartu', () async {
      await db.applyServerChanges(
        units: [
          {'id': '1209', 'rev': 1, 'generation': 'new', 'status': 'active'},
        ],
        deleted: const [],
        maxRev: 1,
      );
      expect((await db.listUnits()).length, 1);

      await db.applyServerChanges(
        units: const [],
        deleted: [
          {'id': '1209', 'rev': 2, 'deletedAt': '2026-08-07T10:00:00.000Z'},
        ],
        maxRev: 2,
      );
      expect(await db.listUnits(), isEmpty);
      expect((await db.syncState()).lastRev, 2);
    });

    test('neodeslaná lokální operace zůstane v outboxu i po pullu', () async {
      await db.writeMeta('1209', {'name': 'moje změna'});
      await db.applyServerChanges(
        units: [
          {
            'id': '1209', 'rev': 5, 'generation': 'new',
            'status': 'active', 'name': 'serverová',
          },
        ],
        deleted: const [],
        maxRev: 5,
      );

      // Karta je serverová (server je zdroj pravdy), ale operace se pořád
      // pošle — server rozhodne podle časů, kdo vyhrál.
      expect((await db.getCard('1209'))!.name, 'serverová');
      expect((await db.pendingOps()).length, 1);
    });
  });

  group('stav synchronizace a hodiny', () {
    test('offset hodin se ukládá a používá pro časy zápisů', () async {
      // Server je o hodinu vpřed proti tomuto stroji.
      await db.saveSyncState(clockOffsetMs: 3600 * 1000);
      expect((await db.syncState()).clockOffsetMs, 3600 * 1000);

      final before = DateTime.now().toUtc();
      await db.writeMeta('1209', {'name': 'X'});
      final op = (await db.pendingOps()).single;

      // Čas operace musí být posunutý na serverový čas, ne místní — jinak by
      // zápis z rozjetých hodin prohrál (nebo přebil) novější serverovou verzi.
      expect(op.at.isAfter(before.add(const Duration(minutes: 50))), isTrue,
          reason: 'čas operace se neopravil o offset: ${op.at} vs $before');
    });

    test('lastSyncAt se plní z pullu', () async {
      final ts = DateTime.utc(2026, 8, 7, 12, 30);
      await db.applyServerChanges(
        units: const [], deleted: const [], maxRev: 7, serverTs: ts,
      );
      final st = await db.syncState();
      expect(st.lastRev, 7);
      expect(st.lastSyncAt!.toUtc(), ts);
    });
  });
}
