// Integrační testy launcheru lokálního serveru (portable Windows EXE).
//
// Testy REÁLNĚ spouští Node proces z `server/` v repu na volném portu —
// jinak by se neověřilo to podstatné (že server naběhne, že se pozná přes
// /api/health, že se po stopu ukončí a uklidí PID file).
//
// Skipují se, když v prostředí není Node nebo `server/` — appka bez nich
// funguje dál jako MQTT tester, takže to není chyba testu.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:p2l_tester/services/local_server.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Porty mimo běžný dev rozsah, ať test nekoliduje s ručně spuštěným
/// serverem na 3001.
const _testPort = 3097;

/// Prostředí pro integrační testy: Node v PATH + `server/` s nainstalovanými
/// závislostmi. Na stroji, kde chybí, testy skipujeme (viz [_requireEnv]).
Future<bool> _envReady() async {
  final sep = Platform.pathSeparator;
  final serverJs = File('${Directory.current.path}${sep}server${sep}server.js');
  final modules =
      Directory('${Directory.current.path}${sep}server${sep}node_modules');
  if (!serverJs.existsSync() || !modules.existsSync()) return false;
  try {
    final res = await Process.run('node', ['-v']);
    return res.exitCode == 0;
  } catch (_) {
    return false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempData;
  var envReady = false;

  /// Každá instance vytvořená testem — tearDown je zastaví, aby po spadlém
  /// testu nezůstal Node držet port (jinak další běh selže na EADDRINUSE).
  final spawned = <LocalServer>[];

  setUpAll(() async {
    // TestWidgetsFlutterBinding podstrkuje HttpClient, který na každý request
    // odpoví 400 — health probe by nikdy neprošel, i když server běží.
    // Tyto testy reálné HTTP na localhost potřebují.
    HttpOverrides.global = null;
    envReady = await _envReady();
  });

  /// Vrací false, když test nemá běžet — zapíše důvod do reportu.
  bool requireEnv() {
    if (envReady) return true;
    markTestSkipped('Node v PATH nebo server/node_modules chybí');
    return false;
  }

  setUp(() {
    tempData = Directory.systemTemp.createTempSync('p2l-local-server-test-');
    SharedPreferences.setMockInitialValues({
      'local_server_port': _testPort,
      'local_server_autostart': true,
    });
  });

  tearDown(() async {
    for (final server in spawned) {
      try {
        await server.stop();
      } catch (_) {
        // už zastavený / nikdy nespuštěný
      }
    }
    spawned.clear();
    try {
      tempData.deleteSync(recursive: true);
    } catch (_) {
      // WAL soubory může ještě držet ukončovaný proces — nevadí
    }
  });

  LocalServer newServer() {
    final server = LocalServer(dataDirOverride: tempData.path);
    spawned.add(server);
    return server;
  }

  group('LocalServer.init', () {
    test('najde server v repu a načte port z nastavení', () async {
      if (!requireEnv()) return;
      final server = newServer();
      await server.init();

      expect(server.isAvailable, isTrue,
          reason: 'server/ má být nalezen v cwd (repo root)');
      expect(server.serverDir, contains('server'));
      expect(server.port, _testPort);
      expect(server.dataDir, tempData.path);
      // Na volném portu nic neběží.
      expect(server.status, LocalServerStatus.stopped);
    });

    test('respektuje vypnutý autostart', () async {
      if (!requireEnv()) return;
      SharedPreferences.setMockInitialValues({
        'local_server_port': _testPort,
        'local_server_autostart': false,
      });
      final server = newServer();
      await server.init();
      expect(server.autostart, isFalse);

      final started = await server.maybeAutostart();
      expect(started, isFalse);
      expect(server.status, LocalServerStatus.stopped);
    });
  });

  group('LocalServer start/stop', () {
    test('spustí server, ohlásí běh a po stopu uklidí PID file', () async {
      if (!requireEnv()) return;
      final server = newServer();
      await server.init();

      final started = await server.start();
      expect(started, isTrue,
          reason: 'start selhal: ${server.lastError}\n${server.log.join('\n')}');
      expect(server.status, LocalServerStatus.running);
      expect(server.ownsProcess, isTrue,
          reason: 'proces spustila appka → musí ho i ukončit');
      expect(server.pid, isNotNull);
      expect(await server.probeHealth(), isTrue);

      // Server si zapisuje PID sám (kvůli úklidu sirotků po hard killu appky).
      final pidFile = File('${tempData.path}${Platform.pathSeparator}server.pid');
      expect(pidFile.existsSync(), isTrue);
      expect(int.tryParse(pidFile.readAsStringSync().trim()), isNotNull);

      // Nabídka „Založit správce" musí odpovídat skutečnému stavu DB.
      // Konkrétní hodnotu neasertujeme: dev server v repu má `.env` s
      // INITIAL_ADMIN_*, takže si správce naseeduje sám (portable dist `.env`
      // nemá → tam nabídka naskočí). Testujeme tedy propojení na endpoint.
      final status = await http.get(
        Uri.parse('http://127.0.0.1:$_testPort/api/bootstrap-status'),
      );
      expect(status.statusCode, 200);
      final hasUsers =
          (jsonDecode(status.body) as Map<String, dynamic>)['hasUsers'];
      expect(server.needsAdminBootstrap, hasUsers == false);

      await server.stop();
      expect(server.status, LocalServerStatus.stopped);
      expect(server.pid, isNull);
      expect(await server.probeHealth(), isFalse);
      expect(pidFile.existsSync(), isFalse,
          reason: 'PID file se má po stopu uklidit');
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('druhá instance běžící server adoptuje a nezabije ho', () async {
      if (!requireEnv()) return;
      final owner = newServer();
      await owner.init();
      expect(await owner.start(), isTrue,
          reason: 'start selhal: ${owner.lastError}');

      // Druhá appka (nebo tatáž po restartu) najde běžící server.
      final adopter = newServer();
      await adopter.init();
      expect(adopter.status, LocalServerStatus.running);

      expect(await adopter.start(), isTrue);
      expect(adopter.ownsProcess, isFalse,
          reason: 'cizí proces si nesmí přivlastnit');

      // Stop na adoptujícím serveru nesmí sestřelit cizí proces.
      await adopter.stop();
      expect(await owner.probeHealth(), isTrue,
          reason: 'adopter neměl cizí server ukončit');

      await owner.stop();
      expect(await owner.probeHealth(), isFalse);
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('osiřelý PID z předchozího běhu se uklidí a start projde', () async {
      if (!requireEnv()) return;
      // Simulace hard killu appky: PID file zůstal po procesu, který už není.
      // 999999 je mimo rozsah reálných PID na Windows.
      File('${tempData.path}${Platform.pathSeparator}server.pid')
          .writeAsStringSync('999999');

      final server = newServer();
      await server.init();
      expect(await server.start(), isTrue,
          reason: 'start selhal: ${server.lastError}\n${server.log.join('\n')}');
      expect(server.status, LocalServerStatus.running);

      await server.stop();
    }, timeout: const Timeout(Duration(seconds: 90)));
  }, skip: !Platform.isWindows && !Platform.isLinux && !Platform.isMacOS);

  group('LocalServer volba databáze', () {
    test('default je SQLite, nastavení MariaDB se uloží do prefs', () async {
      if (!requireEnv()) return;
      final server = newServer();
      await server.init();
      expect(server.dbConfig.driver, 'sqlite');
      expect(server.dbConfig.isMariadb, isFalse);
      expect(server.dbConfig.label, contains('SQLite'));

      await server.setDbConfig(const LocalServerDbConfig(
        driver: 'mariadb',
        host: '10.0.0.5',
        port: 3306,
        user: 'p2l',
        password: 'tajne',
        database: 'P2Lunits',
      ));
      expect(server.dbConfig.isMariadb, isTrue);
      expect(server.dbConfig.label, 'MariaDB 10.0.0.5:3306/P2Lunits');

      // Nová instance musí konfiguraci najít (drží se v SharedPreferences).
      final reopened = newServer();
      await reopened.init();
      expect(reopened.dbConfig.driver, 'mariadb');
      expect(reopened.dbConfig.host, '10.0.0.5');
      expect(reopened.dbConfig.user, 'p2l');
      expect(reopened.dbConfig.password, 'tajne');
      expect(reopened.dbConfig.database, 'P2Lunits');
    });

    test('přepnutí na SQLite zachová údaje k MariaDB pro příště', () async {
      if (!requireEnv()) return;
      final server = newServer();
      await server.init();
      await server.setDbConfig(const LocalServerDbConfig(
        driver: 'mariadb',
        host: '10.0.0.5',
        user: 'p2l',
        password: 'tajne',
      ));
      await server.setDbConfig(server.dbConfig.copyWith(driver: 'sqlite'));

      expect(server.dbConfig.driver, 'sqlite');
      expect(server.dbConfig.host, '10.0.0.5', reason: 'údaje se nemají mazat');
      expect(server.dbConfig.password, 'tajne');
    });

    test('běžící server hlásí svůj driver a nesoulad se pozná', () async {
      if (!requireEnv()) return;
      final server = newServer();
      await server.init();
      expect(await server.start(), isTrue,
          reason: 'start selhal: ${server.lastError}\n${server.log.join('\n')}');

      // /api/health nese typ driveru — server v testu jede na SQLite.
      expect(server.serverDbDriver, 'sqlite');
      expect(server.dbMismatch, isFalse);

      // Změna nastavení bez restartu = běžící server jede nad jinou DB.
      // Tohle je stav, na který UI upozorňuje (jinak by zápisy chodily jinam).
      await server.setDbConfig(
        server.dbConfig.copyWith(driver: 'mariadb', host: '10.0.0.5'),
      );
      expect(server.dbMismatch, isTrue);

      await server.stop();
      // Zastavený server nesoulad nehlásí — není co restartovat.
      expect(server.dbMismatch, isFalse);
    }, timeout: const Timeout(Duration(seconds: 90)));
  }, skip: !Platform.isWindows && !Platform.isLinux && !Platform.isMacOS);
}
