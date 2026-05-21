import 'dart:async';
import 'dart:convert';
import 'package:mqtt_client/mqtt_client.dart';
import 'mqtt_client_factory.dart';

enum AppMqttState { disconnected, connecting, connected, error }

class MqttService {
  MqttClient? _client;
  AppMqttState _state = AppMqttState.disconnected;
  String? _lastError;

  final _stateController = StreamController<AppMqttState>.broadcast();
  final _messageController =
      StreamController<MqttReceivedMessage<MqttMessage>>.broadcast();

  Stream<AppMqttState> get stateStream => _stateController.stream;
  Stream<MqttReceivedMessage<MqttMessage>> get messageStream =>
      _messageController.stream;
  AppMqttState get state => _state;
  String? get lastError => _lastError;

  void _setState(AppMqttState newState) {
    _state = newState;
    _stateController.add(newState);
  }

  Future<bool> connect({
    required String broker,
    required int port,
    required String username,
    required String password,
    bool useSsl = false,
    bool useWebsocket = false,
    String? wsPath,
  }) async {
    if (_state == AppMqttState.connecting) return false;

    _setState(AppMqttState.connecting);
    _lastError = null;

    _client = createMqttClient(
      broker: broker,
      port: port,
      clientIdentifier:
          'p2l_tester_${DateTime.now().millisecondsSinceEpoch}',
      useSsl: useSsl,
      useWebsocket: useWebsocket,
      wsPath: wsPath,
    );

    _client!.onConnected = () {
      _setState(AppMqttState.connected);
    };

    _client!.onDisconnected = () {
      if (_state != AppMqttState.error) {
        _setState(AppMqttState.disconnected);
      }
    };

    _client!.onAutoReconnect = () {
      _setState(AppMqttState.connecting);
    };

    _client!.onAutoReconnected = () {
      _setState(AppMqttState.connected);
    };

    final connMessage = MqttConnectMessage()
        .withClientIdentifier(_client!.clientIdentifier)
        .authenticateAs(username, password)
        .startClean();

    _client!.connectionMessage = connMessage;

    try {
      await _client!.connect();
    } catch (e) {
      _lastError = e.toString();
      _setState(AppMqttState.error);
      _client?.disconnect();
      return false;
    }

    if (_client!.connectionStatus?.state == MqttConnectionState.connected) {
      _client!.updates?.listen((messages) {
        for (final msg in messages) {
          _messageController.add(msg);
        }
      });
      _setState(AppMqttState.connected);
      return true;
    }

    _lastError = 'Connection failed: ${_client!.connectionStatus?.returnCode}';
    _setState(AppMqttState.error);
    return false;
  }

  void subscribe(String topic) {
    if (_client?.connectionStatus?.state == MqttConnectionState.connected) {
      _client!.subscribe(topic, MqttQos.atMostOnce);
    }
  }

  void publish(String topic, String payload) {
    if (_client?.connectionStatus?.state == MqttConnectionState.connected) {
      final builder = MqttClientPayloadBuilder();
      builder.addString(payload);
      _client!.publishMessage(topic, MqttQos.atMostOnce, builder.payload!);
    }
  }

  void publishBytes(String topic, List<int> bytes) {
    if (_client?.connectionStatus?.state == MqttConnectionState.connected) {
      final builder = MqttClientPayloadBuilder();
      for (final b in bytes) {
        builder.addByte(b);
      }
      _client!.publishMessage(topic, MqttQos.atMostOnce, builder.payload!);
    }
  }

  void disconnect() {
    _client?.disconnect();
    _setState(AppMqttState.disconnected);
  }

  static String getPayload(MqttReceivedMessage<MqttMessage> message) {
    final recMessage = message.payload as MqttPublishMessage;
    return MqttPublishPayload.bytesToStringAsString(
        recMessage.payload.message);
  }

  static Map<String, dynamic>? parseJsonPayload(
      MqttReceivedMessage<MqttMessage> message) {
    try {
      final payload = getPayload(message);
      return jsonDecode(payload) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    disconnect();
    _stateController.close();
    _messageController.close();
  }
}
