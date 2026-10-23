// Testy GET-CONFIG (DB5) na modelu P2LUnit a builderu.
// Interní tool ukládá do evidence i SKUTEČNÁ hesla — FW je vrátí, když
// request nese User/Password. Ověřujeme, že se do snapshotu dostanou a že
// se z GET-CONFIG osvěží firmware/MAC.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:p2l_tester/models/unit.dart';
import 'package:p2l_tester/services/command_service.dart';

// Reálná odpověď z jednotky 1209 (FW 26071501NT) na credentialovaný GET-CONFIG.
const _realConfig = {
  'Id': 1209,
  'ver': '26071501NT',
  'mac': '88:57:21:40:E6:6C',
  'SSID': 'Smartbox',
  'PSWD': 'Smartbox2021',
  'mqttPassword': 'smartbox2022',
  'mqttAddress': 'mqtt.config.smartci4.com',
  'mqttPort': 1883,
  'mqttUser': 'smartbox_user',
  'mqttInsec': true,
  'mqttCert': false,
  'ip': '', // DHCP = prázdný string (ne "0.0.0.0")
  'dns': '',
  'gateway': '',
  'subnet': '',
  'actualIp': '192.168.0.198',
  'actualSSID': 'Smartbox',
};

void main() {
  group('buildGetConfigCommand payload', () {
    test('bez přihlašovacích údajů → prázdný payload (bool hesla)', () {
      final cmd = CommandService.buildGetConfigCommand('1209');
      expect(cmd.topic, 'I/001209/UNIT/001209/GET-CONFIG');
      expect(cmd.payload, '{}');
    });

    test('s přihlašovacími údaji → User/Password (skutečná hesla)', () {
      final cmd = CommandService.buildGetConfigCommand('1209',
          user: 'admin', password: 'smartbox');
      final body = jsonDecode(cmd.payload) as Map<String, dynamic>;
      expect(body['User'], 'admin');
      expect(body['Password'], 'smartbox');
    });
  });

  group('P2LUnit.updateFromGetConfig', () {
    test('uloží kompletní snapshot vč. skutečných hesel', () {
      final u = P2LUnit(id: '1209', isNewGen: true);
      u.updateFromGetConfig(Map<String, dynamic>.from(_realConfig));
      expect(u.unitConfig!['PSWD'], 'Smartbox2021');
      expect(u.unitConfig!['mqttPassword'], 'smartbox2022');
      expect(u.unitConfig!['actualIp'], '192.168.0.198');
      // Firmware a MAC se z GET-CONFIG osvěží.
      expect(u.firmware, '26071501NT');
      expect(u.mac, '88:57:21:40:E6:6C');
    });
  });

  group('P2LUnit uložený vs. připojený broker', () {
    P2LUnit unitWith({String? stored, String? running}) {
      final u = P2LUnit(id: '1158', isNewGen: true, mqttServer: running);
      if (stored != null) {
        u.updateFromGetConfig({
          ..._realConfig,
          'Id': 1158,
          'mqttAddress': stored,
          'mqttPort': 8883,
        });
      }
      return u;
    }

    test('uložený almeco, připojena na servisní → rozdíl + servisní režim', () {
      // Reálná situace jednotky 1158.
      final u = unitWith(
        stored: 'mqtt.almeco.smartci4.com',
        running: 'config.smartbox4you.com',
      );
      expect(u.brokerDiffers, isTrue);
      expect(u.inServiceMode, isTrue);
      expect(u.storedMqttServer, 'mqtt.almeco.smartci4.com');
      expect(u.storedMqttPort, 8883);
    });

    test('připojena k uloženému → bez rozdílu', () {
      final u = unitWith(
        stored: 'mqtt.config.smartci4.com',
        running: 'mqtt.config.smartci4.com',
      );
      expect(u.brokerDiffers, isFalse);
      expect(u.inServiceMode, isFalse);
    });

    test('IP vs. doména → rozdíl, ale ne servisní režim', () {
      final u = unitWith(stored: 'tigo.home', running: '172.16.101.192');
      expect(u.brokerDiffers, isTrue);
      expect(u.inServiceMode, isFalse);
    });

    test('servisní broker záměrně uložený → ne servisní režim', () {
      final u = unitWith(
        stored: 'mqtt.config.smartci4.com',
        running: 'config.smartbox4you.com',
      );
      expect(u.brokerDiffers, isTrue);
      expect(u.inServiceMode, isFalse);
    });

    test('servisní WiFi „Service" → servisní režim i bez get_param', () {
      final u = P2LUnit(id: '1266', isNewGen: true);
      u.updateFromGetConfig({
        ..._realConfig,
        'Id': 1266,
        'mqttAddress': '192.168.10.140',
        'SSID': '',
        'actualSSID': 'Service',
      });
      expect(u.mqttServer, isNull);
      expect(u.brokerDiffers, isFalse);
      expect(u.onServiceWifi, isTrue);
      expect(u.inServiceMode, isTrue);

      // „Service" uložená záměrně jako vlastní WiFi → servis to není.
      u.updateFromGetConfig({
        ..._realConfig,
        'SSID': 'Service',
        'actualSSID': 'Service',
      });
      expect(u.inServiceMode, isFalse);
    });

    test('bez GET-CONFIG / bez get_param / prázdné uloženo → nelze určit', () {
      expect(unitWith(running: 'config.smartbox4you.com').brokerDiffers, isFalse);
      expect(unitWith(stored: 'mqtt.almeco.smartci4.com').brokerDiffers, isFalse);
      final empty = unitWith(stored: '', running: 'config.smartbox4you.com');
      expect(empty.storedMqttServer, isNull);
      expect(empty.brokerDiffers, isFalse);
    });
  });

  group('P2LUnit.fromAlive', () {
    // Reálný UNIT ALIVE nové gen — klíče VELKÝMI písmeny. firmware musí být
    // známé hned z ALIVE, jinak fetchConfig (GET-CONFIG) na prvním ALIVE
    // no-opne (firmwareSupportsGetConfig(null)=false) → falešný drift.
    test('načte Firmware/Battery z klíčů velkými písmeny', () {
      final u = P2LUnit.fromAlive('1209', const {
        'HWModel': 'Unit32',
        'HWPart': '',
        'Firmware': '26071501NT',
        'Battery': 10.8,
        'Level': 'INFO',
        'Code': 0,
        'Message': 'OK',
      }, isNewGen: true);
      expect(u.firmware, '26071501NT');
      expect(u.battery, 10.8);
      expect(u.hwModel, 'Unit32');
    });

    test('fallback na malá písmena (starší formát)', () {
      final u = P2LUnit.fromAlive('472', const {
        'firmware': '25010101NT',
        'battery': 42,
      });
      expect(u.firmware, '25010101NT');
      expect(u.battery, 42.0);
    });
  });
}
