import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/broker_profile.dart';
import '../models/unit.dart';
import '../services/command_service.dart';
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

  // Getters pro profily
  List<BrokerProfile> get profiles => List.unmodifiable(_profiles);
  int get activeProfileIndex => _activeProfileIndex;

  // State
  final Map<String, P2LUnit> _units = {};
  final Set<String> _selectedUnits = {};
  AppMqttState _connectionState = AppMqttState.disconnected;
  String? _lastError;
  String _statusMessage = '';

  // Getters
  Map<String, P2LUnit> get units => Map.unmodifiable(_units);
  List<P2LUnit> get unitList => _units.values.toList()
    ..sort((a, b) {
      final na = int.tryParse(a.id.startsWith('u') ? a.id.substring(1) : a.id) ?? 0;
      final nb = int.tryParse(b.id.startsWith('u') ? b.id.substring(1) : b.id) ?? 0;
      return na.compareTo(nb);
    });
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
      _statusMessage = 'Pripojeno, cekam na ALIVE...';
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
    _statusMessage = '';
    notifyListeners();
  }

  void _handleMessage(MqttReceivedMessage<MqttMessage> message) {
    final topic = message.topic;
    final json = MqttService.parseJsonPayload(message);
    if (json == null) return;

    if (topic.contains('/ALIVE')) {
      _handleAlive(topic, json);
    } else if (topic.startsWith('A/SERVER/')) {
      _handleResponse(topic, json);
    }
  }

  void _handleAlive(String topic, Map<String, dynamic> json) {
    // Topic: D/<id>/UNIT/<id>/ALIVE
    final parts = topic.split('/');
    if (parts.length < 4) return;
    final unitId = parts[1];

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
