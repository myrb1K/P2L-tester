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
import 'package:p2l_tester/services/unit_db_service.dart';

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
}
