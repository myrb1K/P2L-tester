// Sekce „Lokální server" v Nastavení — jen na nativu a jen když je vedle EXE
// (nebo v repu) nalezen portable server. Bez něj se nezobrazí vůbec nic, aby
// appka pro terén zůstala vizuálně stejná.
//
// Co tu uživatel řeší:
// - vidí, jestli server běží (a jestli ho spustila appka, nebo je „cizí"),
// - vybere databázi: SQLite soubor (default) nebo sdílená MariaDB,
// - vypne/zapne automatický start při spuštění appky,
// - při prvním spuštění založí účet správce (bez něj není čím se přihlásit),
// - ruční Start/Stop a log pro diagnostiku, když start selže.

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../services/auth_session.dart';
import '../services/local_server.dart';

class LocalServerSection extends StatelessWidget {
  const LocalServerSection({super.key});

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: LocalServer.instance,
      builder: (context, _) {
        final server = LocalServer.instance;
        if (!server.isAvailable) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 24),
            const Text(
              'Lokální server (databáze)',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Card(
              margin: EdgeInsets.zero,
              child: Column(
                children: [
                  _statusTile(context, server),
                  const Divider(height: 1),
                  _databaseTile(context, server),
                  const Divider(height: 1),
                  SwitchListTile(
                    value: server.autostart,
                    onChanged: (v) => server.setAutostart(v),
                    title: const Text('Spouštět se aplikací'),
                    subtitle: const Text(
                      'Server se zapne při startu a vypne při zavření appky',
                    ),
                    dense: true,
                  ),
                  if (server.needsAdminBootstrap) ...[
                    const Divider(height: 1),
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.person_add_alt,
                          color: Colors.orange),
                      title: const Text('Založit účet správce'),
                      subtitle: const Text(
                        'Databáze je nová a nemá žádného uživatele',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _showBootstrapDialog(context),
                    ),
                  ],
                  const Divider(height: 1),
                  _actionsRow(context, server),
                ],
              ),
            ),
            if (server.lastError != null) ...[
              const SizedBox(height: 8),
              Text(
                server.lastError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _statusTile(BuildContext context, LocalServer server) {
    final (icon, color, title) = switch (server.status) {
      LocalServerStatus.running when server.ownsProcess => (
          Icons.check_circle,
          Colors.green,
          'Běží (spuštěn aplikací)'
        ),
      LocalServerStatus.running => (
          Icons.check_circle_outline,
          Colors.green,
          'Běží (spuštěn zvlášť)'
        ),
      LocalServerStatus.starting => (Icons.hourglass_top, Colors.blue, 'Startuje…'),
      LocalServerStatus.failed => (Icons.error, Colors.red, 'Start selhal'),
      LocalServerStatus.stopped => (Icons.stop_circle, Colors.grey, 'Neběží'),
      LocalServerStatus.unavailable => (
          Icons.help_outline,
          Colors.grey,
          'Není k dispozici'
        ),
    };

    final details = [
      'Port ${server.port}',
      if (server.pid != null) 'PID ${server.pid}',
      if (server.dataDir != null) 'Data: ${server.dataDir}',
    ].join(' · ');

    return ListTile(
      dense: true,
      leading: Icon(icon, color: color),
      title: Text(title),
      subtitle: Text(details, style: const TextStyle(fontSize: 11)),
      isThreeLine: false,
    );
  }

  /// Volba databáze + varování, když běžící server jede nad jinou, než je
  /// nastavená (typicky adoptovaný `npm run dev` na SQLite).
  Widget _databaseTile(BuildContext context, LocalServer server) {
    final cfg = server.dbConfig;
    final mismatch = server.dbMismatch;
    return ListTile(
      dense: true,
      leading: Icon(
        cfg.isMariadb ? Icons.storage : Icons.insert_drive_file_outlined,
        color: mismatch ? Colors.orange : null,
      ),
      title: const Text('Databáze'),
      subtitle: Text(
        mismatch
            ? '${cfg.label}\nBěžící server ale jede na '
                '${server.serverDbDriver == 'mariadb' ? 'MariaDB' : 'SQLite'} '
                '— restartuj ho, ať se změna projeví.'
            : cfg.label,
        style: TextStyle(
          fontSize: 11,
          color: mismatch ? Colors.orange : null,
        ),
      ),
      isThreeLine: mismatch,
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _showDbDialog(context, server),
    );
  }

  Future<void> _showDbDialog(BuildContext context, LocalServer server) async {
    final messenger = ScaffoldMessenger.of(context);
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => _DatabaseDialog(server: server),
    );
    if (changed != true) return;
    messenger.showSnackBar(
      SnackBar(content: Text('Databáze: ${server.dbConfig.label}')),
    );
  }

  Widget _actionsRow(BuildContext context, LocalServer server) {
    final busy = server.status == LocalServerStatus.starting;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Row(
        children: [
          if (server.isRunning)
            OutlinedButton.icon(
              onPressed: busy ? null : () => server.stop(),
              icon: const Icon(Icons.stop, size: 18),
              label: const Text('Zastavit'),
            )
          else
            FilledButton.icon(
              onPressed: busy ? null : () => _startAndRestore(context, server),
              icon: const Icon(Icons.play_arrow, size: 18),
              label: const Text('Spustit'),
            ),
          const SizedBox(width: 8),
          if (server.log.isNotEmpty)
            TextButton.icon(
              onPressed: () => _showLog(context, server),
              icon: const Icon(Icons.article_outlined, size: 18),
              label: const Text('Log'),
            ),
        ],
      ),
    );
  }

