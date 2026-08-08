// Testy synchronizace (PRD-DB/03-PRD-sync.md, milestone DB11).
//
// Pokrývá to, co v terénu rozhoduje o tom, jestli se data neztratí:
// - pořadí push → pull
// - vyhodnocení výsledků pushe (applied / superseded / conflict / rejected)
// - captive portal zákazníkovy WiFi (HTTP 200 s přihlašovací stránkou)
// - offline: fronta zůstane, nic se nezahodí
// - idempotence: operace bez odpovědi se pošle znovu se stejným opId

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:p2l_tester/services/auth_session.dart';
import 'package:p2l_tester/services/local_unit_db.dart';
import 'package:p2l_tester/services/sync_engine.dart';
import 'package:p2l_tester/services/unit_db_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Fake server: zaznamenává cesty requestů a odpovídá podle nastavení.
class _FakeServer {
  final List<String> calls = [];

  /// Odpovědi na `POST /units/sync` — výsledky per opId (v pořadí operací).
  List<String> pushStatuses = ['applied'];
  bool healthOk = true;
  bool captivePortal = false;
  bool down = false;
  List<Map<String, dynamic>> changeUnits = const [];

  /// HTTP status pro sync/changes endpointy. 404 simuluje server starší než
  /// DB9 (endpointy tam ještě nejsou), 401 vypršelé přihlášení.
  int syncHttpStatus = 200;
  int changesHttpStatus = 200;

  MockClient get client => MockClient((req) async {
    calls.add('${req.method} ${req.url.path}');
    if (down) throw Exception('offline');

    if (req.url.path.endsWith('/health')) {
      if (captivePortal) {
        // Přesně to, co dělá captive portál: 200 OK s HTML přihlašovací
        // stránkou na jakýkoli request.
        return http.Response('<html><body>Wi-Fi login</body></html>', 200);
      }
      if (!healthOk) return http.Response('{"error":"nope"}', 503);
      return http.Response(
        jsonEncode({'ok': true, 'ts': DateTime.now().toUtc().toIso8601String(), 'db': 'mariadb'}),
        200,
      );
    }

    if (req.url.path.endsWith('/units/sync')) {
      if (syncHttpStatus != 200) {
        return http.Response('{"error":"nope"}', syncHttpStatus);
      }
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final ops = (body['ops'] as List).cast<Map<String, dynamic>>();
      final results = <Map<String, dynamic>>[];
      for (var i = 0; i < ops.length; i++) {
        final status = i < pushStatuses.length ? pushStatuses[i] : 'applied';
        if (status == 'no-answer') continue; // odpověď na tuhle op nepřijde
        results.add({
          'opId': ops[i]['opId'],
          'status': status,
          'rev': status == 'applied' ? 100 + i : null,
          if (status == 'rejected') 'error': 'invalid_id',
        });
      }
      return http.Response(
        jsonEncode({
          'serverTs': DateTime.now().toUtc().toIso8601String(),
          'maxRev': 100,
          'results': results,
        }),
        200,
      );
    }

    if (req.url.path.endsWith('/units/changes')) {
      if (changesHttpStatus != 200) {
        return http.Response('{"error":"nope"}', changesHttpStatus);
      }
      return http.Response(
        jsonEncode({
          'serverTs': DateTime.now().toUtc().toIso8601String(),
          'maxRev': 100,
          'more': false,
          'units': changeUnits,
          'deleted': const [],
        }),
        200,
      );
    }
    return http.Response('{}', 404);
  });
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  final local = LocalUnitDb.instance;
  late _FakeServer server;
  late UnitDbService service;
  late SyncEngine engine;

  setUp(() async {
    await local.close();
    await local.init(path: inMemoryDatabasePath);
    server = _FakeServer();
    service = UnitDbService(
      session: AuthSession()
        ..status = AuthSessionStatus.loggedIn
        ..apiBase = 'http://server:3001/api',
      client: server.client,
      local: local,
    );
    engine = SyncEngine(service: service, local: local);
  });

  tearDown(() async {
    engine.stop();
    await local.close();
  });

  group('pořadí a průběh', () {
    test('nejdřív health, pak push, pak pull', () async {
      await local.writeMeta('1209', {'name': 'X'});
      final ok = await engine.syncNow();

      expect(ok, isTrue);
      expect(engine.status, SyncStatus.ok);
      // Push MUSÍ být před pullem — server tak rozhoduje o konfliktu se
      // znalostí obou verzí a klient si hned stáhne výsledek.
      expect(server.calls, [
        'GET /api/health',
        'POST /api/units/sync',
        'GET /api/units/changes',
      ]);
      expect(engine.pendingCount, 0);
    });

    test('prázdná fronta: push se pošle naprázdno, pull proběhne', () async {
      await engine.syncNow();
      expect(server.calls, ['GET /api/health', 'GET /api/units/changes']);
    });

    test('pull zapíše serverové karty do lokální DB', () async {
      server.changeUnits = [
        {
          'id': '1300',
          'rev': 100,
          'generation': 'new',
          'status': 'active',
          'name': 'Ze serveru',
        },
      ];
      await engine.syncNow();
      expect((await local.getCard('1300'))!.name, 'Ze serveru');
    });
  });

