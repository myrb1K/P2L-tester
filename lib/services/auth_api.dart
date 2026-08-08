// HTTP klient pro auth backend (PRD-WEB/02-auth-bezpecnost.md).
//
// Web (M4): session drží httpOnly cookie, vstup hlídá AuthGate.
// Nativ (DB1, PRD-DB): opt-in login přes AuthSession — session drží bearer
// token (viz [lastLoginToken] a auth_http_client_io.dart).
//
// Base URL je pevně daná — serverová evidence je jedna, firemní (PRD-DB
// 03-PRD-sync.md: „Web, EXE i APK míří na jeden server"). Uživatel ji v běžném
// toku nezadává; login dialog chce jen jméno a heslo.
//
// Změnit ji lze VÝHRADNĚ při buildu přes --dart-define=AUTH_API_BASE=...
// - Dev proti lokálnímu backendu:
//     flutter run --dart-define=AUTH_API_BASE=http://localhost:3001/api
// - Web (same-origin za Nginx/Traefik):
//     flutter build web --dart-define=AUTH_API_BASE=/api
//
// Za běhu ji nejde přenastavit ani adminovi — zvažovaná admin-only pojistka
// v Nastavení by byla k ničemu: `isAdmin` chodí z /api/me, takže by se
// zobrazila jen když server odpovídá, a zmizela by přesně v situaci
// (přestěhovaný/nedostupný server), pro kterou by existovala.
// Přestěhování serveru se řeší novým buildem.

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth_http_client.dart';

const String authApiBase = String.fromEnvironment(
  'AUTH_API_BASE',
  defaultValue: 'https://p2ltester.smartbox.smartci4.com/api',
);

class AuthUser {
  final String username;
  final bool isAdmin;
  const AuthUser({required this.username, required this.isAdmin});

  factory AuthUser.fromJson(Map<String, dynamic> json) => AuthUser(
        username: json['username'] as String,
        isAdmin: json['isAdmin'] as bool? ?? false,
      );
}

/// Záznam ze seznamu uživatelů z admin endpointu (M4.5).
class AdminUserRow {
  final String username;
  final bool isAdmin;
  final String createdAt;
  const AdminUserRow({
    required this.username,
    required this.isAdmin,
    required this.createdAt,
  });

  factory AdminUserRow.fromJson(Map<String, dynamic> json) => AdminUserRow(
        username: json['username'] as String,
        isAdmin: json['isAdmin'] as bool? ?? false,
        createdAt: json['createdAt'] as String? ?? '',
      );
}

/// Vyhozeno z [AuthApi.login] při neplatných credentials nebo rate-limitu.
/// Také z admin metod při guardech (duplicate / not_found / self_delete / last_admin).
class AuthException implements Exception {
  final String code;
  final String message;
  const AuthException(this.code, this.message);
  @override
  String toString() => 'AuthException($code): $message';
}

class AuthApi {
  final http.Client _client;
  final String _base;

  /// JWT z posledního úspěšného [login] (pole `token` v response body,
  /// backend ho vrací od DB1). Čte ho nativní AuthSession a ukládá ho pro
  /// bearer autentizaci; web ho ignoruje (session drží httpOnly cookie).
  String? lastLoginToken;

  AuthApi({http.Client? client, String? base})
      : _client = client ?? createAuthClient(),
        _base = base ?? authApiBase;

  Uri _u(String path) => Uri.parse('$_base$path');

  /// Vrací [AuthUser] pokud je session platná, jinak `null` (401).
  /// Jiné chyby (network, 5xx) jsou propagovány.
  Future<AuthUser?> me() async {
    final res = await _client.get(_u('/me'));
    if (res.statusCode == 401) return null;
    if (res.statusCode != 200) {
      throw AuthException('http_${res.statusCode}', res.body);
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return AuthUser.fromJson(json['user'] as Map<String, dynamic>);
  }

  /// Pokusí se přihlásit; vrací uživatele nebo vyhodí [AuthException].
  Future<AuthUser> login({
    required String username,
    required String password,
    bool rememberMe = false,
  }) async {
    final res = await _client.post(
      _u('/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'username': username,
        'password': password,
        'rememberMe': rememberMe,
      }),
    );

    if (res.statusCode == 200) {
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      lastLoginToken = json['token'] as String?;
      return AuthUser.fromJson(json['user'] as Map<String, dynamic>);
    }
    if (res.statusCode == 401) {
      throw const AuthException('invalid_credentials', 'Špatné jméno nebo heslo.');
    }
    if (res.statusCode == 429) {
      throw const AuthException(
        'too_many_attempts',
        'Příliš mnoho neúspěšných pokusů. Zkus to za 15 minut.',
      );
    }
    throw AuthException('http_${res.statusCode}', res.body);
  }

  Future<void> logout() async {
    await _client.post(_u('/logout'));
  }

  // ─── M4.5 admin endpointy ────────────────────────────────────────
  //
  // Všechny vyžadují session s claim `isAdmin: true`. 403 = chybí role,
  // 401 = neplatná/chybějící session. Volání mapujeme na AuthException
  // s code z backend payloadu (duplicate / not_found / self_delete /
  // last_admin / invalid_*), aby UI mohlo zobrazit konkrétní hlášku.

  Future<List<AdminUserRow>> listUsers() async {
    final res = await _client.get(_u('/admin/users'));
    _throwIfNotOk(res);
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final users = (json['users'] as List).cast<Map<String, dynamic>>();
    return users.map(AdminUserRow.fromJson).toList();
  }

  Future<void> createUser({
    required String username,
    required String password,
    bool isAdmin = false,
  }) async {
    final res = await _client.post(
      _u('/admin/users'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'username': username,
        'password': password,
        'isAdmin': isAdmin,
      }),
    );
    _throwIfNotOk(res, expected: 201);
  }

  Future<void> deleteUser(String username) async {
    final res = await _client.delete(_u('/admin/users/$username'));
    _throwIfNotOk(res, expected: 204);
  }

  Future<void> resetUserPassword(String username, String newPassword) async {
    final res = await _client.post(
      _u('/admin/users/$username/reset'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'newPassword': newPassword}),
    );
    _throwIfNotOk(res);
  }

  void _throwIfNotOk(http.Response res, {int expected = 200}) {
    if (res.statusCode == expected) return;
    // Pokus o JSON s code/message; fallback na status code.
    String code = 'http_${res.statusCode}';
    String message = res.body;
    try {
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      code = json['error'] as String? ?? code;
      message = json['message'] as String? ?? code;
    } catch (_) {
      // nebudeme cpát do message celé HTML/empty body
      message = _humanForStatus(res.statusCode);
    }
    throw AuthException(code, message);
  }

  String _humanForStatus(int s) {
    switch (s) {
      case 401:
        return 'Nepřihlášený.';
      case 403:
        return 'Chybí admin oprávnění.';
      case 404:
        return 'Uživatel nenalezen.';
      case 409:
        return 'Uživatel s tímto jménem už existuje.';
      default:
        return 'Chyba serveru ($s).';
    }
  }
}