  /// Po ručním startu má smysl hned zkusit obnovit session — jinak by karta
  /// Účet dál hlásila „Server nedostupný".
  Future<void> _startAndRestore(
      BuildContext context, LocalServer server) async {
    final ok = await server.start();
    if (ok) await AuthSession.instance.restore();
  }

  Future<void> _showLog(BuildContext context, LocalServer server) async {
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Log lokálního serveru'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: SelectableText(
              server.log.join('\n'),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Zavřít'),
          ),
        ],
      ),
    );
  }

  Future<void> _showBootstrapDialog(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final created = await showDialog<bool>(
      context: context,
      builder: (_) => const _AdminBootstrapDialog(),
    );
    if (created == true) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Správce vytvořen a přihlášen')),
      );
    }
  }
}

/// Volba databáze pro lokální server.
///
/// SQLite = soubor v datovém adresáři (default, nic dalšího netřeba).
/// MariaDB = sdílená databáze, do které míří i ostatní počítače; schéma si
/// server vytvoří sám, ale databáze musí existovat.
///
/// Server konfiguraci čte jen při startu, takže po uložení běžící instanci
/// restartujeme — jinak by zápisy dál chodily do staré databáze.
class _DatabaseDialog extends StatefulWidget {
  const _DatabaseDialog({required this.server});

  final LocalServer server;

  @override
  State<_DatabaseDialog> createState() => _DatabaseDialogState();
}

class _DatabaseDialogState extends State<_DatabaseDialog> {
  late String _driver;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _user;
  late final TextEditingController _password;
  late final TextEditingController _database;

