import 'package:flutter_test/flutter_test.dart';
import 'package:p2l_tester/models/device.dart';
import 'package:p2l_tester/models/module.dart';
import 'package:p2l_tester/services/module_reconstruction.dart';

void main() {
  group('reconstructModules', () {
    test('PUM-A bez tlačítek, jen displej', () {
      final devices = [const Device(type: DeviceType.disp, id: 128)];
      final result = reconstructModules(devices);
      expect(result.length, 1);
      expect(result[0].type, ModuleType.pumA);
      expect(result[0].baseAddress, 128);
      expect(result[0].buttons, isEmpty);
      expect(result[0].hasLeds, false);
    });

    test('PUM-A s 1 tlačítkem (vnitřní levé = 1000+N → tl. 1)', () {
      final devices = [
        const Device(type: DeviceType.disp, id: 128),
        const Device(type: DeviceType.btn, id: 1128),
      ];
      final result = reconstructModules(devices);
      expect(result.length, 1);
      expect(result[0].type, ModuleType.pumA);
      expect(result[0].buttons, {PumaButton.leftInner});
    });

    test('PUM-A s 2 tlačítky (1000+N, N → tl. 1 a 0)', () {
      final devices = [
        const Device(type: DeviceType.disp, id: 128),
        const Device(type: DeviceType.btn, id: 1128),
        const Device(type: DeviceType.btn, id: 128),
      ];
      final result = reconstructModules(devices);
      expect(result.length, 1);
      expect(result[0].type, ModuleType.pumA);
      expect(result[0].buttons, {PumaButton.leftInner, PumaButton.rightInner});
    });

    test('PUM-A se 4 tlačítky (N, 1000+N, 2000+N, 3000+N)', () {
      final devices = [
        const Device(type: DeviceType.disp, id: 128),
        const Device(type: DeviceType.btn, id: 128), // 0
        const Device(type: DeviceType.btn, id: 1128), // 1
        const Device(type: DeviceType.btn, id: 2128), // 2
        const Device(type: DeviceType.btn, id: 3128), // 3
      ];
      final result = reconstructModules(devices);
      expect(result.length, 1);
      expect(result[0].type, ModuleType.pumA);
      expect(result[0].buttonCount, 4);
      expect(result[0].buttonNumbers, [0, 1, 2, 3]);
    });

    test('PUM-A s vnějšími tlačítky 3000+N a 2000+N (čísla 3 a 2)', () {
      final devices = [
        const Device(type: DeviceType.disp, id: 130),
        const Device(type: DeviceType.btn, id: 3130), // 3
        const Device(type: DeviceType.btn, id: 2130), // 2
      ];
      final result = reconstructModules(devices);
      expect(result.length, 1);
      expect(result[0].buttons, {PumaButton.leftOuter, PumaButton.rightOuter});
      expect(result[0].buttonNumbers, [2, 3]);
    });

    test('PUM-A s 1 tl. holým N (BTN N) → tl. 0 (rightInner)', () {
      final devices = [
        const Device(type: DeviceType.disp, id: 128),
        const Device(type: DeviceType.btn, id: 128),
      ];
      final result = reconstructModules(devices);
      expect(result.length, 1);
      expect(result[0].type, ModuleType.pumA);
      expect(result[0].buttons, {PumaButton.rightInner});
    });

    test('PUM-A s LEDS', () {
      final devices = [
        const Device(type: DeviceType.disp, id: 128),
        const Device(type: DeviceType.leds, id: 128),
        const Device(type: DeviceType.btn, id: 1128),
      ];
      final result = reconstructModules(devices);
      expect(result.length, 1);
      expect(result[0].hasLeds, true);
      expect(result[0].buttons, {PumaButton.leftInner});
    });

    test('PUM-B: samostatné BTN bez DISP', () {
      final devices = [const Device(type: DeviceType.btn, id: 200)];
      final result = reconstructModules(devices);
      expect(result.length, 1);
      expect(result[0].type, ModuleType.pumB);
      expect(result[0].baseAddress, 200);
    });

    test('PUM-C: dvojice BTN 1000+M + BTN M bez DISP M', () {
      final devices = [
        const Device(type: DeviceType.btn, id: 1130),
        const Device(type: DeviceType.btn, id: 130),
      ];
      final result = reconstructModules(devices);
      expect(result.length, 1);
      expect(result[0].type, ModuleType.pumC);
      expect(result[0].baseAddress, 130);
    });

    test('Disambiguace: PUM-A 128 (1000+128) + PUM-C 130 (1130,130)', () {
      // 1128 patří PUM-A (na 128 je DISP); 1130/130 jsou PUM-C (na 130 DISP není).
      final devices = [
        const Device(type: DeviceType.disp, id: 128),
        const Device(type: DeviceType.btn, id: 1128),
        const Device(type: DeviceType.btn, id: 1130),
        const Device(type: DeviceType.btn, id: 130),
      ];
      final result = reconstructModules(devices);
      expect(result.length, 2);
      final pumA = result.firstWhere((m) => m.type == ModuleType.pumA);
      expect(pumA.baseAddress, 128);
      expect(pumA.buttons, {PumaButton.leftInner});
      final pumC = result.firstWhere((m) => m.type == ModuleType.pumC);
      expect(pumC.baseAddress, 130);
    });

    test('DIST', () {
      final devices = [const Device(type: DeviceType.dist, id: 50)];
      final result = reconstructModules(devices);
      expect(result.length, 1);
      expect(result[0].type, ModuleType.dist);
      expect(result[0].baseAddress, 50);
    });

    test('Kombinace PUM-A 128 (1 tl.) + PUM-C 129 + PUM-B 200 + DIST 50', () {
      final devices = [
        const Device(type: DeviceType.disp, id: 128),
        const Device(type: DeviceType.leds, id: 128),
        const Device(type: DeviceType.btn, id: 1128),
        const Device(type: DeviceType.btn, id: 1129),
        const Device(type: DeviceType.btn, id: 129),
        const Device(type: DeviceType.btn, id: 200),
        const Device(type: DeviceType.dist, id: 50),
      ];
      final result = reconstructModules(devices);
      expect(result.length, 4);

      final dist = result.firstWhere((m) => m.type == ModuleType.dist);
      expect(dist.baseAddress, 50);

      final pumA = result.firstWhere((m) => m.type == ModuleType.pumA);
      expect(pumA.baseAddress, 128);
      expect(pumA.buttons, {PumaButton.leftInner});
      expect(pumA.hasLeds, true);

      final pumC = result.firstWhere((m) => m.type == ModuleType.pumC);
      expect(pumC.baseAddress, 129);

      final pumB = result.firstWhere((m) => m.type == ModuleType.pumB);
      expect(pumB.baseAddress, 200);
    });

    test('Prázdný seznam', () {
      expect(reconstructModules([]), isEmpty);
    });

    test('DISP N + BTN 1000+N + BTN N → PUM-A s 2 tl.', () {
      final devices = [
        const Device(type: DeviceType.disp, id: 128),
        const Device(type: DeviceType.btn, id: 128),
        const Device(type: DeviceType.btn, id: 1128),
      ];
      final result = reconstructModules(devices);
      expect(result.length, 1);
      final pumA = result[0];
      expect(pumA.type, ModuleType.pumA);
      expect(pumA.buttonCount, 2);
    });
  });

  group('toDevices inverse', () {
    test('PUM-A (2 tl. + LEDS) → 4 devices (1000+N a N)', () {
      const m = PumaModule.pumA(
        address: 128,
        buttons: {PumaButton.leftInner, PumaButton.rightInner},
        hasLeds: true,
      );
      final devices = m.toDevices();
      expect(devices.length, 4);
      expect(devices, contains(const Device(type: DeviceType.disp, id: 128)));
      expect(devices, contains(const Device(type: DeviceType.leds, id: 128)));
      expect(devices, contains(const Device(type: DeviceType.btn, id: 1128)));
      expect(devices, contains(const Device(type: DeviceType.btn, id: 128)));
    });

    test('PUM-A se 4 tl. → DISP + BTN N/1000+N/2000+N/3000+N', () {
      const m = PumaModule.pumA(
        address: 128,
        buttons: {
          PumaButton.rightInner,
          PumaButton.leftInner,
          PumaButton.rightOuter,
          PumaButton.leftOuter,
        },
      );
      final ids = m
          .toDevices()
          .where((d) => d.type == DeviceType.btn)
          .map((d) => d.id)
          .toList();
      expect(ids, unorderedEquals([128, 1128, 2128, 3128]));
    });

    test('PUM-A (1 tl. vnitřní levé) → DISP + BTN 1000+N', () {
      const m = PumaModule.pumA(address: 128, buttons: {PumaButton.leftInner});
      final devices = m.toDevices();
      expect(devices.length, 2);
      expect(devices, contains(const Device(type: DeviceType.disp, id: 128)));
      expect(devices, contains(const Device(type: DeviceType.btn, id: 1128)));
    });

    test('PUM-A (1 tl. holé N) → DISP + BTN N', () {
      const m = PumaModule.pumA(address: 128, buttons: {PumaButton.rightInner});
      final devices = m.toDevices();
      expect(devices.length, 2);
      expect(devices, contains(const Device(type: DeviceType.disp, id: 128)));
      expect(devices, contains(const Device(type: DeviceType.btn, id: 128)));
    });

    test('PUM-C → 2 BTN devices', () {
      const m = PumaModule.pumC(address: 130);
      final devices = m.toDevices();
      expect(devices.length, 2);
      expect(devices, contains(const Device(type: DeviceType.btn, id: 1130)));
      expect(devices, contains(const Device(type: DeviceType.btn, id: 130)));
    });

    test('PUM-B → 1 BTN device', () {
      const m = PumaModule.pumB(address: 200);
      expect(m.toDevices(), [const Device(type: DeviceType.btn, id: 200)]);
    });

    test('Round-trip: modules → devices → modules', () {
      final original = [
        const PumaModule.pumA(
          address: 128,
          buttons: {PumaButton.leftInner, PumaButton.rightInner},
          hasLeds: true,
        ),
        const PumaModule.pumC(address: 130),
        const PumaModule.pumB(address: 200),
      ];
      final devices = original.expand((m) => m.toDevices()).toList();
      final reconstructed = reconstructModules(devices);
      expect(reconstructed.length, 3);
      final a = reconstructed.firstWhere((m) => m.type == ModuleType.pumA);
      expect(a.buttonCount, 2);
      expect(a.hasLeds, true);
    });

    test('Round-trip: PUM-A se 4 tlačítky', () {
      const original = PumaModule.pumA(
        address: 200,
        buttons: {
          PumaButton.rightInner,
          PumaButton.leftInner,
          PumaButton.rightOuter,
          PumaButton.leftOuter,
        },
      );
      final reconstructed = reconstructModules(original.toDevices());
      expect(reconstructed.length, 1);
      expect(reconstructed[0].buttonNumbers, [0, 1, 2, 3]);
    });
  });

  group('PumaButton mapování', () {
    test('číslo = tisícová číslice, strana podle čísla', () {
      expect(PumaButton.rightInner.number, 0);
      expect(PumaButton.leftInner.number, 1);
      expect(PumaButton.rightOuter.number, 2);
      expect(PumaButton.leftOuter.number, 3);
      expect(PumaButton.leftInner.isLeft, true);
      expect(PumaButton.leftOuter.isLeft, true);
      expect(PumaButton.rightInner.isLeft, false);
      expect(PumaButton.rightOuter.isLeft, false);
    });

    test('addressFor a fromNumber', () {
      expect(PumaButton.leftOuter.addressFor(128), 3128);
      expect(PumaButton.rightInner.addressFor(128), 128);
      expect(PumaButtonExt.fromNumber(3), PumaButton.leftOuter);
      expect(PumaButtonExt.fromNumber(0), PumaButton.rightInner);
      expect(PumaButtonExt.fromNumber(9), isNull);
    });
  });

  group('parseGetDevicesPayload', () {
    test('Jednoduchý payload', () {
      final payload = [
        {'Type': 'DISP', 'Id': [128]},
        {'Type': 'LEDS', 'Id': [128]},
        {'Type': 'BTN', 'Id': [1128, 1129, 129]},
      ];
      final devices = parseGetDevicesPayload(payload);
      expect(devices.length, 5);
      expect(devices, contains(const Device(type: DeviceType.disp, id: 128)));
      expect(devices, contains(const Device(type: DeviceType.btn, id: 1128)));
    });

    test('DIST s vnořeným configem', () {
      final payload = [
        {
          'Type': 'DIST',
          'Id': [
            [98, 40, 10, 0, 20, 4, 1, []],
          ],
        },
      ];
      final devices = parseGetDevicesPayload(payload);
      expect(devices.length, 1);
      expect(devices[0].type, DeviceType.dist);
      expect(devices[0].id, 98);
    });
  });
}
