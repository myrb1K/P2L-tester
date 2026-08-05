// Entry point pro launcher lokálního Node serveru (portable Windows EXE).
// Conditional export jako u mqtt_client_factory:
//   dart:io (native) → local_server_io.dart (reálné spouštění procesu)
//   web              → local_server_stub.dart (no-op, server je na hostu)

export 'local_server_stub.dart' if (dart.library.io) 'local_server_io.dart';
