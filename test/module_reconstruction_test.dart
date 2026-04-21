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
      expect(result[0].buttonCount, 0);
      expect(result[0].hasLeds, false);
    });

    test('PUM-A s 1 tlačítkem (levé = 1000+N)', () {
      final devices = [
        const Device(type: DeviceType.disp, id: 128),
        const Device(type: DeviceType.btn, id: 1128),
      ];
      final result = reconstructModules(devices);
      expect(result.length, 1);
      expect(result[0].type, ModuleType.pumA);
      expect(result[0].buttonCount, 1);
    });

    test('PUM-A s 2 tlačítky (1000+N, N)', () {
      final devices = [
        const Device(type: DeviceType.disp, id: 128),
        const Device(type: DeviceType.btn, id: 1128),
        const Device(type: DeviceType.btn, id: 128),
      ];
      final result = reconstructModules(devices);
      expect(result.length, 1);
      expect(result[0].type, ModuleType.pumA);
      expect(result[0].buttonCount, 2);
    });

    test('PUM-A s 1 tl. pravým (BTN N, bez 1000+N)', () {
      final devices = [
        const Device(type: DeviceType.disp, id: 128),
        const Device(type: DeviceType.btn, id: 128),
      ];
      final result = reconstructModules(devices);
      expect(result.length, 1);
      expect(result[0].type, ModuleType.pumA);
      expect(result[0].buttonCount, 1);
      expect(result[0].buttonSide, ButtonSide.right);
    });

    test('PUM-A s 1 tl. levým → side=left', () {
      final devices = [
        const Device(type: DeviceType.disp, id: 128),
        const Device(type: DeviceType.btn, id: 1128),
      ];
      final result = reconstructModules(devices);
      expect(result[0].buttonSide, ButtonSide.left);
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
      expect(result[0].buttonCount, 1);
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

    test('DIST', () {
      final devices = [const Device(type: DeviceType.dist, id: 50)];
      final result = reconstructModules(devices);
      expect(result.length, 1);
      expect(result[0].type, ModuleType.dist);
      expect(result[0].baseAddress, 50);
    });

    test('Kombinace PUM-A 128 (1 tl. L) + PUM-C 129 + PUM-B 200 + DIST 50', () {
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
      expect(pumA.buttonCount, 1);
      expect(pumA.buttonSide, ButtonSide.left);
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
      const m = PumaModule.pumA(address: 128, buttonCount: 2, hasLeds: true);
      final devices = m.toDevices();
      expect(devices.length, 4);
      expect(devices, contains(const Device(type: DeviceType.disp, id: 128)));
      expect(devices, contains(const Device(type: DeviceType.leds, id: 128)));
      expect(devices, contains(const Device(type: DeviceType.btn, id: 1128)));
      expect(devices, contains(const Device(type: DeviceType.btn, id: 128)));
    });

    test('PUM-A (1 tl. levé) → DISP + BTN 1000+N', () {
      const m = PumaModule.pumA(
        address: 128,
        buttonCount: 1,
        buttonSide: ButtonSide.left,
      );
      final devices = m.toDevices();
      expect(devices.length, 2);
      expect(devices, contains(const Device(type: DeviceType.disp, id: 128)));
      expect(devices, contains(const Device(type: DeviceType.btn, id: 1128)));
    });

    test('PUM-A (1 tl. pravé) → DISP + BTN N', () {
      const m = PumaModule.pumA(
        address: 128,
        buttonCount: 1,
        buttonSide: ButtonSide.right,
      );
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
        const PumaModule.pumA(address: 128, buttonCount: 2, hasLeds: true),
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
