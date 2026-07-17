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
}
