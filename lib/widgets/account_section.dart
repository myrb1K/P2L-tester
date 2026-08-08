// Sekce „Účet" v Nastavení — jediné místo v UI, kde se řeší účet
// (žádná ikona účtu v AppBaru, rozhodnuto 2026-07-08).
//
// - Web: login je povinná vstupní brána (AuthGate) → sekce ukazuje jen
//   přihlášeného uživatele + odhlášení (přes AuthScope).
// - Nativ (PRD-DB, DB1): login je opt-in — bez přihlášení appka funguje
//   beze změny. Stavy (loggedOut / loggedIn / offline) drží AuthSession.

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../screens/auth_gate.dart';
import '../services/auth_api.dart';
import '../services/auth_session.dart';

class AccountSection extends StatelessWidget {
  const AccountSection({super.key});

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) return _buildWeb(context);
    return _buildNative(context);
  }

  /// Web: uživatel je díky AuthGate vždy přihlášený — jen jméno + odhlášení.
  /// Po odhlášení AuthGate překlopí celou appku na LoginScreen.
  Widget _buildWeb(BuildContext context) {
    final user = AuthScope.userOf(context);
    if (user == null) return const SizedBox.shrink();
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: const Icon(Icons.person, color: Colors.green),
        title: Text(user.isAdmin ? '${user.username} (admin)' : user.username),
        subtitle: const Text('Přihlášen'),
        trailing: IconButton(
          icon: const Icon(Icons.logout),
          tooltip: 'Odhlásit se',
          onPressed: () => AuthScope.logout(context),
        ),
      ),
    );
  }

  Widget _buildNative(BuildContext context) {
    return AnimatedBuilder(
      animation: AuthSession.instance,
      builder: (context, _) {
        final session = AuthSession.instance;
        switch (session.status) {
          case AuthSessionStatus.loggedOut:
            return Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                leading: const Icon(Icons.person_outline),
                title: const Text('Přihlásit se'),
                subtitle: const Text(
                  'Volitelné — přístup k centrální databázi jednotek',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showLoginDialog(context),
              ),
            );
          case AuthSessionStatus.loggedIn:
            final u = session.user!;
            return Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                leading: const Icon(Icons.person, color: Colors.green),
                title: Text(u.isAdmin ? '${u.username} (admin)' : u.username),
                subtitle: Text('Přihlášen · ${_serverLabel(session.apiBase)}'),
                trailing: IconButton(
                  icon: const Icon(Icons.logout),
                  tooltip: 'Odhlásit se',
                  onPressed: () => session.logout(),
                ),
              ),
            );
          case AuthSessionStatus.offline:
            return Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                leading: const Icon(Icons.cloud_off, color: Colors.orange),
                title: Text(session.savedUsername ?? 'Uložené přihlášení'),
                subtitle: Text(
                  'Server nedostupný · ${_serverLabel(session.apiBase)}',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      tooltip: 'Zkusit znovu',
                      onPressed: () => session.restore(),
                    ),
                    IconButton(
                      icon: const Icon(Icons.logout),
                      tooltip: 'Odhlásit se',
                      onPressed: () => session.logout(),
                    ),
                  ],
                ),
              ),
            );
        }
      },
    );
  }

  /// `http://192.168.1.10:3001/api` → `192.168.1.10:3001` (pro subtitle).
  static String _serverLabel(String base) {
    final uri = Uri.tryParse(base);
    if (uri == null || uri.authority.isEmpty) return base;
    return uri.authority;
  }

  Future<void> _showLoginDialog(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final loggedIn = await showDialog<bool>(
      context: context,
      builder: (_) => const _LoginDialog(),
    );
    if (loggedIn == true) {
      final name = AuthSession.instance.user?.username ?? '';
      messenger.showSnackBar(
        SnackBar(content: Text('Přihlášen jako $name')),
      );
    }
  }
}

class _LoginDialog extends StatefulWidget {
  const _LoginDialog();

  @override
  State<_LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<_LoginDialog> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    // Server se nezadává — evidence je jedna, firemní (viz authApiBase).
    // Adresu smí za běhu změnit jen admin v sekci Účet.
    final server = AuthSession.instance.apiBase;
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _error = 'Vyplň jméno i heslo.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AuthSession.instance
          .login(base: server, username: username, password: password);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on AuthException catch (e) {
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _error = 'Server nedostupný: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Přihlásit se'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _usernameController,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'Jméno',
                prefixIcon: Icon(Icons.person_outline),
              ),
              autofocus: true,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _passwordController,
              enabled: !_busy,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Heslo',
                prefixIcon: Icon(Icons.lock_outline),
              ),
              onSubmitted: (_) => _submit(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Zrušit'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Přihlásit'),
        ),
      ],
    );
  }
}
