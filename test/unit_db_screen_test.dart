// Testy DB4 — modely unit_db.dart (parsing, drift, filtr) a widget testy
// obrazovky Databáze jednotek (seznam, vyhledávání, chyba + Zkusit znovu,
// detail s maskovanými hesly).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:p2l_tester/models/unit_db.dart';
import 'package:p2l_tester/screens/unit_db_screen.dart';
import 'package:p2l_tester/services/auth_api.dart';
import 'package:p2l_tester/services/auth_session.dart';
import 'package:p2l_tester/services/unit_db_service.dart';

UnitDbService _service(MockClientHandler handler, {bool admin = false}) {
  final session = AuthSession()
    ..status = AuthSessionStatus.loggedIn
    ..apiBase = 'http://server:3001/api'
    ..user = AuthUser(username: 'radek', isAdmin: admin);
  return UnitDbService(session: session, client: MockClient(handler));
}

const _listBody = '''
{"units":[
  {"id":"1209","generation":"new","name":"Regál 12","location":"Sklad B",
   "status":"active","last_seen":"2026-07-08T10:00:00Z","firmware":"FW1",
   "drift":true},
  {"id":"128","generation":"old","name":null,"location":null,
   "status":"faulty","last_seen":null,"firmware":null}
]}''';

const _cardBody = '''
{"unit":{"id":"1209","generation":"new","mac":"AA:BB","hw_model":"P2L32",
 "firmware":"FW1","ip":"10.0.0.5","battery":87.5,"ssid":"HALA",
 "mqtt_server":"mqtt.stary.cz","mqtt_port":1883,"brightness":80,
 "last_seen":"2026-07-08 10:00:00",
 "devices":[{"type":"pumA","baseAddress":128,"buttons":[0,1]}],
 "desired":{"broker":{"address":"mqtt.firma.cz","port":1883,"user":"u1","password":"tajne"},
            "wifi":{"ssid":"HALA","password":"w"}},
 "desired_updated_at":"2026-07-08 09:00:00","desired_updated_by":"radek",
 "name":"Regál 12","location":"Sklad B","note":null,"status":"active"}}''';

