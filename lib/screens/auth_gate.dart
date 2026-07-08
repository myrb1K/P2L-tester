// AuthGate — vstupní bod webové verze. Na startu zavolá /api/me a podle
// výsledku zobrazí buď LoginScreen, nebo `child` (typicky _InitialRoute
// → HomeScreen).
//
// Native build (APK/EXE) AuthGate vůbec nepoužívá — main.dart pouští rovnou
// _InitialRoute, guardováno `kIsWeb`.

import 'package:flutter/material.dart';

import '../services/auth_api.dart';
import 'login_screen.dart';

class AuthGate extends StatefulWidget {
  final Widget child;
  final AuthApi? api;

  const AuthGate({super.key, required this.child, this.api});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

enum _AuthState { checking, loggedOut, loggedIn, networkError }

class _AuthGateState extends State<AuthGate> {
  late final AuthApi _api;
  _AuthState _state = _AuthState.checking;
  AuthUser? _user;
  Object? _lastError;

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? AuthApi();
    _check();
  }

  Future<void> _check() async {
    setState(() => _state = _AuthState.checking);
    try {
      final user = await _api.me();
      if (!mounted) return;
      if (user == null) {
        setState(() => _state = _AuthState.loggedOut);
      } else {
        setState(() {
          _user = user;
          _state = _AuthState.loggedIn;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _AuthState.networkError;
        _lastError = e;
      });
    }
  }

  void _onLoggedIn(AuthUser user) {
    setState(() {
      _user = user;
      _state = _AuthState.loggedIn;
    });
  }

  /// Obalí obrazovku vlastním [Overlay]. AuthGate je v [main.dart] vložen přes
  /// `MaterialApp.builder` NAD Navigator, takže stavy, které vrací něco jiného
  /// než `widget.child` (checking / error / login), běží mimo Navigator a nemají
  /// tedy Overlay ancestor. `EditableText` (textová pole na LoginScreenu),
  /// SnackBary i tooltipy ale Overlay vyžadují → jinak "No Overlay widget found".
  /// Stav `loggedIn` obaluje `widget.child` (= Navigator), který Overlay má sám.
  ///
  /// `key: ValueKey(_state)` je nutný: [Overlay] čte `initialEntries` jen při
  /// prvním mountu. Bez klíče by Flutter při přechodu (checking → loggedOut)
  /// recykloval stejný State a `initialEntries` ignoroval → zůstal by viset
  /// první obsah (spinner). Rozdílný klíč per stav vynutí přemount s novým childem.
  Widget _overlayHost(Widget child) => Overlay(
        key: ValueKey(_state),
        initialEntries: [OverlayEntry(builder: (_) => child)],
      );

  @override
  Widget build(BuildContext context) {
    switch (_state) {
      case _AuthState.checking:
        return _overlayHost(const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ));
      case _AuthState.networkError:
        return _overlayHost(Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_off, size: 48, color: Colors.grey),
                  const SizedBox(height: 16),
                  const Text(
                    'Auth backend není dostupný',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$_lastError',
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _check,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Zkusit znovu'),
                  ),
                ],
              ),
            ),
          ),
        ));
      case _AuthState.loggedOut:
        return _overlayHost(LoginScreen(api: _api, onLoggedIn: _onLoggedIn));
      case _AuthState.loggedIn:
        return _AuthScope(
          api: _api,
          user: _user!,
          onLoggedOut: () => setState(() => _state = _AuthState.loggedOut),
          child: widget.child,
        );
    }
  }
}

/// InheritedWidget zpřístupňující [AuthApi] a aktuálního uživatele
/// podstromu (pro logout button, admin gating v Settings, atd.).
class _AuthScope extends InheritedWidget {
  final AuthApi api;
  final AuthUser user;
  final VoidCallback onLoggedOut;

  const _AuthScope({
    required this.api,
    required this.user,
    required this.onLoggedOut,
    required super.child,
  });

  static _AuthScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_AuthScope>();

  @override
  bool updateShouldNotify(_AuthScope oldWidget) =>
      user.username != oldWidget.user.username ||
      user.isAdmin != oldWidget.user.isAdmin;
}

/// Veřejné API pro čtení auth stavu z dětských widgetů.
class AuthScope {
  static AuthUser? userOf(BuildContext context) =>
      _AuthScope.maybeOf(context)?.user;

  static AuthApi? apiOf(BuildContext context) =>
      _AuthScope.maybeOf(context)?.api;

  /// Zavolá `/api/logout` na backendu a překlopí UI na LoginScreen.
  static Future<void> logout(BuildContext context) async {
    final scope = _AuthScope.maybeOf(context);
    if (scope == null) return;
    try {
      await scope.api.logout();
    } catch (_) {
      // Logout nikdy nezablokuje — i kdyby backend nešel, UI musí přejít
      // do loggedOut stavu (uživatel si refreshne a /api/me to dořeší).
    }
    scope.onLoggedOut();
  }
}
