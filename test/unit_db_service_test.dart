// Testy UnitDbService (PRD-DB, milestone DB3):
// - gating: nepřihlášený → žádné HTTP
// - observed payload (ALIVE vs get_param vs devices)
// - throttle ALIVE pushů per jednotka
// - desired fragment, change-id
// - selhání serveru se polyká (fire-and-forget)

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:p2l_tester/models/module.dart';
import 'package:p2l_tester/models/unit.dart';
import 'package:p2l_tester/services/auth_session.dart';
import 'package:p2l_tester/services/local_unit_db.dart';
import 'package:p2l_tester/services/unit_db_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Captured {
  final List<http.Request> requests = [];
}

/// Service s přihlášenou session a MockClientem zachytávajícím requesty.
(UnitDbService, _Captured) _service({bool loggedIn = true, int status = 200}) {
  final captured = _Captured();
  final session = AuthSession()
    ..status = loggedIn ? AuthSessionStatus.loggedIn : AuthSessionStatus.loggedOut
    ..apiBase = 'http://server:3001/api';
  final service = UnitDbService(
    session: session,
    client: MockClient((request) async {
      captured.requests.add(request);
      return http.Response('{"ok":true}', status);
    }),
  );
  return (service, captured);
}

P2LUnit _unit() {
  final u = P2LUnit(id: '1209', isNewGen: true);
  u.firmware = 'P2L_26070201NT';
  u.battery = 87.5;
  return u;
}

