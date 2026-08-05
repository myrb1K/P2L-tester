// Web varianta launcheru lokálního serveru — no-op.
//
// Prohlížeč nemůže spustit proces (ani otevřít TCP spojení do MariaDB), takže
// na webu není co spouštět: appka se připojuje k Node serveru na síti — buď
// k tomu, který ji servíruje (Nginx + Node, same-origin), nebo k zadanému
// v Nastavení → Účet. API drží stejný tvar jako local_server_io.dart, aby
// volající kód nemusel větvit na kIsWeb.

import 'package:flutter/foundation.dart';

enum LocalServerStatus {
  /// Portable rozložení nenalezeno (nebo web) — funkce se v UI vůbec neukáže.
  unavailable,
  stopped,
  starting,
  running,

  /// Spuštění selhalo — detail v [LocalServer.lastError] / [LocalServer.log].
  failed,
}

/// Symetrie s nativní implementací — na webu se nikam nepředává.
class LocalServerDbConfig {
  const LocalServerDbConfig({
    this.driver = 'sqlite',
    this.host = '127.0.0.1',
    this.port = 3306,
    this.user = '',
    this.password = '',
    this.database = 'P2Lunits',
  });

  final String driver;
  final String host;
  final int port;
  final String user;
  final String password;
  final String database;

  bool get isMariadb => driver == 'mariadb';
  String get label => isMariadb ? 'MariaDB $host:$port/$database' : 'SQLite (soubor)';

  LocalServerDbConfig copyWith({
    String? driver,
    String? host,
    int? port,
    String? user,
    String? password,
    String? database,
  }) =>
      LocalServerDbConfig(
        driver: driver ?? this.driver,
        host: host ?? this.host,
        port: port ?? this.port,
        user: user ?? this.user,
        password: password ?? this.password,
        database: database ?? this.database,
      );
}

class LocalServer extends ChangeNotifier {
  static final LocalServer instance = LocalServer();

  /// [dataDirOverride] existuje jen kvůli symetrii s nativní implementací
  /// (používají ho testy) — na webu se ignoruje.
  LocalServer({String? dataDirOverride});

  LocalServerStatus get status => LocalServerStatus.unavailable;
  bool get isAvailable => false;
  bool get isRunning => false;
  bool get ownsProcess => false;
  bool get autostart => false;
  bool get needsAdminBootstrap => false;
  String? get lastError => null;
  String? get serverDir => null;
  String? get nodeExe => null;
  String? get dataDir => null;
  int? get pid => null;
  int get port => 3001;
  String get baseUrl => '/api';
  List<String> get log => const [];
  LocalServerDbConfig get dbConfig => const LocalServerDbConfig();
  String? get serverDbDriver => null;
  bool get dbMismatch => false;

  Future<void> init() async {}
  Future<bool> maybeAutostart() async => false;
  Future<bool> start({String? adminUser, String? adminPassword}) async => false;
  Future<bool> restart({String? adminUser, String? adminPassword}) async =>
      false;
  Future<void> stop() async {}
  Future<bool> probeHealth({Duration timeout = const Duration(seconds: 1)}) async =>
      false;
  Future<void> setAutostart(bool value) async {}
  Future<void> setPort(int value) async {}
  Future<void> setDbConfig(LocalServerDbConfig config) async {}
}
