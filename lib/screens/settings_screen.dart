import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
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
  bool _addingNew = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _brokerController = TextEditingController();
    _portController = TextEditingController(text: '1883');
    _usernameController = TextEditingController(text: 'smartbox_user');
    _passwordController = TextEditingController(text: 'smartbox2022');

    final state = context.read<AppState>();
    _ledsOnController = TextEditingController(text: state.ledsOn.toString());
    _ledsOffController = TextEditingController(text: state.ledsOff.toString());
    _selectedColor = state.ledColor;
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
    _addingNew = false;
    _nameController.text = profile.name;
    _brokerController.text = profile.broker;
    _portController.text = profile.port.toString();
    _usernameController.text = profile.username;
    _passwordController.text = profile.password;
    _useSsl = profile.useSsl;
  }

  void _clearForm() {
    _editingIndex = null;
    _addingNew = false;
    _nameController.clear();
    _brokerController.clear();
    _portController.text = '1883';
    _usernameController.text = 'smartbox_user';
    _passwordController.text = 'smartbox2022';
    _useSsl = false;
  }

  void _toggleEdit(BrokerProfile profile, int index) {
    setState(() {
      if (_editingIndex == index && !_addingNew) {
        _clearForm();
      } else {
        _loadProfile(profile, index);
      }
    });
  }

  void _toggleAddNew() {
    setState(() {
      if (_addingNew) {
        _clearForm();
      } else {
        _clearForm();
        _addingNew = true;
      }
    });
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

  /// Vrací index uloženého profilu, null při chybě.
  Future<int?> _save() async {
    if (!_formKey.currentState!.validate()) return null;

    final state = context.read<AppState>();
    final profile = _profileFromForm();
    final originalIndex = _editingIndex;

    final error = originalIndex != null
        ? await state.updateProfile(originalIndex, profile)
        : await state.addProfile(profile);

    if (!mounted) return null;

    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error), backgroundColor: Colors.red),
      );
      return null;
    }

    final savedIndex = originalIndex ?? state.profiles.length - 1;
    setState(_clearForm);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Profil uložen')),
    );
    return savedIndex;
  }

  Future<void> _connectAndTest() async {
    final savedIndex = await _save();
    if (savedIndex == null || !mounted) return;

    final state = context.read<AppState>();
    await state.selectProfile(savedIndex);
    final result = await state.connect();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              result ? 'Připojení úspěšné!' : 'Chyba: ${state.lastError}'),
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
              child: const Text('Zrušit')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Smazat')),
        ],
      ),
    );
    if (confirmed == true) {
      await state.deleteProfile(index);
      if (_editingIndex == index) {
        setState(_clearForm);
      } else {
        setState(() {});
      }
    }
  }

  Future<void> _exportSettings(AppState state) async {
    final json = state.exportSettingsJson();
    final stamp = DateTime.now().toIso8601String().substring(0, 16).replaceAll(':', '-');
    final defaultName = 'p2l_tester_settings_$stamp.json';
    final messenger = ScaffoldMessenger.of(context);
    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Uložit nastavení',
        fileName: defaultName,
        type: FileType.custom,
        allowedExtensions: const ['json'],
        bytes: utf8.encode(json),
      );
      if (path == null) return;
      // Na desktopech `saveFile` ne vždy zapíše obsah — udělej to ručně.
      final file = File(path);
      if (!await file.exists() || await file.length() == 0) {
        await file.writeAsString(json);
      }
      messenger.showSnackBar(
        SnackBar(content: Text('Exportováno do $path'), backgroundColor: Colors.green),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Export selhal: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _importSettings(AppState state) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Načíst nastavení',
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.single;
    final String content;
    try {
      if (file.bytes != null) {
        content = utf8.decode(file.bytes!);
      } else if (file.path != null) {
        content = await File(file.path!).readAsString();
      } else {
        messenger.showSnackBar(
          const SnackBar(content: Text('Nelze načíst obsah souboru'), backgroundColor: Colors.red),
        );
        return;
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Čtení souboru selhalo: $e'), backgroundColor: Colors.red),
      );
      return;
    }

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Přepsat nastavení?'),
        content: const Text(
          'Stávající broker profily, šablony a LED pattern budou nahrazeny obsahem souboru. Pokračovat?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Zrušit'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.orange),
            child: const Text('Přepsat'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final error = await state.importSettingsJson(content);
    if (!mounted) return;
    if (error != null) {
      messenger.showSnackBar(
        SnackBar(content: Text(error), backgroundColor: Colors.red),
      );
      return;
    }
    setState(() {
      _clearForm();
      _ledsOnController.text = state.ledsOn.toString();
      _ledsOffController.text = state.ledsOff.toString();
      _selectedColor = state.ledColor;
    });
    messenger.showSnackBar(
      const SnackBar(content: Text('Nastavení naimportováno'), backgroundColor: Colors.green),
    );
  }

  Widget _buildProfileForm(AppState state) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: 'Název profilu',
              hintText: 'např. Lékárna, Sklad…',
              prefixIcon: Icon(Icons.label),
              border: OutlineInputBorder(),
            ),
            validator: (v) {
              if (v == null || v.trim().isEmpty) {
                return 'Zadejte název';
              }
              if (state.isProfileNameTaken(v, excludeIndex: _editingIndex)) {
                return 'Tento název už existuje';
              }
              return null;
            },
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
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
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
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save),
            label: Text(_editingIndex != null
                ? 'Uložit změny'
                : 'Uložit nový profil'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _connectAndTest,
            icon: const Icon(Icons.wifi),
            label: const Text('Uložit a připojit'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Nastavení MQTT'),
            actions: [
              PopupMenuButton<String>(
                icon: const Icon(Icons.import_export),
                tooltip: 'Export / Import nastavení',
                onSelected: (v) {
                  if (v == 'export') _exportSettings(state);
                  if (v == 'import') _importSettings(state);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'export',
                    child: ListTile(
                      leading: Icon(Icons.upload_file),
                      title: Text('Export nastavení'),
                      subtitle: Text('Profily, šablony, LED pattern do JSON'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'import',
                    child: ListTile(
                      leading: Icon(Icons.download),
                      title: Text('Import nastavení'),
                      subtitle: Text('Přepíše stávající profily a šablony'),
                    ),
                  ),
                ],
              ),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Uložené profily',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                if (state.profiles.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'Žádné uložené profily',
                      style: TextStyle(color: Colors.grey[600]),
                    ),
                  )
                else
                  ReorderableListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    buildDefaultDragHandles: false,
                    itemCount: state.profiles.length,
                    onReorder: (oldIndex, newIndex) {
                      // Po reorderu by se _editingIndex mohl rozejít s
                      // reálnou pozicí profilu — raději vyčistíme formulář.
                      setState(_clearForm);
                      state.reorderProfiles(oldIndex, newIndex);
                    },
                    itemBuilder: (ctx, i) {
                      final p = state.profiles[i];
                      final isActive = i == state.activeProfileIndex;
                      final isEditing = _editingIndex == i && !_addingNew;
                      final scheme = Theme.of(context).colorScheme;
                      return Card(
                        key: ValueKey('profile_${p.name}_$i'),
                        color: isActive ? Colors.blue.withAlpha(20) : null,
                        shape: isEditing
                            ? RoundedRectangleBorder(
                                side: BorderSide(
                                    color: scheme.primary, width: 2),
                                borderRadius: BorderRadius.circular(12),
                              )
                            : null,
                        child: Column(
                          children: [
                            ListTile(
                              leading: Icon(
                                isActive
                                    ? Icons.check_circle
                                    : Icons.circle_outlined,
                                color: isActive ? Colors.green : Colors.grey,
                              ),
                              title: Text(
                                p.name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold),
                              ),
                              subtitle: Text('${p.broker}:${p.port}'),
                              onTap: () => _toggleEdit(p, i),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (!isActive)
                                    IconButton(
                                      icon: const Icon(Icons.play_arrow,
                                          size: 20),
                                      tooltip: 'Připojit',
                                      onPressed: () async {
                                        await state.selectProfile(i);
                                        if (!context.mounted) return;
                                        final result = await state.connect();
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(
                                            SnackBar(
                                              content: Text(result
                                                  ? 'Připojeno k ${p.name}'
                                                  : 'Chyba: ${state.lastError}'),
                                              backgroundColor: result
                                                  ? Colors.green
                                                  : Colors.red,
                                            ),
                                          );
                                          if (result) {
                                            Navigator.of(context).pop();
                                          }
                                        }
                                      },
                                    ),
                                  IconButton(
                                    icon: Icon(
                                      isEditing
                                          ? Icons.close
                                          : Icons.edit_outlined,
                                      size: 20,
                                    ),
                                    tooltip: isEditing
                                        ? 'Zavřít editaci'
                                        : 'Upravit',
                                    onPressed: () => _toggleEdit(p, i),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline,
                                        size: 20),
                                    onPressed: () => _deleteProfile(i),
                                  ),
                                  ReorderableDragStartListener(
                                    index: i,
                                    child: const Padding(
                                      padding: EdgeInsets.symmetric(
                                          horizontal: 4),
                                      child: Icon(Icons.drag_handle,
                                          color: Colors.grey),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (isEditing)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                    16, 0, 16, 16),
                                child: _buildProfileForm(state),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _toggleAddNew,
                  icon: Icon(_addingNew ? Icons.close : Icons.add),
                  label: Text(_addingNew ? 'Zrušit nový profil' : 'Nový profil'),
                ),
                if (_addingNew) ...[
                  const SizedBox(height: 8),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: _buildProfileForm(state),
                    ),
                  ),
                ],
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
                const SizedBox(height: 8),
                Consumer<AppState>(
                  builder: (context2, state, child) => Text(
                    'Aktuálně: ${state.ledsOn} svítí / ${state.ledsOff} nesvítí',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                ),
                const SizedBox(height: 12),
                const Text('Barva LED:'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
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
                  label: const Text('Uložit schéma'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
