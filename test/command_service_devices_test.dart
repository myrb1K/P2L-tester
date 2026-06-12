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

    test('DEVICE-REPLACE — UNIT topic, payload From/To', () {
      // From = factory default nového kusu, To = adresa vadného.
      final cmd = CommandService.buildDeviceReplaceCommand(
        unitId: '001001',
        fromAddress: 127,
        toAddress: 1,
      );
      expect(cmd.topic, 'I/001001/UNIT/001001/DEVICE-REPLACE');
      expect(cmd.payload, '{"From":127,"To":1}');
    });

    test('DEVICE-REPLACE padding 4-digit ID na 6-digit', () {
      final cmd = CommandService.buildDeviceReplaceCommand(
        unitId: '1017',
        fromAddress: 246,
        toAddress: 128,
      );
      expect(cmd.topic, 'I/001017/UNIT/001017/DEVICE-REPLACE');
      expect(cmd.payload, '{"From":246,"To":128}');
    });

    test('DEVICE-SET-ID — UNIT topic, payload From/To', () {
      final cmd = CommandService.buildDeviceSetIdCommand(
        unitId: '001001',
        fromAddress: 128,
        toAddress: 130,
      );
      expect(cmd.topic, 'I/001001/UNIT/001001/DEVICE-SET-ID');
      expect(cmd.payload, '{"From":128,"To":130}');
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
    test('LEDS default = 0 (DEVICE-REPLACE samostatně nepodporován)', () {
      expect(CommandService.defaultReplacementAddress(DeviceType.leds), 0);
    });
    test('supportsReplace pro DIST, DISP a BTN — LEDS ne', () {
      expect(CommandService.supportsReplace(DeviceType.dist), true);
      expect(CommandService.supportsReplace(DeviceType.disp), true);
      expect(CommandService.supportsReplace(DeviceType.btn), true);
      expect(CommandService.supportsReplace(DeviceType.leds), false);
    });
  });

  group('ModuleType.addressRange', () {
    test('PUM-A: 128–246, default 246', () {
      expect(ModuleType.pumA.addressRange, (min: 128, max: 246));
      expect(ModuleType.pumA.defaultAddress, 246);
    });
    test('PUM-B: 128–247, default 247', () {
      expect(ModuleType.pumB.addressRange, (min: 128, max: 247));
      expect(ModuleType.pumB.defaultAddress, 247);
    });
    test('PUM-C: 128–247, default 247', () {
      expect(ModuleType.pumC.addressRange, (min: 128, max: 247));
      expect(ModuleType.pumC.defaultAddress, 247);
    });
    test('DIST: 1–127, default 127', () {
      expect(ModuleType.dist.addressRange, (min: 1, max: 127));
      expect(ModuleType.dist.defaultAddress, 127);
    });
  });

  group('buildUpdateCommand', () {
    test('produkuje payload podle README-P2L specifikace', () {
      final payload = CommandService.buildUpdateCommand(
        fileName: 'http://185.149.129.164/download/P2L_26033101NT.bin',
      );
      final decoded = jsonDecode(payload) as Map<String, dynamic>;
      expect(decoded['request_id'], -1);
      final cmds = decoded['cmds'] as List;
      expect(cmds.length, 1);
      final cmd = cmds.first as Map<String, dynamic>;
      expect(cmd['cmd'], 'update');
      expect(
        (cmd['args'] as Map)['file_name'],
        'http://185.149.129.164/download/P2L_26033101NT.bin',
      );
    });

    test('relativní cesta v file_name se neupravuje', () {
      final payload = CommandService.buildUpdateCommand(
        fileName: 'data/P2L_23091201OT.bin',
      );
      final cmd = (jsonDecode(payload) as Map)['cmds'][0] as Map;
      expect((cmd['args'] as Map)['file_name'], 'data/P2L_23091201OT.bin');
    });
  });
}
