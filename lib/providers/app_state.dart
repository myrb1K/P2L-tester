import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dart:convert';

import '../models/broker_profile.dart';
import '../models/bus_scan.dart';
import '../models/device.dart';
import '../models/device_template.dart';
import '../models/module.dart';
import '../models/unit.dart';
import '../services/command_service.dart';
import '../services/module_reconstruction.dart';
import '../services/mqtt_service.dart';
import '../services/unit_ids_io.dart';

class AppState extends ChangeNotifier {
  final MqttService _mqttService = MqttService();
  Timer? _tickTimer;

  // Broker profiles
  List<BrokerProfile> _profiles = [];
  int _activeProfileIndex = -1;

  // Connection settings (z aktivního profilu)
  String broker = '';
  int port = 1883;
  String username = '';
  String password = '';
  bool useSsl = false;
  bool useWebsocket = false;
  String wsPath = '/mqtt';

  // LED pattern
  int ledsOn = 3;
  int ledsOff = 10;
  int ledColor = 0; // 0=RED, 1=GREEN, 2=BLUE, 3=YELLOW, 4=PURPLE, 5=WHITE

  // Vybrané porty pro test
  Set<int> selectedPorts = {0, 1, 2, 3, 4, 5, 6, 7};

  // Filtr offline jednotek
  bool filterOffline = false;

  // Getters pro profily
  List<BrokerProfile> get profiles => List.unmodifiable(_profiles);
  int get activeProfileIndex => _activeProfileIndex;

  /// Název aktivního brokeru, nebo `null` pokud žádný profil není vybraný.
  /// Používá se pro pojmenování exportního JSON.
  String? get activeBrokerName {
    if (_activeProfileIndex < 0 || _activeProfileIndex >= _profiles.length) {
      return null;
    }
    return _profiles[_activeProfileIndex].name;
  }

  /// Všechna aktuálně známá ID P2L modulů (zachovává tvar v `_units.keys`).
  /// Seřazená numericky pro stabilní export.
  List<String> get allUnitIds {
    final ids = _units.keys.toList();
    ids.sort((a, b) {
      final na = int.tryParse(a.startsWith('u') ? a.substring(1) : a) ?? 0;
      final nb = int.tryParse(b.startsWith('u') ? b.substring(1) : b) ?? 0;
      return na.compareTo(nb);
    });
    return ids;
  }

  // State
  final Map<String, P2LUnit> _units = {};
  final Set<String> _selectedUnits = {};
  AppMqttState _connectionState = AppMqttState.disconnected;
  String? _lastError;
  String _statusMessage = '';

  // Device management state
  final Map<String, List<PumaModule>> _unitModules = {};
  final Map<String, DateTime> _unitModulesFetchedAt = {};
  final Set<String> _unitModulesPending = {};
  // Read-only scan sběrnice (SCAN-DEVICES) — fyzický stav, oddělený od _unitModules.
  final Map<String, BusScanResult> _unitBusScan = {};
  final Set<String> _unitBusScanPending = {};
  // Rozsah posledního odeslaného skenu (odpověď ho neobsahuje, ale porovnání ho
  // potřebuje, aby sken jen DIST nehlásil PUM moduly jako „chybí").
  final Map<String, BusScanScope> _unitBusScanScope = {};
  // Adresa posledního skenu jedné adresy (`{"Id":N}`), nebo chybí pro rozsahový
  // sken — porovnání ji potřebuje, aby omezilo diagnostiku jen na tu adresu.
  final Map<String, int> _unitBusScanId = {};
  // Adresa, kterou po následném GET-DEVICES ověříme cíleným SCAN-DEVICES
  // {"Id":N} (instant kontrola fyzické přítomnosti) — po přidání i po smazání
  // device (zjistí, zda čip na sběrnici fyzicky zůstal).
  final Map<String, int> _pendingAddVerify = {};
  // Probíhající probe adresy (ověření před výměnou) — completer doplní odpověď
  // SCAN-DEVICES. Klíč `unitId:address`. Na rozdíl od skenu výsledek neukládá.
  final Map<String, Completer<bool?>> _busProbes = {};
  // Nová adresa PUM-A displeje po přečíslování (DEVICE-SET-ID) — po potvrzení
  // se na displej pošle, aby se nová adresa fyzicky zobrazila.
  final Map<String, int> _pendingDispAddrAfterSetId = {};
  List<DeviceTemplate> _templates = [];
  String _deviceActionStatus = '';
  // true = poslední hláška je chybová (Code != 0) → v UI červeně.
  bool _deviceActionIsError = false;

  /// Jednotné nastavení stavové hlášky správy devices. `isError` určuje červené
  /// zabarvení v UI; každé volání příznak přepíše, takže se nezasekne na červené.
  void _setStatus(String msg, {bool isError = false}) {
    _deviceActionStatus = msg;
    _deviceActionIsError = isError;
  }

  // Timestamp posledního stisku BTN. Klíč: "<unitId>:<baseAddr>:<left|right>".
  // Klíč `unitId:baseAddr:side` → poslední stisk (čas + číslo tlačítka 0–3).
  final Map<String, ({DateTime ts, int number})> _btnPresses = {};

  // Poslední naměřená vzdálenost DIST senzoru [mm]. Klíč: "<unitId>:<addr>".
  final Map<String, int> _distValues = {};

  // Devices jednotky, které v posledním ALIVE hlásily Code != 0 (porucha).
  // Klíč = unitId, hodnota = set deviceId. Prázdný/chybějící = vše OK.
  final Map<String, Set<String>> _unitDeviceFaults = {};

  // ID jednotek, pro které už se zahrála wave animace v UI seznamu. Vlna
  // má proběhnout právě jednou — při prvním objevení nebo přechodu offline→online.
  // Bez tracking-u na úrovni AppState by se animace spouštěla pokaždé, když
  // ListView.builder zničí a znovu vytvoří kartu (off-screen recyklace).
  final Set<String> _wavedUnitIds = {};

  // Getters
  Map<String, P2LUnit> get units => Map.unmodifiable(_units);
  List<P2LUnit> get unitList {
    var list = _units.values.toList();
    if (filterOffline) {
      list = list.where((u) => !u.isOnline).toList();
    }
    list.sort((a, b) {
      final na = int.tryParse(a.id.startsWith('u') ? a.id.substring(1) : a.id) ?? 0;
      final nb = int.tryParse(b.id.startsWith('u') ? b.id.substring(1) : b.id) ?? 0;
      return na.compareTo(nb);
    });
    return list;
  }

  int get offlineCount => _units.values.where((u) => !u.isOnline).length;

  // Device management getters
  List<PumaModule>? modulesForUnit(String unitId) => _unitModules[_normUnitId(unitId)];
  DateTime? modulesFetchedAt(String unitId) => _unitModulesFetchedAt[_normUnitId(unitId)];
  bool isModulesPending(String unitId) => _unitModulesPending.contains(_normUnitId(unitId));
  BusScanResult? busScanFor(String unitId) => _unitBusScan[_normUnitId(unitId)];
  bool isBusScanPending(String unitId) => _unitBusScanPending.contains(_normUnitId(unitId));

  /// Diagnostické porovnání posledního skenu sběrnice s konfigurací (OK /
  /// chybí / nezaregistrované). Prázdné, dokud sken neproběhl. Z toho se v UI
  /// odvozuje červené zvýraznění chybějících chipů a šedé „ghost" chipy
  /// nalezených, ale neuložených devices.
  List<BusScanRow> busDiagnosis(String unitId) {
    final id = _normUnitId(unitId);
    final scan = _unitBusScan[id];
    final mods = _unitModules[id];
    if (scan == null || mods == null) return const [];
    return diagnoseBus(mods, scan);
  }
  List<DeviceTemplate> get templates => List.unmodifiable(_templates);
  String get deviceActionStatus => _deviceActionStatus;
  bool get deviceActionIsError => _deviceActionIsError;

  static String _normUnitId(String unitId) =>
      unitId.startsWith('u') ? unitId.substring(1) : unitId;

  /// CMD topic pro jednotku s respektováním zjištěné generace
  /// (`P2LUnit.isNewGen`). Pokud jednotku ještě neznáme, fallback heuristika
  /// podle čísla (>= 1000 = nová) v `CommandService.getCommandTopic`.
  String _topicFor(String unitId) {
    final id = _normUnitId(unitId);
    return CommandService.getCommandTopic(id, isNewGen: _units[id]?.isNewGen);
  }

  void toggleOfflineFilter() {
    filterOffline = !filterOffline;
    notifyListeners();
  }
  Set<String> get selectedUnits => Set.unmodifiable(_selectedUnits);
  AppMqttState get connectionState => _connectionState;
  String? get lastError => _lastError;
  String get statusMessage => _statusMessage;
  bool get isConnected => _connectionState == AppMqttState.connected;
  int get selectedCount => _selectedUnits.length;
  int get totalCount => _units.length;

  void togglePort(int port) {
    if (selectedPorts.contains(port)) {
      if (selectedPorts.length > 1) selectedPorts.remove(port);
    } else {
      selectedPorts.add(port);
    }
    notifyListeners();
  }

  void selectAllPorts() {
    selectedPorts = {0, 1, 2, 3, 4, 5, 6, 7};
    notifyListeners();
  }

