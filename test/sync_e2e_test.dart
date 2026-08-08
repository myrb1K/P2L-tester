// E2E synchronizace proti REÁLNÉMU serveru (DB9–DB11).
//
// Na rozdíl od sync_engine_test.dart (fake HTTP klient) tady jde o skutečný
// Node server přes skutečné HTTP: login → JWT → push fronty → pull změn →
// konflikt → tombstone. Testuje tedy i to, co fake klient nikdy neodhalí —
// tvar payloadu, chování routeru, serializaci časů, idempotenci na serveru.
//
// Server se spouští z repa (`server/server.js`) nad SQLite v temp adresáři,
// takže se nic nesahá na produkční data. Testy se skipují, když chybí Node
// nebo `server/node_modules`.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:p2l_tester/services/auth_http_client.dart';
import 'package:p2l_tester/services/auth_session.dart';
import 'package:p2l_tester/services/auth_token_store.dart';
import 'package:p2l_tester/services/local_unit_db.dart';
import 'package:p2l_tester/services/sync_engine.dart';
import 'package:p2l_tester/services/unit_db_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Port mimo dev rozsah (3001), ať test nekoliduje s běžícím `npm run dev`.
const _port = 3098;
const _base = 'http://127.0.0.1:$_port/api';
const _admin = 'e2e-admin';
const _password = 'e2e-heslo-123';