  bool _busy = false;
  String? _error;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    final cfg = widget.server.dbConfig;
    _driver = cfg.driver;
    _host = TextEditingController(text: cfg.host);
    _port = TextEditingController(text: '${cfg.port}');
    _user = TextEditingController(text: cfg.user);
    _password = TextEditingController(text: cfg.password);
    _database = TextEditingController(text: cfg.database);
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _user.dispose();
    _password.dispose();
    _database.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final server = widget.server;
    LocalServerDbConfig cfg;
    if (_driver == 'mariadb') {
      final host = _host.text.trim();
      final port = int.tryParse(_port.text.trim()) ?? 0;
      final database = _database.text.trim();
      if (host.isEmpty || database.isEmpty) {
        setState(() => _error = 'Server a název databáze jsou povinné.');
        return;
      }
      if (port <= 0 || port > 65535) {
        setState(() => _error = 'Port musí být 1–65535.');
        return;
      }
      cfg = LocalServerDbConfig(
        driver: 'mariadb',
        host: host,
        port: port,
        user: _user.text.trim(),
        password: _password.text,
        database: database,
      );
    } else {
      // Přihlašovací údaje si necháme uložené, ať je uživatel nemusí psát
      // znovu, když se k MariaDB vrátí.
      cfg = server.dbConfig.copyWith(driver: 'sqlite');
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    await server.setDbConfig(cfg);

    // Restart jen když server patří nám — cizí (adoptovaný) proces nesaháme.
    if (server.isRunning && server.ownsProcess) {
      final ok = await server.restart();
      if (!ok) {
        setState(() {
          _busy = false;
          _error = server.lastError ??
              'Server se nepodařilo spustit nad novou databází.';
        });
        return;
      }
      await AuthSession.instance.restore();
    }

    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final isMaria = _driver == 'mariadb';
    final adopted = widget.server.isRunning && !widget.server.ownsProcess;
    return AlertDialog(
      title: const Text('Databáze lokálního serveru'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'sqlite',
                      label: Text('SQLite'),
                      icon: Icon(Icons.insert_drive_file_outlined, size: 16),
                    ),
                    ButtonSegment(
                      value: 'mariadb',
                      label: Text('MariaDB'),
                      icon: Icon(Icons.storage, size: 16),
                    ),
                  ],
                  selected: {_driver},
                  onSelectionChanged: _busy
                      ? null
                      : (s) => setState(() => _driver = s.first),
                  showSelectedIcon: false,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                isMaria
                    ? 'Sdílená databáze — evidence je společná pro všechny '
                        'počítače, které se na ni připojí.'
                    : 'Soubor v tomto počítači — evidence zůstane jen tady.',
                style: const TextStyle(fontSize: 11),
              ),
              if (isMaria) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _host,
                        enabled: !_busy,
                        decoration: const InputDecoration(
                          labelText: 'Server',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _port,
                        enabled: !_busy,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Port',
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _database,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    labelText: 'Databáze',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _user,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    labelText: 'Uživatel',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _password,
                  enabled: !_busy,
                  obscureText: _obscure,
                  decoration: InputDecoration(
                    labelText: 'Heslo',
                    isDense: true,
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscure ? Icons.visibility : Icons.visibility_off,
                        size: 18,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Databáze musí existovat — tabulky si server vytvoří sám. '
                  'Účty pro přihlášení do appky jsou pak taky v ní.',
                  style: TextStyle(fontSize: 11),
                ),
              ],
              if (adopted) ...[
                const SizedBox(height: 12),
                const Text(
                  'Server na tomto portu spustil někdo jiný, takže ho appka '
                  'nerestartuje. Změna se projeví až po jeho ručním restartu.',
                  style: TextStyle(fontSize: 11, color: Colors.orange),
                ),
              ],
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
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Zrušit'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Uložit'),
        ),
      ],
    );
  }
}

/// Založení prvního uživatele v nové databázi.
///
/// Seed dělá server sám z `INITIAL_ADMIN_*`, ale jen při startu a jen když je
/// tabulka uživatelů prázdná — proto server restartujeme s těmito proměnnými
/// a hned se přihlásíme. Heslo se nikam neukládá, žije jen v tomto dialogu.
class _AdminBootstrapDialog extends StatefulWidget {
  const _AdminBootstrapDialog();

  @override
  State<_AdminBootstrapDialog> createState() => _AdminBootstrapDialogState();
}

class _AdminBootstrapDialogState extends State<_AdminBootstrapDialog> {
  final _userController = TextEditingController(text: 'radek');
  final _passwordController = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _userController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final user = _userController.text.trim();
    final password = _passwordController.text;
    if (user.isEmpty || password.length < 8) {
      setState(() => _error = 'Jméno a heslo (min. 8 znaků) jsou povinné.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    final server = LocalServer.instance;
    final ok = await server.restart(adminUser: user, adminPassword: password);
    if (!ok) {
      setState(() {
        _busy = false;
        _error = server.lastError ?? 'Server se nepodařilo spustit.';
      });
      return;
    }

    try {
      await AuthSession.instance.login(
        base: server.baseUrl,
        username: user,
        password: password,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      setState(() {
        _busy = false;
        _error = 'Účet vznikl, ale přihlášení selhalo: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Založit účet správce'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Databáze je prázdná. Tímto účtem se budeš přihlašovat '
              'k databázi jednotek.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _userController,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'Jméno',
                prefixIcon: Icon(Icons.person_outline),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _passwordController,
              enabled: !_busy,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Heslo (min. 8 znaků)',
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
              : const Text('Vytvořit'),
        ),
      ],
    );
  }
}
