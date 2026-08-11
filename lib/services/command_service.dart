import 'dart:convert';

import '../models/bus_scan.dart';
import '../models/device.dart';
import '../models/module.dart';

class CommandService {
  /// Zjistí, zda jednotka používá nový formát topicu (ID >= 1000)
  static bool isNewTopicFormat(String unitId) {
    final cleanId = unitId.startsWith('u') ? unitId.substring(1) : unitId;
    final num = int.tryParse(cleanId) ?? 0;
    return num >= 1000;
  }

  /// CMD topic podle generace jednotky.
  ///
  /// [isNewGen] — pokud je zadané, použije se přímo. Jinak fallback na
  /// heuristiku podle čísla (>= 1000 = nová generace) — ta ale selhává
  /// u nových jednotek s nízkým ID (typicky default 0000), takže volající
  /// by měl vždy předat příznak z `P2LUnit.isNewGen`.
  ///
  /// Stará (false): I/u<4dig>/SERVER/CMD (např. I/u0472/SERVER/CMD)
  /// Nová (true):   I/<6dig>/P2L/01<4dig>/CMD (např. I/001017/P2L/011017/CMD)
  static String getCommandTopic(String unitId, {bool? isNewGen}) {
    final cleanId = unitId.startsWith('u') ? unitId.substring(1) : unitId;
    final useNew = isNewGen ?? ((int.tryParse(cleanId) ?? 0) >= 1000);

    if (useNew) {
      final addr = cleanId.padLeft(6, '0');
      final last4 = addr.substring(addr.length - 4);
      return 'I/$addr/P2L/01$last4/CMD';
    }
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

  /// Rostoucí `request_id` pro potvrzované příkazy. Jednotka odpoví ackem na
  /// `O/.../P2L/.../CMD` (`status:"received"`) jen když `request_id != -1`; a
  /// **nesmí se opakovat v posledních 10**, které si pamatuje.
  ///
  /// FW limit: **max 65535** (16bit unsigned, 5 míst). Rozsah tedy 1–65535 s
  /// wraparoundem. Seed = **sekundy od epochy mod 65535** → nový běh appky
  /// začne jinde než minulý; protože appka mezi restarty běží déle než pár
  /// sekund a čítač jde po 1, seed přeskočí posledních 10 z minulého běhu →
  /// bez kolize přes restart. 65535 unikátních hodnot před opakováním
  /// (>> 10) → v posledních 10 se nikdy nezopakuje.
  static int _reqIdSeq = (DateTime.now().millisecondsSinceEpoch ~/ 1000) % 65535;
  static int nextRequestId() {
    _reqIdSeq = _reqIdSeq >= 65535 ? 1 : _reqIdSeq + 1;
    return _reqIdSeq;
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

  /// Příkaz `set_Mqtt` – hromadná změna brokera. [requestId] != -1 → jednotka
  /// pošle ack na `O/.../P2L/.../CMD` (potvrzení příjmu).
  static String buildSetMqttCommand({
    required String address,
    required int port,
    required String user,
    required String password,
    bool insecure = false,
    int requestId = -1,
  }) {
    return jsonEncode({
      'request_id': requestId,
      'cmds': [
        {
          'cmd': 'set_Mqtt',
          'args': {
            'address': address,
            'port': port,
            'user': user,
            'password': password,
            'insecure': insecure,
          },
        },
      ],
    });
  }

  /// Příkaz `set_brightness` – nastavení jasu jednotky (LED strip apod.).
  /// Hodnota v procentech 0–100.
  static String buildSetBrightnessCommand({required int value}) {
    return jsonEncode({
      'request_id': -1,
      'cmds': [
        {
          'cmd': 'set_brightness',
          'args': {'value': value},
        },
      ],
    });
  }

  /// Příkaz `update` – nahrát firmware z dané URL/cesty. Firmware si soubor
  /// stáhne sám a po flashi se restartuje. Funguje na obou generacích
  /// jednotek (JSON cmd, topic řeší volající přes `getCommandTopic`).
  static String buildUpdateCommand({required String fileName, int requestId = -1}) {
    return jsonEncode({
      'request_id': requestId,
      'cmds': [
        {
          'cmd': 'update',
          'args': {'file_name': fileName},
        },
      ],
    });
  }

  /// Příkaz `set_WiFi` – hromadná změna WiFi. [requestId] != -1 → jednotka
  /// pošle ack na `O/.../P2L/.../CMD` (potvrzení příjmu).
  static String buildSetWifiCommand({
    required String ssid,
    required String password,
    int requestId = -1,
  }) {
    return jsonEncode({
      'request_id': requestId,
      'cmds': [
        {
          'cmd': 'set_WiFi',
          'args': {
            'SSID': ssid,
            'PSWD': password,
          },
        },
      ],
    });
  }

  /// Args pro kombinovanou změnu WiFi **a** brokera. Klíče jsou stejné pro obě
  /// varianty příkazu (starý `set_Config` i nový UNIT `SET-CONFIG`), liší se
  /// jen obálka a topic — proto jeden zdroj.
  static Map<String, dynamic> _networkConfigArgs({
    required String ssid,
    required String wifiPassword,
    required String address,
    required int port,
    required String user,
    required String password,
    required bool insecure,
  }) {
    return {
      'SSID': ssid,
      'PSWD': wifiPassword,
      'mqttAddress': address,
      'mqttPort': port,
      'mqttUser': user,
      'mqttPassword': password,
      'mqttInsec': insecure,
    };
  }

  /// Příkaz `set_Config` – WiFi i broker **v jednom příkazu** pro firmware,
  /// který ještě nezná UNIT `SET-CONFIG` (< `P2L_26071501NT`, a stará
  /// generace). Jde přes běžný CMD topic, takže platí i ack přes
  /// [requestId] != -1 (`status:"received"` na `O/.../P2L/.../CMD`).
  ///
  /// Pro novější firmware použij [buildUnitSetConfigCommand] — tam FW navíc
  /// odpoví Code/Message a umí i další parametry (Id, statická IP).
  static String buildSetConfigCommand({
    required String ssid,
    required String wifiPassword,
    required String address,
    required int port,
    required String user,
    required String password,
    bool insecure = false,
    int requestId = -1,
  }) {
    return jsonEncode({
      'request_id': requestId,
      'cmds': [
        {
          'cmd': 'set_Config',
          'args': _networkConfigArgs(
            ssid: ssid,
            wifiPassword: wifiPassword,
            address: address,
            port: port,
            user: user,
            password: password,
            insecure: insecure,
          ),
        },
      ],
    });
  }

  /// UNIT `SET-CONFIG` (FW ≥ `P2L_26071501NT`) – WiFi i broker v jednom
  /// příkazu. Payload je plochý JSON, odpověď chodí na zrcadlový topic
  /// `O/<unit>/UNIT/<unit>/SET-CONFIG` jako `{"Code":0,"Message":"OK"}`
  /// (žádné `request_id`). Po změně sítě se jednotka restartuje.
  ///
  /// Posílají se jen WiFi + MQTT parametry; `Id` a statickou IP appka
  /// tímhle příkazem nemění (na ID je `set_id`, IP se nekonfiguruje).
  static ({String topic, String payload}) buildUnitSetConfigCommand({
    required String unitId,
    required String ssid,
    required String wifiPassword,
    required String address,
    required int port,
    required String user,
    required String password,
    bool insecure = false,
  }) {
    return (
      topic: getUnitCommandTopic(unitId, 'SET-CONFIG'),
      payload: jsonEncode(_networkConfigArgs(
        ssid: ssid,
        wifiPassword: wifiPassword,
        address: address,
        port: port,
        user: user,
        password: password,
        insecure: insecure,
      )),
    );
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

  /// Zjistí, zda firmware podporuje UNIT `GET-CONFIG` / `SET-CONFIG`
  /// (od `P2L_26071501NT`, tj. datum ≥ 260715). Stará generace ho neumí
  /// vůbec — volající navíc gejtuje přes `P2LUnit.isNewGen`. Starší nová
  /// gen prostě neodpoví, observed dál plní `get_param`.
  static bool firmwareSupportsGetConfig(String? firmware) {
    if (firmware == null || firmware.isEmpty) return false;
    final match = RegExp(r'(\d{6})').firstMatch(firmware);
    if (match == null) return false;
    final dateNum = int.tryParse(match.group(1)!);
    if (dateNum == null) return false;
    return dateNum >= 260715;
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
  /// Prefixy: DISP `05`, BTN `06`, LEDS `11`, DIST `04` (viz `DeviceTypeExt.addressPrefix`).
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

  /// Request pro UNIT `GET-CONFIG` (FW ≥ P2L_26071501NT). Odpověď je přímý
  /// JSON objekt s uloženou konfigurací (Id/ver/mac/SSID/mqtt*/ip/dns/…) i
  /// reálným stavem (actualIp/actualSSID).
  ///
  /// Bez [user]/[password] (payload `{}`) FW vrací hesla jen jako bool
  /// „je nastaveno". Se správnými přihlašovacími údaji vrátí i **skutečná
  /// hesla** (`PSWD`/`mqttPassword` jako string) — používá se pro kompletní
  /// evidenci/obnovu (interní tool).
  static ({String topic, String payload}) buildGetConfigCommand(String unitId,
      {String? user, String? password}) {
    final hasCreds =
        (user != null && user.isNotEmpty) || (password != null && password.isNotEmpty);
    return (
      topic: getUnitCommandTopic(unitId, 'GET-CONFIG'),
      payload: hasCreds
          ? jsonEncode({'User': user ?? '', 'Password': password ?? ''})
          : '{}',
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
          // 8. prvek = segmenty (poziční tvar); prázdné = režim vzdálenosti
          cfg.segments.map((s) => s.toPositional()).toList(),
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

  /// DEVICE-REPLACE: vadný device se nahradí novým osazeným kusem.
  ///
  /// Nový FW (kolegův přepis): UNIT-level topic `I/<unit>/UNIT/<unit>/DEVICE-REPLACE`,
  /// payload `{"From": <default_nového>, "To": <adresa_vadného>}`. Adresa typu se
  /// už neřeší v topicu — firmware přemapuje device z factory-default adresy
  /// (`From`) na cílovou adresu vadného kusu (`To`).
  ///
  /// Firmware atomicky přečipuje 1 fyzický čip — pro PUM-A přemapuje i LEDS
  /// (pokud jsou osazené), pro PUM-C i sekundární BTN @1000+M. Aplikace tedy
  /// pošle 1 DEVICE-REPLACE na modul.
  static ({String topic, String payload}) buildDeviceReplaceCommand({
    required String unitId,
    required int fromAddress,
    required int toAddress,
  }) {
    return (
      topic: getUnitCommandTopic(unitId, 'DEVICE-REPLACE'),
      payload: jsonEncode({'From': fromAddress, 'To': toAddress}),
    );
  }

  /// DEVICE-SET-ID: přečíslování existujícího device z adresy `From` na `To`.
  ///
  /// Nový FW: UNIT-level topic `I/<unit>/UNIT/<unit>/DEVICE-SET-ID`,
  /// payload `{"From": <stará_adresa>, "To": <nová_adresa>}`. Firmware atomicky
  /// přemapuje celý fyzický čip (analogicky k DEVICE-REPLACE) — aplikace pošle
  /// 1 DEVICE-SET-ID na modul.
  static ({String topic, String payload}) buildDeviceSetIdCommand({
    required String unitId,
    required int fromAddress,
    required int toAddress,
  }) {
    return (
      topic: getUnitCommandTopic(unitId, 'DEVICE-SET-ID'),
      payload: jsonEncode({'From': fromAddress, 'To': toAddress}),
    );
  }

  /// SET-DATA na DISP: zobrazí 4-znakový text. Prázdný řetězec = smazání displeje.
  /// `dispAddress: 0` = broadcast (DISP 050000) na všechny displeje — nový FW
  /// broadcast pro SET-DATA podporuje (na rozdíl od SET-CONFIG). Speciální text
  /// `"????"` = displej si sám zobrazí svou RS485 adresu (Pum-A FW v3.01+).
  static ({String topic, String payload}) buildSetDispDataCommand({
    required String unitId,
    required int dispAddress,
    required String data,
  }) {
    return (
      topic: getDeviceCommandTopic(unitId, DeviceType.disp, dispAddress, 'SET-DATA'),
      payload: jsonEncode({'Data': data}),
    );
  }

  /// SET-CONFIG na DISP: nastaví intensitu (jas) displeje. Rozsah 0–6.
  /// Pozn.: nový FW neumí broadcast přes adresu 0 (vrací „unknown ID") — posílej
  /// na konkrétní DISP adresu, pro „všechny" iteruj.
  static ({String topic, String payload}) buildSetDispConfigCommand({
    required String unitId,
    required int dispAddress,
    required int intensity,
  }) {
    return (
      topic: getDeviceCommandTopic(unitId, DeviceType.disp, dispAddress, 'SET-CONFIG'),
      payload: jsonEncode({'Intensity': intensity}),
    );
  }

  /// SET-LEDS na LEDS zařízení: rozsvítí LED daným stylem a barvou.
  /// Style 0 = svítí, Color: 0=RED, 1=GREEN, 2=BLUE, 3=YELLOW, 4=PURPLE, 5=WHITE.
  static ({String topic, String payload}) buildSetLedsCommand({
    required String unitId,
    required int ledsAddress,
    int style = 0,
    int color = 1,
  }) {
    return (
      topic: getDeviceCommandTopic(unitId, DeviceType.leds, ledsAddress, 'SET-LEDS'),
      payload: jsonEncode({'Style': style, 'Color': color}),
    );
  }

  /// CLEAR-LEDS: zhasne LED. Payload prázdný objekt.
  static ({String topic, String payload}) buildClearLedsCommand({
    required String unitId,
    required int ledsAddress,
  }) {
    return (
      topic: getDeviceCommandTopic(unitId, DeviceType.leds, ledsAddress, 'CLEAR-LEDS'),
      payload: '{}',
    );
  }

  /// SET-CONFIG pro DIST sensor.
  static ({String topic, String payload}) buildSetDistConfigCommand({
    required String unitId,
    required int distAddress,
    required DistConfig config,
  }) {
    return (
      topic: getDeviceCommandTopic(unitId, DeviceType.dist, distAddress, 'SET-CONFIG'),
      payload: jsonEncode({
        'MeasurePeriod': config.measurePeriod,
        'Timeout': config.timeout,
        'CountMeasures': config.countMeasures,
        'MaxDeviation': config.maxDeviation,
        'Offset': config.offset,
        'MeasureType': config.measureType,
        // Segmenty se posílají jen když existují — bez pole `Segments` firmware
        // přepne senzor zpět do režimu měření vzdálenosti (viz README-P2L-32).
        if (config.segments.isNotEmpty)
          'Segments': config.segments.map((s) => s.toJson()).toList(),
      }),
    );
  }

  /// GET-VALUE pro DIST sensor (od FW `P2L_26062301NT`): vyžádá poslední
  /// naměřenou vzdálenost + stav senzoru. Odpověď na zrcadlovém topicu
  /// `O/<unit>/DIST/04<addr>/GET-VALUE` jako `{"Distance":<mm>,"Code":0,…}`.
  static ({String topic, String payload}) buildGetValueCommand({
    required String unitId,
    required int distAddress,
  }) {
    return (
      topic: getDeviceCommandTopic(unitId, DeviceType.dist, distAddress, 'GET-VALUE'),
      payload: '{}',
    );
  }

  /// GET-ALIVE na konkrétní device (od FW `P2L_26070201NT`): vynutí okamžité
  /// odeslání ALIVE na topic `D/<unit>/<TYPE>/<DEVICE_ID>/ALIVE` bez čekání na
  /// periodický 5min interval. U DISP/LEDS firmware před odesláním provede RS485
  /// kontrolu. Payload `{}`. Odpověď chodí na `D/` topic (žádná extra `O/`).
  static ({String topic, String payload}) buildGetAliveCommand({
    required String unitId,
    required DeviceType type,
    required int address,
  }) {
    return (
      topic: getDeviceCommandTopic(unitId, type, address, 'GET-ALIVE'),
      payload: '{}',
    );
  }

  /// RESTART jednotky: SW restart. Payload prázdný objekt.
  static ({String topic, String payload}) buildRestartCommand(String unitId) {
    return (
      topic: getUnitCommandTopic(unitId, 'RESTART'),
      payload: '{}',
    );
  }

  /// SET-ID: změna ID jednotky. Firmware se po přijetí restartuje a přihlásí
  /// se s novým ID novým ALIVE.
  ///
  /// Stará (isNewGen=false): JSON CMD topic `I/u<4dig>/SERVER/CMD`,
  ///   payload `{"request_id":-1,"cmds":[{"cmd":"set_id","args":{"id":<new>}}]}`
  /// Nová (isNewGen=true): UNIT topic `I/<6dig>/UNIT/<6dig>/SET-ID`,
  ///   payload `{"Id":<new>}`
  static ({String topic, String payload}) buildSetUnitIdCommand({
    required String unitId,
    required int newId,
    required bool isNewGen,
  }) {
    if (isNewGen) {
      return (
        topic: getUnitCommandTopic(unitId, 'SET-ID'),
        payload: jsonEncode({'Id': newId}),
      );
    }
    return (
      topic: getCommandTopic(unitId, isNewGen: false),
      payload: jsonEncode({
        'request_id': -1,
        'cmds': [
          {
            'cmd': 'set_id',
            'args': {'id': newId},
          },
        ],
      }),
    );
  }

  /// SCAN-DEVICES na UNIT (od FW `P2L_26061801NT`): read-only scan RS485
  /// sběrnice — vrátí fyzicky připojené čipy **bez zápisu** do konfigurace
  /// (na rozdíl od [buildScanCommand]). Odpověď chodí na zrcadlový topic
  /// `O/<unit>/UNIT/<unit>/SCAN-DEVICES` jako přímý JSON objekt
  /// `{"PUM-A":[…],"DIST":[…]}` (úspěch), nebo Code/Message při chybě.
  static ({String topic, String payload}) buildScanDevicesCommand({
    required String unitId,
    BusScanScope scope = BusScanScope.all,
    int? scanId,
  }) {
    final args = <String, dynamic>{};
    if (scanId != null) {
      // Sken jedné adresy: firmware si typ (DIST/PUM) odvodí z rozsahu,
      // `Type` se neposílá.
      args['Id'] = scanId;
    } else {
      switch (scope) {
        case BusScanScope.dist:
          args['Type'] = 'DIST';
        case BusScanScope.pum:
          args['Type'] = 'PUM';
        case BusScanScope.all:
          break;
      }
    }
    return (
      topic: getUnitCommandTopic(unitId, 'SCAN-DEVICES'),
      payload: jsonEncode(args),
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

  /// Factory default adresa nového čipu podle typu device (z výroby).
  /// Po DEVICE-REPLACE aplikace přečipuje nový kus na ID původního (`From` =
  /// tato default adresa, `To` = adresa vadného kusu).
  ///
  /// Hodnoty = horní mez provozního rozsahu daného modulu (viz
  /// `ModuleTypeExt.addressRange`):
  /// - DIST: 127 (PUM = DIST, rozsah 1–127)
  /// - DISP: 246 (PUM-A, rozsah 128–246)
  /// - BTN: 247 (PUM-B i PUM-C, rozsah 128–247)
  /// - LEDS: 0 (DEVICE-REPLACE samostatně nepodporován; LEDS se přečipují
  ///   automaticky s DISP v rámci stejného PUM-A čipu)
  static int defaultReplacementAddress(DeviceType type) => switch (type) {
        DeviceType.dist => 127,
        DeviceType.disp => 246,
        DeviceType.btn => 247,
        _ => 0,
      };

  /// Zda je výměna přes DEVICE-REPLACE podporována pro daný typ. LEDS se
  /// vyměňují s celým PUM-A čipem (firmware atomicky přemapuje DISP+LEDS).
  static bool supportsReplace(DeviceType type) =>
      type == DeviceType.dist ||
      type == DeviceType.disp ||
      type == DeviceType.btn;
}

