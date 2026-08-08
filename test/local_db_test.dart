// Testy lokální DB jednotek (PRD-DB/03-PRD-sync.md, milestone DB10).
//
// Lokální SQLite v appce = offline evidence (EXE i APK). Testy běží nad
// `:memory:` přes sqflite_common_ffi, takže nepotřebují zařízení ani soubory.
//
// Pozn.: `sqlite3` je v pubspec.yaml držený na řadě 2.x — 3.x staví native
// knihovnu přes Dart build hooks, které na Windows profilu s mezerou v cestě
// spadnou (viz komentář v pubspec.yaml).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:p2l_tester/services/local_unit_db.dart';
import 'package:path/path.dart' as p;
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

  // Appka drží ID kanonicky s nulami (`001114`, klíč v AppState._units a
  // MQTT topicy), server ale ukládá `1114`. Kdyby lokální DB nechala tvar
  // s nulami, první pull by kartu zdvojil — tohle to hlídá.
  group('tvar ID (bez vodicích nul, shodně se serverem)', () {
    test('zápis s nulami se uloží pod plain ID', () async {
      await db.writeObserved('001114', {'ip': '10.0.0.5'});

      final list = await db.listUnits();
      expect(list.single.id, '1114');

      // Číst jde oběma tvary — volající (AppState) zná jen ten kanonický.
      expect((await db.getCard('001114'))!.ip, '10.0.0.5');
      expect((await db.getCard('1114'))!.ip, '10.0.0.5');
      expect((await db.getCard('1114'))!.id, '1114');
    });

    test('pull po lokálním zápisu kartu NEzdvojí', () async {
      await db.writeMeta('001114', {'name': 'lokální'});
      expect((await db.listUnits()).length, 1);

      // Server vrací ID bez nul — dřív vznikla druhá karta.
      await db.applyServerChanges(
        units: [
          {'id': '1114', 'rev': 5, 'name': 'serverová', 'status': 'active'},
        ],
        deleted: const [],
        maxRev: 5,
      );

      final list = await db.listUnits();
      expect(list.length, 1, reason: 'karta se nesmí zdvojit');
      expect(list.single.id, '1114');
      expect(list.single.name, 'serverová');
    });

    test('outbox, historie i konflikty nesou plain ID', () async {
      await db.writeMeta('001114', {'name': 'X'}, username: 'radek');
      expect((await db.pendingOps()).single.unitId, '1114');
      expect((await db.history('001114')).length, 1);

      await db.recordConflict(
        unitId: '001114',
        layer: UnitLayer.meta,
        payload: const {'name': 'moje'},
        at: DateTime.utc(2026, 8, 8),
      );
      // Dotaz kanonickým tvarem musí konflikt najít.
      expect((await db.conflicts(unitId: '001114')).single.unitId, '1114');
      expect((await db.conflicts(unitId: '1114')).length, 1);
    });

    test('stará jednotka (< 1000) taky ztratí nuly', () async {
      await db.writeObserved('0472', {'ip': '10.0.0.9'});
      final list = await db.listUnits();
      expect(list.single.id, '472');
      expect(list.single.generation, 'old');
    });
  });

  // Migrace schématu v2 → v3 nad reálným souborem. Existující instalace mají
  // v lokální DB stovky karet s ID ve tvaru `001114`; upgrade appky je musí
  // převést, jinak by je první pull zdvojil.
  group('migrace v2 → v3 (ID bez vodicích nul)', () {
    late Directory tmp;
    late String file;

    setUp(() async {
      await db.close();
      tmp = await Directory.systemTemp.createTemp('p2l-mig-test');
      file = p.join(tmp.path, 'units-local.db');
    });

    tearDown(() async {
      await db.close();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {
        // Windows drží handle chvíli po close — na úklidu testu nezáleží.
      }
    });

    /// Vyrobí DB, která vypadá jako od staré verze appky: aktuální schéma,
    /// ale data s vodicími nulami a `user_version = 2`.
    Future<void> seedV2(List<Map<String, Object?>> cards) async {
      await db.init(path: file); // vytvoří tabulky
      await db.close();

      final raw = await databaseFactory.openDatabase(file);
      for (final c in cards) {
        final id = c['id'] as String;
        await raw.insert('units_cache', {
          'id': id,
          'rev': c['rev'] ?? 0,
          'generation': 'new',
          'name': c['name'],
          'status': 'active',
          'card_json': jsonEncode({'id': id, 'name': c['name']}),
          'updated_at': c['updated_at'] ?? '2026-08-08T09:00:00.000Z',
        });
        await raw.insert('outbox', {
          'op_id': 'op-$id',
          'unit_id': id,
          'layer': 'meta',
          'payload_json': '{}',
          'at': '2026-08-08T09:00:00.000Z',
          'created_at': '2026-08-08T09:00:00.000Z',
        });
        await raw.insert('local_history', {
          'uuid': 'uuid-$id',
          'unit_id': id,
          'at': '2026-08-08T09:00:00.000Z',
          'action': 'meta',
        });
      }
      await raw.execute('PRAGMA user_version = 2');
      await raw.close();
    }

    test('karty, outbox i historie se převedou na plain ID', () async {
      await seedV2([
        {'id': '001114', 'name': 'A'},
        {'id': '001180', 'name': 'B'},
        {'id': '0472', 'name': 'stará'},
      ]);

      await db.init(path: file); // spustí onUpgrade 2 → 3
      expect(db.isAvailable, isTrue);

      final ids = (await db.listUnits()).map((u) => u.id).toList()..sort();
      expect(ids, ['1114', '1180', '472']);

      // ID uvnitř card_json se musí přepsat taky — jinak by karta v UI
      // hlásila starý tvar a `saveDesired(card.id, …)` psal vedle.
      expect((await db.getCard('1114'))!.id, '1114');
      expect((await db.getCard('1114'))!.name, 'A');

      final ops = await db.pendingOps();
      expect(ops.map((o) => o.unitId).toList()..sort(), ['1114', '1180', '472']);
      expect((await db.history('1114')).length, 1);
    });

    test('kolize starého a nového tvaru: vyhraje karta se serverovou revizí',
        () async {
      await seedV2([
        {'id': '001114', 'name': 'lokální', 'rev': 0},
        {'id': '1114', 'name': 'serverová', 'rev': 9},
      ]);

      await db.init(path: file);

      final list = await db.listUnits();
      expect(list.length, 1, reason: 'kolize se musí sloučit na jednu kartu');
      expect(list.single.id, '1114');
      expect(list.single.name, 'serverová');
    });

    test('opakované otevření už nic nemění (idempotence)', () async {
      await seedV2([
        {'id': '001114', 'name': 'A'},
      ]);
      await db.init(path: file);
      await db.close();

      await db.init(path: file);
      final list = await db.listUnits();
      expect(list.single.id, '1114');
      expect(list.single.name, 'A');
    });
  });
}
