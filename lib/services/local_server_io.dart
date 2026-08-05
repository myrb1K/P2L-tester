// Launcher lokálního Node serveru pro portable Windows EXE.
//
// Proč: databáze jednotek (PRD-DB) žije v SQLite, kterou obsluhuje Node
// backend v `server/`. Bez běžícího serveru je EXE jen MQTT tester. Aby
// nebylo potřeba ručně spouštět `npm start`, appka si server nastartuje sama
// jako podproces a při zavření ho ukončí.
//
// Portable rozložení (viz tools/pack-portable.ps1):
//   P2L-Tester-vX.YY/
//     p2l_tester vX.YY.exe
//     server/
//       node.exe          ← přiložený runtime, aby nebyl potřeba systémový Node
//       server.js, db/, routes/, node_modules/
//
// Klíčová pravidla:
// - **Data leží mimo aplikační složku** (`%APPDATA%\P2L-Tester\server-data`),
//   předaná serveru přes `P2L_DATA_DIR`. Jinak by rozbalení novější verze
//   dist zipu přepsalo units.db.
// - **`.env` se nepoužívá** — konfiguraci (JWT_SECRET, PORT, DB_*) předáváme
//   jako env proměnné procesu. Secret se generuje jednou a drží
//   v SharedPreferences, takže vydané tokeny přežijí restart appky.
// - **Databáze může být SQLite (default) nebo MariaDB.** Při MariaDB si server
//   nedrží nic lokálně a všechny instance sdílejí jednu evidenci — viz
//   [LocalServerDbConfig]. Android a web si server spustit nemohou (není tam
//   Node runtime), ty se připojují k serveru na síti přes Nastavení → Účet.
// - **Cizí server se nikdy nezabíjí.** Když už na portu někdo odpovídá
//   (typicky `npm run dev` v terminálu), jen ho adoptujeme — [ownsProcess]
//   zůstane false a při zavření appky ho necháme běžet.
// - **Sirotci se uklízí přes PID file**, který si píše sám server
//   (server.js → data/server.pid). Hard kill appky graceful hook nespustí.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum LocalServerStatus {
  /// Portable rozložení nenalezeno — funkce se v UI vůbec neukáže.
  unavailable,
  stopped,
  starting,
  running,

  /// Spuštění selhalo — detail v [LocalServer.lastError] / [LocalServer.log].
  failed,
}

