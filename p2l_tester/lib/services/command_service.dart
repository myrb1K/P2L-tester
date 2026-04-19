import 'dart:convert';

import '../models/device.dart';
import '../models/module.dart';

class CommandService {
  /// Zjistí, zda jednotka používá nový formát topicu (ID >= 1000)
  static bool isNewTopicFormat(String unitId) {
    final cleanId = unitId.startsWith('u') ? unitId.substring(1) : unitId;
    final num = int.tryParse(cleanId) ?? 0;
    return num >= 1000;
  }

  /// CMD topic podle ID jednotky:
  /// ID < 1000 (starý):  I/u<4digit>/SERVER/CMD  (např. I/u0472/SERVER/CMD)
  /// ID >= 1000 (nový):  I/<6digit>/P2L/01<4digit>/CMD  (např. I/001017/P2L/011017/CMD)
  static String getCommandTopic(String unitId) {
    if (isNewTopicFormat(unitId)) {
      final addr = unitId.padLeft(6, '0');
      final last4 = addr.substring(addr.length - 4);
      return 'I/$unitId/P2L/01$last4/CMD';
    }
    // Starý formát: I/u<4digit>/SERVER/CMD (např. I/u0547/SERVER/CMD)
    final cleanId = unitId.startsWith('u') ? unitId.substring(1) : unitId;
    final numId = int.tryParse(cleanId) ?? 0;
    final fourDigit = numId.toString().padLeft(4, '0');
    return 'I/u$fourDigit/SERVER/CMD';
  }

  /// BIN topic (pouze nový formát, ID >= 1000): `I/<unit_id>/UNIT/<unit_id>/BIN`
  static String getBinTopic(String unitId) {
    return 'I/$unitId/UNIT/$unitId/BIN';
  }

  /// Vygeneruje colors_id pattern: [ledsOn × color, ledsOff × color6(black)]
  static List<int> _buildColorsPattern(int ledsOn, int ledsOff, int color) {
    return [
      ...List.filled(ledsOn, color),
      ...List.filled(ledsOff, 6),
    ];
  }

  /// Barvy pro porty v cyklu: RED, GREEN, BLUE, PURPLE
  static const _portColors = [0, 1, 2, 3, 4, 0, 1, 2];

  /// Testovací LED pattern (OLD/JSON)
  static String buildTestCommand({int ledsOn = 3, int ledsOff = 10, int color = 0, List<int>? ports}) {
    final activePorts = ports ?? [0, 1, 2, 3, 4, 5, 6, 7];
    final cmds = <Map<String, dynamic>>[
      {'cmd': 'clr_strips'},
    ];

    for (final port in activePorts) {
      final portColor = _portColors[port];
      final colorsPattern = _buildColorsPattern(ledsOn, ledsOff, portColor);
      cmds.add({
        'cmd': 'set_leds',
        'args': {
          'port': port,
          'x1': 0,
          'x2': 599,
          'style_id': 0,
          'colors_id': colorsPattern,
        },
      });
    }

    return jsonEncode({
      'request_id': -1,
      'cmds': cmds,
    });
  }

  /// Testovací LED pattern (BIN formát)
  static List<int> buildTestCommandBin({int ledsOn = 3, int ledsOff = 10, int color = 0, List<int>? ports}) {
    final activePorts = ports ?? [0, 1, 2, 3, 4, 5, 6, 7];
    final bytes = <int>[];
    const x1 = 0;
    const x2 = 599;

    for (final port in activePorts) {
      final portColor = _portColors[port];
      final colorsPattern = _buildColorsPattern(ledsOn, ledsOff, portColor);
      bytes.add(0x03);              // type: P2L-Set_leds
      bytes.add(port);              // id: port number
      bytes.add(x1 & 0xFF);        // x1 low byte
      bytes.add((x1 >> 8) & 0xFF); // x1 high byte
      bytes.add(x2 & 0xFF);        // x2 low byte
      bytes.add((x2 >> 8) & 0xFF); // x2 high byte
      bytes.add(0x00);              // style: 0
      bytes.add(colorsPattern.length);
      bytes.addAll(colorsPattern);
    }

    bytes.add(0x00); // terminator

    return bytes;
  }

  /// Zhasne všechny LED (JSON)
  static String buildClearCommand() {
    return jsonEncode({
      'request_id': -1,
      'cmds': [
        {'cmd': 'clr_strips'},
      ],
    });
  }

  /// Zjistí parametry jednotky
  static String buildGetParamCommand() {
    return jsonEncode({
      'request_id': -1,
      'cmds': [
        {'cmd': 'get_param'},
      ],
    });
  }

  /// Zjistí, zda firmware podporuje BIN (>= 250925)
  static bool firmwareSupportsBin(String? firmware) {
    if (firmware == null || firmware.isEmpty) return false;

    // Podpora obou formatu: "25092501NT" i "P2L_25092501NT"
    final match = RegExp(r'(\d{6})').firstMatch(firmware);
    if (match == null) return false;

    final dateNum = int.tryParse(match.group(1)!);
    if (dateNum == null) return false;
    return dateNum >= 250925;
  }

  // ============================================================
  // Device management commands (P2L32 protokol, viz README-P2L-32.md)
  // ============================================================

  /// Normalizuje unit_id na 6-místný formát (pro topicy nového protokolu).
  static String _unitId6(String unitId) {
    final clean = unitId.startsWith('u') ? unitId.substring(1) : unitId;
    return clean.padLeft(6, '0');
  }

  /// Topic pro UNIT-level příkazy: `I/<unit_id>/UNIT/<unit_id>/<CMD>`.
  static String getUnitCommandTopic(String unitId, String command) {
    final id = _unitId6(unitId);
    return 'I/$id/UNIT/$id/$command';
  }

