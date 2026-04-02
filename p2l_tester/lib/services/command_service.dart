import 'dart:convert';

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

  /// BIN topic (pouze nový formát, ID >= 1000):
  /// I/<unit_id>/UNIT/<unit_id>/BIN
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
}
