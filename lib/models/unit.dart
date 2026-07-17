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
  /// True = nová generace (P2L32) → topic `I/<6dig>/P2L/01<4dig>/CMD` a UNIT
  /// příkazy. False = stará jednotka (`I/u<4dig>/SERVER/CMD`). Detekuje se z
  /// formátu příchozího ALIVE topicu (přítomnost prefixu `u`).
  bool isNewGen;
  /// True = jednotka byla přidána ručně (import seznamu ID) a zatím
  /// neodpověděla na get_param ani neposlala ALIVE. Tick timer ji přeskakuje
  /// (neoznačuje "offline po 360s") a v UI dostane šedou ikonu `help_outline`.
  /// Resetuje se na false v `updateFromGetParam` nebo v `AppState._handleAlive`.
  bool isPlaceholder;

  /// Poslední odpověď na UNIT `GET-CONFIG` (FW ≥ P2L_26071501NT) 1:1 —
  /// uložená konfigurace (mqttAddress/SSID/ip/dns/…, hesla jako bool) i reálný
  /// stav (actualIp/actualSSID). Zdroj observed vrstvy pro centrální DB (DB5),
  /// bohatší než `get_param`. `null` u staré generace / staršího FW.
  Map<String, dynamic>? unitConfig;

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
    this.isNewGen = false,
    this.isPlaceholder = false,
  })  : ledsPerPort = ledsPerPort ?? {},
        colors = colors ?? {},
        lastSeen = lastSeen ?? DateTime.now();

  /// Placeholder jednotka vytvořená z importu seznamu ID. Nemá žádné údaje
  /// kromě `id` a `isNewGen`. Po prvním ALIVE / get_param odpovědi se přepne
  /// na plnou jednotku (`isPlaceholder = false`).
  factory P2LUnit.placeholder(String id, {required bool isNewGen}) {
    return P2LUnit(
      id: id,
      isNewGen: isNewGen,
      isOnline: false,
      isPlaceholder: true,
    );
  }

  factory P2LUnit.fromAlive(
    String unitId,
    Map<String, dynamic> json, {
    bool isNewGen = false,
  }) {
    final fw = json['firmware'] as String?;
    return P2LUnit(
      id: unitId,
      hwModel: json['HWModel'] as String?,
      firmware: fw,
      battery: (json['battery'] as num?)?.toDouble(),
      useBin: CommandService.firmwareSupportsBin(fw),
      isNewGen: isNewGen,
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
    final bat = args['Bat'];
    if (bat is num) battery = bat.toDouble();

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
    isPlaceholder = false;
    useBin = CommandService.firmwareSupportsBin(firmware);
  }

  /// Uloží odpověď na UNIT `GET-CONFIG` (viz [unitConfig]). GET-CONFIG nese
  /// i firmware (`ver`) a MAC — udrž je čerstvé (u nové gen, která nikdy
  /// nedělala get_param, je MAC jinak null). Neplní ploché get_param fieldy
  /// (`ssid`/`mqttServer`), aby zůstal jasný rozdíl „běží" vs „uloženo".
  ///
  /// Se správnými přihlašovacími údaji v requestu vrací FW i skutečná hesla
  /// (`PSWD`/`mqttPassword` jako string) — ukládají se do evidence pro
  /// kompletní config/obnovu (interní tool; ochrana = HTTPS + auth + přístup
  /// k serveru, viz PRD-DB v2 §3).
  void updateFromGetConfig(Map<String, dynamic> config) {
    unitConfig = Map<String, dynamic>.from(config);
    final ver = config['ver'];
    if (ver is String && ver.isNotEmpty) {
      firmware = ver;
      useBin = CommandService.firmwareSupportsBin(ver);
    }
    final m = config['mac'];
    if (m is String && m.isNotEmpty) mac = m;
    lastSeen = DateTime.now();
    isOnline = true;
    isPlaceholder = false;
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
    if (diff.inSeconds > 599) return 'offline';
    if (diff.inSeconds < 60) return '${diff.inSeconds}s';
    final min = diff.inMinutes;
    final sec = diff.inSeconds % 60;
    return '${min}m${sec.toString().padLeft(2, '0')}s';
  }
}