  /// Topic pro konkrétní device: `I/<unit_id>/<TYPE>/<DEVICE_ID>/<CMD>`.
  /// DEVICE_ID = 2-ciferný kód typu + 4-ciferná adresa (např. 050246 = DISP @246).
  /// Pro BTN (bez prefixu v README) použijeme holou 6-místnou adresu.
  static String getDeviceCommandTopic(
      String unitId, DeviceType type, int address, String command) {
    final unit = _unitId6(unitId);
    final typeCode = type.addressPrefix;
    final addrStr = address.toString().padLeft(4, '0');
    final deviceId = typeCode != null ? '$typeCode$addrStr' : addrStr.padLeft(6, '0');
    return 'I/$unit/${type.code}/$deviceId/$command';
  }

  /// Response topic pattern pro subscribe (O místo I): `O/<unit>/UNIT/<unit>/<CMD>`.
  /// Pro subscribe wildcards na všechny jednotky použij MqttService přímo.

  /// Request payload pro GET-DEVICES. Vrátí {topic, payload}.
  static ({String topic, String payload}) buildGetDevicesCommand(String unitId) {
    return (
      topic: getUnitCommandTopic(unitId, 'GET-DEVICES'),
      payload: '{}',
    );
  }

  /// Sestaví payload pro ADD-DEVICES / RECREATE-DEVICES / DELETE-DEVICES.
  /// Sgrupuje moduly do seznamu {"Type": ..., "Id": [...]} entries.
  /// Pro DELETE použij [forDelete=true] — DIST se pošle jen s holým Id (bez configu),
  /// i kdyby měl vnořený config, aby odpovídal příkladu v README.
  static String _buildDevicesPayload(List<PumaModule> modules, {bool forDelete = false}) {
    // Sgrupuj všechny atomic Device entries podle typu
    final byType = <DeviceType, List<dynamic>>{};
    for (final module in modules) {
      if (module.type == ModuleType.dist && !forDelete) {
        // DIST s plnou konfigurací (pokud je)
        final cfg = module.distConfig ?? const DistConfig();
        byType.putIfAbsent(DeviceType.dist, () => []).add([
          module.baseAddress,
          cfg.measurePeriod,
          cfg.timeout,
          cfg.offset,
          cfg.maxDeviation,
          cfg.countMeasures,
          cfg.measureType,
          [], // segments — první iterace nepodporuje, prázdný seznam
        ]);
      } else {
        for (final dev in module.toDevices()) {
          byType.putIfAbsent(dev.type, () => []).add(dev.id);
        }
      }
    }

    final entries = <Map<String, dynamic>>[];
    for (final type in DeviceType.values) {
      if (byType.containsKey(type) && byType[type]!.isNotEmpty) {
        entries.add({'Type': type.code, 'Id': byType[type]!});
      }
    }

    return jsonEncode(entries);
  }

  static ({String topic, String payload}) buildAddDevicesCommand(
      String unitId, List<PumaModule> modules) {
    return (
      topic: getUnitCommandTopic(unitId, 'ADD-DEVICES'),
      payload: _buildDevicesPayload(modules),
    );
  }

  static ({String topic, String payload}) buildRecreateDevicesCommand(
      String unitId, List<PumaModule> modules) {
    return (
      topic: getUnitCommandTopic(unitId, 'RECREATE-DEVICES'),
      payload: _buildDevicesPayload(modules),
    );
  }

  static ({String topic, String payload}) buildDeleteDevicesCommand(
      String unitId, List<PumaModule> modules) {
    return (
      topic: getUnitCommandTopic(unitId, 'DELETE-DEVICES'),
      payload: _buildDevicesPayload(modules, forDelete: true),
    );
  }

  /// REPLACE-FROM: vadný device (typ+oldAddr) se nahradí novým (newDefaultAddr).
  /// Podporováno pouze pro DIST a DISP (viz README-P2L-32.md).
  static ({String topic, String payload}) buildReplaceFromCommand({
    required String unitId,
    required DeviceType type,
    required int oldAddress,
    required int newDefaultAddress,
  }) {
    return (
      topic: getDeviceCommandTopic(unitId, type, oldAddress, 'REPLACE-FROM'),
      payload: jsonEncode({'Id': newDefaultAddress}),
    );
  }

  /// RESTART jednotky: SW restart. Payload prázdný objekt.
  static ({String topic, String payload}) buildRestartCommand(String unitId) {
    return (
      topic: getUnitCommandTopic(unitId, 'RESTART'),
      payload: '{}',
    );
  }

  /// SCAN na UNIT: najde nová zařízení na RS485.
  static ({String topic, String payload}) buildScanCommand({
    required String unitId,
    DeviceType? type,
    int? id,
  }) {
    final args = <String, dynamic>{};
    if (type != null) args['Type'] = type.code;
    if (id != null) args['Id'] = id;
    return (
      topic: getUnitCommandTopic(unitId, 'SCAN'),
      payload: jsonEncode(args),
    );
  }

  /// Default (výchozí) adresa nového náhradního kusu podle typu device.
  /// DIST: 127 (rozsah 0-126 pro provoz), DISP: 247 (rozsah 127-246).
  static int defaultReplacementAddress(DeviceType type) => switch (type) {
        DeviceType.dist => 127,
        DeviceType.disp => 247,
        _ => 0, // BTN/LEDS: REPLACE-FROM není v README dokumentováno
      };

  /// Zda je výměna přes REPLACE-FROM podporována protokolem pro daný typ.
  static bool supportsReplace(DeviceType type) =>
      type == DeviceType.dist || type == DeviceType.disp;
}

