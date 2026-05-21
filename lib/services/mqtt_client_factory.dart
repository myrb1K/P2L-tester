// Entry point pro vytvoření MqttClient instance napříč platformami.
// Conditional export vybere implementaci podle dostupné knihovny:
//   dart:io (native)  → MqttServerClient přes mqtt_client_factory_io.dart
//   dart:html (web)   → MqttBrowserClient přes mqtt_client_factory_web.dart
// Volající (typicky MqttService) jen volá createMqttClient(...).

export 'mqtt_client_factory_stub.dart'
    if (dart.library.io) 'mqtt_client_factory_io.dart'
    if (dart.library.html) 'mqtt_client_factory_web.dart';
