import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:p2l_tester/models/device.dart';
import 'package:p2l_tester/models/module.dart';
import 'package:p2l_tester/services/command_service.dart';

void main() {
  group('Device command topics', () {
    test('GET-DEVICES topic padding 4-digit ID na 6-digit', () {
      final cmd = CommandService.buildGetDevicesCommand('1017');
      expect(cmd.topic, 'I/001017/UNIT/001017/GET-DEVICES');
      expect(cmd.payload, '{}');
    });

    test('GET-DEVICES topic se 6-místným ID', () {
      final cmd = CommandService.buildGetDevicesCommand('001001');
      expect(cmd.topic, 'I/001001/UNIT/001001/GET-DEVICES');
    });

    test('REPLACE-FROM topic pro DIST', () {
      final cmd = CommandService.buildReplaceFromCommand(
        unitId: '001001',
        type: DeviceType.dist,
        oldAddress: 1,
        newDefaultAddress: 127,
      );
      expect(cmd.topic, 'I/001001/DIST/040001/REPLACE-FROM');
      expect(cmd.payload, '{"Id":127}');
    });

    test('REPLACE-FROM topic pro DISP', () {
      final cmd = CommandService.buildReplaceFromCommand(
        unitId: '001001',
        type: DeviceType.disp,
        oldAddress: 128,
        newDefaultAddress: 246,
      );
      expect(cmd.topic, 'I/001001/DISP/050128/REPLACE-FROM');
      expect(cmd.payload, '{"Id":246}');
    });
  });

  group('ADD-DEVICES payload', () {
    test('PUM-A 128 (DISP+LEDS+2BTN) + DIST 98', () {
      final modules = [
        const PumaModule.pumA(address: 128, buttonCount: 2, hasLeds: true),
        PumaModule.dist(address: 98),
      ];
      final cmd = CommandService.buildAddDevicesCommand('001001', modules);
      expect(cmd.topic, 'I/001001/UNIT/001001/ADD-DEVICES');

      final decoded = jsonDecode(cmd.payload) as List;
      final byType = {for (final e in decoded) (e as Map)['Type']: e['Id']};
      // PUM-A 2 tl.: levé = 1128, pravé = 128
      expect(byType['BTN'], unorderedEquals([1128, 128]));
      expect(byType['DISP'], [128]);
      expect(byType['LEDS'], [128]);
      expect(byType['DIST'], isNotNull);
      expect((byType['DIST'] as List)[0], isA<List>());
      expect(((byType['DIST'] as List)[0] as List)[0], 98);
    });

    test('PUM-A 128 s 1 tl. LEVÝM + PUM-C 130 + PUM-B 200', () {
      final modules = [
        const PumaModule.pumA(
          address: 128,
          buttonCount: 1,
          hasLeds: true,
          buttonSide: ButtonSide.left,
        ),
        const PumaModule.pumC(address: 129),
        const PumaModule.pumB(address: 200),
      ];
      final cmd = CommandService.buildAddDevicesCommand('001001', modules);
      final decoded = jsonDecode(cmd.payload) as List;
      final byType = {for (final e in decoded) (e as Map)['Type']: e['Id']};

      // PUM-A s 1 tl. levým → BTN 1128; PUM-C 129 → 1129, 129; PUM-B → 200
      expect(byType['BTN'], unorderedEquals([1128, 1129, 129, 200]));
      expect(byType['DISP'], [128]);
      expect(byType['LEDS'], [128]);
      expect(byType.containsKey('DIST'), false);
    });

    test('PUM-A s 1 tl. PRAVÝM → BTN N', () {
      final modules = [
        const PumaModule.pumA(
          address: 128,
          buttonCount: 1,
          buttonSide: ButtonSide.right,
        ),
      ];
      final cmd = CommandService.buildAddDevicesCommand('001001', modules);
      final decoded = jsonDecode(cmd.payload) as List;
      final byType = {for (final e in decoded) (e as Map)['Type']: e['Id']};
      expect(byType['BTN'], [128]);
      expect(byType['DISP'], [128]);
    });
  });

  group('DELETE-DEVICES payload', () {
    test('DIST se pošle bez configu (jen Id)', () {
      final modules = [PumaModule.dist(address: 98)];
      final cmd = CommandService.buildDeleteDevicesCommand('001001', modules);
      expect(cmd.topic, 'I/001001/UNIT/001001/DELETE-DEVICES');
      final decoded = jsonDecode(cmd.payload) as List;
      final dist = decoded.firstWhere((e) => (e as Map)['Type'] == 'DIST') as Map;
      expect(dist['Id'], [98]); // holé, bez configu
    });
  });

  group('Factory default addresses', () {
    test('DIST default = 127', () {
      expect(CommandService.defaultReplacementAddress(DeviceType.dist), 127);
    });
    test('DISP default = 246 (PUM-A)', () {
      expect(CommandService.defaultReplacementAddress(DeviceType.disp), 246);
    });
    test('BTN default = 247 (PUM-B / PUM-C)', () {
      expect(CommandService.defaultReplacementAddress(DeviceType.btn), 247);
    });
    test('LEDS default = 0 (REPLACE-FROM nedokumentován)', () {
      expect(CommandService.defaultReplacementAddress(DeviceType.leds), 0);
    });
    test('supportsReplace jen DIST a DISP', () {
      expect(CommandService.supportsReplace(DeviceType.dist), true);
      expect(CommandService.supportsReplace(DeviceType.disp), true);
      expect(CommandService.supportsReplace(DeviceType.btn), false);
      expect(CommandService.supportsReplace(DeviceType.leds), false);
    });
  });
}
