import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dart:convert';

import '../models/broker_profile.dart';
import '../models/device.dart';
import '../models/device_template.dart';
import '../models/module.dart';
import '../models/unit.dart';
import '../services/command_service.dart';
import '../services/module_reconstruction.dart';
import '../services/mqtt_service.dart';

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
  List<DeviceTemplate> _templates = [];
  String _deviceActionStatus = '';

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
  List<DeviceTemplate> get templates => List.unmodifiable(_templates);
  String get deviceActionStatus => _deviceActionStatus;

  static String _normUnitId(String unitId) =>
      unitId.startsWith('u') ? unitId.substring(1) : unitId;

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
  }

  Future<void> addProfile(BrokerProfile profile) async {
    _profiles.add(profile);
    _activeProfileIndex = _profiles.length - 1;
    _applyProfile(profile);
    await _saveProfiles();
    notifyListeners();
  }

  Future<void> updateProfile(int index, BrokerProfile profile) async {
    if (index < 0 || index >= _profiles.length) return;
    _profiles[index] = profile;
    if (index == _activeProfileIndex) {
      _applyProfile(profile);
    }
    await _saveProfiles();
    notifyListeners();
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
      }
    } else if (_activeProfileIndex > index) {
      _activeProfileIndex--;
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
    );

    if (result) {
      _mqttService.subscribe('D/+/UNIT/+/ALIVE');
      _mqttService.subscribe('A/SERVER/+/CMD');
      // Odpovědi na device management commandy (P2L32 protokol)
      _mqttService.subscribe('O/+/UNIT/+/GET-DEVICES');
      _mqttService.subscribe('O/+/UNIT/+/ADD-DEVICES');
      _mqttService.subscribe('O/+/UNIT/+/RECREATE-DEVICES');
      _mqttService.subscribe('O/+/UNIT/+/DELETE-DEVICES');
      _mqttService.subscribe('O/+/DIST/+/REPLACE-FROM');
      _mqttService.subscribe('O/+/DISP/+/REPLACE-FROM');
      _statusMessage = 'Připojeno, čekám na ALIVE…';
      _tickTimer?.cancel();
      _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_units.isNotEmpty) {
          for (final unit in _units.values) {
            unit.isOnline = DateTime.now().difference(unit.lastSeen).inSeconds < 360;
          }
          notifyListeners();
        }
      });
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
    } else if (topic.startsWith('O/')) {
      // GET-DEVICES odpověď je top-level pole; ostatní O/ odpovědi jsou Map s Code/Message.
      final json = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
      _handleDeviceResponse(topic, json, message);
    }
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
    } else if (cmd == 'REPLACE-FROM' ||
        cmd == 'ADD-DEVICES' ||
        cmd == 'RECREATE-DEVICES' ||
        cmd == 'DELETE-DEVICES') {
      _deviceActionStatus = '$cmd na $unitId: ${code == 0 || code == '0' ? 'OK' : 'chyba'}${msg != null ? " — $msg" : ""}';
      _unitModulesPending.remove(unitId);
      if (code == 0 || code == '0') {
        if (_pendingRestart.remove(unitId)) {
          // S restartem: GET-DEVICES posílat až po návratu jednotky online (první ALIVE).
          _awaitingAliveAfterRestart.add(unitId);
          _restartSentAt[unitId] = DateTime.now();
          Future.microtask(() => restartUnit(unitId));
        } else {
          Future.microtask(() => fetchDevices(unitId));
        }
      } else {
        _pendingRestart.remove(unitId);
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
      _deviceActionStatus = 'Devices jednotky $unitId načteny (${devices.length} entries → ${_unitModules[unitId]!.length} modulů)';
    } else {
      _deviceActionStatus = 'GET-DEVICES $unitId: neočekávaný formát odpovědi';
    }
    notifyListeners();
  }

  void _handleAlive(String topic, Map<String, dynamic> json) {
    // Topic: D/<id>/UNIT/<id>/ALIVE
    final parts = topic.split('/');
    if (parts.length < 4) return;
    final unitId = _normUnitId(parts[1]);

    if (_units.containsKey(unitId)) {
      _units[unitId]!.lastSeen = DateTime.now();
      _units[unitId]!.isOnline = true;
      if (json['battery'] != null) {
        _units[unitId]!.battery = (json['battery'] as num).toDouble();
      }
      if (json['firmware'] != null) {
        _units[unitId]!.firmware = json['firmware'] as String;
      }
    } else {
      _units[unitId] = P2LUnit.fromAlive(unitId, json);
      _statusMessage = 'Nalezeno ${_units.length} jednotek';
    }

    // Po restartu: první ALIVE mimo grace window → dotáhni devices.
    if (_awaitingAliveAfterRestart.contains(unitId)) {
      final sentAt = _restartSentAt[unitId];
      if (sentAt != null && DateTime.now().difference(sentAt) >= _restartGrace) {
        _awaitingAliveAfterRestart.remove(unitId);
        _restartSentAt.remove(unitId);
        _initialFetchDone.add(unitId);
        _deviceActionStatus = 'Jednotka $unitId zpět online — načítám devices.';
        Future.microtask(() => fetchDevices(unitId));
      }
    } else if (_initialFetchDone.add(unitId)) {
      // První ALIVE této jednotky v rámci aktuálního připojení → auto-fetch.
      Future.microtask(() => fetchDevices(unitId));
    }
    notifyListeners();
  }

  void _handleResponse(String topic, Map<String, dynamic> json) {
    if (json['cmd'] == 'get_param' && json['args'] != null) {
      final args = json['args'] as Map<String, dynamic>;
      final unitId = args['id'] as String?;
      if (unitId == null) return;

      final lookupId = unitId.startsWith('u') ? unitId.substring(1) : unitId;

      if (_units.containsKey(lookupId)) {
        _units[lookupId]!.updateFromGetParam(args);
      } else if (_units.containsKey(unitId)) {
        _units[unitId]!.updateFromGetParam(args);
      } else {
        final unit = P2LUnit(id: lookupId);
        unit.updateFromGetParam(args);
        _units[lookupId] = unit;
        _statusMessage = 'Nalezeno ${_units.length} jednotek';
      }
      notifyListeners();
    }
  }

  void clearUnits() {
    _units.clear();
    _selectedUnits.clear();
    _statusMessage = 'Seznam vycisten';
    notifyListeners();
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
        final cmdTopic = CommandService.getCommandTopic(unitId);
        _mqttService.publish(cmdTopic, CommandService.buildClearCommand());
        final binTopic = CommandService.getBinTopic(unitId);
        _mqttService.publishBytes(binTopic, binPayload);
      } else {
        final topic = CommandService.getCommandTopic(unitId);
        _mqttService.publish(topic, oldPayload);
      }
    }
    _statusMessage = 'Test odeslan na ${_selectedUnits.length} jednotek';
    notifyListeners();
  }

  void sendClear() {
    final payload = CommandService.buildClearCommand();
    for (final unitId in _selectedUnits) {
      final topic = CommandService.getCommandTopic(unitId);
      _mqttService.publish(topic, payload);
    }
    _statusMessage = 'Clear odeslan na ${_selectedUnits.length} jednotek';
    notifyListeners();
  }

  void sendGetParam(String unitId) {
    final payload = CommandService.buildGetParamCommand();
    final topic = CommandService.getCommandTopic(unitId);
    _mqttService.publish(topic, payload);
    _statusMessage = 'Get param odeslan na $unitId';
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
    _deviceActionStatus = 'Načítám devices jednotky $id…';
    notifyListeners();

    final cmd = CommandService.buildGetDevicesCommand(id);
    _mqttService.publish(cmd.topic, cmd.payload);
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
    _deviceActionStatus = 'Přidávám moduly do $id…';
    if (restartAfter) _pendingRestart.add(id);
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
    _deviceActionStatus = 'Restart jednotky $id odeslán';
    notifyListeners();
  }

  /// Pošle text na DISP (4 znaky). Adresa 0 = broadcast na všechny displeje.
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
    _deviceActionStatus = data.isEmpty
        ? 'DISP @$dispAddress na $id: smazáno'
        : 'DISP @$dispAddress na $id: "$data"';
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
    _deviceActionStatus = 'DIST @$distAddress: config aktualizován';
    notifyListeners();
  }

  Future<void> recreateDevices(String unitId, List<PumaModule> modules) async {
    final id = _normUnitId(unitId);
    _unitModulesPending.add(id);
    _deviceActionStatus = 'Přepisuji konfiguraci $id…';
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
    _deviceActionStatus = 'Mažu ${module.displayLabel} na $id…';
    notifyListeners();

    final cmd = CommandService.buildDeleteDevicesCommand(id, [module]);
    _mqttService.publish(cmd.topic, cmd.payload);
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
    _deviceActionStatus =
        'Výměna ${type.code} @$oldAddress za nový ($newDefaultAddress) na $id…';
    if (restartAfter) _pendingRestart.add(id);
    notifyListeners();

    final cmd = CommandService.buildReplaceFromCommand(
      unitId: id,
      type: type,
      oldAddress: oldAddress,
      newDefaultAddress: newDefaultAddress,
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
    _deviceActionStatus =
        'Šablona "${template.name}" aplikována na ${targetUnitIds.length} jednotek';
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

  Future<void> _persistTemplates() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('device_templates', DeviceTemplate.listToJson(_templates));
  }

  void scanAll() {
    final payload = CommandService.buildGetParamCommand();
    for (final unitId in _units.keys) {
      final topic = CommandService.getCommandTopic(unitId);
      _mqttService.publish(topic, payload);
    }
    _statusMessage = 'Scan odeslan na ${_units.length} jednotek';
    notifyListeners();
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    _mqttService.dispose();
    super.dispose();
  }
}