  void deselectAllPorts() {
    selectedPorts = {0};
    notifyListeners();
  }

  AppState() {
    _mqttService.stateStream.listen((state) {
      _connectionState = state;
      _lastError = _mqttService.lastError;
      notifyListeners();
    });

    _mqttService.messageStream.listen(_handleMessage);
  }

  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final profilesJson = prefs.getString('broker_profiles');
    if (profilesJson != null) {
      _profiles = BrokerProfile.listFromJson(profilesJson);
    }
    _activeProfileIndex = prefs.getInt('active_profile') ?? -1;
    if (_activeProfileIndex >= 0 && _activeProfileIndex < _profiles.length) {
      _applyProfile(_profiles[_activeProfileIndex]);
    }
    ledsOn = prefs.getInt('leds_on') ?? 3;
    ledsOff = prefs.getInt('leds_off') ?? 10;
    ledColor = prefs.getInt('led_color') ?? 0;
    _lastWifiSsid = prefs.getString('last_wifi_ssid') ?? '';
    _lastWifiPassword = prefs.getString('last_wifi_password') ?? '';
    _firmwareBaseUrl = prefs.getString('firmware_base_url') ??
        'http://185.149.129.164/download';

    final templatesJson = prefs.getString('device_templates');
    if (templatesJson != null && templatesJson.isNotEmpty) {
      try {
        _templates = DeviceTemplate.listFromJson(templatesJson);
      } catch (_) {
        _templates = [];
      }
    }
    notifyListeners();
  }

  Future<void> _saveProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('broker_profiles', BrokerProfile.listToJson(_profiles));
    await prefs.setInt('active_profile', _activeProfileIndex);
  }

  Future<void> saveLedPattern(int on, int off, int color) async {
    ledsOn = on;
    ledsOff = off;
    ledColor = color;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('leds_on', on);
    await prefs.setInt('leds_off', off);
    await prefs.setInt('led_color', color);
    notifyListeners();
  }

  void _applyProfile(BrokerProfile profile) {
    broker = profile.broker;
    port = profile.port;
    username = profile.username;
    password = profile.password;
    useSsl = profile.useSsl;
    useWebsocket = profile.useWebsocket;
    wsPath = profile.wsPath;
  }

  /// True pokud už existuje profil se stejným názvem (case-insensitive, trim).
  /// [excludeIndex] umožňuje vynechat konkrétní profil při editaci.
  bool isProfileNameTaken(String name, {int? excludeIndex}) {
    final needle = name.trim().toLowerCase();
    if (needle.isEmpty) return false;
    for (var i = 0; i < _profiles.length; i++) {
      if (i == excludeIndex) continue;
      if (_profiles[i].name.trim().toLowerCase() == needle) return true;
    }
    return false;
  }

  /// Přidá profil. Vrací `null` při úspěchu, jinak chybovou zprávu
  /// (např. duplicitní název).
  Future<String?> addProfile(BrokerProfile profile) async {
    if (isProfileNameTaken(profile.name)) {
      return 'Profil s názvem "${profile.name.trim()}" už existuje';
    }
    _profiles.add(profile);
    _activeProfileIndex = _profiles.length - 1;
    _applyProfile(profile);
    await _saveProfiles();
    notifyListeners();
    return null;
  }

  /// Přidá profil do seznamu, ale nenastaví ho jako aktivní a nepřepne
  /// připojení. Používá se při hromadné změně brokera, kde uživatel zadává
  /// nový broker pro vybrané P2L moduly, ale aplikace má zůstat na aktuálním.
  /// Vrací `null` při úspěchu, jinak chybovou zprávu.
  Future<String?> addProfileWithoutActivating(BrokerProfile profile) async {
    if (isProfileNameTaken(profile.name)) {
      return 'Profil s názvem "${profile.name.trim()}" už existuje';
    }
    _profiles.add(profile);
    await _saveProfiles();
    notifyListeners();
    return null;
  }

  /// Upraví existující profil. Vrací `null` při úspěchu, jinak chybovou zprávu.
  Future<String?> updateProfile(int index, BrokerProfile profile) async {
    if (index < 0 || index >= _profiles.length) return 'Neplatný profil';
    if (isProfileNameTaken(profile.name, excludeIndex: index)) {
      return 'Profil s názvem "${profile.name.trim()}" už existuje';
    }
    _profiles[index] = profile;
    if (index == _activeProfileIndex) {
      _applyProfile(profile);
    }
    await _saveProfiles();
    notifyListeners();
    return null;
  }

  Future<void> deleteProfile(int index) async {
    if (index < 0 || index >= _profiles.length) return;
    _profiles.removeAt(index);
    if (_activeProfileIndex == index) {
      _activeProfileIndex = _profiles.isEmpty ? -1 : 0;
      if (_activeProfileIndex >= 0) {
        _applyProfile(_profiles[_activeProfileIndex]);
      } else {
        broker = '';
        port = 1883;
        username = '';
        password = '';
        useSsl = false;
        useWebsocket = false;
        wsPath = '/mqtt';
      }
    } else if (_activeProfileIndex > index) {
      _activeProfileIndex--;
    }
    await _saveProfiles();
    notifyListeners();
  }

  /// Přesune profil z [oldIndex] na [newIndex] a udrží `_activeProfileIndex`
  /// ukazující na původně aktivní profil.
  Future<void> reorderProfiles(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _profiles.length) return;
    // ReorderableListView konvence: pokud táhneš dolů, newIndex je o 1 větší
    // než cílová pozice po odebrání položky.
    var target = newIndex;
    if (target > oldIndex) target -= 1;
    if (target < 0) target = 0;
    if (target >= _profiles.length) target = _profiles.length - 1;
    if (target == oldIndex) return;

    final moved = _profiles.removeAt(oldIndex);
    _profiles.insert(target, moved);

    // Přepočet _activeProfileIndex tak, aby dál ukazoval na stejný profil.
    if (_activeProfileIndex == oldIndex) {
      _activeProfileIndex = target;
    } else if (_activeProfileIndex > oldIndex && _activeProfileIndex <= target) {
      _activeProfileIndex -= 1;
    } else if (_activeProfileIndex < oldIndex && _activeProfileIndex >= target) {
      _activeProfileIndex += 1;
    }

    await _saveProfiles();
    notifyListeners();
  }

  Future<void> selectProfile(int index) async {
    if (index < 0 || index >= _profiles.length) return;
    _activeProfileIndex = index;
    _applyProfile(_profiles[index]);
    await _saveProfiles();
    notifyListeners();
  }

  Future<bool> connect() async {
    if (broker.isEmpty) {
      _lastError = 'Broker address is empty';
      notifyListeners();
      return false;
    }

    final result = await _mqttService.connect(
      broker: broker,
      port: port,
      username: username,
      password: password,
      useSsl: useSsl,
      useWebsocket: useWebsocket,
      wsPath: wsPath,
    );

    if (result) {
      _mqttService.subscribe('D/+/UNIT/+/ALIVE');
      // Device ALIVE (každých ~5 min) nese Code/Message — sledování poruch
      // devices (Code != 0 → červená ikona „Seznam devices").
      _mqttService.subscribe('D/+/DIST/+/ALIVE');
      _mqttService.subscribe('D/+/DISP/+/ALIVE');
      _mqttService.subscribe('D/+/BTN/+/ALIVE');
      _mqttService.subscribe('D/+/LEDS/+/ALIVE');
      _mqttService.subscribe('A/SERVER/+/CMD');
      // Odpovědi na device management commandy (P2L32 protokol)
      _mqttService.subscribe('O/+/UNIT/+/GET-DEVICES');
      _mqttService.subscribe('O/+/UNIT/+/ADD-DEVICES');
      _mqttService.subscribe('O/+/UNIT/+/RECREATE-DEVICES');
      _mqttService.subscribe('O/+/UNIT/+/DELETE-DEVICES');
      // Nový FW: výměna i přečíslování device jsou UNIT-level příkazy.
      _mqttService.subscribe('O/+/UNIT/+/DEVICE-REPLACE');
      _mqttService.subscribe('O/+/UNIT/+/DEVICE-SET-ID');
      // Read-only scan sběrnice (od FW P2L_26061801NT)
      _mqttService.subscribe('O/+/UNIT/+/SCAN-DEVICES');
      // BTN press notifikace pro vizuální flash na chipech
      _mqttService.subscribe('D/+/BTN/+/UPDATE');
      // DIST měření vzdálenosti (živá hodnota u senzoru v seznamu devices)
      _mqttService.subscribe('D/+/DIST/+/UPDATE');
      // Vyžádané změření DIST (GET-VALUE, od FW P2L_26062301NT)
      _mqttService.subscribe('O/+/DIST/+/GET-VALUE');
      _statusMessage = 'Připojeno, čekám na ALIVE…';
      _tickTimer?.cancel();
      _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_units.isNotEmpty) {
          for (final unit in _units.values) {
            // Placeholder (importované ID, ještě neodpovědělo) přeskakujeme —
            // nemá smysl počítat jeho lastSeen do online/offline výpočtu.
            if (unit.isPlaceholder) continue;
            final wasOnline = unit.isOnline;
            unit.isOnline = DateTime.now().difference(unit.lastSeen).inSeconds < 360;
            // Při online→offline odebrat z waved setu, aby návrat (kdykoliv,
            // i když je karta mimo viewport) zase spustil vlnu.
            if (wasOnline && !unit.isOnline) {
              _wavedUnitIds.remove(_normUnitId(unit.id));
            }
          }
          notifyListeners();
        }
      });
    } else {
      // Chybu vezmeme synchronně z MqttService — stateStream listener ji
      // doručí až v microtasku, takže UI (čte lastError hned po awaitu) by
      // jinak viděla starou hodnotu (typicky null = "Chyba: null").
      _lastError = _mqttService.lastError ??
          'Připojení k brokeru selhalo (neznámá chyba)';
    }

    notifyListeners();
    return result;
  }

  void disconnect() {
    _tickTimer?.cancel();
    _mqttService.disconnect();
    _units.clear();
    _selectedUnits.clear();
    _initialFetchDone.clear();
    _awaitingAliveAfterRestart.clear();
    _restartSentAt.clear();
    _statusMessage = '';
    notifyListeners();
  }

  void _handleMessage(MqttReceivedMessage<MqttMessage> message) {
    final topic = message.topic;
    dynamic decoded;
    try {
      decoded = jsonDecode(MqttService.getPayload(message));
    } catch (_) {
      return;
    }

    if (topic.contains('/ALIVE') && decoded is Map<String, dynamic>) {
      _handleAlive(topic, decoded);
    } else if (topic.startsWith('A/SERVER/') && decoded is Map<String, dynamic>) {
      _handleResponse(topic, decoded);
    } else if (topic.startsWith('D/') && topic.contains('/BTN/') && topic.endsWith('/UPDATE')) {
      _handleBtnUpdate(topic);
    } else if (topic.startsWith('D/') && topic.contains('/DIST/') && topic.endsWith('/UPDATE') && decoded is Map<String, dynamic>) {
      _handleDistUpdate(topic, decoded);
    } else if (topic.startsWith('O/') && topic.contains('/DIST/') && topic.endsWith('/GET-VALUE') && decoded is Map<String, dynamic>) {
      _handleGetValueResponse(topic, decoded);
    } else if (topic.startsWith('O/')) {
      // GET-DEVICES odpověď je top-level pole; ostatní O/ odpovědi jsou Map s Code/Message.
      final json = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
      _handleDeviceResponse(topic, json, message);
    }
  }

  /// Topic: `D/<unit>/BTN/<deviceId>/UPDATE`, deviceId = `06<addr4>`.
  /// Číslo tlačítka (0–3) = tisícová číslice adresy; bázová adresa = addr % 1000.
  /// Tlačítka 1 a 3 jsou levá (levá hrana buňky), 0 a 2 pravá. PUM-B/PUM-C: 0/1.
  void _handleBtnUpdate(String topic) {
    final parts = topic.split('/');
    if (parts.length < 5) return;
    final unitId = _normUnitId(parts[1]);
    final deviceId = parts[3];
    if (deviceId.length < 4) return;
    final addr = int.tryParse(deviceId.substring(deviceId.length - 4));
    if (addr == null) return;

    final number = addr ~/ 1000; // 0..3
    final baseAddr = addr % 1000;
    final isLeft = number == 1 || number == 3;
    final side = isLeft ? 'left' : 'right';
    _btnPresses['$unitId:$baseAddr:$side'] = (ts: DateTime.now(), number: number);
    notifyListeners();
  }

  /// Vrátí poslední stisk (čas + číslo tlačítka) pro daný PUM modul a stranu.
  /// `left=true` → levá hrana (tlačítka 1/3), `false` → pravá (tlačítka 0/2).
  ({DateTime ts, int number})? lastButtonPress(String unitId, int baseAddr,
      {required bool left}) {
    final id = _normUnitId(unitId);
    return _btnPresses['$id:$baseAddr:${left ? 'left' : 'right'}'];
  }

  /// Topic: `D/<unit>/DIST/<deviceId>/UPDATE`, deviceId = `04<addr4>`,
  /// payload `{"distance": <mm>}`. Uloží poslední naměřenou vzdálenost senzoru.
  void _handleDistUpdate(String topic, Map<String, dynamic> json) {
    final parts = topic.split('/');
    if (parts.length < 5) return;
    final unitId = _normUnitId(parts[1]);
    final deviceId = parts[3];
    if (deviceId.length < 4) return;
    final addr = int.tryParse(deviceId.substring(deviceId.length - 4));
    final distance = json['distance'];
    if (addr == null || distance is! num) return;

    _distValues['$unitId:$addr'] = distance.toInt();
    notifyListeners();
  }

  /// Poslední naměřená vzdálenost [mm] DIST senzoru, nebo null (zatím nepřišla).
  int? distanceFor(String unitId, int address) =>
      _distValues['${_normUnitId(unitId)}:$address'];

  // Vyžádané změření DIST (GET-VALUE) — completer dokončí odpověď nebo timeout.
  final Map<String, Completer<({int? distance, bool ok, String? message})?>>
      _distValueCompleters = {};

  /// Vyžádá aktuální měření DIST senzoru přes GET-VALUE (od FW `P2L_26062301NT`).
  /// Vrátí `distance` [mm] + `ok` (Code==0) + `message`, nebo null při timeoutu.
  /// Úspěšné měření zároveň aktualizuje živou hodnotu ([distanceFor]).
  Future<({int? distance, bool ok, String? message})?> requestDistValue(
      String unitId, int address) {
    final id = _normUnitId(unitId);
    final key = '$id:$address';
    final existing = _distValueCompleters[key];
    if (existing != null) return existing.future;

    final completer = Completer<({int? distance, bool ok, String? message})?>();
    _distValueCompleters[key] = completer;
    final displayId = int.tryParse(id)?.toString() ?? id;
    _setStatus('Měřím senzor $address na jednotce $displayId…');
    notifyListeners();

    final cmd =
        CommandService.buildGetValueCommand(unitId: id, distAddress: address);
    _mqttService.publish(cmd.topic, cmd.payload);

    Future.delayed(const Duration(seconds: 10), () {
      final c = _distValueCompleters.remove(key);
      if (c == null || c.isCompleted) return;
      _setStatus('Měření senzoru $address: bez odpovědi (starší firmware?)',
          isError: true);
      notifyListeners();
      c.complete(null);
    });

    return completer.future;
  }

  /// Topic: `O/<unit>/DIST/04<addr>/GET-VALUE`, payload
  /// `{"Distance":<mm>,"Code":0,"Message":"OK","Level":"INFO"}`.
  void _handleGetValueResponse(String topic, Map<String, dynamic> json) {
    final parts = topic.split('/');
    if (parts.length < 5) return;
    final unitId = _normUnitId(parts[1]);
    final deviceId = parts[3];
    if (deviceId.length < 4) return;
    final addr = int.tryParse(deviceId.substring(deviceId.length - 4));
    if (addr == null) return;

    final key = '$unitId:$addr';
    final code = json['Code'];
    final ok = code == 0 || code == '0';
    final dist = json['Distance'];
    final distance = dist is num ? dist.toInt() : null;
    // Živou hodnotu přepisujeme jen při úspěchu (při poruše je Distance stará).
    if (ok && distance != null) _distValues[key] = distance;

    final completer = _distValueCompleters.remove(key);
    if (completer != null && !completer.isCompleted) {
      completer.complete(
          (distance: distance, ok: ok, message: json['Message'] as String?));
    }
    notifyListeners();
  }

  void _handleDeviceResponse(
      String topic, Map<String, dynamic> json, dynamic message) {
    // Topic: O/<unit>/<TYPE>/<DEVICE_ID>/<CMD>
    final parts = topic.split('/');
    if (parts.length < 5) return;
    final unitId = _normUnitId(parts[1]);
    final cmd = parts[4];

    final code = json['Code'];
    final msg = json['Message'] as String?;

    if (cmd == 'GET-DEVICES') {
      _handleGetDevicesResponse(unitId, json, message);
    } else if (cmd == 'SCAN-DEVICES') {
      _handleScanDevicesResponse(unitId, json);
    } else if (cmd == 'DEVICE-REPLACE' ||
        cmd == 'DEVICE-SET-ID' ||
        cmd == 'ADD-DEVICES' ||
        cmd == 'RECREATE-DEVICES' ||
        cmd == 'DELETE-DEVICES') {
      final ok = code == 0 || code == '0';
      _setStatus('$cmd na $unitId: ${ok ? 'OK' : 'chyba'}${msg != null ? " — $msg" : ""}',
          isError: !ok);
      _unitModulesPending.remove(unitId);
      if (ok) {
        // Re-adresování (REPLACE/SET-ID) mění fyzické adresy čipů → starý sken
        // je neplatný. ADD/RECREATE/DELETE mění jen konfiguraci jednotky, ale
        // fyzická sběrnice je beze změny → sken NEzahazujeme: diagnostika se
        // přepočítá proti novému configu (přidaný device zezelená, ostatní
        // ghost devices zůstanou viditelné). Při chybě sken vždy zachováme.
        if (cmd == 'DEVICE-REPLACE' || cmd == 'DEVICE-SET-ID') {
          _invalidateBusScan(unitId);
        }
        // Přečíslovaný PUM-A → zobraz novou adresu na jeho displeji (jen bez
        // restartu — po restartu by se displej stejně překreslil).
        final dispAddr = cmd == 'DEVICE-SET-ID'
            ? _pendingDispAddrAfterSetId.remove(unitId)
            : null;
        if (_pendingRestart.remove(unitId)) {
          // S restartem: GET-DEVICES posílat až po návratu jednotky online (první ALIVE).
          _awaitingAliveAfterRestart.add(unitId);
          _restartSentAt[unitId] = DateTime.now();
          Future.microtask(() => restartUnit(unitId));
        } else {
          Future.microtask(() => fetchDevices(unitId));
          if (dispAddr != null) {
            // Krátká prodleva, ať se čip stihne přemapovat na novou adresu.
            Future.delayed(const Duration(milliseconds: 300), () {
              sendDispData(
                unitId: unitId,
                dispAddress: dispAddr,
                data: dispAddr.toString().padLeft(4, '0'),
              );
            });
          }
        }
      } else {
        _pendingRestart.remove(unitId);
        // Add selhal → GET-DEVICES neproběhne, ověřovací sken zahodíme.
        _pendingAddVerify.remove(unitId);
        _pendingDispAddrAfterSetId.remove(unitId);
      }
      notifyListeners();
    }
  }

  void _handleGetDevicesResponse(
      String unitId, Map<String, dynamic> json, dynamic message) {
    _unitModulesPending.remove(unitId);

    // Payload: buď pole entries, nebo objekt s "Devices" polem, nebo raw payload.
    dynamic devicesField;
    if (json['Devices'] != null) {
      devicesField = json['Devices'];
    } else if (json['devices'] != null) {
      devicesField = json['devices'];
    } else {
      // Možná je payload rovnou pole (parseJsonPayload nepropustí non-map).
      // Zkus re-parse raw payloadu.
      try {
        final raw = MqttService.getPayload(message);
        final decoded = jsonDecode(raw);
        if (decoded is List) devicesField = decoded;
      } catch (_) {}
    }

    if (devicesField != null) {
      final devices = parseGetDevicesPayload(devicesField);
      _unitModules[unitId] = reconstructModules(devices);
      _unitModulesFetchedAt[unitId] = DateTime.now();
      _setStatus('Devices P2L modulu ${int.tryParse(unitId)?.toString() ?? unitId} načteny (${devices.length} entit → ${_unitModules[unitId]!.length} devices)');
      // Ověření právě přidaného device cíleným skenem jeho adresy (až teď, kdy
      // je config aktuální). Výsledek se v `_handleScanDevicesResponse`
      // vmerguje do případného existujícího skenu, takže ostatní ghost devices
      // v seznamu zůstanou.
      final verifyAddr = _pendingAddVerify.remove(unitId);
      if (verifyAddr != null) {
        Future.microtask(() => scanBus(unitId, scanId: verifyAddr));
      }
    } else {
      _setStatus('GET-DEVICES $unitId: neočekávaný formát odpovědi', isError: true);
    }
    notifyListeners();
  }

  /// SCAN-DEVICES: úspěch je přímý JSON objekt s adresami (bez `Code`), chyba
  /// je Code/Message (`-1 unknown Type`, `-2 response too large`,
  /// `-3 mqtt publish failed`).
  void _handleScanDevicesResponse(String unitId, Map<String, dynamic> json) {
    _unitBusScanPending.remove(unitId);
    final displayId = int.tryParse(unitId)?.toString() ?? unitId;
    final code = json['Code'];

    // Čekající probe (ověření adresy, např. před výměnou)? Doplň completer
    // podle toho, zda sken adresu našel — a NEukládej do zobrazeného skenu.
    final probeKey = _busProbes.keys
        .firstWhere((k) => k.startsWith('$unitId:'), orElse: () => '');
    if (probeKey.isNotEmpty) {
      final completer = _busProbes.remove(probeKey);
      final addr = int.tryParse(probeKey.split(':').last);
      if (completer != null && !completer.isCompleted) {
        final isError = code != null && code != 0 && code != '0';
        if (isError || addr == null) {
          completer.complete(null);
        } else {
          final found = BusScanResult.fromJson(json, DateTime.now())
              .addressTypes
              .containsKey(addr);
          completer.complete(found);
        }
      }
      return;
    }

    if (code != null && code != 0 && code != '0') {
      final msg = json['Message'] as String?;
      _setStatus('Sken sběrnice $displayId: chyba${msg != null ? " — $msg" : ""}',
          isError: true);
    } else {
      final scope = _unitBusScanScope[unitId] ?? BusScanScope.all;
      final scanId = _unitBusScanId[unitId];
      final existing = _unitBusScan[unitId];
      final BusScanResult scan;
      if (scanId != null &&
          existing != null &&
          existing.scanId == null &&
          existing.scope.containsAddress(scanId)) {
        // Cílené ověření adresy proti existujícímu rozsahovému skenu →
        // aktualizuj jen tuhle adresu, ostatní nalezené devices zachovej.
        scan = existing.withUpdatedAddress(scanId, json, DateTime.now());
      } else {
        scan = BusScanResult.fromJson(json, DateTime.now(),
            scope: scope, scanId: scanId);
      }
      _unitBusScan[unitId] = scan;
      if (scanId != null) {
        final type = scan.addressTypes[scanId];
        _setStatus(type != null
            ? 'Ověření adresy $scanId na $displayId: připojeno ($type)'
            : 'Ověření adresy $scanId na $displayId: na sběrnici nenalezeno');
      } else {
        _setStatus('Sken sběrnice $displayId: nalezeno ${scan.total} čipů');
      }
    }
    notifyListeners();
  }

  void _handleAlive(String topic, Map<String, dynamic> json) {
    // Topic: D/<id>/UNIT/<id>/ALIVE
    final parts = topic.split('/');
    if (parts.length < 4) return;
    // Device-level ALIVE (BTN/DISP/LEDS/DIST) nese diagnostiku Code/Message;
    // řešíme zvlášť, UNIT ALIVE pokračuje níž.
    if (parts.length >= 3 && parts[2] != 'UNIT') {
      _handleDeviceAlive(parts, json);
      return;
    }
    final rawId = parts[1];
    // Stará jednotka má v topicu prefix 'u' (D/u0472/UNIT/u0472/ALIVE),
    // nová P2L32 posílá 6-cifernou holou adresu (D/000123/UNIT/000123/ALIVE).
    final isNewGen = !rawId.startsWith('u');
    final unitId = _normUnitId(rawId);

    if (_units.containsKey(unitId)) {
      final u = _units[unitId]!;
      // Placeholder (z importu) → překlopit na plnou jednotku.
      final wasPlaceholder = u.isPlaceholder;
      u.lastSeen = DateTime.now();
      u.isOnline = true;
      u.isNewGen = isNewGen;
      u.isPlaceholder = false;
      if (wasPlaceholder && json['HWModel'] != null) {
        u.hwModel = json['HWModel'] as String;
      }
      if (json['battery'] != null) {
        u.battery = (json['battery'] as num).toDouble();
      }
      if (json['firmware'] != null) {
        u.firmware = json['firmware'] as String;
        u.useBin = CommandService.firmwareSupportsBin(u.firmware);
      }
    } else {
      _units[unitId] = P2LUnit.fromAlive(unitId, json, isNewGen: isNewGen);
      _statusMessage = 'Nalezeno ${_units.length} P2L modulů';
    }

    // Po restartu: první ALIVE mimo grace window → dotáhni devices.
    if (_awaitingAliveAfterRestart.contains(unitId)) {
      final sentAt = _restartSentAt[unitId];
      if (sentAt != null && DateTime.now().difference(sentAt) >= _restartGrace) {
        _awaitingAliveAfterRestart.remove(unitId);
        _restartSentAt.remove(unitId);
        _initialFetchDone.add(unitId);
        _setStatus('P2L modul ${int.tryParse(unitId)?.toString() ?? unitId} zpět online — načítám devices.');
        Future.microtask(() => fetchDevices(unitId));
      }
    } else if (_initialFetchDone.add(unitId)) {
      // První ALIVE této jednotky v rámci aktuálního připojení → auto-fetch.
      Future.microtask(() => fetchDevices(unitId));
    }
    notifyListeners();
  }

  /// Device ALIVE (BTN/DISP/LEDS/DIST), topic `D/<unit>/<TYPE>/<deviceId>/ALIVE`.
  /// Nese diagnostiku `Code`/`Message`: `Code:0` = OK (ticho), jinak chybu
  /// vypíšeme do stavové hlášky červeně. Zároveň osvěží lastSeen jednotky.
  void _handleDeviceAlive(List<String> parts, Map<String, dynamic> json) {
    if (parts.length < 5) return;
    final unitId = _normUnitId(parts[1]);
    final type = parts[2];
    final deviceId = parts[3];

    // Device ALIVE je doklad, že jednotka relayuje → osvěž lastSeen/online.
    final u = _units[unitId];
    if (u != null) {
      u.lastSeen = DateTime.now();
      u.isOnline = true;
    }

    final code = json['Code'];
    final isError = code != null && code != 0 && code != '0';

    // Sleduj poruchy devices: deviceId je v rámci jednotky unikátní. Při Code != 0
    // device přidej do poruch jednotky, při Code 0 (zotavení) odeber. Z toho se
    // odvozuje červená ikona „Seznam devices" v seznamu jednotek.
    final faults = _unitDeviceFaults.putIfAbsent(unitId, () => {});
    if (isError) {
      faults.add(deviceId);
    } else {
      faults.remove(deviceId);
    }

    if (isError) {
      final msg = (json['Message'] as String?) ?? 'chyba';
      final displayId = int.tryParse(unitId)?.toString() ?? unitId;
      _setStatus('$displayId · $type $deviceId: $msg (Code $code)',
          isError: true);
    }
    notifyListeners();
  }

  /// True, pokud některý device jednotky v posledním ALIVE hlásil Code != 0.
  bool unitHasDeviceFault(String unitId) =>
      _unitDeviceFaults[_normUnitId(unitId)]?.isNotEmpty ?? false;

  /// Base adresy modulů s poruchou (z device ALIVE Code != 0). DeviceId je
  /// `<typeCode><addr4>`; levé tlačítko (addr ≥ 1000) se mapuje na base adresu
  /// modulu (addr-1000). Slouží k červenému rámečku chipu v detailu.
  Set<int> deviceFaultAddresses(String unitId) {
    final faults = _unitDeviceFaults[_normUnitId(unitId)];
    if (faults == null || faults.isEmpty) return const {};
    final out = <int>{};
    for (final devId in faults) {
      final addr = devId.length >= 4
          ? int.tryParse(devId.substring(devId.length - 4))
          : int.tryParse(devId);
      if (addr == null) continue;
      out.add(addr >= 1000 ? addr - 1000 : addr);
    }
    return out;
  }

  void _handleResponse(String topic, Map<String, dynamic> json) {
    if (json['cmd'] == 'get_param' && json['args'] != null) {
      final args = json['args'] as Map<String, dynamic>;
      final unitId = args['id'] as String?;
      if (unitId == null) return;

      final lookupId = unitId.startsWith('u') ? unitId.substring(1) : unitId;

      String effectiveId;
      if (_units.containsKey(lookupId)) {
        _units[lookupId]!.updateFromGetParam(args);
        effectiveId = lookupId;
      } else if (_units.containsKey(unitId)) {
        _units[unitId]!.updateFromGetParam(args);
        effectiveId = unitId;
      } else {
        final unit = P2LUnit(id: lookupId);
        unit.updateFromGetParam(args);
        _units[lookupId] = unit;
        _statusMessage = 'Nalezeno ${_units.length} P2L modulů';
        effectiveId = lookupId;
      }

      // Po manuálním ověření (get_param) dotáhni devices hned, ať uživatel
      // nemusí čekat na další ALIVE. Guard přes _initialFetchDone zajistí,
      // že se nevolá podruhé, až přijde nejbližší ALIVE.
      if (!_awaitingAliveAfterRestart.contains(effectiveId) &&
          _initialFetchDone.add(effectiveId)) {
        Future.microtask(() => fetchDevices(effectiveId));
      }
      notifyListeners();
    }
  }

  void clearUnits() {
    _units.clear();
    _selectedUnits.clear();
    _wavedUnitIds.clear();
    _statusMessage = 'Seznam vycisten';
    notifyListeners();
  }

  /// Vrací `true` jen jednou pro daný `unitId` — používá `_UnitCard` k tomu,
  /// aby modrou vlnu spustil právě jednou při prvním objevení jednotky
  /// (ALIVE / manuální zadání ID). Při remountu karty (scrolování pryč
  /// a zpět) už vrací `false`.
  bool consumeFirstAppearAnimation(String unitId) {
    return _wavedUnitIds.add(_normUnitId(unitId));
  }

  /// Označí jednotku za "už animovanou" bez kontroly. Volá se z
  /// `didUpdateWidget` po offline→online přechodu, aby další remount
  /// karty animaci nezopakoval.
  void markUnitWaved(String unitId) {
    _wavedUnitIds.add(_normUnitId(unitId));
  }

  void toggleUnit(String unitId) {
    if (_selectedUnits.contains(unitId)) {
      _selectedUnits.remove(unitId);
    } else {
      _selectedUnits.add(unitId);
    }
    notifyListeners();
  }

  void selectAll() {
    _selectedUnits.addAll(_units.keys);
    notifyListeners();
  }

  void deselectAll() {
    _selectedUnits.clear();
    notifyListeners();
  }

  void toggleBinMode(String unitId) {
    if (_units.containsKey(unitId)) {
      _units[unitId]!.useBin = !_units[unitId]!.useBin;
      notifyListeners();
    }
  }

  void sendTest() {
    final ports = selectedPorts.toList()..sort();
    final oldPayload = CommandService.buildTestCommand(ledsOn: ledsOn, ledsOff: ledsOff, color: ledColor, ports: ports);
    final binPayload = CommandService.buildTestCommandBin(ledsOn: ledsOn, ledsOff: ledsOff, color: ledColor, ports: ports);
    for (final unitId in _selectedUnits) {
      final unit = _units[unitId];
      if (unit != null && unit.useBin) {
        // BIN: nejdřív clr_strips přes CMD, pak set_leds přes BIN
        final cmdTopic = _topicFor(unitId);
        _mqttService.publish(cmdTopic, CommandService.buildClearCommand());
        final binTopic = CommandService.getBinTopic(unitId);
        _mqttService.publishBytes(binTopic, binPayload);
      } else {
        final topic = _topicFor(unitId);
        _mqttService.publish(topic, oldPayload);
      }
    }
    _statusMessage = 'Test odeslan na ${_selectedUnits.length} jednotek';
    notifyListeners();
  }

  void sendClear() {
    final payload = CommandService.buildClearCommand();
    for (final unitId in _selectedUnits) {
      final topic = _topicFor(unitId);
      _mqttService.publish(topic, payload);
    }
    _statusMessage = 'Clear odeslan na ${_selectedUnits.length} jednotek';
    notifyListeners();
  }

  // Poslední zadané SSID/heslo pro WiFi (z SharedPreferences).
  String _lastWifiSsid = '';
  String _lastWifiPassword = '';
  String get lastWifiSsid => _lastWifiSsid;
  String get lastWifiPassword => _lastWifiPassword;

  String _firmwareBaseUrl = '';
  String get firmwareBaseUrl => _firmwareBaseUrl;

  Future<void> setFirmwareBaseUrl(String url) async {
    _firmwareBaseUrl = url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('firmware_base_url', url);
  }

  /// Hromadná změna brokera: pošle `set_Mqtt` všem vybraným jednotkám s 100ms pauzou.
  Future<void> sendBulkBroker(BrokerProfile profile) async {
    if (_selectedUnits.isEmpty) return;
    final payload = CommandService.buildSetMqttCommand(
      address: profile.broker,
      port: profile.port,
      user: profile.username,
      password: profile.password,
      insecure: !profile.useSsl,
    );
    final targets = _selectedUnits.toList();
    var sent = 0;
    for (final unitId in targets) {
      final topic = _topicFor(unitId);
      _mqttService.publish(topic, payload);
      sent++;
      _statusMessage = 'Broker: $sent / ${targets.length} (${profile.name})';
      notifyListeners();
      if (sent < targets.length) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
    _statusMessage = 'Broker "${profile.name}" odeslán na $sent P2L jednotek';
    notifyListeners();
  }

  /// Hromadná změna WiFi: pošle `set_WiFi` všem vybraným jednotkám s 100ms pauzou.
  /// Hromadná změna jasu jednotky (`set_brightness`, value 0–100)
  /// na všech vybraných jednotkách s 100 ms pauzou.
  Future<void> sendBulkUnitBrightness(int value) async {
    if (_selectedUnits.isEmpty) return;
    final clamped = value.clamp(0, 100);
    final payload = CommandService.buildSetBrightnessCommand(value: clamped);
    final targets = _selectedUnits.toList();
    var sent = 0;
    for (final unitId in targets) {
      final topic = _topicFor(unitId);
      _mqttService.publish(topic, payload);
      sent++;
      _statusMessage = 'Jas jednotky: $sent / ${targets.length} ($clamped%)';
      notifyListeners();
      if (sent < targets.length) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
    _statusMessage = 'Jas jednotky $clamped% odeslán na $sent P2L modulů';
    notifyListeners();
  }

  /// DISP adresy (PUM-A) jednotky z posledního GET-DEVICES, vzestupně.
  List<int> _dispAddressesFor(String unitId) {
    final mods = _unitModules[_normUnitId(unitId)] ?? const <PumaModule>[];
    final addrs = mods
        .where((m) => m.type == ModuleType.pumA)
        .map((m) => m.baseAddress)
        .toList()
      ..sort();
    return addrs;
  }

  /// Hromadná změna jasu displejů (DISP SET-CONFIG) na všech vybraných
  /// jednotkách. Intensity 0–6.
  ///
  /// Nový FW neumí broadcast na DISP adresu 0 (vrací „unknown ID") — posíláme
  /// SET-CONFIG na každou skutečnou DISP adresu zvlášť (z posledního
  /// GET-DEVICES) se 100ms pauzou. Jednotky bez známých DISP (nenačtené devices)
  /// se přeskočí.
  Future<void> sendBulkBrightness(int intensity) async {
    if (_selectedUnits.isEmpty) return;
    final clamped = intensity.clamp(0, 6);
    final targets = _selectedUnits.toList();
    var sent = 0;
    var skipped = 0;
    for (final unitId in targets) {
      final disps = _dispAddressesFor(unitId);
      if (disps.isEmpty) {
        skipped++;
        continue;
      }
      for (final addr in disps) {
        final cmd = CommandService.buildSetDispConfigCommand(
          unitId: _normUnitId(unitId),
          dispAddress: addr,
          intensity: clamped,
        );
        _mqttService.publish(cmd.topic, cmd.payload);
        sent++;
        _statusMessage = 'Jas: $sent displejů (intensity=$clamped)';
        notifyListeners();
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
    _statusMessage = skipped > 0
        ? 'Jas $clamped odeslán na $sent displejů ($skipped jednotek bez známých DISP — otevři detail / Obnovit)'
        : 'Jas $clamped odeslán na $sent displejů';
    notifyListeners();
  }

  Future<void> sendBulkWifi({required String ssid, required String password}) async {
    if (_selectedUnits.isEmpty) return;
    final payload = CommandService.buildSetWifiCommand(ssid: ssid, password: password);
    final targets = _selectedUnits.toList();
    var sent = 0;
    for (final unitId in targets) {
      final topic = _topicFor(unitId);
      _mqttService.publish(topic, payload);
      sent++;
      _statusMessage = 'WiFi: $sent / ${targets.length}';
      notifyListeners();
      if (sent < targets.length) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
    _lastWifiSsid = ssid;
    _lastWifiPassword = password;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_wifi_ssid', ssid);
    await prefs.setString('last_wifi_password', password);
    _statusMessage = 'WiFi "$ssid" odeslána na $sent P2L jednotek';
    notifyListeners();
  }

  /// Hromadné nahrání firmware na vybrané jednotky.
  ///
  /// [fileName] — kompletní cesta/URL, kterou si firmware downloader stáhne
  /// (např. `http://185.149.129.164/download/P2L_26033101NT.bin`). Aplikace
  /// nic na řetězci nemění, pošle ho přesně tak v `update.args.file_name`.
  ///
  /// 100ms pauza mezi publishi (analogicky k ostatním bulk operacím).
  /// Po flashi se jednotka restartuje a několik minut nebude online —
  /// proto označíme každou jednotku jako offline-until-alive.
  Future<void> sendBulkFirmwareUpdate({required String fileName}) async {
    if (_selectedUnits.isEmpty) return;
    final payload = CommandService.buildUpdateCommand(fileName: fileName);
    final targets = _selectedUnits.toList();
    var sent = 0;
    for (final unitId in targets) {
      final topic = _topicFor(unitId);
      _mqttService.publish(topic, payload);
      final id = _normUnitId(unitId);
      _markUnitOfflineUntilAlive(id);
      sent++;
      _statusMessage = 'FW: $sent / ${targets.length}';
      notifyListeners();
      if (sent < targets.length) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
    _statusMessage = 'Update odeslán na $sent P2L modulů ($fileName)';
    notifyListeners();
  }

  void sendGetParam(String unitId) {
    final payload = CommandService.buildGetParamCommand();
    final topic = _topicFor(unitId);
    _mqttService.publish(topic, payload);
    _statusMessage = 'Get param odeslan na $unitId';
    notifyListeners();
  }

  /// Změní ID jednotky. Firmware se po přijetí restartuje a přihlásí se
  /// novým ALIVE s [newId]. Lokálně staré entry odstraníme — nová entry
  /// vznikne automaticky při příštím ALIVE.
  Future<void> setUnitId(String oldId, int newId) async {
    final id = _normUnitId(oldId);
    final unit = _units[id];
    final isNewGen = unit?.isNewGen ??
        ((int.tryParse(id) ?? 0) >= 1000);

    final cmd = CommandService.buildSetUnitIdCommand(
      unitId: id,
      newId: newId,
      isNewGen: isNewGen,
    );
    _mqttService.publish(cmd.topic, cmd.payload);

    // Po set_id se firmware restartuje, na starý topic už neodpoví.
    // Pročistit lokální stav — nová entry přijde s prvním ALIVE z new ID.
    _units.remove(id);
    _selectedUnits.remove(id);
    _initialFetchDone.remove(id);
    _awaitingAliveAfterRestart.remove(id);
    _restartSentAt.remove(id);
    _pendingRestart.remove(id);
    _unitModules.remove(id);
    _unitModulesFetchedAt.remove(id);
    _unitModulesPending.remove(id);
    _unitBusScan.remove(id);
    _unitBusScanPending.remove(id);
    _unitBusScanScope.remove(id);
    _unitBusScanId.remove(id);
    _pendingAddVerify.remove(id);
    _pendingDispAddrAfterSetId.remove(id);
    for (final key in _busProbes.keys.where((k) => k.startsWith('$id:')).toList()) {
      final c = _busProbes.remove(key);
      if (c != null && !c.isCompleted) c.complete(null);
    }
    _unitDeviceFaults.remove(id);

    final newIdStr = newId.toString().padLeft(4, '0');
    _statusMessage =
        'ID jednotky $id → $newIdStr odesláno; jednotka se restartuje';
    notifyListeners();
  }

  // ============================================================
  // Device management flow
  // ============================================================

  Future<void> fetchDevices(String unitId) async {
    final id = _normUnitId(unitId);
    _unitModulesPending.add(id);
    // Ruční načtení ruší čekání na post-restart auto-trigger.
    _awaitingAliveAfterRestart.remove(id);
    _restartSentAt.remove(id);
    _setStatus('Načítám devices jednotky ${int.tryParse(id)?.toString() ?? id}…');
    notifyListeners();

    final cmd = CommandService.buildGetDevicesCommand(id);
    _mqttService.publish(cmd.topic, cmd.payload);
  }

  /// Read-only sken RS485 sběrnice (SCAN-DEVICES) — zjistí fyzicky připojené
  /// čipy bez zápisu do konfigurace jednotky. Vyžaduje FW ≥ P2L_26061801NT;
  /// starší FW neodpoví a po timeoutu se zobrazí hláška.
  Future<void> scanBus(String unitId,
      {BusScanScope scope = BusScanScope.all, int? scanId}) async {
    final id = _normUnitId(unitId);
    _unitBusScanPending.add(id);
    _unitBusScanScope[id] = scope;
    if (scanId != null) {
      _unitBusScanId[id] = scanId;
    } else {
      _unitBusScanId.remove(id);
    }
    final displayId = int.tryParse(id)?.toString() ?? id;
    _setStatus(scanId != null
        ? 'Skenuji adresu $scanId na sběrnici jednotky $displayId…'
        : 'Skenuji sběrnici jednotky $displayId… (může trvat i přes 10 s)');
    notifyListeners();

    final cmd = CommandService.buildScanDevicesCommand(
        unitId: id, scope: scope, scanId: scanId);
    _mqttService.publish(cmd.topic, cmd.payload);

    // Sken sběrnice je pomalý — reálně trvá i přes 20 s (ověřeno tracem).
    // Timeout proto velkoryse 45 s; teprve potom ukončíme pending (starší FW
    // SCAN-DEVICES nezná a neodpoví vůbec). Když odpověď dorazí dřív, pending
    // už je pryč.
    Future.delayed(const Duration(seconds: 45), () {
      if (!_unitBusScanPending.remove(id)) return;
      _setStatus(
          'Sken sběrnice ${int.tryParse(id)?.toString() ?? id}: bez odpovědi (starší firmware?)',
          isError: true);
      notifyListeners();
    });
  }

  /// Ověří jednu adresu cíleným `SCAN-DEVICES {"Id":N}` a vrátí, zda je na ní
  /// device fyzicky připojen: `true` = nalezen, `false` = sken odpověděl, ale
  /// nic tam není, `null` = bez odpovědi (starší firmware / timeout).
  /// Na rozdíl od [scanBus] výsledek **neukládá** do zobrazeného skenu — slouží
  /// jen jako kontrola (např. nový kus před výměnou).
  Future<bool?> probeBusAddress(String unitId, int address) {
    final id = _normUnitId(unitId);
    final key = '$id:$address';
    final existing = _busProbes[key];
    if (existing != null) return existing.future;

    final completer = Completer<bool?>();
    _busProbes[key] = completer;
    final displayId = int.tryParse(id)?.toString() ?? id;
    _setStatus('Ověřuji adresu $address na sběrnici jednotky $displayId…');
    notifyListeners();

    final cmd =
        CommandService.buildScanDevicesCommand(unitId: id, scanId: address);
    _mqttService.publish(cmd.topic, cmd.payload);

    Future.delayed(const Duration(seconds: 15), () {
      final c = _busProbes.remove(key);
      if (c == null || c.isCompleted) return;
      c.complete(null); // bez odpovědi
    });

    return completer.future;
  }

  /// Zahodí výsledek skenu sběrnice (zavření diagnostického panelu).
  void clearBusScan(String unitId) {
    final id = _normUnitId(unitId);
    if (_unitBusScan.remove(id) != null) notifyListeners();
  }

  /// Zneplatní uložený sken po operaci, která mění devices (přečíslování,
  /// výměna, přidání, přepis, smazání) — fyzický stav sběrnice i config se mění,
  /// takže staré porovnání by ukazovalo falešné „chybí"/„neuloženo". Volající
  /// následně stejně volá notifyListeners.
  void _invalidateBusScan(String id) {
    _unitBusScan.remove(id);
    _unitBusScanScope.remove(id);
    _unitBusScanId.remove(id);
  }

  final Set<String> _pendingRestart = {};
  final Set<String> _awaitingAliveAfterRestart = {};
  final Map<String, DateTime> _restartSentAt = {};
  // Jednotky, pro které jsme už po připojení k brokeru jednou fetchnuli devices.
  final Set<String> _initialFetchDone = {};

  /// Minimální doba po odeslání RESTART, po které teprve ALIVE počítáme jako
  /// "jednotka nabootovala" (chrání před in-flight ALIVE, které přišel těsně
  /// před doručením RESTART do jednotky).
  static const _restartGrace = Duration(seconds: 2);

  Future<void> addModules(String unitId, List<PumaModule> modules,
      {bool restartAfter = false}) async {
    if (modules.isEmpty) return;
    final id = _normUnitId(unitId);
    _unitModulesPending.add(id);
    _setStatus('Přidávám devices do ${int.tryParse(id)?.toString() ?? id}…');
    if (restartAfter) _pendingRestart.add(id);
    // Po přidání jednoho device ho rovnou ověříme cíleným skenem jeho adresy
    // (proběhne až po následném GET-DEVICES). Při přidání více devices najednou
    // (import) auto-ověření přeskočíme — jeden ID-sken víc adres nepokryje.
    if (modules.length == 1) {
      _pendingAddVerify[id] = modules.first.baseAddress;
    } else {
      _pendingAddVerify.remove(id);
    }
    notifyListeners();

    final cmd = CommandService.buildAddDevicesCommand(id, modules);
    _mqttService.publish(cmd.topic, cmd.payload);

    // Fallback: některé firmware neposílají O/.../ADD-DEVICES odpověď.
    // Po 200 ms si vynutíme restart (pokud je požadován) nebo GET-DEVICES.
    Future.delayed(const Duration(milliseconds: 200), () {
      if (!_unitModulesPending.contains(id)) return;
      _unitModulesPending.remove(id);
      if (_pendingRestart.remove(id)) {
        _awaitingAliveAfterRestart.add(id);
        _restartSentAt[id] = DateTime.now();
        restartUnit(id);
      } else {
        fetchDevices(id);
      }
    });
  }

  Future<void> restartUnit(String unitId) async {
    final id = _normUnitId(unitId);
    final cmd = CommandService.buildRestartCommand(id);
    _mqttService.publish(cmd.topic, cmd.payload);
    _markUnitOfflineUntilAlive(id);
    _setStatus('Restart jednotky ${int.tryParse(id)?.toString() ?? id} odeslán');
    notifyListeners();
  }

  /// Po odeslání RESTART nastaví jednotku do offline stavu (čítač zamrzne na
  /// "offline"), dokud nedorazí nový ALIVE. ALIVE handler obnoví `lastSeen`
  /// a `isOnline` automaticky.
  void _markUnitOfflineUntilAlive(String unitId) {
    final unit = _units[unitId];
    if (unit == null) return;
    unit.lastSeen = DateTime.now().subtract(const Duration(seconds: 700));
    unit.isOnline = false;
    // Aby další ALIVE jednotku zase animoval (i když je karta mimo viewport).
    _wavedUnitIds.remove(_normUnitId(unitId));
  }

  /// Hromadný restart: pošle RESTART všem vybraným jednotkám s 100ms pauzou.
  /// Každou jednotku zaregistruje do `_awaitingAliveAfterRestart`, aby si
  /// `_handleAlive` po jejím návratu sám znovu stáhnul devices.
  Future<void> sendBulkRestart() async {
    if (_selectedUnits.isEmpty) return;
    final targets = _selectedUnits.toList();
    var sent = 0;
    for (final unitId in targets) {
      final id = _normUnitId(unitId);
      final cmd = CommandService.buildRestartCommand(id);
      _awaitingAliveAfterRestart.add(id);
      _restartSentAt[id] = DateTime.now();
      _mqttService.publish(cmd.topic, cmd.payload);
      _markUnitOfflineUntilAlive(id);
      sent++;
      _statusMessage = 'Restart: $sent / ${targets.length}';
      notifyListeners();
      if (sent < targets.length) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
    _statusMessage = 'Restart odeslán na $sent P2L jednotek';
    notifyListeners();
  }

  /// Pošle text na DISP (4 znaky) na konkrétní adresu. Pozn.: nový FW neumí
  /// broadcast přes adresu 0 (vrací „unknown ID") — pro „všechny displeje"
  /// volej tuto metodu v cyklu přes skutečné DISP adresy.
  Future<void> sendDispData({
    required String unitId,
    required int dispAddress,
    required String data,
  }) async {
    final id = _normUnitId(unitId);
    final cmd = CommandService.buildSetDispDataCommand(
      unitId: id,
      dispAddress: dispAddress,
      data: data,
    );
    _mqttService.publish(cmd.topic, cmd.payload);
    _setStatus(data.isEmpty
        ? 'DISP @$dispAddress na $id: smazáno'
        : 'DISP @$dispAddress na $id: "$data"');
    notifyListeners();
  }

  /// SET-LEDS: rozsvítí LED na daném LEDS zařízení.
  /// Pokud `color` není zadané, použije se `ledColor` z nastavení (Barva LED).
  Future<void> sendLedsOn({
    required String unitId,
    required int ledsAddress,
    int style = 0,
    int? color,
  }) async {
    final id = _normUnitId(unitId);
    final effectiveColor = color ?? ledColor;
    final cmd = CommandService.buildSetLedsCommand(
      unitId: id,
      ledsAddress: ledsAddress,
      style: style,
      color: effectiveColor,
    );
    _mqttService.publish(cmd.topic, cmd.payload);
    _setStatus('LEDS @$ledsAddress na $id: rozsvíceno');
    notifyListeners();
  }

  /// CLEAR-LEDS: zhasne LED na daném LEDS zařízení.
  Future<void> sendLedsOff({
    required String unitId,
    required int ledsAddress,
  }) async {
    final id = _normUnitId(unitId);
    final cmd = CommandService.buildClearLedsCommand(
      unitId: id,
      ledsAddress: ledsAddress,
    );
    _mqttService.publish(cmd.topic, cmd.payload);
    _setStatus('LEDS @$ledsAddress na $id: zhasnuto');
    notifyListeners();
  }

  /// Aktualizuje konfiguraci DIST sensoru (SET-CONFIG). Lokálně updatne model.
  Future<void> updateDistConfig({
    required String unitId,
    required int distAddress,
    required DistConfig config,
  }) async {
    final id = _normUnitId(unitId);
    final cmd = CommandService.buildSetDistConfigCommand(
      unitId: id,
      distAddress: distAddress,
      config: config,
    );
    _mqttService.publish(cmd.topic, cmd.payload);

    final list = _unitModules[id];
    if (list != null) {
      final idx = list.indexWhere((m) =>
          m.type == ModuleType.dist && m.baseAddress == distAddress);
      if (idx >= 0) {
        _unitModules[id] = [
          ...list.sublist(0, idx),
          PumaModule.dist(address: distAddress, config: config),
          ...list.sublist(idx + 1),
        ];
      }
    }
    _setStatus('DIST @$distAddress: config aktualizován');
    notifyListeners();
  }

  Future<void> recreateDevices(String unitId, List<PumaModule> modules) async {
    final id = _normUnitId(unitId);
    _unitModulesPending.add(id);
    _setStatus('Přepisuji konfiguraci $id…');
    notifyListeners();

    final cmd = CommandService.buildRecreateDevicesCommand(id, modules);
    _mqttService.publish(cmd.topic, cmd.payload);

    // Fallback pro firmware, který neposílá O/.../RECREATE-DEVICES odpověď.
    Future.delayed(const Duration(milliseconds: 200), () {
      if (!_unitModulesPending.contains(id)) return;
      _unitModulesPending.remove(id);
      fetchDevices(id);
    });
  }

  /// Smaže všechna devices jednotky (RECREATE-DEVICES s prázdným polem).
  Future<void> wipeDevices(String unitId) async {
    await recreateDevices(unitId, const []);
  }

  Future<void> deleteModule(String unitId, PumaModule module) async {
    final id = _normUnitId(unitId);
    _unitModulesPending.add(id);
    _setStatus('Mažu ${module.displayLabel} na ${int.tryParse(id)?.toString() ?? id}…');
    // Po smazání ověříme adresu skenem — když je čip pořád fyzicky na sběrnici,
    // ukáže se jako šedý „ghost" (v configu už není, na sběrnici ano).
    _pendingAddVerify[id] = module.baseAddress;
    notifyListeners();

    final cmd = CommandService.buildDeleteDevicesCommand(id, [module]);
    _mqttService.publish(cmd.topic, cmd.payload);

    // Fallback: pokud firmware neodpoví na DELETE-DEVICES, refreshni seznam ručně.
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!_unitModulesPending.contains(id)) return;
      _unitModulesPending.remove(id);
      fetchDevices(id);
    });
  }

  Future<void> replaceDevice({
    required String unitId,
    required DeviceType type,
    required int oldAddress,
    required int newDefaultAddress,
    bool restartAfter = false,
  }) async {
    final id = _normUnitId(unitId);
    _unitModulesPending.add(id);
    _setStatus(
        'Výměna ${type.code} @$oldAddress za nový ($newDefaultAddress) na $id…');
    if (restartAfter) _pendingRestart.add(id);
    notifyListeners();

    // Nový FW: DEVICE-REPLACE má From = factory default nového kusu,
    // To = adresa vadného (původního) device.
    final cmd = CommandService.buildDeviceReplaceCommand(
      unitId: id,
      fromAddress: newDefaultAddress,
      toAddress: oldAddress,
    );
    _mqttService.publish(cmd.topic, cmd.payload);
  }

  /// Přečíslování existujícího device (DEVICE-SET-ID). Změní adresu z
  /// [oldAddress] na [newAddress]. Firmware atomicky přemapuje celý čip.
  Future<void> setDeviceId({
    required String unitId,
    required DeviceType type,
    required int oldAddress,
    required int newAddress,
    bool restartAfter = false,
  }) async {
    final id = _normUnitId(unitId);
    _unitModulesPending.add(id);
    _setStatus(
        'Přečíslování ${type.code} @$oldAddress → $newAddress na $id…');
    if (restartAfter) _pendingRestart.add(id);
    // PUM-A (displej) → po potvrzení zobrazíme novou adresu na displeji.
    if (type == DeviceType.disp) {
      _pendingDispAddrAfterSetId[id] = newAddress;
    } else {
      _pendingDispAddrAfterSetId.remove(id);
    }
    notifyListeners();

    final cmd = CommandService.buildDeviceSetIdCommand(
      unitId: id,
      fromAddress: oldAddress,
      toAddress: newAddress,
    );
    _mqttService.publish(cmd.topic, cmd.payload);
  }

  Future<void> applyTemplateToUnits(
      DeviceTemplate template, List<String> targetUnitIds) async {
    final normIds = <String>[];
    for (final target in targetUnitIds) {
      final id = _normUnitId(target);
      final cmd = CommandService.buildRecreateDevicesCommand(id, template.modules);
      _mqttService.publish(cmd.topic, cmd.payload);
      _unitModulesPending.add(id);
      normIds.add(id);
    }
    _setStatus(
        'Šablona "${template.name}" aplikována na ${targetUnitIds.length} jednotek');
    notifyListeners();

    // Fallback: firmware neposílá O/.../RECREATE-DEVICES odpověď.
    Future.delayed(const Duration(milliseconds: 200), () {
      for (final id in normIds) {
        if (!_unitModulesPending.contains(id)) continue;
        _unitModulesPending.remove(id);
        fetchDevices(id);
      }
    });
  }

  Future<void> saveTemplate(DeviceTemplate template) async {
    final idx = _templates.indexWhere((t) => t.name == template.name);
    if (idx >= 0) {
      _templates[idx] = template;
    } else {
      _templates.add(template);
    }
    await _persistTemplates();
    notifyListeners();
  }

  Future<void> deleteTemplate(String name) async {
    _templates.removeWhere((t) => t.name == name);
    await _persistTemplates();
    notifyListeners();
  }

  /// True, pokud existuje šablona se stejným názvem (case-insensitive, trim).
  bool hasTemplate(String name) {
    final needle = name.trim().toLowerCase();
    return _templates.any((t) => t.name.trim().toLowerCase() == needle);
  }

  /// Vrátí unikátní název odvozený z [base]. Pokud `base` neexistuje, vrátí
  /// `base`. Jinak hledá nejnižší volný suffix `(2)`, `(3)`, …
  String suggestUniqueTemplateName(String base) {
    final trimmed = base.trim();
    if (!hasTemplate(trimmed)) return trimmed;
    for (var i = 2; i < 1000; i++) {
      final candidate = '$trimmed ($i)';
      if (!hasTemplate(candidate)) return candidate;
    }
    return '$trimmed (${DateTime.now().millisecondsSinceEpoch})';
  }

  Future<void> _persistTemplates() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('device_templates', DeviceTemplate.listToJson(_templates));
  }

  /// Serializuje broker profily, šablony a LED pattern do jednoho JSON stringu.
  /// WiFi credentials se z bezpečnostních důvodů neexportují.
  String exportSettingsJson() {
    return const JsonEncoder.withIndent('  ').convert({
      'version': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'brokerProfiles': _profiles.map((p) => p.toJson()).toList(),
      'deviceTemplates': _templates.map((t) => t.toJson()).toList(),
      'ledPattern': {
        'on': ledsOn,
        'off': ledsOff,
        'color': ledColor,
      },
    });
  }

  /// Importuje nastavení z JSON stringu — přepíše broker profily, šablony,
  /// LED pattern. Aktivní profil se zachová pokud existuje, jinak `-1`.
  /// Vrací `null` při úspěchu, jinak chybovou zprávu.
  Future<String?> importSettingsJson(String jsonString) async {
    final dynamic decoded;
    try {
      decoded = jsonDecode(jsonString);
    } catch (e) {
      return 'Nelze parsovat JSON: $e';
    }
    if (decoded is! Map<String, dynamic>) {
      return 'Neplatný formát: očekáván objekt';
    }

    try {
      final activeBefore = _activeProfileIndex >= 0 &&
              _activeProfileIndex < _profiles.length
          ? _profiles[_activeProfileIndex].name
          : null;

      final profilesRaw = decoded['brokerProfiles'];
      if (profilesRaw is List) {
        _profiles = profilesRaw
            .whereType<Map<String, dynamic>>()
            .map(BrokerProfile.fromJson)
            .toList();
      }

      final templatesRaw = decoded['deviceTemplates'];
      if (templatesRaw is List) {
        _templates = templatesRaw
            .whereType<Map<String, dynamic>>()
            .map(DeviceTemplate.fromJson)
            .toList();
      }

      final ledRaw = decoded['ledPattern'];
      if (ledRaw is Map<String, dynamic>) {
        ledsOn = (ledRaw['on'] as num?)?.toInt() ?? ledsOn;
        ledsOff = (ledRaw['off'] as num?)?.toInt() ?? ledsOff;
        ledColor = (ledRaw['color'] as num?)?.toInt() ?? ledColor;
      }

      // Zkusit zachovat aktivní profil podle názvu, jinak -1.
      _activeProfileIndex = activeBefore == null
          ? -1
          : _profiles.indexWhere((p) => p.name == activeBefore);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('broker_profiles', BrokerProfile.listToJson(_profiles));
      await prefs.setInt('active_profile', _activeProfileIndex);
      await prefs.setString('device_templates', DeviceTemplate.listToJson(_templates));
      await prefs.setInt('leds_on', ledsOn);
      await prefs.setInt('leds_off', ledsOff);
      await prefs.setInt('led_color', ledColor);

      notifyListeners();
      return null;
    } catch (e) {
      return 'Chyba při importu: $e';
    }
  }

  /// Pošle `get_param` na všechny známé jednotky s 100 ms pauzou mezi publishi
  /// (aby se nezahltil broker při desítkách jednotek po importu). Aktualizuje
  /// `_statusMessage` v každém kroku, takže UI ukazuje progress `X / N`.
  Future<void> scanAll() async {
    final payload = CommandService.buildGetParamCommand();
    final targets = _units.keys.toList();
    if (targets.isEmpty) {
      _statusMessage = 'Žádné P2L moduly k aktualizaci';
      notifyListeners();
      return;
    }
    var sent = 0;
    for (final unitId in targets) {
      final topic = _topicFor(unitId);
      _mqttService.publish(topic, payload);
      sent++;
      _statusMessage = 'Scan: $sent / ${targets.length}';
      notifyListeners();
      if (sent < targets.length) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
    _statusMessage = 'Scan odeslán na $sent P2L modulů';
    notifyListeners();
  }

  /// Naimportuje seznam ID P2L modulů. Pro každé neznámé ID vytvoří
  /// placeholder jednotku (zobrazí se hned se šedou ikonou v UI). Pak pošle
  /// `get_param` na všechny jednotky (přes `scanAll`). Jednotky, které na
  /// brokeru reálně existují, odpoví a placeholder se přepne na plnou.
  /// Vrací počet nově vytvořených placeholderů.
  Future<int> importUnitIds(List<String> rawIds) async {
    var created = 0;
    for (final raw in rawIds) {
      final canonical = canonicalUnitId(raw);
      if (canonical == null) continue;
      if (_units.containsKey(canonical)) continue;
      final n = int.tryParse(canonical) ?? 0;
      _units[canonical] = P2LUnit.placeholder(
        canonical,
        isNewGen: n >= 1000,
      );
      created++;
    }
    _statusMessage = created > 0
        ? 'Importováno $created nových P2L modulů, dotazuji…'
        : 'Žádné nové ID — všechny už v seznamu';
    notifyListeners();
    await scanAll();
    return created;
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    _mqttService.dispose();
    super.dispose();
  }
}
