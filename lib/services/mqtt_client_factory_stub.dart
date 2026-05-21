import 'package:mqtt_client/mqtt_client.dart';

/// Fallback stub — pokud kompilátor nemá ani `dart:io`, ani `dart:html`.
/// V praxi se nikdy nezavolá (mqtt_client_factory.dart re-exportuje
/// platformně-specifický soubor přes conditional import).
MqttClient createMqttClient({
  required String broker,
  required int port,
  required String clientIdentifier,
  required bool useSsl,
  required bool useWebsocket,
  String? wsPath,
}) {
  throw UnsupportedError(
    'MQTT klient není podporován na této platformě '
    '(nedostupné dart:io ani dart:html).',
  );
}
