import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/broker_profile.dart';
import '../providers/app_state.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _brokerController;
  late TextEditingController _portController;
  late TextEditingController _usernameController;
  late TextEditingController _passwordController;
  late TextEditingController _ledsOnController;
  late TextEditingController _ledsOffController;
  int _selectedColor = 0;
  bool _useSsl = false;
  bool _obscurePassword = true;
  int? _editingIndex;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _brokerController = TextEditingController();
    _portController = TextEditingController(text: '1883');
    _usernameController = TextEditingController();
    _passwordController = TextEditingController();

    final state = context.read<AppState>();
    _ledsOnController = TextEditingController(text: state.ledsOn.toString());
    _ledsOffController = TextEditingController(text: state.ledsOff.toString());
    _selectedColor = state.ledColor;

    // Pokud existuje aktivní profil, načti ho do formuláře
    if (state.activeProfileIndex >= 0 &&
        state.activeProfileIndex < state.profiles.length) {
      _loadProfile(state.profiles[state.activeProfileIndex],
          state.activeProfileIndex);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _brokerController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _ledsOnController.dispose();
    _ledsOffController.dispose();
    super.dispose();
  }

  void _loadProfile(BrokerProfile profile, int index) {
    _editingIndex = index;
    _nameController.text = profile.name;
    _brokerController.text = profile.broker;
    _portController.text = profile.port.toString();
    _usernameController.text = profile.username;
    _passwordController.text = profile.password;
    _useSsl = profile.useSsl;
  }

  void _clearForm() {
    _editingIndex = null;
    _nameController.clear();
    _brokerController.clear();
    _portController.text = '1883';
    _usernameController.text = 'smartbox_user';
    _passwordController.text = 'smartbox2022';
    _useSsl = false;
  }

  BrokerProfile _profileFromForm() {
    return BrokerProfile(
      name: _nameController.text.trim(),
      broker: _brokerController.text.trim(),
      port: int.tryParse(_portController.text.trim()) ?? 1883,
      username: _usernameController.text.trim(),
      password: _passwordController.text,
      useSsl: _useSsl,
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final state = context.read<AppState>();
    final profile = _profileFromForm();

    if (_editingIndex != null) {
      await state.updateProfile(_editingIndex!, profile);
    } else {
      await state.addProfile(profile);
      _editingIndex = state.profiles.length - 1;
    }

    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profil ulozen')),
      );
    }
  }

  Future<void> _connectAndTest() async {
    await _save();
    if (!mounted) return;

    final state = context.read<AppState>();
    if (_editingIndex != null) {
      await state.selectProfile(_editingIndex!);
    }
    final result = await state.connect();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              result ? 'Pripojeni uspesne!' : 'Chyba: ${state.lastError}'),
          backgroundColor: result ? Colors.green : Colors.red,
        ),
      );
      if (result) {
        Navigator.of(context).pop();
      }
    }
  }

  Future<void> _deleteProfile(int index) async {
    final state = context.read<AppState>();
    final name = state.profiles[index].name;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Smazat profil?'),
        content: Text('Opravdu smazat "$name"?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Zrusit')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Smazat')),
        ],
      ),
    );
    if (confirmed == true) {
      await state.deleteProfile(index);
      if (_editingIndex == index) {
        setState(() => _clearForm());
      } else {
        setState(() {});
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Nastaveni MQTT'),
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Seznam uložených profilů
                if (state.profiles.isNotEmpty) ...[
                  const Text('Ulozene profily',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  ...List.generate(state.profiles.length, (i) {
                    final p = state.profiles[i];
                    final isActive = i == state.activeProfileIndex;
                    return Card(
                      color: isActive ? Colors.blue.withAlpha(20) : null,
                      child: ListTile(
                        leading: Icon(
                          isActive ? Icons.check_circle : Icons.circle_outlined,
                          color: isActive ? Colors.green : Colors.grey,
                        ),
                        title: Text(p.name),
                        subtitle: Text('${p.broker}:${p.port}'),
                        onTap: () {
                          setState(() => _loadProfile(p, i));
                        },
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (!isActive)
                              IconButton(
                                icon: const Icon(Icons.play_arrow, size: 20),
                                tooltip: 'Pripojit',
                                onPressed: () async {
                                  await state.selectProfile(i);
                                  if (!context.mounted) return;
                                  final result = await state.connect();
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(result
                                            ? 'Pripojeno k ${p.name}'
                                            : 'Chyba: ${state.lastError}'),
                                        backgroundColor:
                                            result ? Colors.green : Colors.red,
                                      ),
                                    );
                                    if (result) Navigator.of(context).pop();
                                  }
                                },
                              ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, size: 20),
                              onPressed: () => _deleteProfile(i),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => setState(() => _clearForm()),
                    icon: const Icon(Icons.add),
                    label: const Text('Novy profil'),
                  ),
                  const Divider(height: 32),
                ],
                // Formulář
                Text(
                  _editingIndex != null ? 'Upravit profil' : 'Novy profil',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextFormField(
                        controller: _nameController,
                        decoration: const InputDecoration(
                          labelText: 'Nazev profilu',
                          hintText: 'napr. Lekarna, Sklad...',
                          prefixIcon: Icon(Icons.label),
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) => v == null || v.trim().isEmpty
                            ? 'Zadejte nazev'
                            : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _brokerController,
                        decoration: const InputDecoration(
                          labelText: 'Broker adresa',
                          hintText: 'mqtt.lekarna.smartci4.com',
                          prefixIcon: Icon(Icons.dns),
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) => v == null || v.trim().isEmpty
                            ? 'Zadejte adresu brokeru'
                            : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _portController,
                        decoration: const InputDecoration(
                          labelText: 'Port',
                          hintText: '1883',
                          prefixIcon: Icon(Icons.settings_ethernet),
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) return 'Zadejte port';
                          final port = int.tryParse(v.trim());
                          if (port == null || port < 1 || port > 65535) {
                            return 'Port musi byt 1-65535';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _usernameController,
                        decoration: const InputDecoration(
                          labelText: 'Username',
                          prefixIcon: Icon(Icons.person),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _passwordController,
                        obscureText: _obscurePassword,
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: const Icon(Icons.lock),
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            icon: Icon(_obscurePassword
                                ? Icons.visibility
                                : Icons.visibility_off),
                            onPressed: () => setState(
                                () => _obscurePassword = !_obscurePassword),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SwitchListTile(
                        title: const Text('SSL/TLS'),
                        value: _useSsl,
                        onChanged: (v) => setState(() => _useSsl = v),
                        secondary: const Icon(Icons.security),
                      ),
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: _save,
                        icon: const Icon(Icons.save),
                        label: Text(_editingIndex != null
                            ? 'Ulozit zmeny'
                            : 'Ulozit novy profil'),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _connectAndTest,
                        icon: const Icon(Icons.wifi),
                        label: const Text('Ulozit a pripojit'),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 32),
                // LED pattern
                const Text('Schema LED pasku',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _ledsOnController,
                        decoration: const InputDecoration(
                          labelText: 'Sviti (pocet LED)',
                          prefixIcon: Icon(Icons.light_mode),
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _ledsOffController,
                        decoration: const InputDecoration(
                          labelText: 'Nesviti (pocet LED)',
                          prefixIcon: Icon(Icons.dark_mode),
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text('Barva LED:'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final entry in const [
                      (0, 'RED', Color(0xFFE53935)),
                      (1, 'GREEN', Color(0xFF43A047)),
                      (2, 'BLUE', Color(0xFF1E88E5)),
                      (3, 'YELLOW', Color(0xFFFDD835)),
                      (4, 'PURPLE', Color(0xFF8E24AA)),
                      (5, 'WHITE', Color(0xFFEEEEEE)),
                    ])
                      ChoiceChip(
                        label: Text(entry.$2),
                        selected: _selectedColor == entry.$1,
                        selectedColor: entry.$3,
                        onSelected: (_) => setState(() => _selectedColor = entry.$1),
                        avatar: CircleAvatar(backgroundColor: entry.$3, radius: 8),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Consumer<AppState>(
                  builder: (context2, state, child) => Text(
                    'Aktualne: ${state.ledsOn} sviti / ${state.ledsOff} nesviti',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () async {
                    final on = int.tryParse(_ledsOnController.text.trim()) ?? 3;
                    final off = int.tryParse(_ledsOffController.text.trim()) ?? 10;
                    if (on < 1 || off < 1) return;
                    final appState = context.read<AppState>();
                    final messenger = ScaffoldMessenger.of(context);
                    await appState.saveLedPattern(on, off, _selectedColor);
                    if (!mounted) return;
                    messenger.showSnackBar(
                      const SnackBar(content: Text('Schema ulozeno')),
                    );
                  },
                  icon: const Icon(Icons.save),
                  label: const Text('Ulozit schema'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