void main() {
  group('UnitDbSummary', () {
    test('parsing + matches filtruje přes id/název/umístění', () {
      final units = (jsonDecode(_listBody)['units'] as List)
          .cast<Map<String, dynamic>>()
          .map(UnitDbSummary.fromJson)
          .toList();
      expect(units, hasLength(2));
      expect(units.first.name, 'Regál 12');
      expect(units.first.matches('regál'), isTrue);
      expect(units.first.matches('sklad'), isTrue);
      expect(units.first.matches('1209'), isTrue);
      expect(units.first.matches('xyz'), isFalse);
      expect(units.last.matches(''), isTrue);
    });
  });

  group('UnitDbCard', () {
    test('parsing vč. devices (PumaModule.fromJson) a SQLite času', () {
      final card = UnitDbCard.fromJson(
          jsonDecode(_cardBody)['unit'] as Map<String, dynamic>);
      expect(card.devices, hasLength(1));
      expect(card.devices.first.baseAddress, 128);
      expect(card.lastSeen, DateTime.utc(2026, 7, 8, 10));
      expect(card.desiredUpdatedBy, 'radek');
    });

    test('driftWarnings: broker nesouhlasí, wifi souhlasí', () {
      final card = UnitDbCard.fromJson(
          jsonDecode(_cardBody)['unit'] as Map<String, dynamic>);
      // desired broker = mqtt.firma.cz, observed = mqtt.stary.cz → drift
      expect(card.driftWarnings, hasLength(1));
      expect(card.driftWarnings.single, contains('mqtt.firma.cz'));
      expect(card.driftWarnings.single, contains('mqtt.stary.cz'));
    });

    test('driftWarnings přes seen_on_broker (jen ALIVE, bez get_param)', () {
      // Scénář z praxe: jednotka přeconfigurovaná mimo appku — mqtt_server
      // (get_param) chybí, ale ALIVE přišel přes jiný broker než v evidenci.
      final card = UnitDbCard.fromJson({
        'id': '1209',
        'generation': 'new',
        'status': 'active',
        'seen_on_broker': 'config.smartbox4you.com',
        'desired': {
          'broker': {'address': 'mqtt.smartbox.smartci4.com'},
        },
      });
      expect(card.driftWarnings, hasLength(1));
      expect(card.driftWarnings.single, contains('config.smartbox4you.com'));

      // Když get_param i seen-on hlásí totéž (oba ≠ evidence), varování je jen
      // jedno — neduplikovat.
      final card2 = UnitDbCard.fromJson({
        'id': '1209',
        'generation': 'new',
        'status': 'active',
        'mqtt_server': 'config.smartbox4you.com',
        'seen_on_broker': 'config.smartbox4you.com',
        'desired': {
          'broker': {'address': 'mqtt.smartbox.smartci4.com'},
        },
      });
      expect(card2.driftWarnings, hasLength(1));
    });

    test('unit_config parsing (GET-CONFIG snapshot, DB5)', () {
      final card = UnitDbCard.fromJson({
        'id': '1209',
        'generation': 'new',
        'status': 'active',
        'unit_config': {'mqttAddress': 'mqtt.firma.cz', 'actualIp': '10.0.0.9'},
        'unit_config_fetched_at': '2026-07-16 10:00:00',
      });
      expect(card.unitConfig!['mqttAddress'], 'mqtt.firma.cz');
      expect(card.unitConfigFetchedAt, '2026-07-16 10:00:00');
    });

    test('drift v2 kat.2: nastaveno vs. běží (statická IP × DHCP)', () {
      final card = UnitDbCard.fromJson({
        'id': '1209',
        'generation': 'new',
        'status': 'active',
        'unit_config': {
          'ip': '10.0.0.72',
          'actualIp': '10.0.0.150',
          'SSID': 'HALA',
          'actualSSID': 'HALA',
        },
      });
      expect(card.driftWarnings, hasLength(1));
      expect(card.driftWarnings.single, contains('10.0.0.72'));
      expect(card.driftWarnings.single, contains('10.0.0.150'));

      // "0.0.0.0" = statická IP vypnutá → neporovnává se.
      final dhcp = UnitDbCard.fromJson({
        'id': '1209',
        'generation': 'new',
        'status': 'active',
        'unit_config': {'ip': '0.0.0.0', 'actualIp': '10.0.0.150'},
      });
      expect(dhcp.driftWarnings, isEmpty);
    });

    test('drift v2 kat.1: evidence vs. uloženo v jednotce (GET-CONFIG)', () {
      final card = UnitDbCard.fromJson({
        'id': '1209',
        'generation': 'new',
        'status': 'active',
        'unit_config': {'mqttAddress': 'mqtt.stary.cz'},
        'desired': {
          'broker': {'address': 'mqtt.novy.cz'},
        },
      });
      expect(card.driftWarnings,
          contains(predicate<String>((w) => w.contains('uloženo v jednotce'))));
    });

    test('driftWarnings nedupluje broker, když uloženo == hlásí', () {
      final card = UnitDbCard.fromJson({
        'id': '1888',
        'generation': 'new',
        'status': 'active',
        'mqtt_server': 'mqtt.config.smartci4.com',
        'unit_config': {'mqttAddress': 'mqtt.config.smartci4.com'},
        'desired': {
          'broker': {'address': 'mqtt.dev.smartci4.com'},
        },
      });
      // Jen jedno hlášení (kat.1 „uloženo"), ne duplicitní „jednotka hlásí".
      expect(card.driftWarnings, hasLength(1));
      expect(card.driftWarnings.single, contains('uloženo v jednotce'));
    });

    test('driftWarnings ukáže „uloženo" i „hlásí", když se běží liší', () {
      final card = UnitDbCard.fromJson({
        'id': '1888',
        'generation': 'new',
        'status': 'active',
        'mqtt_server': 'mqtt.bezi.cz',
        'unit_config': {'mqttAddress': 'mqtt.ulozeno.cz'},
        'desired': {
          'broker': {'address': 'mqtt.dev.cz'},
        },
      });
      // Tři různé hodnoty (evidence/uloženo/běží) → dvě různá hlášení.
      expect(card.driftWarnings, hasLength(2));
    });

    test('driftWarnings: čekající změna (neviděno od změny) → nic', () {
      final card = UnitDbCard.fromJson({
        'id': '1888',
        'generation': 'new',
        'status': 'active',
        // Poslední pozorování PŘED změnou evidence → čekající, nehlásit.
        'last_seen': '2026-07-22 16:00:00',
        'desired_updated_at': '2026-07-22 16:59:00',
        'mqtt_server': 'mqtt.config.smartci4.com',
        'unit_config': {'mqttAddress': 'mqtt.config.smartci4.com'},
        'desired': {
          'broker': {'address': 'mqtt.dev.smartci4.com'},
        },
      });
      expect(card.driftWarnings, isEmpty);
    });

    test('driftWarnings: viděno až po změně → nesoulad se hlásí', () {
      final card = UnitDbCard.fromJson({
        'id': '1888',
        'generation': 'new',
        'status': 'active',
        'last_seen': '2026-07-22 17:05:00',
        'desired_updated_at': '2026-07-22 16:59:00',
        'mqtt_server': 'mqtt.config.smartci4.com',
        'unit_config': {'mqttAddress': 'mqtt.config.smartci4.com'},
        'desired': {
          'broker': {'address': 'mqtt.dev.smartci4.com'},
        },
      });
      expect(card.driftWarnings, isNotEmpty);
    });
  });

  group('acceptObservedFragment', () {
    test('broker z observed, credentials zůstávají; jen driftující klíče', () {
      final card = UnitDbCard.fromJson(
          jsonDecode(_cardBody)['unit'] as Map<String, dynamic>);
      // drift: broker (evidence mqtt.firma.cz vs observed mqtt.stary.cz);
      // wifi souhlasí (HALA == HALA) → do fragmentu nepatří.
      final f = card.acceptObservedFragment()!;
      expect(f.keys, ['broker']);
      expect(f['broker']['address'], 'mqtt.stary.cz');
      expect(f['broker']['port'], 1883);
      expect(f['broker']['user'], 'u1'); // credentials zachované
      expect(f['broker']['password'], 'tajne');
    });

    test('seen_on_broker fallback bez get_param; bez driftu → null', () {
      final card = UnitDbCard.fromJson({
        'id': '1209',
        'generation': 'new',
        'status': 'active',
        'seen_on_broker': 'config.smartbox4you.com',
        'desired': {
          'broker': {'address': 'mqtt.smartbox.smartci4.com', 'password': 'x'},
        },
      });
      final f = card.acceptObservedFragment()!;
      expect(f['broker']['address'], 'config.smartbox4you.com');
      expect(f['broker']['password'], 'x');

      final noDrift = UnitDbCard.fromJson({
        'id': '1209',
        'generation': 'new',
        'status': 'active',
        'seen_on_broker': 'a',
        'desired': {
          'broker': {'address': 'a'},
        },
      });
      expect(noDrift.acceptObservedFragment(), isNull);
    });

    test('GET-CONFIG mqttAddress/port má přednost před get_param', () {
      final card = UnitDbCard.fromJson({
        'id': '1209',
        'generation': 'new',
        'status': 'active',
        'mqtt_server': 'mqtt.stary.cz',
        'mqtt_port': 1883,
        'unit_config': {'mqttAddress': 'mqtt.config.cz', 'mqttPort': 8883},
        'desired': {
          'broker': {'address': 'mqtt.evidence.cz', 'password': 'x'},
        },
      });
      final f = card.acceptObservedFragment()!;
      expect(f['broker']['address'], 'mqtt.config.cz'); // GET-CONFIG autoritativní
      expect(f['broker']['port'], 8883);
      expect(f['broker']['password'], 'x'); // credentials zachované
    });
  });

  group('UnitDbListScreen', () {
    testWidgets('zobrazí seznam a vyhledávání filtruje', (tester) async {
      final service = _service((r) async => http.Response(_listBody, 200));
      await tester.pumpWidget(
          MaterialApp(home: UnitDbListScreen(service: service)));
      await tester.pumpAndSettle();

      expect(find.text('1209'), findsOneWidget);
      expect(find.text('128'), findsOneWidget);
      // Drift příznak ze serveru → oranžový trojúhelník jen u 1209.
      expect(find.byIcon(Icons.warning_amber), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'regál');
      await tester.pumpAndSettle();
      expect(find.text('1209'), findsOneWidget);
      expect(find.text('128'), findsNothing);
    });

    testWidgets('chyba serveru → hláška + Zkusit znovu → data', (tester) async {
      var calls = 0;
      final service = _service((r) async {
        calls++;
        if (calls == 1) throw Exception('offline');
        return http.Response(_listBody, 200);
      });
      await tester.pumpWidget(
          MaterialApp(home: UnitDbListScreen(service: service)));
      await tester.pumpAndSettle();

      expect(find.textContaining('Server nedostupný'), findsOneWidget);
      await tester.tap(find.text('Zkusit znovu'));
      await tester.pumpAndSettle();
      expect(find.text('1209'), findsOneWidget);
    });

    testWidgets('návrat z detailu obnoví seznam (změna meta se propíše)',
        (tester) async {
      var listCalls = 0;
      final service = _service((r) async {
        if (r.url.path.endsWith('/units') || r.url.path.endsWith('/units/')) {
          listCalls++;
          // Druhé načtení vrátí změněný název — simulace editace na kartě.
          return http.Response(
              listCalls == 1
                  ? _listBody
                  : _listBody.replaceFirst('Regál 12', 'Regál 99'),
              200);
        }
        if (r.url.path.endsWith('/history')) {
          return http.Response('{"history":[]}', 200);
        }
        return http.Response(_cardBody, 200);
      });
      await tester.pumpWidget(
          MaterialApp(home: UnitDbListScreen(service: service)));
      await tester.pumpAndSettle();
      expect(find.textContaining('Regál 12'), findsOneWidget);

      // Do detailu a zpět.
      await tester.tap(find.text('1209'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(listCalls, 2, reason: 'návrat z karty má seznam obnovit');
      expect(find.textContaining('Regál 99'), findsOneWidget);
    });

    testWidgets('filtr stavu Vadná ukáže jen vadné', (tester) async {
      final service = _service((r) async => http.Response(_listBody, 200));
      await tester.pumpWidget(
          MaterialApp(home: UnitDbListScreen(service: service)));
      await tester.pumpAndSettle();

      // Otevři dropdown „Stav" a vyber „Vadná" (v otevřeném menu je
      // poslední výskyt — overlay je v stromu nejníž).
      await tester.tap(find.ancestor(
        of: find.text('Stav'),
        matching: find.byType(DropdownButtonFormField<String?>),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Vadná').last);
      await tester.pumpAndSettle();
      expect(find.text('128'), findsOneWidget);
      expect(find.text('1209'), findsNothing);
    });

    testWidgets('filtr zákazníka ukáže jen jeho jednotky', (tester) async {
      final service = _service((r) async => http.Response(_listBody, 200));
      await tester.pumpWidget(
          MaterialApp(home: UnitDbListScreen(service: service)));
      await tester.pumpAndSettle();

      // Otevři dropdown „Zákazník" a vyber „Regál 12" (má ho jen 1209).
      await tester.tap(find.ancestor(
        of: find.text('Zákazník'),
        matching: find.byType(DropdownButtonFormField<String?>),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Regál 12').last);
      await tester.pumpAndSettle();
      expect(find.text('1209'), findsOneWidget);
      expect(find.text('128'), findsNothing);
    });

    testWidgets('výběr vše + hromadná editace evidence → POST /bulk/desired',
        (tester) async {
      http.Request? bulkPost;
      final service = _service((r) async {
        if (r.method == 'POST' &&
            r.url.path.endsWith('/bulk/common-desired')) {
          return http.Response('{"common":{}}', 200);
        }
        if (r.method == 'POST' && r.url.path.endsWith('/bulk/desired')) {
          bulkPost = r;
          return http.Response('{"ok":true,"count":2}', 200);
        }
        return http.Response(_listBody, 200);
      });
      await tester.pumpWidget(
          MaterialApp(home: UnitDbListScreen(service: service)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Vybrat vše'));
      await tester.pumpAndSettle();
      expect(find.text('Vybráno: 2'), findsOneWidget);

      await tester.tap(find.byTooltip('Hromadné úpravy'));
      await tester.pumpAndSettle();
      // Non-admin → „Smazat" v menu není.
      expect(find.text('Smazat'), findsNothing);
      await tester.tap(find.text('Změnit parametry'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, 'SSID'), 'NovaSit');
      await tester.tap(find.text('Uložit'));
      await tester.pumpAndSettle();

      expect(bulkPost, isNotNull);
      final body = jsonDecode(bulkPost!.body) as Map<String, dynamic>;
      expect((body['ids'] as List).length, 2);
      expect(body['fragment']['wifi']['ssid'], 'NovaSit');
    });

    testWidgets('hromadná editace předvyplní společné hodnoty vybraných',
        (tester) async {
      final service = _service((r) async {
        if (r.method == 'POST' &&
            r.url.path.endsWith('/bulk/common-desired')) {
          return http.Response(
              '{"common":{"wifi":{"ssid":"SpolecnaSit"},"brightness":50}}',
              200);
        }
        return http.Response(_listBody, 200);
      });
      await tester.pumpWidget(
          MaterialApp(home: UnitDbListScreen(service: service)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Vybrat vše'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Hromadné úpravy'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Změnit parametry'));
      await tester.pumpAndSettle();

      // Společná pole se předvyplnila (SSID + jas P2L LED).
      expect(find.text('SpolecnaSit'), findsOneWidget);
      expect(find.text('50'), findsOneWidget);
    });

    testWidgets('hromadné smazání (admin) → potvrzení počtu → POST /bulk/delete',
        (tester) async {
      http.Request? bulkDel;
      final service = _service((r) async {
        if (r.method == 'POST' && r.url.path.endsWith('/bulk/delete')) {
          bulkDel = r;
          return http.Response('{"ok":true,"count":2}', 200);
        }
        return http.Response(_listBody, 200);
      }, admin: true);
      await tester.pumpWidget(
          MaterialApp(home: UnitDbListScreen(service: service)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Vybrat vše'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Hromadné úpravy'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Smazat'));
      await tester.pumpAndSettle();

      // Bez opsání počtu je tlačítko Smazat v dialogu neaktivní.
      final delBtn = find.widgetWithText(FilledButton, 'Smazat');
      expect(tester.widget<FilledButton>(delBtn).onPressed, isNull);
      await tester.enterText(find.byType(TextField).last, '2');
      await tester.pumpAndSettle();
      await tester.tap(delBtn);
      await tester.pumpAndSettle();

      expect(bulkDel, isNotNull);
      expect((jsonDecode(bulkDel!.body)['ids'] as List).length, 2);
    });

    testWidgets('reset filtrů vrátí seznam na vše', (tester) async {
      final service = _service((r) async => http.Response(_listBody, 200));
      await tester.pumpWidget(
          MaterialApp(home: UnitDbListScreen(service: service)));
      await tester.pumpAndSettle();

      // Nastav filtr stavu na Vadná → jen 128.
      await tester.tap(find.ancestor(
        of: find.text('Stav'),
        matching: find.byType(DropdownButtonFormField<String?>),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Vadná').last);
      await tester.pumpAndSettle();
      expect(find.text('1209'), findsNothing);

      // Tlačítko „Zrušit filtry" → obě jednotky zpět.
      await tester.tap(find.byTooltip('Zrušit filtry'));
      await tester.pumpAndSettle();
      expect(find.text('128'), findsOneWidget);
      expect(find.text('1209'), findsOneWidget);
    });
  });

  group('UnitDbDetailScreen', () {
    testWidgets('zobrazí kartu, hesla maskovaná + drift banner', (tester) async {
      // Detail je ListView — vyšší viewport, ať jsou vidět všechny sekce
      // (desired s hesly a historie jsou dole).
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final service = _service((r) async {
        if (r.url.path.endsWith('/history')) {
          return http.Response(
              '{"history":[{"at":"2026-07-08 09:00:00","username":"radek",'
              '"action":"desired","detail":{"wifi":{"ssid":"HALA"}}}]}',
              200);
        }
        return http.Response(_cardBody, 200);
      });
      await tester.pumpWidget(MaterialApp(
          home: UnitDbDetailScreen(unitId: '1209', service: service)));
      await tester.pumpAndSettle();

      expect(find.text('Nesouhlasí s evidencí'), findsOneWidget);
      expect(find.text('••••••'), findsNWidgets(2)); // broker + wifi heslo
      expect(find.textContaining('tajne'), findsNothing);
      // displayLabel — vidět i počet/čísla tlačítek (a případné LEDS)
      expect(find.textContaining('PUM-A @128 · 2 tl. (0,1)'), findsOneWidget);

      // Oko odmaskuje hesla.
      await tester.tap(find.byIcon(Icons.visibility));
      await tester.pumpAndSettle();
      expect(find.text('tajne'), findsOneWidget);

      // Historie.
      expect(find.textContaining('Konfigurace — radek'), findsOneWidget);
    });

    testWidgets('sloučené pohledy: shoda → ✓, rozdíl → evidence/uloženo/běží',
        (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // Broker souhlasí ve všech třech pohledech; WiFi se liší
      // (evidence StaraSit vs. uloženo/běží NovaSit).
      const body = '''
{"unit":{"id":"1209","generation":"new","status":"active",
 "mqtt_server":"mqtt.demo.cz","mqtt_port":1883,"ssid":"NovaSit",
 "unit_config":{"mqttAddress":"mqtt.demo.cz","mqttPort":1883,
                "SSID":"NovaSit","actualSSID":"NovaSit"},
 "desired":{"broker":{"address":"mqtt.demo.cz","port":1883},
            "wifi":{"ssid":"StaraSit"}}}}''';
      final service = _service((r) async {
        if (r.url.path.endsWith('/history')) {
          return http.Response('{"history":[]}', 200);
        }
        return http.Response(body, 200);
      });
      await tester.pumpWidget(MaterialApp(
          home: UnitDbDetailScreen(unitId: '1209', service: service)));
      await tester.pumpAndSettle();

      // Broker: jedna hodnota se ✓ (shoda tří zdrojů).
      expect(find.textContaining('mqtt.demo.cz:1883  ✓'), findsOneWidget);
      // WiFi: rozepsané pohledy s popisky a oběma hodnotami.
      expect(find.text('evidence'), findsOneWidget);
      expect(find.text('uloženo'), findsOneWidget);
      expect(find.text('běží'), findsOneWidget);
      expect(find.text('StaraSit'), findsOneWidget);
      // NovaSit je uloženo i běží → dvě hodnoty.
      expect(find.text('NovaSit'), findsNWidgets(2));
    });

    testWidgets('Převzít skutečnost do evidence → PUT desired + reload',
        (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      http.Request? desiredPut;
      var cardLoads = 0;
      final service = _service((r) async {
        if (r.method == 'PUT' && r.url.path.endsWith('/desired')) {
          desiredPut = r;
          return http.Response('{"ok":true,"id":"1209"}', 200);
        }
        if (r.url.path.endsWith('/history')) {
          return http.Response('{"history":[]}', 200);
        }
        cardLoads++;
        // Po převzetí vrátit kartu bez driftu (desired = observed broker).
        return http.Response(
            cardLoads <= 1
                ? _cardBody
                : _cardBody.replaceAll('mqtt.firma.cz', 'mqtt.stary.cz'),
            200);
      });
      await tester.pumpWidget(MaterialApp(
          home: UnitDbDetailScreen(unitId: '1209', service: service)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Převzít skutečnost do evidence'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Převzít')); // potvrzení dialogu
      await tester.pumpAndSettle();

      expect(desiredPut, isNotNull);
      final body = jsonDecode(desiredPut!.body) as Map<String, dynamic>;
      expect(body['broker']['address'], 'mqtt.stary.cz');
      expect(body['broker']['password'], 'tajne'); // credentials zachované
      // Karta se obnovila a drift banner zmizel.
      expect(find.text('Nesouhlasí s evidencí'), findsNothing);
    });

    testWidgets('ruční editace evidence → PUT desired, hesla zachovaná',
        (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      http.Request? desiredPut;
      final service = _service((r) async {
        if (r.method == 'PUT' && r.url.path.endsWith('/desired')) {
          desiredPut = r;
          return http.Response('{"ok":true,"id":"1209"}', 200);
        }
        if (r.url.path.endsWith('/history')) {
          return http.Response('{"history":[]}', 200);
        }
        return http.Response(_cardBody, 200);
      });
      await tester.pumpWidget(MaterialApp(
          home: UnitDbDetailScreen(unitId: '1209', service: service)));
      await tester.pumpAndSettle();

      // Tlačítko editace evidence v sekci Konfigurace (ne meta v AppBaru).
      await tester.tap(find.byTooltip('Upravit evidenci ručně'));
      await tester.pumpAndSettle();

      // Přepiš adresu brokeru (předvyplněná z evidence mqtt.firma.cz).
      await tester.enterText(
          find.widgetWithText(TextField, 'Adresa'), 'mqtt.zakaznik.cz');
      await tester.tap(find.text('Uložit'));
      await tester.pumpAndSettle();

      expect(desiredPut, isNotNull);
      final body = jsonDecode(desiredPut!.body) as Map<String, dynamic>;
      expect(body['broker']['address'], 'mqtt.zakaznik.cz');
      // Port a heslo předvyplněná z evidence → zachovaná (merge celý objekt).
      expect(body['broker']['port'], 1883);
      expect(body['broker']['password'], 'tajne');
      expect(body['wifi']['ssid'], 'HALA');
    });
  });
}
