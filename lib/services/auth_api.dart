// HTTP klient pro auth backend (PRD-WEB/02-auth-bezpecnost.md).
//
// V M4 se používá jen na webu (login screen pro Flutter Web). Na nativu
// se nevolá — kód je guardovaný `kIsWeb` v UI vrstvě.
//
// Base URL je konfigurovatelná přes --dart-define=AUTH_API_BASE=...
// - Dev (default): http://localhost:3001/api (backend na jiném portu)
// - Prod: /api (Nginx proxyuje same-origin)
//
// Build prod buildu:
//   flutter build web --dart-define=AUTH_API_BASE=/api

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth_http_client.dart';

const String authApiBase = String.fromEnvironment(
  'AUTH_API_BASE',
  defaultValue: 'http://localhost:3001/api',
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

/// Vyhozeno z [AuthApi.login] při neplatných credentials nebo rate-limitu.
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
}
