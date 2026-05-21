import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

/// Native implementace (Windows, Android, iOS, macOS, Linux).
/// Používá `MqttServerClient`, který umí TCP i WebSocket (přes flag).
MqttClient createMqttClient({
  required String broker,
  required int port,
  required String clientIdentifier,
  required bool useSsl,
  required bool useWebsocket,
  String? wsPath,
}) {
  final host = useWebsocket
      ? '${useSsl ? "wss" : "ws"}://$broker${wsPath ?? "/mqtt"}'
      : broker;
  final client = MqttServerClient(host, clientIdentifier)
    ..port = port
    ..useWebSocket = useWebsocket
    ..secure = useSsl
    ..keepAlivePeriod = 60
    ..autoReconnect = true
    ..resubscribeOnAutoReconnect = true
    ..logging(on: false);
  if (useWebsocket) {
    // Pokud i nativní klient jede přes WS, broker (např. Mosquitto)
    // vyžaduje MQTT subprotocol v handshake hlavičkách.
    client.websocketProtocols = MqttClientConstants.protocolsSingleDefault;
  }
  return client;
}
