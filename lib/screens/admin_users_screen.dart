// M4.5 — Admin UI pro správu uživatelů.
//
// Přístupné jen pro uživatele s isAdmin=true (gating v SettingsScreen
// + backend middleware requireAdmin vrátí 403 i kdyby UI náhodou pustilo).
//
// Pure additive change vůči M4 — žádná DB migrace, žádný breaking change
// existujícího login flow.

import 'package:flutter/material.dart';

import '../services/auth_api.dart';
import 'auth_gate.dart';

class AdminUsersScreen extends StatefulWidget {
  const AdminUsersScreen({super.key});

  @override
  State<AdminUsersScreen> createState() => _AdminUsersScreenState();
}

class _AdminUsersScreenState extends State<AdminUsersScreen> {
  AuthApi? _api;
  List<AdminUserRow>? _users;
  String? _error;
  bool _loading = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // AuthApi lookup z AuthScope (InheritedWidget — musí být tady, ne
    // v initState, kde context ještě nemá ancestors v plně sestaveném
    // tree). Username čteme až v build() pro robustnost.
    _api ??= AuthScope.apiOf(context) ?? AuthApi();
    if (_users == null && _loading) _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final users = await _api!.listUsers();
      if (!mounted) return;
      setState(() {
        _users = users;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is AuthException ? e.message : '$e';
        _loading = false;
      });
    }
  }

  Future<void> _addUser() async {
    final result = await showDialog<_NewUserResult>(
      context: context,
      builder: (_) => const _NewUserDialog(),
    );
    if (result == null) return;
    try {
      await _api!.createUser(
        username: result.username,
        password: result.password,
        isAdmin: result.isAdmin,
      );
      if (!mounted) return;
      _toast('Uživatel "${result.username}" vytvořen.');
      _reload();
    } on AuthException catch (e) {
      if (!mounted) return;
      _toast('Chyba: ${e.message}');
    }
  }

  Future<void> _resetPassword(AdminUserRow row) async {
    final newPwd = await showDialog<String>(
      context: context,
      builder: (_) => _ResetPasswordDialog(username: row.username),
    );
    if (newPwd == null) return;
    try {
      await _api!.resetUserPassword(row.username, newPwd);
      if (!mounted) return;
      _toast('Heslo pro "${row.username}" změněno.');
    } on AuthException catch (e) {
      if (!mounted) return;
      _toast('Chyba: ${e.message}');
    }
  }

  Future<void> _deleteUser(AdminUserRow row) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Smazat uživatele'),
        content: Text(
          'Opravdu smazat uživatele "${row.username}"? Tato akce je nevratná.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Zrušit'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Smazat'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _api!.deleteUser(row.username);
      if (!mounted) return;
      _toast('Uživatel "${row.username}" smazán.');
      _reload();
    } on AuthException catch (e) {
      if (!mounted) return;
      _toast('Chyba: ${e.message}');
    }
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Administrace uživatelů'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Obnovit',
            onPressed: _reload,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addUser,
        icon: const Icon(Icons.person_add),
        label: const Text('Nový'),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.grey),
              const SizedBox(height: 16),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _reload,
                icon: const Icon(Icons.refresh),
                label: const Text('Zkusit znovu'),
              ),
            ],
          ),
        ),
      );
    }
    final users = _users ?? [];
    if (users.isEmpty) {
      return const Center(child: Text('Žádní uživatelé.'));
    }
    final currentUsername = AuthScope.userOf(context)?.username ?? '';
    return ListView.separated(
      itemCount: users.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final u = users[i];
        final isSelf = u.username == currentUsername;
        return ListTile(
          leading: CircleAvatar(
            backgroundColor:
                u.isAdmin ? Colors.blue.shade100 : Colors.grey.shade200,
            child: Icon(
              u.isAdmin ? Icons.shield : Icons.person,
              color: u.isAdmin ? Colors.blue.shade800 : Colors.grey.shade700,
              size: 20,
            ),
          ),
          title: Row(
            children: [
              Text(u.username,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              if (u.isAdmin) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade100,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('admin',
                      style: TextStyle(fontSize: 10, color: Colors.blue)),
                ),
              ],
              if (isSelf) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.green.shade100,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('to jsi ty',
                      style: TextStyle(fontSize: 10, color: Colors.green)),
                ),
              ],
            ],
          ),
          subtitle: Text(
            'Vytvořen: ${u.createdAt}',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.key_outlined),
                tooltip: 'Reset hesla',
                onPressed: () => _resetPassword(u),
              ),
              IconButton(
                icon: Icon(Icons.delete_outline,
                    color: isSelf ? Colors.grey.shade400 : Colors.red),
                tooltip: isSelf
                    ? 'Nelze smazat svůj vlastní účet'
                    : 'Smazat uživatele',
                onPressed: isSelf ? null : () => _deleteUser(u),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _NewUserResult {
  final String username;
  final String password;
  final bool isAdmin;
  const _NewUserResult(this.username, this.password, this.isAdmin);
}

class _NewUserDialog extends StatefulWidget {
  const _NewUserDialog();

  @override
  State<_NewUserDialog> createState() => _NewUserDialogState();
}

class _NewUserDialogState extends State<_NewUserDialog> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isAdmin = false;
  bool _obscure = true;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      _NewUserResult(
        _usernameController.text.trim(),
        _passwordController.text,
        _isAdmin,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Nový uživatel'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _usernameController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Uživatelské jméno',
                prefixIcon: Icon(Icons.person_outline),
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Zadej jméno' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _passwordController,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: 'Heslo',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  icon: Icon(_obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
                border: const OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v == null || v.isEmpty) ? 'Zadej heslo' : null,
              onFieldSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 4),
            CheckboxListTile(
              value: _isAdmin,
              onChanged: (v) => setState(() => _isAdmin = v ?? false),
              title: const Text('Admin role'),
              subtitle: const Text('Může spravovat ostatní uživatele',
                  style: TextStyle(fontSize: 11)),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Zrušit'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Vytvořit')),
      ],
    );
  }
}

class _ResetPasswordDialog extends StatefulWidget {
  final String username;
  const _ResetPasswordDialog({required this.username});

  @override
  State<_ResetPasswordDialog> createState() => _ResetPasswordDialogState();
}

class _ResetPasswordDialogState extends State<_ResetPasswordDialog> {
  final _controller = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_controller.text.isEmpty) return;
    Navigator.pop(context, _controller.text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Reset hesla — ${widget.username}'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        obscureText: _obscure,
        decoration: InputDecoration(
          labelText: 'Nové heslo',
          prefixIcon: const Icon(Icons.lock_outline),
          suffixIcon: IconButton(
            icon: Icon(_obscure
                ? Icons.visibility_outlined
                : Icons.visibility_off_outlined),
            onPressed: () => setState(() => _obscure = !_obscure),
          ),
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Zrušit'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Nastavit')),
      ],
    );
  }
}