void main() {
  test('nepřihlášený → žádné HTTP', () async {
    final (service, captured) = _service(loggedIn: false);
    await service.pushObserved(_unit());
    await service.pushDesired('1209', {'brightness': 50});
    await service.pushChangeId('1209', 1350);
    expect(captured.requests, isEmpty);
  });

  test('pushObserved (ALIVE): PUT observed bez get_param polí', () async {
    final (service, captured) = _service();
    final u = _unit();
    u.mqttServer = 'mqtt.stary.cz'; // v modelu je, ale ALIVE push ho nenese
    await service.pushObserved(u);
    expect(captured.requests, hasLength(1));
    final r = captured.requests.single;
    expect(r.method, 'PUT');
    expect(r.url.toString(), 'http://server:3001/api/units/1209/observed');
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    expect(body['generation'], 'new');
    expect(body['firmware'], 'P2L_26070201NT');
    expect(body['battery'], 87.5);
    expect(body.containsKey('mqttServer'), isFalse);
    expect(body.containsKey('brightness'), isFalse);
    expect(body.containsKey('devices'), isFalse);
  });

  test('pushObserved: seenOnBroker se posílá (drift detekce brokeru)', () async {
    final (service, captured) = _service();
    await service.pushObserved(_unit(), seenOnBroker: 'mqtt.config.smartci4.com');
    final body =
        jsonDecode(captured.requests.single.body) as Map<String, dynamic>;
    expect(body['seenOnBroker'], 'mqtt.config.smartci4.com');
  });

  test('pushObserved (get_param): includeParams přidá ssid/broker/jas', () async {
    final (service, captured) = _service();
    final u = _unit();
    u.ssid = 'HALA';
    u.mqttServer = 'mqtt.firma.cz';
    u.mqttPort = 1883;
    u.brightness = 80;
    await service.pushObserved(u, includeParams: true);
    final body =
        jsonDecode(captured.requests.single.body) as Map<String, dynamic>;
    expect(body['ssid'], 'HALA');
    expect(body['mqttServer'], 'mqtt.firma.cz');
    expect(body['mqttPort'], 1883);
    expect(body['brightness'], 80);
  });

  test('pushObserved (GET-CONFIG): includeConfig přidá unitConfig snapshot',
      () async {
    final (service, captured) = _service();
    final u = _unit();
    u.unitConfig = {
      'mqttAddress': 'mqtt.firma.cz',
      'SSID': 'HALA',
      'ip': '10.0.0.72',
      'actualIp': '10.0.0.72',
      'mqttPassword': true,
    };
    await service.pushObserved(u, includeConfig: true);
    final body =
        jsonDecode(captured.requests.single.body) as Map<String, dynamic>;
    final cfg = body['unitConfig'] as Map<String, dynamic>;
    expect(cfg['mqttAddress'], 'mqtt.firma.cz');
    expect(cfg['actualIp'], '10.0.0.72');
    expect(cfg['mqttPassword'], true);
  });

  test('pushObserved bez includeConfig unitConfig neposílá', () async {
    final (service, captured) = _service();
    final u = _unit()..unitConfig = {'mqttAddress': 'x'};
    await service.pushObserved(u);
    final body =
        jsonDecode(captured.requests.single.body) as Map<String, dynamic>;
    expect(body.containsKey('unitConfig'), isFalse);
  });

  test('pushObserved s modules serializuje devices přes toJson', () async {
    final (service, captured) = _service();
    final modules = [
      PumaModule(
          type: ModuleType.pumA,
          baseAddress: 128,
          buttons: {PumaButton.rightInner, PumaButton.leftInner}),
    ];
    await service.pushObserved(_unit(), modules: modules);
    final body =
        jsonDecode(captured.requests.single.body) as Map<String, dynamic>;
    final devices = body['devices'] as List;
    expect(devices, hasLength(1));
    expect(devices.first['type'], 'pumA');
    expect(devices.first['baseAddress'], 128);
  });

  test('throttle: druhý ALIVE push téže jednotky se přeskočí, jiné jednotky ne',
      () async {
    final (service, captured) = _service();
    await service.pushObserved(_unit(), throttled: true);
    await service.pushObserved(_unit(), throttled: true); // < 30 s → skip
    final other = P2LUnit(id: '128');
    await service.pushObserved(other, throttled: true);
    await service.pushObserved(_unit()); // bez throttle → projde
    expect(captured.requests, hasLength(3));
  });

  test('pushDesired: PUT fragmentu na /desired', () async {
    final (service, captured) = _service();
    await service.pushDesired('1209', {
      'wifi': {'ssid': 'HALA', 'password': 'x'},
    });
    final r = captured.requests.single;
    expect(r.url.path, '/api/units/1209/desired');
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    expect(body['wifi']['ssid'], 'HALA');
  });

  test('pushChangeId: POST na /change-id', () async {
    final (service, captured) = _service();
    await service.pushChangeId('1209', 1350);
    final r = captured.requests.single;
    expect(r.method, 'POST');
    expect(r.url.path, '/api/units/1209/change-id');
    expect(jsonDecode(r.body), {'newId': '1350'});
  });

  test('exportDatabase: GET /units/export vrací dekódovaný JSON', () async {
    final session = AuthSession()
      ..status = AuthSessionStatus.loggedIn
      ..apiBase = 'http://server:3001/api';
    http.Request? seen;
    final service = UnitDbService(
      session: session,
      client: MockClient((req) async {
        seen = req;
        return http.Response(
          '{"format":"p2l-tester.unit-db","units":[{"id":"1209"}]}',
          200,
        );
      }),
    );
    final backup = await service.exportDatabase();
    expect(seen!.method, 'GET');
    expect(seen!.url.toString(), 'http://server:3001/api/units/export');
    expect(backup['format'], 'p2l-tester.unit-db');
    expect((backup['units'] as List), hasLength(1));
  });

  test('importDatabase: POST /units/import s tělem, vrací počty', () async {
    final session = AuthSession()
      ..status = AuthSessionStatus.loggedIn
      ..apiBase = 'http://server:3001/api';
    http.Request? seen;
    final service = UnitDbService(
      session: session,
      client: MockClient((req) async {
        seen = req;
        return http.Response('{"ok":true,"created":1,"updated":2,"total":3}', 200);
      }),
    );
    final res = await service.importDatabase({
      'format': 'p2l-tester.unit-db',
      'units': [
        {'id': '1209'},
      ],
    });
    expect(seen!.method, 'POST');
    expect(seen!.url.path, '/api/units/import');
    expect(jsonDecode(seen!.body)['format'], 'p2l-tester.unit-db');
    expect(res['created'], 1);
    expect(res['updated'], 2);
  });

  test('exportDatabase: 403 → UnitDbException', () async {
    final session = AuthSession()
      ..status = AuthSessionStatus.loggedIn
      ..apiBase = 'http://server:3001/api';
    final service = UnitDbService(
      session: session,
      client: MockClient((_) async => http.Response('{"error":"forbidden"}', 403)),
    );
    expect(
      () => service.exportDatabase(),
      throwsA(isA<UnitDbException>()),
    );
  });

  test('výjimka klienta se polyká (fire-and-forget)', () async {
    final session = AuthSession()
      ..status = AuthSessionStatus.loggedIn
      ..apiBase = 'http://server:3001/api';
    final service = UnitDbService(
      session: session,
      client: MockClient((_) async => throw Exception('offline')),
    );
    // Nesmí vyhodit — čekáme normální dokončení.
    await service.pushObserved(_unit());
    await service.pushDesired('1209', {'brightness': 1});
    await service.pushChangeId('1209', 1350);
  });

  // ── Lokální (offline-first) režim, DB10 ────────────────────────────────
  //
  // Ostatní testy výše jedou přes HTTP, protože LocalUnitDb není otevřená
  // (`isAvailable == false`) — přesně jako na webu nebo když lokální DB nejde
  // otevřít. Tady ji naopak otevřeme nad `:memory:`.

  group('lokální režim (DB10)', () {
    final local = LocalUnitDb.instance;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      await local.close();
      await local.init(path: inMemoryDatabasePath);
      expect(local.isAvailable, isTrue);
    });

    tearDown(() async => local.close());

    UnitDbService svc(MockClient client) => UnitDbService(
      session: AuthSession()
        ..status = AuthSessionStatus.loggedIn
        ..apiBase = 'http://server:3001/api',
      client: client,
      local: local,
    );

    test('zápisy jdou do lokální DB, ne přes HTTP', () async {
      final requests = <http.Request>[];
      final service = svc(MockClient((req) async {
        requests.add(req);
        return http.Response('{"ok":true}', 200);
      }));

      await service.pushObserved(_unit());
      await service.pushDesired('1209', {'brightness': 40});

      // Žádný zápisový request — data čekají ve frontě na sync (DB11).
      expect(requests.where((r) => r.method == 'PUT'), isEmpty);
      expect(await service.pendingChanges(), 2);
      final card = await local.getCard('1209');
      expect(card!.firmware, 'P2L_26070201NT');
      expect(card.desired!['brightness'], 40);
    });

    test('pull naplní lokální DB z /units/changes a posune revizi', () async {
      final service = svc(MockClient((req) async {
        expect(req.url.path, endsWith('/units/changes'));
        expect(req.url.queryParameters['since'], '0');
        return http.Response(
          jsonEncode({
            'serverTs': DateTime.now().toUtc().toIso8601String(),
            'maxRev': 12,
            'more': false,
            'units': [
              {
                'id': '1300',
                'rev': 12,
                'generation': 'new',
                'status': 'active',
                'name': 'Ze serveru',
                'firmware': 'FW7',
              },
            ],
            'deleted': [],
          }),
          200,
        );
      }));

      final list = await service.fetchUnits();
      expect(list.single.id, '1300');
      expect(list.single.name, 'Ze serveru');
      expect((await local.syncState()).lastRev, 12);
    });

    test('offline čtení vrátí poslední známý stav, ne chybu', () async {
      await local.writeMeta('1209', {'name': 'Uloženo offline'});
      final service = svc(MockClient((_) async => throw Exception('offline')));

      // fetchUnits nejdřív zkusí pull (spadne, spolkne se) → čte lokál.
      final list = await service.fetchUnits();
      expect(list.single.name, 'Uloženo offline');
      expect((await service.fetchUnit('1209')).name, 'Uloženo offline');
    });

    test('editace offline uspěje a zařadí se do fronty', () async {
      final service = svc(MockClient((_) async => throw Exception('offline')));

      // saveMeta/saveDesired v online režimu hází UnitDbException; offline-first
      // je musí přijmout, jinak by uživatel u zákazníka nemohl editovat.
      await service.saveMeta('1209', name: 'Hala A');
      await service.saveDesired('1209', {
        'broker': {'address': 'a.cz', 'password': 'tajne'},
      });

      final card = await local.getCard('1209');
      expect(card!.name, 'Hala A');
      expect(card.desired!['broker']['address'], 'a.cz');
      expect(await service.pendingChanges(), 2);
    });

    test('hromadné akce zapíšou lokálně po jednotkách', () async {
      final service = svc(MockClient((_) async => throw Exception('offline')));
      final n = await service.bulkSaveMeta(['1209', '1300'], {'status': 'stock'});
      expect(n, 2);
      expect((await local.getCard('1300'))!.status, 'stock');
      expect(await service.pendingChanges(), 2);
    });

    test('smazání skryje kartu a zařadí delete operaci', () async {
      await local.writeMeta('1209', {'name': 'X'});
      final service = svc(MockClient((_) async => throw Exception('offline')));

      await service.bulkDelete(['1209']);
      expect(await local.getCard('1209'), isNull);
      final ops = await local.pendingOps();
      expect(ops.any((o) => o.layer == UnitLayer.delete), isTrue);
    });
  });
}
