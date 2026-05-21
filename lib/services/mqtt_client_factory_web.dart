import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_browser_client.dart';

/// Web implementace (Flutter Web). Browser nemá TCP socket, proto vždy
/// WebSocket. `useWebsocket` parametr je ignorován (efektivně vždy true).
MqttClient createMqttClient({
  required String broker,
  required int port,
  required String clientIdentifier,
  required bool useSsl,
  required bool useWebsocket,
  String? wsPath,
}) {
  final url = '${useSsl ? "wss" : "ws"}://$broker${wsPath ?? "/mqtt"}';
  final client = MqttBrowserClient.withPort(url, clientIdentifier, port)
    ..keepAlivePeriod = 60
    ..autoReconnect = true
    ..resubscribeOnAutoReconnect = true
    ..logging(on: false)
    // Mosquitto vyžaduje MQTT subprotocol v WebSocket handshake.
    // Bez tohoto se broker spojení zavře před handshake response.
    ..websocketProtocols = MqttClientConstants.protocolsSingleDefault;
  return client;
}
