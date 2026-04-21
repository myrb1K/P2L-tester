import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/broker_profile.dart';
import '../providers/app_state.dart';

enum _BulkAction { broker, wifi }

enum _BrokerMode { existing, newProfile }

class BulkConfigMenu extends StatelessWidget {
  const BulkConfigMenu({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        final hasSelection = state.selectedCount > 0;
        return PopupMenuButton<_BulkAction>(
          icon: const Icon(Icons.settings_remote),
          tooltip: 'Hromadná konfigurace',
          enabled: hasSelection,
          onSelected: (action) async {
            switch (action) {
              case _BulkAction.broker:
                await _showBrokerDialog(context, state);
              case _BulkAction.wifi:
                await _showWifiDialog(context, state);
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: _BulkAction.broker,
              child: ListTile(
                leading: const Icon(Icons.dns),
                title: const Text('Změnit broker'),
                subtitle: hasSelection
                    ? Text('${state.selectedCount} vybraných')
                    : const Text('Nejprve vyberte P2L moduly'),
              ),
            ),
            PopupMenuItem(
              value: _BulkAction.wifi,
              child: ListTile(
                leading: const Icon(Icons.wifi),
                title: const Text('Změnit WiFi'),
                subtitle: hasSelection
                    ? Text('${state.selectedCount} vybraných')
                    : const Text('Nejprve vyberte P2L moduly'),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showBrokerDialog(BuildContext context, AppState state) async {
    // Z dropdownu odfiltrujeme aktuálně aktivní broker — měnit aktuální na
    // aktuální nedává smysl.
    final selectable = <BrokerProfile>[
      for (var i = 0; i < state.profiles.length; i++)
        if (i != state.activeProfileIndex) state.profiles[i],
    ];
    final result = await showDialog<BrokerProfile>(
      context: context,
      builder: (ctx) => _BulkBrokerDialog(
        selectableProfiles: selectable,
        selectedCount: state.selectedCount,
      ),
    );
    if (result != null && context.mounted) {
      await state.sendBulkBroker(result);
    }
  }

  Future<void> _showWifiDialog(BuildContext context, AppState state) async {
    final result = await showDialog<({String ssid, String password})>(
      context: context,
      builder: (ctx) => _BulkWifiDialog(
        initialSsid: state.lastWifiSsid,
        initialPassword: state.lastWifiPassword,
        selectedCount: state.selectedCount,
      ),
    );
    if (result != null && context.mounted) {
      await state.sendBulkWifi(ssid: result.ssid, password: result.password);
    }
  }
}

class _BulkBrokerDialog extends StatefulWidget {
  final List<BrokerProfile> selectableProfiles;
  final int selectedCount;

  const _BulkBrokerDialog({
    required this.selectableProfiles,
    required this.selectedCount,
  });

  @override
  State<_BulkBrokerDialog> createState() => _BulkBrokerDialogState();
}

class _BulkBrokerDialogState extends State<_BulkBrokerDialog> {
  late _BrokerMode _mode;
  BrokerProfile? _selected;

  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _brokerCtrl = TextEditingController();
  final _portCtrl = TextEditingController(text: '1883');
  final _userCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _useSsl = false;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    // Pokud nemáme žádné použitelné profily (kromě aktuálního), rovnou
    // otevřeme dialog v režimu "zadat nový".
    if (widget.selectableProfiles.isEmpty) {
      _mode = _BrokerMode.newProfile;
    } else {
      _mode = _BrokerMode.existing;
      _selected = widget.selectableProfiles.first;
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _brokerCtrl.dispose();
    _portCtrl.dispose();
    _userCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_mode == _BrokerMode.existing) {
      if (_selected == null) return;
      Navigator.pop(context, _selected);
      return;
    }
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final profile = BrokerProfile(
      name: _nameCtrl.text.trim(),
      broker: _brokerCtrl.text.trim(),
      port: int.parse(_portCtrl.text.trim()),
      username: _userCtrl.text,
      password: _passwordCtrl.text,
      useSsl: _useSsl,
    );
    // Uložíme jako nový profil, ale nepřepínáme aktivní připojení.
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final error = await state.addProfileWithoutActivating(profile);
    if (!mounted) return;
    if (error != null) {
      messenger.showSnackBar(
        SnackBar(content: Text(error), backgroundColor: Colors.red),
      );
      return;
    }
    Navigator.pop(context, profile);
  }

  @override
  Widget build(BuildContext context) {
    final hasSelectable = widget.selectableProfiles.isNotEmpty;
    return AlertDialog(
      title: const Text('Hromadná změna brokera'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Bude odesláno na ${widget.selectedCount} P2L modulů.'),
            const SizedBox(height: 12),
            if (hasSelectable)
              SegmentedButton<_BrokerMode>(
                segments: const [
                  ButtonSegment(
                    value: _BrokerMode.existing,
                    label: Text('Uložený'),
                    icon: Icon(Icons.list),
                  ),
                  ButtonSegment(
                    value: _BrokerMode.newProfile,
                    label: Text('Nový'),
                    icon: Icon(Icons.add),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => setState(() => _mode = s.first),
              ),
            const SizedBox(height: 12),
            if (_mode == _BrokerMode.existing && hasSelectable)
              _buildExistingPicker()
            else
              _buildNewForm(),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.orange.withAlpha(30),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Row(
                children: [
                  Icon(Icons.warning_amber, color: Colors.orange),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'P2L moduly se po změně odpojí z aktuálního brokera.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Zrušit'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(_mode == _BrokerMode.newProfile ? 'Uložit a odeslat' : 'Odeslat'),
        ),
      ],
    );
  }

  Widget _buildExistingPicker() {
    return DropdownButtonFormField<BrokerProfile>(
      initialValue: _selected,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Broker profil',
        border: OutlineInputBorder(),
      ),
      items: widget.selectableProfiles
          .map((p) => DropdownMenuItem(
                value: p,
                child: Text('${p.name}  (${p.broker}:${p.port})'),
              ))
          .toList(),
      onChanged: (p) => setState(() => _selected = p),
    );
  }

  Widget _buildNewForm() {
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextFormField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              labelText: 'Název profilu',
              border: OutlineInputBorder(),
            ),
            autofocus: true,
            validator: (v) {
              if (v == null || v.trim().isEmpty) return 'Zadejte název';
              if (context.read<AppState>().isProfileNameTaken(v)) {
                return 'Tento název už existuje';
              }
              return null;
            },
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _brokerCtrl,
            decoration: const InputDecoration(
              labelText: 'Broker (hostname/IP)',
              border: OutlineInputBorder(),
            ),
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'Zadejte adresu brokera' : null,
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _portCtrl,
            decoration: const InputDecoration(
              labelText: 'Port',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
            validator: (v) {
              final n = int.tryParse((v ?? '').trim());
              if (n == null || n < 1 || n > 65535) return 'Port 1–65535';
              return null;
            },
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _userCtrl,
            decoration: const InputDecoration(
              labelText: 'Uživatel',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _passwordCtrl,
            obscureText: _obscurePassword,
            decoration: InputDecoration(
              labelText: 'Heslo',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(
                    _obscurePassword ? Icons.visibility : Icons.visibility_off),
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('SSL/TLS'),
            value: _useSsl,
            onChanged: (v) => setState(() => _useSsl = v),
          ),
        ],
      ),
    );
  }
}

class _BulkWifiDialog extends StatefulWidget {
  final String initialSsid;
  final String initialPassword;
  final int selectedCount;

  const _BulkWifiDialog({
    required this.initialSsid,
    required this.initialPassword,
    required this.selectedCount,
  });

  @override
  State<_BulkWifiDialog> createState() => _BulkWifiDialogState();
}

class _BulkWifiDialogState extends State<_BulkWifiDialog> {
  late final TextEditingController _ssidCtrl;
  late final TextEditingController _pwdCtrl;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _ssidCtrl = TextEditingController(text: widget.initialSsid);
    _pwdCtrl = TextEditingController(text: widget.initialPassword);
  }

  @override
  void dispose() {
    _ssidCtrl.dispose();
    _pwdCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Hromadná změna WiFi'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Bude odesláno na ${widget.selectedCount} P2L modulů.'),
          const SizedBox(height: 12),
          TextField(
            controller: _ssidCtrl,
            decoration: const InputDecoration(
              labelText: 'SSID',
              border: OutlineInputBorder(),
            ),
            autofocus: true,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _pwdCtrl,
            obscureText: _obscurePassword,
            decoration: InputDecoration(
              labelText: 'Heslo',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(_obscurePassword ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Zrušit'),
        ),
        FilledButton(
          onPressed: () {
            final ssid = _ssidCtrl.text.trim();
            if (ssid.isEmpty) return;
            Navigator.pop(context, (ssid: ssid, password: _pwdCtrl.text));
          },
          child: const Text('Odeslat'),
        ),
      ],
    );
  }
}
