// Testy nativní auth session (PRD-DB, milestone DB1):
// - BearerClient přidává Authorization header jen když je token nastavený
// - AuthSession.restore: loggedOut / loggedIn / 401 → smazání / offline
// - AuthSession.login: uložení tokenu, chybějící token, špatné heslo
// - normalizeApiBase

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:p2l_tester/services/auth_api.dart';
import 'package:p2l_tester/services/auth_http_client_io.dart';
import 'package:p2l_tester/services/auth_session.dart';
import 'package:p2l_tester/services/auth_token_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _meOkBody = '{"user":{"username":"radek","isAdmin":true}}';
const _loginOkBody =
    '{"ok":true,"token":"tok123","user":{"username":"radek","isAdmin":false}}';

/// AuthSession s MockClient handlerem místo reálného HTTP.
AuthSession _session(MockClientHandler handler) {
  return AuthSession(
    apiFactory: (base) => AuthApi(client: MockClient(handler), base: base),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    currentAuthToken = null;
    SharedPreferences.setMockInitialValues({});
  });

  group('BearerClient', () {
    test('přidá Authorization header, když je token nastavený', () async {
      String? seenAuth;
      final client = BearerClient(MockClient((request) async {
        seenAuth = request.headers['Authorization'];
        return http.Response('{}', 200);
      }));
      currentAuthToken = 'abc';
      await client.get(Uri.parse('http://x/api/me'));
      expect(seenAuth, 'Bearer abc');
    });

    test('bez tokenu header neposílá', () async {
      String? seenAuth;
      final client = BearerClient(MockClient((request) async {
        seenAuth = request.headers['Authorization'];
        return http.Response('{}', 200);
      }));
      await client.get(Uri.parse('http://x/api/me'));
      expect(seenAuth, isNull);
    });
  });

  group('AuthSession.restore', () {
    test('bez uloženého tokenu → loggedOut, žádné HTTP', () async {
      var called = false;
      final s = _session((request) async {
        called = true;
        return http.Response(_meOkBody, 200);
      });
      await s.restore();
      expect(s.status, AuthSessionStatus.loggedOut);
      expect(called, isFalse);
    });

    test('platný token → loggedIn + user', () async {
      SharedPreferences.setMockInitialValues({
        'auth_session_token': 'tok123',
        'auth_api_base': 'http://server:3001/api',
        'auth_session_user': 'radek',
      });
      final s = _session((request) async => http.Response(_meOkBody, 200));
      await s.restore();
      expect(s.status, AuthSessionStatus.loggedIn);
      expect(s.user?.username, 'radek');
      expect(s.user?.isAdmin, isTrue);
      expect(s.apiBase, 'http://server:3001/api');
      expect(currentAuthToken, 'tok123');
    });

    test('401 (vypršelý token) → loggedOut a token smazaný', () async {
      SharedPreferences.setMockInitialValues({
        'auth_session_token': 'expired',
        'auth_session_user': 'radek',
      });
      final s =
          _session((request) async => http.Response('{"error":"x"}', 401));
      await s.restore();
      expect(s.status, AuthSessionStatus.loggedOut);
      expect(s.savedUsername, isNull);
      expect(currentAuthToken, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth_session_token'), isNull);
    });

    test('síťová chyba → offline, token zůstává', () async {
      SharedPreferences.setMockInitialValues({
        'auth_session_token': 'tok123',
        'auth_session_user': 'radek',
      });
      final s = _session((request) async => throw Exception('no route'));
      await s.restore();
      expect(s.status, AuthSessionStatus.offline);
      expect(s.savedUsername, 'radek');
      expect(currentAuthToken, 'tok123');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth_session_token'), 'tok123');
    });
  });

  group('AuthSession.login', () {
    test('úspěch → loggedIn, token + server + jméno v prefs', () async {
      final s = _session((request) async => http.Response(_loginOkBody, 200));
      await s.login(
          base: '192.168.1.10:3001', username: 'radek', password: 'heslo');
      expect(s.status, AuthSessionStatus.loggedIn);
      expect(s.apiBase, 'http://192.168.1.10:3001/api');
      expect(currentAuthToken, 'tok123');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth_session_token'), 'tok123');
      expect(prefs.getString('auth_api_base'), 'http://192.168.1.10:3001/api');
      expect(prefs.getString('auth_session_user'), 'radek');
    });

    test('backend bez tokenu v body → AuthException no_token', () async {
      final s = _session((request) async => http.Response(
          '{"ok":true,"user":{"username":"radek","isAdmin":false}}', 200));
      expect(
        () => s.login(base: 'x:3001', username: 'radek', password: 'heslo'),
        throwsA(isA<AuthException>()
            .having((e) => e.code, 'code', 'no_token')),
      );
    });

    test('špatné heslo → AuthException, stav zůstává loggedOut', () async {
      final s =
          _session((request) async => http.Response('{"error":"x"}', 401));
      await expectLater(
        s.login(base: 'x:3001', username: 'radek', password: 'spatne'),
        throwsA(isA<AuthException>()
            .having((e) => e.code, 'code', 'invalid_credentials')),
      );
      expect(s.status, AuthSessionStatus.loggedOut);
      expect(currentAuthToken, isNull);
    });
  });

  group('AuthSession.logout', () {
    test('smaže session i při nedostupném serveru', () async {
      SharedPreferences.setMockInitialValues({
        'auth_session_token': 'tok123',
        'auth_session_user': 'radek',
      });
      final s = _session((request) async => throw Exception('offline'));
      await s.restore(); // → offline
      await s.logout();
      expect(s.status, AuthSessionStatus.loggedOut);
      expect(currentAuthToken, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth_session_token'), isNull);
    });
  });

  // R6: EXE si dřív spouštělo vlastní Node server na loopbacku a uložilo si
  // jeho adresu. Server zmizel, takže uložený base musí ustoupit firemnímu —
  // jinak by se appka po updatu marně hlásila na mrtvý port.
  group('migrace uloženého loopback base (R6)', () {
    test('uložený localhost se přepíše na firemní server a uloží', () async {
      SharedPreferences.setMockInitialValues({
        'auth_api_base': 'http://127.0.0.1:3001/api',
      });
      final s = _session((request) async => http.Response('{}', 401));
      await s.restore();
      expect(s.apiBase, authApiBase);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth_api_base'), authApiBase);
    });

    test('uložený vzdálený server zůstane nedotčený', () async {
      SharedPreferences.setMockInitialValues({
        'auth_api_base': 'https://db.firma.cz/api',
      });
      final s = _session((request) async => http.Response('{}', 401));
      await s.restore();
      expect(s.apiBase, 'https://db.firma.cz/api');
    });

    test('bez uloženého base se použije firemní default', () async {
      final s = _session((request) async => http.Response('{}', 401));
      await s.restore();
      expect(s.apiBase, authApiBase);
    });

    test('restore po migraci volá /me už na firemním serveru', () async {
      final seen = <String>[];
      final s = _session((request) async {
        seen.add(request.url.toString());
        return http.Response(_meOkBody, 200);
      });
      SharedPreferences.setMockInitialValues({
        'auth_api_base': 'http://localhost:3001/api',
        'auth_session_token': 'tok123',
      });
      await s.restore();
      expect(seen.single, '$authApiBase/me');
      expect(s.status, AuthSessionStatus.loggedIn);
    });
  });

  group('normalizeApiBase', () {
    test('holý host:port → doplní http a /api', () {
      expect(AuthSession.normalizeApiBase('192.168.1.10:3001'),
          'http://192.168.1.10:3001/api');
    });
    test('trailing slash a existující /api se nezdvojí', () {
      expect(AuthSession.normalizeApiBase('http://x:3001/api/'),
          'http://x:3001/api');
    });
    test('https zůstává', () {
      expect(AuthSession.normalizeApiBase('https://example.com'),
          'https://example.com/api');
    });
  });
}