Future<bool> _envReady() async {
  final sep = Platform.pathSeparator;
  if (!File('${Directory.current.path}${sep}server${sep}server.js').existsSync()) {
    return false;
  }
  if (!Directory('${Directory.current.path}${sep}server${sep}node_modules')
      .existsSync()) {
    return false;
  }
  try {
    return (await Process.run('node', ['-v'])).exitCode == 0;
  } catch (_) {
    return false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final local = LocalUnitDb.instance;
  late Directory dataDir;
  Process? server;
  var envReady = false;
  String? token;

  /// Přímý HTTP klient s tokenem — pro kontrolní dotazy „co je opravdu na
  /// serveru" a pro simulaci druhého klienta (kolegy).
  Future<Map<String, dynamic>> api(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final uri = Uri.parse('$_base$path');
    final headers = {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
    final res = switch (method) {
      'GET' => await http.get(uri, headers: headers),
      'PUT' => await http.put(uri, headers: headers, body: jsonEncode(body)),
      'POST' => await http.post(uri, headers: headers, body: jsonEncode(body)),
      _ => throw ArgumentError(method),
    };
    if (res.statusCode >= 400) {
      throw StateError('$method $path → ${res.statusCode}: ${res.body}');
    }
    return res.body.isEmpty
        ? const {}
        : (jsonDecode(res.body) as Map).cast<String, dynamic>();
  }

  setUpAll(() async {
    // TestWidgetsFlutterBinding jinak vrací na každý request 400.
    HttpOverrides.global = null;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    envReady = await _envReady();
    if (!envReady) return;

    dataDir = Directory.systemTemp.createTempSync('p2l-sync-e2e-');
    server = await Process.start(
      'node',
      ['server.js'],
      workingDirectory: '${Directory.current.path}${Platform.pathSeparator}server',
      environment: {
        'PORT': '$_port',
        'P2L_DATA_DIR': dataDir.path,
        // Explicitně sqlite: server/.env může mít DB_DRIVER=mariadb a dotenv
        // existující env nepřepisuje, takže bez tohohle by test jel proti
        // firemní databázi.
        'DB_DRIVER': 'sqlite',
        'JWT_SECRET': 'e' * 40,
        'NODE_ENV': 'production',
        'INITIAL_ADMIN_USER': _admin,
        'INITIAL_ADMIN_PASSWORD': _password,
      },
    );
    // Log serveru do konzole testu — bez něj se špatně hledá, proč nenaběhl.
    // ignore_for_file: avoid_print
    server!.stdout
        .transform(utf8.decoder)
        .listen((l) => print('[server] ${l.trim()}'));
    server!.stderr
        .transform(utf8.decoder)
        .listen((l) => print('[server-err] ${l.trim()}'));

    // Čekání na health.
    for (var i = 0; i < 60; i++) {
      try {
        final res = await http.get(Uri.parse('$_base/health'));
        if (res.statusCode == 200) break;
      } catch (_) {
        // ještě nenaběhl
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    final login = await http.post(
      Uri.parse('$_base/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'username': _admin,
        'password': _password,
        'rememberMe': true,
      }),
    );
    token = (jsonDecode(login.body) as Map)['token'] as String?;
  });

  tearDownAll(() async {
    server?.kill();
    await local.close();
    try {
      dataDir.deleteSync(recursive: true);
    } catch (_) {
      // Windows drží soubor DB → nechat, je to temp
    }
  });

  late UnitDbService service;
  late SyncEngine engine;

  setUp(() async {
    await local.close();
    await local.init(path: inMemoryDatabasePath);
    currentAuthToken = token; // BearerClient posílá Authorization header
    service = UnitDbService(
      session: AuthSession()
        ..status = AuthSessionStatus.loggedIn
        ..apiBase = _base,
      client: createAuthClient(),
      local: local,
    );
    engine = SyncEngine(service: service, local: local);
  });

  tearDown(() {
    engine.stop();
  });

  bool ready() {
    if (envReady && token != null) return true;
    markTestSkipped('Node / server/node_modules chybí, nebo login neprošel');
    return false;
  }

  test('probeServer projde proti běžícímu serveru', () async {
    if (!ready()) return;
    expect(await service.probeServer(), isTrue);
  });

  test('lokální změny se odešlou a jsou na serveru', () async {
    if (!ready()) return;
    await local.writeMeta('9001', {
      'name': 'E2E jednotka',
      'location': 'Hala Z',
    }, username: _admin);
    await local.writeDesired('9001', {
      'broker': {'address': 'mqtt.e2e.cz', 'port': 1883, 'password': 'tajne'},
    }, username: _admin);
    // Čítač v engine se plní až refreshCounts/syncNow, takže se ptáme DB.
    expect(await local.outboxCount(), 2, reason: 'nejdřív musí něco čekat');

    expect(await engine.syncNow(), isTrue);
    expect(engine.pendingCount, 0, reason: 'fronta se má vyprázdnit');

    // Kontrola přímo na serveru, ne přes lokální DB.
    final unit = (await api('GET', '/units/9001'))['unit'] as Map;
    expect(unit['name'], 'E2E jednotka');
    expect(unit['location'], 'Hala Z');
    expect((unit['desired'] as Map)['broker']['address'], 'mqtt.e2e.cz');
    // Hesla se do evidence ukládají skutečná (rozhodnutí z DB5).
    expect((unit['desired'] as Map)['broker']['password'], 'tajne');
  });

  test('observed z MQTT dojde na server a nese revizi', () async {
    if (!ready()) return;
    await local.writeObserved('9002', {
      'firmware': 'P2L_26071501NT',
      'ip': '192.168.1.77',
      'battery': 91.5,
      'seenOnBroker': 'dev.e2e.cz',
    });
    expect(await engine.syncNow(), isTrue);

    final unit = (await api('GET', '/units/9002'))['unit'] as Map;
    expect(unit['firmware'], 'P2L_26071501NT');
    expect(unit['ip'], '192.168.1.77');
    expect((unit['rev'] as num).toInt(), greaterThan(0));
  });

  test('změna od jiného klienta se stáhne pullem', () async {
    if (!ready()) return;
    // „Kolega" zapíše přímo na server (jiný klient).
    await api('PUT', '/units/9003/meta', body: {'name': 'Od kolegy'});

    expect(await engine.syncNow(), isTrue);
    final card = await local.getCard('9003');
    expect(card, isNotNull);
    expect(card!.name, 'Od kolegy');
    // Rozdílový pull si drží revizi, takže podruhé už není co stahovat.
    final rev = (await local.syncState()).lastRev;
    expect(rev, greaterThan(0));
    await engine.syncNow();
    expect((await local.syncState()).lastRev, greaterThanOrEqualTo(rev));
  });

  test('konflikt: novější serverová změna přehlasuje starší lokální', () async {
    if (!ready()) return;
    // 1) Lokální změna „z terénu": posunutím offsetu o hodinu zpět dostane
    //    operace starší čas — přesně jako když technik hodinu pracoval offline.
    await local.saveSyncState(clockOffsetMs: -3600 * 1000);
    await local.writeMeta('9004', {'name': 'Moje verze'}, username: _admin);
    await local.saveSyncState(clockOffsetMs: 0); // hodiny zpátky srovnané

    // 2) Mezitím kolega uložil na server něco novějšího.
    await api('PUT', '/units/9004/meta', body: {'name': 'Verze kolegy'});

    // 3) Push mojí starší změny → server ji odmítne jako conflict.
    expect(await engine.syncNow(), isTrue);

    final conflicts = await local.conflicts(unitId: '9004');
    expect(conflicts.length, 1, reason: 'prohraná verze musí být zachycená');
    expect(conflicts.single.payload['name'], 'Moje verze');

    // Na serveru i v lokální DB platí verze kolegy.
    final unit = (await api('GET', '/units/9004'))['unit'] as Map;
    expect(unit['name'], 'Verze kolegy');
    expect((await local.getCard('9004'))!.name, 'Verze kolegy');

    // 4) „Poslat znovu" = nový zápis s aktuálním časem → teď vyhraje.
    await service.saveMeta('9004', name: 'Moje verze');
    expect(await engine.syncNow(), isTrue);
    expect(((await api('GET', '/units/9004'))['unit'] as Map)['name'], 'Moje verze');
  });

  test('idempotence: dvakrát poslaná operace se nezapíše dvakrát', () async {
    if (!ready()) return;
    await local.writeMeta('9005', {'note': 'jednou'}, username: _admin);
    final op = (await local.pendingOps()).single;

    // Ruční push téže operace dvakrát — jako když se odpověď ztratí v síti.
    final first = await api('POST', '/units/sync', body: {
      'ops': [op.toWire()],
      'sourceDevice': 'e2e-test',
    });
    final second = await api('POST', '/units/sync', body: {
      'ops': [op.toWire()],
      'sourceDevice': 'e2e-test',
    });
    expect((first['results'] as List).single['status'], 'applied');
    expect((second['results'] as List).single['duplicate'], isTrue);

    // V historii je jeden záznam, ne dva.
    final hist = (await api('GET', '/units/9005/history'))['history'] as List;
    expect(hist.where((h) => (h as Map)['action'] == 'meta').length, 1);
  });

  test('audit nese, odkud změna přišla', () async {
    if (!ready()) return;
    await local.writeMeta('9006', {'name': 'Auditovaná'}, username: _admin);
    expect(await engine.syncNow(), isTrue);

    final hist = (await api('GET', '/units/9006/history'))['history'] as List;
    final entry = hist.first as Map;
    expect(entry['origin'], 'sync');
    expect(entry['sourceDevice'], isNotNull);
    expect(entry['layer'], 'meta');
  });

  test('smazání se propíše na server a vrátí se jako tombstone', () async {
    if (!ready()) return;
    await local.writeMeta('9007', {'name': 'Ke smazání'}, username: _admin);
    expect(await engine.syncNow(), isTrue);
    expect(((await api('GET', '/units/9007'))['unit'] as Map)['name'], 'Ke smazání');

    // Mazání smí jen admin — testovací účet jím je (INITIAL_ADMIN).
    await local.writeDelete('9007', username: _admin);
    expect(await engine.syncNow(), isTrue);

    // Na serveru už není (tombstone se v detailu chová jako 404).
    await expectLater(
      api('GET', '/units/9007'),
      throwsA(isA<StateError>()),
    );
    expect(await local.getCard('9007'), isNull);
  });

  test('audit napříč jednotkami: filtry, stránkování, nabídky (DB12)', () async {
    if (!ready()) return;
    // Několik změn od dvou „uživatelů" (druhý přes přímé API = online zápis).
    await local.writeMeta('9100', {'name': 'Audit A'}, username: _admin);
    await local.writeDesired('9100', {'brightness': 25}, username: _admin);
    await local.writeMeta('9101', {'name': 'Audit B'}, username: _admin);
    expect(await engine.syncNow(), isTrue);
    await api('PUT', '/units/9102/meta', body: {'name': 'Přímo online'});

    // Bez filtru vidíme všechno, nejnovější první.
    final all = await service.fetchAudit(limit: 100);
    expect(all.events.length, greaterThanOrEqualTo(4));
    expect(all.events.first.at.compareTo(all.events.last.at) >= 0, isTrue);

    // Filtr na jednotku.
    final perUnit = await service.fetchAudit(unitId: '9100');
    expect(perUnit.events.length, 2);
    expect(perUnit.events.every((e) => e.unitId == '9100'), isTrue);

    // Filtr na vrstvu a na původ (sync = přišlo z fronty, online = přímý zápis).
    expect((await service.fetchAudit(unitId: '9100', layer: 'desired')).events.length, 1);
    final viaSync = await service.fetchAudit(unitId: '9100', origin: 'sync');
    expect(viaSync.events.length, 2);
    expect(viaSync.events.first.sourceDevice, isNotNull);
    final online = await service.fetchAudit(unitId: '9102', origin: 'online');
    expect(online.events.length, 1);

    // Stránkování.
    final page1 = await service.fetchAudit(limit: 2);
    expect(page1.events.length, 2);
    expect(page1.hasMore, isTrue);
    final page2 = await service.fetchAudit(limit: 2, offset: 2);
    expect(page2.events.first.at, isNot(page1.events.first.at));

    // Nabídky filtrů se plní z dat.
    final filters = await service.fetchAuditFilters();
    expect(filters.usernames, contains(_admin));
    expect(filters.layers, containsAll(['desired', 'meta']));
    expect(filters.origins, containsAll(['online', 'sync']));
  });

  test('audit nevrací hesla', () async {
    if (!ready()) return;
    await local.writeDesired('9103', {
      'wifi': {'ssid': 'HALA', 'password': 'nesmi-uniknout'},
    }, username: _admin);
    expect(await engine.syncNow(), isTrue);

    final page = await service.fetchAudit(unitId: '9103');
    final detail = page.events.first.detail!;
    expect(detail['wifi']['ssid'], 'HALA');
    expect(detail['wifi']['password'], '•••');
    // Kontrola i na surové odpovědi, ať se to neschová v modelu.
    final raw = await api('GET', '/units/history?unitId=9103');
    expect(jsonEncode(raw).contains('nesmi-uniknout'), isFalse);
  });

  test('offline → fronta zůstane, po návratu se odešle', () async {
    if (!ready()) return;
    // Simulace offline: service míří na port, kde nic neposlouchá.
    final offlineService = UnitDbService(
      session: AuthSession()
        ..status = AuthSessionStatus.loggedIn
        ..apiBase = 'http://127.0.0.1:1/api',
      client: createAuthClient(),
      local: local,
    );
    final offlineEngine = SyncEngine(service: offlineService, local: local);

    await local.writeMeta('9008', {'name': 'Vzniklo offline'}, username: _admin);
    expect(await offlineEngine.syncNow(), isFalse);
    expect(offlineEngine.status, SyncStatus.offline);
    expect(await local.outboxCount(), greaterThan(0));
    offlineEngine.stop();

    // Server je zpátky → tentýž obsah fronty se odešle.
    expect(await engine.syncNow(), isTrue);
    expect(((await api('GET', '/units/9008'))['unit'] as Map)['name'],
        'Vzniklo offline');
  });
}