  group('dostupnost serveru', () {
    test('captive portal (200 + HTML) se NEbere jako běžící server', () async {
      // Bez kontroly obsahu odpovědi by se appka považovala za online a sync
      // by dokola padal — PRD §7 bod 1.
      server.captivePortal = true;
      await local.writeMeta('1209', {'name': 'X'});

      final ok = await engine.syncNow();
      expect(ok, isFalse);
      expect(engine.status, SyncStatus.offline);
      // Dál než k health se to nesmí dostat.
      expect(server.calls, ['GET /api/health']);
      expect(engine.pendingCount, 1, reason: 'fronta musí zůstat');
    });

    test('server vrací chybu → offline, fronta zůstává', () async {
      server.healthOk = false;
      await local.writeMeta('1209', {'name': 'X'});
      expect(await engine.syncNow(), isFalse);
      expect(engine.status, SyncStatus.offline);
      expect(engine.pendingCount, 1);
    });

    test('síť spadne → offline, nic se nezahodí', () async {
      server.down = true;
      await local.writeDesired('1209', {'brightness': 30});
      expect(await engine.syncNow(), isFalse);
      expect(engine.pendingCount, 1);
      expect((await local.getCard('1209'))!.desired!['brightness'], 30);
    });
  });

  group('vyhodnocení výsledků pushe', () {
    test('applied → operace z fronty zmizí', () async {
      await local.writeMeta('1209', {'name': 'X'});
      server.pushStatuses = ['applied'];
      await engine.syncNow();
      expect(await local.outboxCount(), 0);
      expect(await local.conflictCount(), 0);
    });

    test('superseded → zmizí bez upozornění (server má novější)', () async {
      await local.writeObserved('1209', {'firmware': 'FW1'});
      server.pushStatuses = ['superseded'];
      await engine.syncNow();
      expect(await local.outboxCount(), 0);
      expect(await local.conflictCount(), 0,
          reason: 'observed konflikt netvoří — novější pozorování je pravda');
    });

    test('conflict → zmizí z fronty a uloží se pro uživatele', () async {
      await local.writeDesired('1209', {
        'broker': {'address': 'muj.broker', 'password': 'tajne'},
      }, username: 'radek');
      server.pushStatuses = ['conflict'];
      await engine.syncNow();

      expect(await local.outboxCount(), 0);
      final conflicts = await local.conflicts(unitId: '1209');
      expect(conflicts.length, 1);
      expect(conflicts.single.layer, UnitLayer.desired);
      // Prohraná verze se nesmí zahodit mlčky — musí být dohledatelná.
      expect(conflicts.single.payload['broker']['address'], 'muj.broker');
      expect(engine.conflictCount, 1);
    });

    test('rejected → zmizí z fronty (jinak by se posílala donekonečna)', () async {
      await local.writeMeta('1209', {'name': 'X'});
      server.pushStatuses = ['rejected'];
      await engine.syncNow();
      expect(await local.outboxCount(), 0);
      expect(await local.conflictCount(), 0);
    });

    test('operace bez odpovědi zůstane ve frontě se stejným opId', () async {
      await local.writeMeta('1209', {'name': 'X'});
      final opIdBefore = (await local.pendingOps()).single.opId;

      server.pushStatuses = ['no-answer'];
      await engine.syncNow();

      final ops = await local.pendingOps();
      expect(ops.length, 1);
      // Stejné opId je podmínka idempotence: server podle něj pozná, že už tu
      // operaci zpracoval, a nezapíše ji dvakrát.
      expect(ops.single.opId, opIdBefore);
    });

    test('konflikt lze uzavřít (dismiss) — čítač spadne', () async {
      await local.writeMeta('1209', {'name': 'X'});
      server.pushStatuses = ['conflict'];
      await engine.syncNow();
      expect(engine.conflictCount, 1);

      final c = (await local.conflicts()).single;
      await local.dismissConflict(c.id);
      await engine.refreshCounts();
      expect(engine.conflictCount, 0);
      // Záznam zůstává — dohledatelnost je celý smysl.
      expect((await local.conflicts()).isEmpty, isTrue);
    });
  });

