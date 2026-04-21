import '../services/command_service.dart';

class P2LUnit {
  final String id;
  String? firmware;
  String? mac;
  String? ip;
  String? ssid;
  String? mqttServer;
  int? mqttPort;
  double? battery;
  String? hwModel;
  int brightness;
  Map<int, int> ledsPerPort;
  Map<int, String> colors;
  DateTime lastSeen;
  bool isOnline;
  bool useBin; // true = BIN režim, false = OLD/JSON režim

  P2LUnit({
    required this.id,
    this.firmware,
    this.mac,
    this.ip,
    this.ssid,
    this.mqttServer,
    this.mqttPort,
    this.battery,
    this.hwModel,
    this.brightness = 100,
    Map<int, int>? ledsPerPort,
    Map<int, String>? colors,
    DateTime? lastSeen,
    this.isOnline = true,
    this.useBin = false,
  })  : ledsPerPort = ledsPerPort ?? {},
        colors = colors ?? {},
        lastSeen = lastSeen ?? DateTime.now();

  factory P2LUnit.fromAlive(String unitId, Map<String, dynamic> json) {
    final fw = json['firmware'] as String?;
    return P2LUnit(
      id: unitId,
      hwModel: json['HWModel'] as String?,
      firmware: fw,
      battery: (json['battery'] as num?)?.toDouble(),
      useBin: CommandService.firmwareSupportsBin(fw),
    );
  }

  void updateFromGetParam(Map<String, dynamic> args) {
    firmware = args['ver'] as String? ?? firmware;
    mac = args['mac'] as String? ?? mac;
    ip = args['ip'] as String? ?? ip;
    ssid = args['SSID'] as String? ?? ssid;
    mqttServer = args['mqtt_server'] as String? ?? mqttServer;
    mqttPort = args['mqtt_port'] as int? ?? mqttPort;
    brightness = args['brightness'] as int? ?? brightness;

    for (int i = 0; i < 8; i++) {
      final key = 'leds port$i';
      if (args.containsKey(key)) {
        ledsPerPort[i] = args[key] as int;
      }
    }

    for (int i = 0; i < 10; i++) {
      final key = 'color$i';
      if (args.containsKey(key)) {
        colors[i] = args[key] as String;
      }
    }

    lastSeen = DateTime.now();
    isOnline = true;
    useBin = CommandService.firmwareSupportsBin(firmware);
  }

  bool get supportsBin => CommandService.firmwareSupportsBin(firmware);

  /// Zobrazí poslední 4 číslice ID (001017 → 1017)
  String get displayName {
    final cleanId = id.startsWith('u') ? id.substring(1) : id;
    if (cleanId.length > 4) {
      return cleanId.substring(cleanId.length - 4);
    }
    return cleanId;
  }

  String get lastSeenText {
    final diff = DateTime.now().difference(lastSeen);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s';
    final min = diff.inMinutes;
    final sec = diff.inSeconds % 60;
    if (min < 60) return '${min}m${sec.toString().padLeft(2, '0')}s';
    final hrs = diff.inHours;
    final remMin = min % 60;
    return '${hrs}h${remMin.toString().padLeft(2, '0')}m';
  }
}