/// Kam si lokální server ukládá data.
///
/// `sqlite` — soubory v [LocalServer.dataDir]; nic dalšího není potřeba.
/// `mariadb` — sdílená databáze na serveru (typicky `P2Lunits`); evidence je
/// pak společná pro všechny počítače, které se na tu DB připojí. Schéma si
/// server vytvoří sám, databáze musí existovat.
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

  /// Krátký popis pro Nastavení.
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
  static const _autostartKey = 'local_server_autostart';
  static const _secretKey = 'local_server_jwt_secret';
  static const _portKey = 'local_server_port';
  static const _dbDriverKey = 'local_server_db_driver';
  static const _dbHostKey = 'local_server_db_host';
  static const _dbPortKey = 'local_server_db_port';
  static const _dbUserKey = 'local_server_db_user';
  static const _dbPasswordKey = 'local_server_db_password';
  static const _dbNameKey = 'local_server_db_name';

  /// Kolik řádků logu ze serveru držíme pro diagnostiku v Nastavení.
  static const _logLimit = 60;

  /// Jak dlouho čekáme, než server po spuštění začne odpovídat na /api/health.
  /// better-sqlite3 + schema init trvá na pomalém disku klidně 3 s (u MariaDB
  /// se čeká i na spojení po síti), 20 s je bezpečný strop, po kterém hlásíme
  /// selhání. Nedostupnou databázi ohlásí server sám a hned skončí — to se
  /// pozná z exit code, ne až timeoutem.
  static const _startupTimeout = Duration(seconds: 20);
  static const _healthTimeout = Duration(milliseconds: 1200);

  static final LocalServer instance = LocalServer();

  /// [dataDirOverride] používají jen testy, aby nepsaly do reálného
  /// %APPDATA%. Produkční kód nechává null (viz [_resolveDataDir]).
  LocalServer({String? dataDirOverride}) : _dataDirOverride = dataDirOverride;

  final String? _dataDirOverride;

  LocalServerStatus _status = LocalServerStatus.unavailable;
  LocalServerStatus get status => _status;

  String? _lastError;
  String? get lastError => _lastError;

  /// Adresář se `server.js` — null, když portable rozložení není k dispozici.
  String? _serverDir;
  String? get serverDir => _serverDir;

  /// Cesta k node runtime (přiložený `server/node.exe`, jinak `node` z PATH).
  String? _nodeExe;
  String? get nodeExe => _nodeExe;

  String? _dataDir;
  String? get dataDir => _dataDir;

  int _port = 3001;
  int get port => _port;

  bool _autostart = true;
  bool get autostart => _autostart;

  LocalServerDbConfig _dbConfig = const LocalServerDbConfig();
  LocalServerDbConfig get dbConfig => _dbConfig;

  /// True jen když server spustila tato appka — pak ho při zavření ukončíme.
  /// Adoptovaný cizí proces (npm run dev) necháváme běžet.
  bool _ownsProcess = false;
  bool get ownsProcess => _ownsProcess;

  Process? _process;
  int? _pid;
  int? get pid => _pid;

  final List<String> _log = [];
  List<String> get log => List.unmodifiable(_log);

  bool get isAvailable => _serverDir != null;
  bool get isRunning => _status == LocalServerStatus.running;

  String get baseUrl => 'http://127.0.0.1:$_port/api';

  /// True, když běžící server hlásí prázdnou tabulku uživatelů — první
  /// spuštění portable instalace, kdy je potřeba založit účet správce (jinak
  /// není čím se přihlásit; seed dělá server z INITIAL_ADMIN_* při startu).
  ///
  /// Zdroj je `/api/bootstrap-status`, ne existence `users.db` — soubor
  /// vznikne i při startu nad prázdnou DB, takže by nabídka zmizela dřív, než
  /// by uživatel účet vytvořil.
  bool _needsAdminBootstrap = false;
  bool get needsAdminBootstrap => _needsAdminBootstrap;

  /// Zjistí, jestli DB má uživatele. Ticho při chybě — je to jen podklad pro
  /// nabídku v Nastavení, nikdy nesmí shodit start.
  Future<void> _refreshBootstrapStatus() async {
    try {
      final res = await http
          .get(Uri.parse('$baseUrl/bootstrap-status'))
          .timeout(_healthTimeout);
      if (res.statusCode != 200) return;
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      _needsAdminBootstrap = json['hasUsers'] == false;
    } catch (_) {
      // starší server bez endpointu / síťová chyba — nabídku neukazujeme
    }
  }

  /// Detekce prostředí + načtení nastavení. Nespouští server — o to se stará
  /// [maybeAutostart] z main.dart, aby start appky nic neblokovalo.
  Future<void> init() async {
    _serverDir = _findServerDir();
    _nodeExe = await _findNode(_serverDir);
    _dataDir = _dataDirOverride ?? await _resolveDataDir();

    final prefs = await SharedPreferences.getInstance();
    _autostart = prefs.getBool(_autostartKey) ?? true;
    _port = prefs.getInt(_portKey) ?? 3001;
    _dbConfig = LocalServerDbConfig(
      driver: prefs.getString(_dbDriverKey) ?? 'sqlite',
      host: prefs.getString(_dbHostKey) ?? '127.0.0.1',
      port: prefs.getInt(_dbPortKey) ?? 3306,
      user: prefs.getString(_dbUserKey) ?? '',
      password: prefs.getString(_dbPasswordKey) ?? '',
      database: prefs.getString(_dbNameKey) ?? 'P2Lunits',
    );

    if (_serverDir == null || _nodeExe == null) {
      _status = LocalServerStatus.unavailable;
      if (_serverDir != null && _nodeExe == null) {
        _lastError = 'Nenalezen Node runtime (server/node.exe ani node v PATH).';
      }
    } else {
      // Server už může běžet z předchozího spuštění nebo z terminálu.
      if (await probeHealth()) {
        _status = LocalServerStatus.running;
        await _refreshBootstrapStatus();
      } else {
        _status = LocalServerStatus.stopped;
      }
    }
    notifyListeners();
  }

  /// Autostart při spuštění appky — respektuje přepínač v Nastavení.
  /// Vrací true, když je server po návratu dostupný.
  Future<bool> maybeAutostart() async {
    if (!isAvailable || !_autostart) return _status == LocalServerStatus.running;
    if (_status == LocalServerStatus.running) return true;
    return start();
  }

  /// Spustí server (nebo adoptuje už běžící). [adminUser]/[adminPassword]
  /// se předají jako INITIAL_ADMIN_* — server z nich při prázdné tabulce
  /// uživatelů založí správce a jinde je ignoruje. Do prefs se NEUKLÁDAJÍ.
  Future<bool> start({String? adminUser, String? adminPassword}) async {
    if (!isAvailable || _nodeExe == null) {
      _lastError = 'Portable server není k dispozici.';
      _status = LocalServerStatus.unavailable;
      notifyListeners();
      return false;
    }

    _lastError = null;
    _status = LocalServerStatus.starting;
    notifyListeners();

    // Cizí server na portu = adopce, ne druhá instance (SQLite by se tloukly).
    if (await probeHealth()) {
      _ownsProcess = false;
      _process = null;
      _pid = _readPidFile();
      _status = LocalServerStatus.running;
      _appendLog('[appka] server už běží — přebírám (neukončuji při zavření)');
      await _refreshBootstrapStatus();
      notifyListeners();
      return true;
    }

    await _killOrphan();

    final env = <String, String>{
      'PORT': '$_port',
      'JWT_SECRET': await _jwtSecret(),
      // P2L_DATA_DIR platí i pro MariaDB — server si tam pořád píše PID file.
      'P2L_DATA_DIR': _dataDir ?? '',
      'NODE_ENV': 'production',
      'DB_DRIVER': _dbConfig.driver,
    };
    if (_dbConfig.isMariadb) {
      env['DB_HOST'] = _dbConfig.host;
      env['DB_PORT'] = '${_dbConfig.port}';
      env['DB_USER'] = _dbConfig.user;
      env['DB_PASSWORD'] = _dbConfig.password;
      env['DB_NAME'] = _dbConfig.database;
    }
    if (adminUser != null && adminUser.isNotEmpty && adminPassword != null) {
      env['INITIAL_ADMIN_USER'] = adminUser;
      env['INITIAL_ADMIN_PASSWORD'] = adminPassword;
    }

    try {
      _process = await Process.start(
        _nodeExe!,
        ['server.js'],
        workingDirectory: _serverDir,
        environment: env,
      );
    } catch (e) {
      _lastError = 'Nepodařilo se spustit Node: $e';
      _status = LocalServerStatus.failed;
      notifyListeners();
      return false;
    }

    _ownsProcess = true;
    _pid = _process!.pid;
    _appendLog('[appka] spouštím $_nodeExe server.js (PID $_pid)');
    _pipeLogs(_process!);

    // Když proces spadne (chybí node_modules, obsazený port), nečekáme
    // na timeout — exit code přijde hned.
    var exited = false;
    unawaited(_process!.exitCode.then((code) {
      exited = true;
      _appendLog('[node] proces skončil s kódem $code');
      if (_status == LocalServerStatus.starting ||
          _status == LocalServerStatus.running) {
        _status = LocalServerStatus.failed;
        _lastError = 'Server skončil s kódem $code.';
        _process = null;
        _pid = null;
        notifyListeners();
      }
    }));

    final deadline = DateTime.now().add(_startupTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (exited) return false;
      if (await probeHealth()) {
        _status = LocalServerStatus.running;
        _lastError = null;
        _appendLog('[appka] server odpovídá na $baseUrl/health');
        await _refreshBootstrapStatus();
        notifyListeners();
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    _lastError = 'Server nenaběhl do ${_startupTimeout.inSeconds} s.';
    _status = LocalServerStatus.failed;
    notifyListeners();
    return false;
  }

  /// Ukončí server, pokud ho spustila tato appka. Cizí (adoptovaný) proces
  /// necháme běžet — nepatří nám.
  Future<void> stop() async {
    final proc = _process;
    if (!_ownsProcess || proc == null) {
      _process = null;
      _pid = null;
      _ownsProcess = false;
      if (_status != LocalServerStatus.unavailable) {
        _status = await probeHealth()
            ? LocalServerStatus.running
            : LocalServerStatus.stopped;
      }
      notifyListeners();
      return;
    }

    _appendLog('[appka] ukončuji server (PID ${proc.pid})');
    proc.kill();
    try {
      await proc.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      proc.kill(ProcessSignal.sigkill);
    }

    // Na Windows je kill() TerminateProcess, takže SIGTERM handler v serveru
    // neproběhne a PID file zůstane — uklidíme ho za něj.
    _removePidFile();

    _process = null;
    _pid = null;
    _ownsProcess = false;
    _status = LocalServerStatus.stopped;
    notifyListeners();
  }

  /// Restart — potřeba po založení správce (seed běží jen při startu serveru).
  Future<bool> restart({String? adminUser, String? adminPassword}) async {
    await stop();
    return start(adminUser: adminUser, adminPassword: adminPassword);
  }

  Future<bool> probeHealth({Duration timeout = _healthTimeout}) async {
    try {
      final res =
          await http.get(Uri.parse('$baseUrl/health')).timeout(timeout);
      if (res.statusCode != 200) return false;
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      if (json['ok'] != true) return false;
      // Starší server pole `db` neposílá → necháme null (nic nehlásíme).
      final db = json['db'];
      _serverDbDriver = db is String && db.isNotEmpty ? db : null;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Driver, na kterém běžící server skutečně jede (z `/api/health`).
  /// Null u starších serverů, které pole neposílají.
  String? _serverDbDriver;
  String? get serverDbDriver => _serverDbDriver;

  /// True, když běžící server jede nad jinou databází, než je nastavená.
  /// Nastane po adopci cizího procesu (`npm run dev` nad SQLite) nebo když
  /// se nastavení změnilo a server se od té doby nerestartoval.
  bool get dbMismatch =>
      isRunning &&
      _serverDbDriver != null &&
      _serverDbDriver != _dbConfig.driver;

  Future<void> setAutostart(bool value) async {
    _autostart = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autostartKey, value);
    notifyListeners();
  }

  Future<void> setPort(int value) async {
    _port = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_portKey, value);
    notifyListeners();
  }

  /// Uloží volbu databáze. Server konfiguraci čte jen při startu, takže
  /// běžící instanci musí volající restartovat (dělá to dialog v Nastavení).
  ///
  /// Heslo k MariaDB leží v SharedPreferences v otevřené podobě — stejně jako
  /// hesla brokerů. Kdo má přístup k profilu uživatele, přečte obojí; proto
  /// databázový účet ať má práva jen na tuhle jednu databázi.
  Future<void> setDbConfig(LocalServerDbConfig config) async {
    _dbConfig = config;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_dbDriverKey, config.driver);
    await prefs.setString(_dbHostKey, config.host);
    await prefs.setInt(_dbPortKey, config.port);
    await prefs.setString(_dbUserKey, config.user);
    await prefs.setString(_dbPasswordKey, config.password);
    await prefs.setString(_dbNameKey, config.database);
    notifyListeners();
  }

  // ─── detekce prostředí ─────────────────────────────────────────────

  /// Hledá adresář se `server.js`:
  /// 1. `<vedle EXE>/server` — portable dist,
  /// 2. `<cwd>/server` — dev (`flutter run` z rootu repa).
  static String? _findServerDir() {
    final sep = Platform.pathSeparator;
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = [
      '$exeDir${sep}server',
      '${Directory.current.path}${sep}server',
    ];
    for (final dir in candidates) {
      if (File('$dir${sep}server.js').existsSync()) return dir;
    }
    return null;
  }

  /// Přiložený runtime má přednost — jeho verze odpovídá zkompilovaným
  /// native modulům (better-sqlite3, bcrypt) v node_modules.
  static Future<String?> _findNode(String? serverDir) async {
    final sep = Platform.pathSeparator;
    if (serverDir != null) {
      final bundled = Platform.isWindows
          ? '$serverDir${sep}node.exe'
          : '$serverDir${sep}node';
      if (File(bundled).existsSync()) return bundled;
    }
    // Fallback na systémový Node (dev na tomto PC).
    try {
      final res = await Process.run('node', ['-v']);
      if (res.exitCode == 0) return 'node';
    } catch (_) {
      // není v PATH
    }
    return null;
  }

  /// `%APPDATA%\P2L-Tester\server-data` — záměrně mimo aplikační složku,
  /// aby DB přežila rozbalení nové verze dist zipu.
  static Future<String> _resolveDataDir() async {
    final sep = Platform.pathSeparator;
    final appData = Platform.environment['APPDATA'];
    if (appData != null && appData.isNotEmpty) {
      return '$appData${sep}P2L-Tester${sep}server-data';
    }
    final support = await getApplicationSupportDirectory();
    return '${support.path}${sep}server-data';
  }

  /// Secret musí být stabilní mezi starty, jinak by po restartu appky
  /// přestaly platit vydané JWT (a uživatel by se musel pořád přihlašovat).
  Future<String> _jwtSecret() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_secretKey);
    if (existing != null && existing.length >= 32) return existing;

    final rnd = Random.secure();
    final bytes = List<int>.generate(32, (_) => rnd.nextInt(256));
    final secret =
        bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    await prefs.setString(_secretKey, secret);
    return secret;
  }

  // ─── PID file (sirotci po hard killu appky) ────────────────────────

  File? _pidFile() {
    final dir = _dataDir;
    if (dir == null) return null;
    return File('$dir${Platform.pathSeparator}server.pid');
  }

  int? _readPidFile() {
    try {
      final f = _pidFile();
      if (f == null || !f.existsSync()) return null;
      return int.tryParse(f.readAsStringSync().trim());
    } catch (_) {
      return null;
    }
  }

  void _removePidFile() {
    try {
      _pidFile()?.deleteSync();
    } catch (_) {
      // už smazaný / zamčený — nic neřešíme
    }
  }

  /// Zabije osiřelý server z předchozího běhu. Volá se jen když /api/health
  /// neodpovídá, takže nemůže sestřelit funkční instanci. PID se ověřuje
  /// proti jménu procesu — PID se ve Windows recyklují.
  Future<void> _killOrphan() async {
    final orphanPid = _readPidFile();
    if (orphanPid == null) return;

    if (Platform.isWindows) {
      try {
        final res = await Process.run(
          'tasklist',
          ['/FI', 'PID eq $orphanPid', '/FO', 'CSV', '/NH'],
        );
        final out = (res.stdout as String).toLowerCase();
        if (!out.contains('node.exe')) {
          _removePidFile();
          return;
        }
        await Process.run('taskkill', ['/F', '/PID', '$orphanPid']);
        _appendLog('[appka] uklizen osiřelý server (PID $orphanPid)');
      } catch (e) {
        _appendLog('[appka] úklid PID $orphanPid selhal: $e');
      }
    } else {
      try {
        Process.killPid(orphanPid, ProcessSignal.sigterm);
        _appendLog('[appka] uklizen osiřelý server (PID $orphanPid)');
      } catch (_) {
        // proces už neexistuje
      }
    }
    _removePidFile();
  }

  // ─── logy ──────────────────────────────────────────────────────────

  void _pipeLogs(Process proc) {
    proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _appendLog('[node] $line'));
    proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _appendLog('[node!] $line'));
  }

  void _appendLog(String line) {
    if (line.trim().isEmpty) return;
    _log.add(line);
    if (_log.length > _logLimit) _log.removeRange(0, _log.length - _logLimit);
    if (kDebugMode) debugPrint('LocalServer: $line');
    notifyListeners();
  }
}
