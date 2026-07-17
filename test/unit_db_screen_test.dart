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
import 'package:p2l_tester/services/auth_session.dart';
import 'package:p2l_tester/services/unit_db_service.dart';

UnitDbService _service(MockClientHandler handler) {
  final session = AuthSession()
    ..status = AuthSessionStatus.loggedIn
    ..apiBase = 'http://server:3001/api';
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

      await tester.tap(find.text('Vadná'));
      await tester.pumpAndSettle();
      expect(find.text('128'), findsOneWidget);
      expect(find.text('1209'), findsNothing);
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
  });
}
