import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:p2l_tester/models/bus_scan.dart';
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

    test('GET-CONFIG topic + prázdný payload (DB5)', () {
      final cmd = CommandService.buildGetConfigCommand('1209');
      expect(cmd.topic, 'I/001209/UNIT/001209/GET-CONFIG');
      expect(cmd.payload, '{}');
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

    test('SCAN-DEVICES — scope all → bez Type', () {
      final cmd = CommandService.buildScanDevicesCommand(unitId: '1017');
      expect(cmd.topic, 'I/001017/UNIT/001017/SCAN-DEVICES');
      expect(cmd.payload, '{}');
    });

    test('SCAN-DEVICES — scope pum/dist → Type PUM/DIST', () {
      expect(
        CommandService.buildScanDevicesCommand(
                unitId: '001001', scope: BusScanScope.pum)
            .payload,
        '{"Type":"PUM"}',
      );
      expect(
        CommandService.buildScanDevicesCommand(
                unitId: '001001', scope: BusScanScope.dist)
            .payload,
        '{"Type":"DIST"}',
      );
    });

    test('SCAN-DEVICES — scanId → {"Id":N}, bez Type (typ z rozsahu)', () {
      final cmd = CommandService.buildScanDevicesCommand(
          unitId: '001001', scanId: 132);
      expect(cmd.topic, 'I/001001/UNIT/001001/SCAN-DEVICES');
      expect(cmd.payload, '{"Id":132}');
    });

    test('SCAN-DEVICES — scanId má přednost před scope', () {
      expect(
        CommandService.buildScanDevicesCommand(
                unitId: '001001', scope: BusScanScope.dist, scanId: 50)
            .payload,
        '{"Id":50}',
      );
    });

    test('GET-VALUE — DIST device topic, prázdný payload', () {
      final cmd =
          CommandService.buildGetValueCommand(unitId: '1017', distAddress: 67);
      expect(cmd.topic, 'I/001017/DIST/040067/GET-VALUE');
      expect(cmd.payload, '{}');
    });

    test('GET-ALIVE — device topic dle typu (prefix + adresa), prázdný payload',
        () {
      final disp = CommandService.buildGetAliveCommand(
          unitId: '1017', type: DeviceType.disp, address: 246);
      expect(disp.topic, 'I/001017/DISP/050246/GET-ALIVE');
      expect(disp.payload, '{}');

      final leds = CommandService.buildGetAliveCommand(
          unitId: '1017', type: DeviceType.leds, address: 128);
      expect(leds.topic, 'I/001017/LEDS/110128/GET-ALIVE');

      final btn = CommandService.buildGetAliveCommand(
          unitId: '1017', type: DeviceType.btn, address: 128);
      expect(btn.topic, 'I/001017/BTN/060128/GET-ALIVE');

      // PUM-A tlačítko s offsetem (1000+128) → BTN 061128.
      final btnOffset = CommandService.buildGetAliveCommand(
          unitId: '1017', type: DeviceType.btn, address: 1128);
      expect(btnOffset.topic, 'I/001017/BTN/061128/GET-ALIVE');

      final dist = CommandService.buildGetAliveCommand(
          unitId: '1017', type: DeviceType.dist, address: 67);
      expect(dist.topic, 'I/001017/DIST/040067/GET-ALIVE');
    });
  });

  group('ADD-DEVICES payload', () {
    test('PUM-A 128 (DISP+LEDS+2BTN) + DIST 98', () {
      final modules = [
        const PumaModule.pumA(
          address: 128,
          buttons: {PumaButton.leftInner, PumaButton.rightInner},
          hasLeds: true,
        ),
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
          buttons: {PumaButton.leftInner},
          hasLeds: true,
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

    test('PUM-A s 1 tl. holým N → BTN N', () {
      final modules = [
        const PumaModule.pumA(
          address: 128,
          buttons: {PumaButton.rightInner},
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

  group('DIST segmenty', () {
    const cfgWithSegments = DistConfig(
      measurePeriod: 50,
      timeout: 10,
      offset: 0,
      maxDeviation: 20,
      countMeasures: 4,
      measureType: 2,
      segments: [
        DistSegment(id: 'R01.A01', from: 0, to: 200),
        DistSegment(id: 'R01.A02', from: 300, to: 500),
      ],
    );

    test('SET-CONFIG přiloží Segments (objektový tvar) → zachová režim', () {
      final cmd = CommandService.buildSetDistConfigCommand(
        unitId: '001001',
        distAddress: 97,
        config: cfgWithSegments,
      );
      final decoded = jsonDecode(cmd.payload) as Map<String, dynamic>;
      expect(decoded['MeasurePeriod'], 50);
      final segs = decoded['Segments'] as List;
      expect(segs.length, 2);
      expect((segs[0] as Map)['SegmentId'], 'R01.A01');
      expect((segs[0] as Map)['From'], 0);
      expect((segs[0] as Map)['To'], 200);
    });

    test('SET-CONFIG bez segmentů pole Segments neposílá', () {
      final cmd = CommandService.buildSetDistConfigCommand(
        unitId: '001001',
        distAddress: 97,
        config: const DistConfig(),
      );
      final decoded = jsonDecode(cmd.payload) as Map<String, dynamic>;
      expect(decoded.containsKey('Segments'), false);
    });

    test('ADD-DEVICES vloží segmenty jako 8. prvek (poziční, 3 prvky)', () {
      final cmd = CommandService.buildAddDevicesCommand(
        '001001',
        [PumaModule.dist(address: 97, config: cfgWithSegments)],
      );
      final decoded = jsonDecode(cmd.payload) as List;
      final dist = decoded.firstWhere((e) => (e as Map)['Type'] == 'DIST') as Map;
      final entry = (dist['Id'] as List)[0] as List;
      expect(entry[0], 97);
      expect(entry.length, 8);
      final segs = entry[7] as List;
      expect(segs.length, 2);
      expect(segs[0], ['R01.A01', 0, 200]);
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

  group('firmwareSupportsGetConfig (DB5, práh 260715)', () {
    test('nové FW >= P2L_26071501NT umí GET-CONFIG', () {
      expect(CommandService.firmwareSupportsGetConfig('26071501NT'), isTrue);
      expect(CommandService.firmwareSupportsGetConfig('P2L_26071501NT'), isTrue);
      expect(CommandService.firmwareSupportsGetConfig('P2L_26080101NT'), isTrue);
    });

    test('starší FW GET-CONFIG neumí', () {
      expect(CommandService.firmwareSupportsGetConfig('26071401NT'), isFalse);
      expect(CommandService.firmwareSupportsGetConfig('25092501NT'), isFalse);
      expect(CommandService.firmwareSupportsGetConfig(null), isFalse);
      expect(CommandService.firmwareSupportsGetConfig(''), isFalse);
    });
  });

  group('request_id ACK (potvrzení příjmu)', () {
    test('nextRequestId: rozsah 1–65535, krok +1/wrap, neopakuje se v 10', () {
      final ids = List.generate(50, (_) => CommandService.nextRequestId());
      // FW limit: request_id max 65535 (16bit, 5 míst), nikdy -1 ani 0.
      expect(ids.every((id) => id >= 1 && id <= 65535), isTrue);
      // Každý krok je +1, nebo wraparound 65535 → 1.
      for (var i = 1; i < ids.length; i++) {
        final ok = ids[i] == ids[i - 1] + 1 || (ids[i - 1] == 65535 && ids[i] == 1);
        expect(ok, isTrue);
      }
      // Nesmí se opakovat v žádném okně 10 po sobě.
      for (var i = 0; i + 10 <= ids.length; i++) {
        expect(ids.sublist(i, i + 10).toSet().length, 10);
      }
    });

    test('buildSetWifiCommand: requestId se propíše, default -1', () {
      final withId = jsonDecode(CommandService.buildSetWifiCommand(
          ssid: 'HALA', password: 'x', requestId: 8999)) as Map;
      expect(withId['request_id'], 8999);
      final def = jsonDecode(
          CommandService.buildSetWifiCommand(ssid: 'HALA', password: 'x')) as Map;
      expect(def['request_id'], -1);
    });

    test('buildSetMqttCommand a buildUpdateCommand nesou requestId', () {
      final mqtt = jsonDecode(CommandService.buildSetMqttCommand(
          address: 'a', port: 1883, user: 'u', password: 'p', requestId: 42)) as Map;
      expect(mqtt['request_id'], 42);
      final upd = jsonDecode(CommandService.buildUpdateCommand(
          fileName: 'f.bin', requestId: 7)) as Map;
      expect(upd['request_id'], 7);
    });

    test('config CMD topic: nová gen jde na P2L, ne na starou SERVER', () {
      // Nová jednotka (ID >= 1000): I/<6dig>/P2L/01<4dig>/CMD.
      // Ack se zrcadlí na O/001209/P2L/011209/CMD → subscribe O/+/P2L/+/CMD.
      expect(CommandService.getCommandTopic('1209', isNewGen: true),
          'I/001209/P2L/011209/CMD');
      // I když FW hlásí ID s „u" prefixem (→ isNewGen vratký false), heuristika
      // podle čísla to podchytí: 1209 >= 1000 → P2L.
      expect(CommandService.getCommandTopic('u1209'), 'I/001209/P2L/011209/CMD');
      // Skutečně stará gen (ID < 1000) zůstává na SERVER topicu.
      expect(CommandService.getCommandTopic('472', isNewGen: false),
          'I/u0472/SERVER/CMD');
    });
  });
}
