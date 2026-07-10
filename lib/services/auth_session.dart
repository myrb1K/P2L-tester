// Nativní auth session (PRD-DB/01-PRD.md, milestone DB1).
//
// Na webu session drží httpOnly cookie a vstup hlídá AuthGate — tenhle soubor
// se na webu nepoužívá. Na nativu (EXE/APK) je login OPT-IN: appka bez
// přihlášení funguje přesně jako dřív, session je potřeba jen pro centrální
// DB jednotek (DB2+). Token se ukládá do SharedPreferences a při startu se
// tiše obnoví (main.dart) — přihlášení je tak jednorázové, dokud JWT nevyprší
// (7 dní, rememberMe).
//
// Klíčové pravidlo: nedostupný server NIKDY neblokuje start ani práci
// s jednotkami — projeví se jen stavem `offline` v sekci Účet v Nastavení.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_api.dart';
import 'auth_token_store.dart';

enum AuthSessionStatus {
  /// Žádný uložený token — výchozí stav, appka jede lokálně jako dřív.
  loggedOut,

  /// Token uložený a právě ověřený proti `/api/me`.
  loggedIn,

  /// Token uložený, ale server nedostupný (síť/timeout/5xx). Token se
  /// zachovává — po „Zkusit znovu" nebo dalším startu se ověří znovu.
  offline,
}

class AuthSession extends ChangeNotifier {
  static const _tokenKey = 'auth_session_token';
  static const _baseKey = 'auth_api_base';
  static const _userKey = 'auth_session_user';

  /// Timeout pro tichou obnovu — krátký, ať stav v Nastavení nenaskakuje
  /// dlouho po startu, když server neběží.
  static const _restoreTimeout = Duration(seconds: 5);
  static const _loginTimeout = Duration(seconds: 10);

  final AuthApi Function(String base) _apiFactory;

  AuthSession({AuthApi Function(String base)? apiFactory})
      : _apiFactory = apiFactory ?? ((base) => AuthApi(base: base));

  /// Globální instance pro produkční kód (main.dart, AccountSection).
  static final AuthSession instance = AuthSession();

  AuthSessionStatus status = AuthSessionStatus.loggedOut;

  /// Uživatel z posledního úspěšného `/api/me` nebo loginu (jen loggedIn).
  AuthUser? user;

  /// Jméno z posledního úspěšného loginu — pro zobrazení ve stavu offline,
  /// kdy `/api/me` neprošlo a [user] je null.
  String? savedUsername;

  /// Base URL auth API (končí `/api`). Default z `--dart-define=AUTH_API_BASE`,
  /// po prvním loginu poslední použitý server ze SharedPreferences.
  String apiBase = authApiBase;

  bool get isLoggedIn => status == AuthSessionStatus.loggedIn;

  /// Tichá obnova session při startu appky (a při „Zkusit znovu").
  /// Nikdy nehází: neplatný/vypršelý token → [AuthSessionStatus.loggedOut],
  /// server nedostupný → [AuthSessionStatus.offline] (token zůstává).
  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    apiBase = prefs.getString(_baseKey) ?? authApiBase;
    savedUsername = prefs.getString(_userKey);
    final token = prefs.getString(_tokenKey);
    if (token == null || token.isEmpty) {
      status = AuthSessionStatus.loggedOut;
      notifyListeners();
      return;
    }

    currentAuthToken = token;
    try {
      final me = await _apiFactory(apiBase).me().timeout(_restoreTimeout);
      if (me == null) {
        // 401 — token vypršel nebo byl invalidován, session končí.
        await _clear(prefs);
      } else {
        user = me;
        savedUsername = me.username;
        status = AuthSessionStatus.loggedIn;
      }
    } catch (_) {
      // Síťová chyba / timeout / 5xx — token si necháme, jen jsme offline.
      status = AuthSessionStatus.offline;
    }
    notifyListeners();
  }

  /// Přihlášení proti serveru [base] (viz [normalizeApiBase] — stačí zadat
  /// `192.168.1.10:3001`). Při úspěchu uloží token + server + jméno do
  /// SharedPreferences. Hází [AuthException] (špatné heslo, rate limit)
  /// nebo síťové výjimky — obsluhuje login dialog.
  Future<void> login({
    required String base,
    required String username,
    required String password,
  }) async {
    final normalized = normalizeApiBase(base);
    final api = _apiFactory(normalized);
    // rememberMe: na nativu vždy — smysl opt-in loginu je „přihlásit se
    // jednou", takže bereme nejdelší TTL, které backend nabízí (7 dní).
    final loggedUser = await api
        .login(username: username, password: password, rememberMe: true)
        .timeout(_loginTimeout);
    final token = api.lastLoginToken;
    if (token == null || token.isEmpty) {
      throw const AuthException(
        'no_token',
        'Server nevrátil token — backend je potřeba aktualizovat (DB1).',
      );
    }

    currentAuthToken = token;
    user = loggedUser;
    savedUsername = loggedUser.username;
    apiBase = normalized;
    status = AuthSessionStatus.loggedIn;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
    await prefs.setString(_baseKey, normalized);
    await prefs.setString(_userKey, loggedUser.username);
    notifyListeners();
  }

  /// Odhlášení: smaže lokální session. `POST /logout` je best-effort —
  /// JWT nemá server-side blacklist, vyprší sám; offline odhlášení je OK.
  Future<void> logout() async {
    try {
      await _apiFactory(apiBase).logout().timeout(_restoreTimeout);
    } catch (_) {
      // offline logout je v pořádku — lokální stav se maže tak jako tak
    }
    final prefs = await SharedPreferences.getInstance();
    await _clear(prefs);
    notifyListeners();
  }

  Future<void> _clear(SharedPreferences prefs) async {
    await prefs.remove(_tokenKey);
    await prefs.remove(_userKey);
    // _baseKey záměrně zůstává — příští login předvyplní poslední server.
    currentAuthToken = null;
    user = null;
    savedUsername = null;
    status = AuthSessionStatus.loggedOut;
  }

  /// Normalizace uživatelského vstupu na API base:
  /// `192.168.1.10:3001` → `http://192.168.1.10:3001/api`. Doplní schéma
  /// (default http) a suffix `/api`, odstraní trailing `/`.
  static String normalizeApiBase(String raw) {
    var u = raw.trim();
    if (u.isEmpty) return u;
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      u = 'http://$u';
    }
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    if (!u.endsWith('/api')) u = '$u/api';
    return u;
  }
}
