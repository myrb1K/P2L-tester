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
        newDefaultAddress: 247,
      );
      expect(cmd.topic, 'I/001001/DISP/050128/REPLACE-FROM');
      expect(cmd.payload, '{"Id":247}');
    });
  });

  group('ADD-DEVICES payload', () {
    test('Příklad z README: PUM-A 128 (DISP+LEDS+2BTN) + DIST 98', () {
      final modules = [
        const PumaModule.pumA(address: 128, buttonCount: 2, hasLeds: true),
        PumaModule.dist(address: 98),
      ];
      final cmd = CommandService.buildAddDevicesCommand('001001', modules);
      expect(cmd.topic, 'I/001001/UNIT/001001/ADD-DEVICES');

      final decoded = jsonDecode(cmd.payload) as List;
      // Očekáváme entries pro BTN, DISP, LEDS, DIST
      final byType = {for (final e in decoded) (e as Map)['Type']: e['Id']};
      expect(byType['BTN'], unorderedEquals([1128, 2128]));
      expect(byType['DISP'], [128]);
      expect(byType['LEDS'], [128]);
      expect(byType['DIST'], isNotNull);
      // DIST je vnořené pole s configem
      expect((byType['DIST'] as List)[0], isA<List>());
      expect(((byType['DIST'] as List)[0] as List)[0], 98);
    });

    test('Příklad PUM-A s 1 tl. + PUM-C + PUM-B', () {
      final modules = [
        const PumaModule.pumA(address: 128, buttonCount: 1, hasLeds: true),
        const PumaModule.pumC(address: 130),
        const PumaModule.pumB(address: 200),
      ];
      final cmd = CommandService.buildAddDevicesCommand('001001', modules);
      final decoded = jsonDecode(cmd.payload) as List;
      final byType = {for (final e in decoded) (e as Map)['Type']: e['Id']};

      // PUM-A s 1 tl. → BTN 128 (sdílí s DISP); PUM-C → 1130, 130; PUM-B → 200
      expect(byType['BTN'], unorderedEquals([128, 1130, 130, 200]));
      expect(byType['DISP'], [128]);
      expect(byType['LEDS'], [128]);
      expect(byType.containsKey('DIST'), false);
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

  group('Default addresses', () {
    test('DIST default = 127', () {
      expect(CommandService.defaultReplacementAddress(DeviceType.dist), 127);
    });
    test('DISP default = 247', () {
      expect(CommandService.defaultReplacementAddress(DeviceType.disp), 247);
    });
    test('supportsReplace jen DIST a DISP', () {
      expect(CommandService.supportsReplace(DeviceType.dist), true);
      expect(CommandService.supportsReplace(DeviceType.disp), true);
      expect(CommandService.supportsReplace(DeviceType.btn), false);
      expect(CommandService.supportsReplace(DeviceType.leds), false);
    });
  });
}