  group('stav a čítače', () {
    test('label popisuje stav lidsky', () async {
      expect(engine.label, 'Nesynchronizováno');

      await local.writeMeta('1209', {'name': 'X'});
      await engine.refreshCounts();
      expect(engine.label, contains('1 změna čeká'));

      await local.writeMeta('1300', {'name': 'Y'});
      await local.writeMeta('1400', {'name': 'Z'});
      await engine.refreshCounts();
      expect(engine.label, contains('3 změny čeká'));

      await engine.syncNow();
      expect(engine.label, startsWith('Sladěno'));
    });

    test('offline s čekajícími změnami to řekne', () async {
      server.down = true;
      await local.writeMeta('1209', {'name': 'X'});
      await engine.syncNow();
      expect(engine.label, 'Offline · 1 změna čeká');
    });

    test('notifyLocalChange osvěží čítač hned (bez čekání na debounce)', () async {
      await local.writeMeta('1209', {'name': 'X'});
      engine.notifyLocalChange();
      // refreshCounts je fire-and-forget → dáme mu proběhnout.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(engine.pendingCount, 1);
      engine.stop(); // ať debounce timer nespustí sync po skončení testu
    });

    test('souběžné spuštění se neprolne', () async {
      await local.writeMeta('1209', {'name': 'X'});
      final a = engine.syncNow();
      final b = engine.syncNow(); // druhý běh se má zahodit
      final results = await Future.wait([a, b]);
      expect(results.where((r) => r).length, 1);
      expect(server.calls.where((c) => c.contains('sync')).length, 1);
    });
  });

  // Server žije (health OK), ale sync endpointy nemá nebo je odmítá. Do teď
  // se každá ne-200 odpověď mlčky spolkla: fronta rostla a uživatel viděl jen
  // „N čeká", což vypadá jako normální fronta. Narazili jsme na to naživo —
  // 130 operací se nikdy neodeslalo, protože nasazený server byl starší
  // než DB9 a `/units/sync` vracel 404.
  group('server odpovídá, ale synchronizaci nepřijme', () {
    test('404 na push → stav unsupported, fronta zůstane, pull se nezkouší',
        () async {
      server.syncHttpStatus = 404;
      await local.writeMeta('1209', {'name': 'X'});

      final ok = await engine.syncNow();

      expect(ok, isFalse);
      expect(engine.status, SyncStatus.unsupported);
      expect(engine.needsAttention, isTrue);
      expect(engine.pendingCount, 1, reason: 'nic se nesmí zahodit');
      // Nemá smysl pokračovat pullem, když server endpointy nemá.
      expect(server.calls.where((c) => c.contains('changes')), isEmpty);
      expect(engine.label, contains('Server neumí synchronizaci'));
    });

    test('404 na pull (push prošel) → taky unsupported', () async {
      server.changesHttpStatus = 404;
      final ok = await engine.syncNow();

      expect(ok, isFalse);
      expect(engine.status, SyncStatus.unsupported);
    });

    test('401 → unauthorized, ne offline', () async {
      server.syncHttpStatus = 401;
      await local.writeMeta('1209', {'name': 'X'});

      await engine.syncNow();

      expect(engine.status, SyncStatus.unauthorized);
      expect(engine.needsAttention, isTrue);
      expect(engine.pendingCount, 1);
      expect(engine.label, contains('Přihlášení vypršelo'));
    });

    test('500 je přechodné → offline (zkusí se znovu), ne chyba k řešení',
        () async {
      server.syncHttpStatus = 500;
      await local.writeMeta('1209', {'name': 'X'});

      await engine.syncNow();

      expect(engine.status, SyncStatus.offline);
      expect(engine.needsAttention, isFalse);
      expect(engine.pendingCount, 1);
      engine.stop(); // zruší naplánovaný retry, ať nezasahuje do dalších testů
    });

    test('fronta delší než dávka odejde celá, ne po stovkách', () async {
      // Push posílá po 100. Dokud se neposílalo ve smyčce, zbytek čekal na
      // další trigger (10 min) — v provozu to vypadalo jako zaseknutá fronta.
      for (var i = 0; i < 120; i++) {
        await local.writeMeta('${2000 + i}', {'name': 'U$i'});
      }
      expect(await local.outboxCount(), 120);

      final ok = await engine.syncNow();

      expect(ok, isTrue);
      expect(engine.pendingCount, 0, reason: 'fronta musí odejít celá');
      expect(
        server.calls.where((c) => c.contains('units/sync')).length,
        2,
        reason: '120 operací = dvě dávky po 100',
      );
    });

    test('operace bez odpovědi kolo nezacyklí', () async {
      // Server na nic neodpoví → fronta se nezmenší. Smyčka to musí poznat
      // a skončit, ne posílat donekonečna.
      server.pushStatuses = List.filled(10, 'no-answer');
      for (var i = 0; i < 3; i++) {
        await local.writeMeta('${3000 + i}', {'name': 'X'});
      }

      await engine.syncNow().timeout(const Duration(seconds: 10));

      expect(engine.pendingCount, 3, reason: 'nic se nesmí zahodit');
      expect(
        server.calls.where((c) => c.contains('units/sync')).length,
        1,
        reason: 'druhé kolo nemá smysl, fronta se nezmenšila',
      );
    });

    test('po aktualizaci serveru se fronta odešle', () async {
      server.syncHttpStatus = 404;
      await local.writeMeta('1209', {'name': 'X'});
      await engine.syncNow();
      expect(engine.status, SyncStatus.unsupported);

      // Server se nasadil znovu, už s DB9.
      server.syncHttpStatus = 200;
      final ok = await engine.syncNow();

      expect(ok, isTrue);
      expect(engine.status, SyncStatus.ok);
      expect(engine.pendingCount, 0);
    });
  });
}
