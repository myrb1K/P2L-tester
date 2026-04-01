import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../main.dart';
import '../models/unit.dart';
import '../providers/app_state.dart';
import '../services/mqtt_service.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _manualIdController = TextEditingController();

  @override
  void dispose() {
    _manualIdController.dispose();
    super.dispose();
  }

  void _showBrokerPicker(BuildContext context, AppState state) {
    if (state.profiles.isEmpty) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const SettingsScreen()),
      );
      return;
    }
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Vybrat broker',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            ...List.generate(state.profiles.length, (i) {
              final p = state.profiles[i];
              final isActive = i == state.activeProfileIndex;
              return ListTile(
                leading: Icon(
                  isActive ? Icons.check_circle : Icons.circle_outlined,
                  color: isActive ? Colors.green : Colors.grey,
                ),
                title: Text(p.name),
                subtitle: Text('${p.broker}:${p.port}'),
                onTap: () async {
                  Navigator.pop(ctx);
                  state.disconnect();
                  await state.selectProfile(i);
                  await state.connect();
                },
              );
            }),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('Pridat novy profil'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                );
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _sendManualGetParam() {
    final input = _manualIdController.text.trim();
    if (input.isEmpty) return;
    // Doplní na 6místné ID: 1017 → 001017
    final id = input.padLeft(6, '0');
    context.read<AppState>().sendGetParam(id);
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        return Scaffold(
          appBar: AppBar(
            title: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                const Text('P2L Tester'),
                const SizedBox(width: 6),
                Text(
                  'v$appVersion',
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.normal),
                ),
              ],
            ),
            actions: [
              if (state.isConnected)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Center(
                    child: Text(
                      state.broker,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                ),
              GestureDetector(
                onTap: state.isConnected ? state.disconnect : null,
                child: _ConnectionIndicator(state: state.connectionState),
              ),
              IconButton(
                icon: const Icon(Icons.swap_horiz),
                tooltip: 'Vybrat broker',
                onPressed: () => _showBrokerPicker(context, state),
              ),
              if (state.units.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Vymazat seznam',
                  onPressed: () => state.clearUnits(),
                ),
              IconButton(
                icon: const Icon(Icons.settings),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                ),
              ),
            ],
          ),
          body: Column(
            children: [
              _StatusBar(state: state),
              _ManualIdInput(
                controller: _manualIdController,
                onSubmit: _sendManualGetParam,
                isConnected: state.isConnected,
              ),
              if (state.units.isNotEmpty)
                _SelectionBar(state: state),
              Expanded(
                child: state.units.isEmpty
                    ? _EmptyState(isConnected: state.isConnected)
                    : _UnitListView(state: state),
              ),
            ],
          ),
          bottomNavigationBar: state.isConnected && state.units.isNotEmpty
              ? _ActionBar(state: state)
              : null,
        );
      },
    );
  }
}

class _ConnectionIndicator extends StatelessWidget {
  final AppMqttState state;

  const _ConnectionIndicator({required this.state});

  @override
  Widget build(BuildContext context) {
    Color color;
    IconData icon;
    switch (state) {
      case AppMqttState.connected:
        color = Colors.green;
        icon = Icons.wifi;
      case AppMqttState.connecting:
        color = Colors.orange;
        icon = Icons.wifi_find;
      case AppMqttState.error:
        color = Colors.red;
        icon = Icons.wifi_off;
      case AppMqttState.disconnected:
        color = Colors.grey;
        icon = Icons.wifi_off;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Icon(icon, color: color, size: 20),
    );
  }
}

class _StatusBar extends StatelessWidget {
  final AppState state;

  const _StatusBar({required this.state});

  @override
  Widget build(BuildContext context) {
    final message = !state.isConnected
        ? 'Odpojeno - otevrete Nastaveni'
        : state.statusMessage.isNotEmpty
            ? state.statusMessage
            : 'Pripojeno';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: state.isConnected
          ? Colors.green.withAlpha(25)
          : Colors.orange.withAlpha(25),
      child: Text(
        message,
        style: TextStyle(
          fontSize: 13,
          color: state.isConnected ? Colors.green[800] : Colors.orange[800],
        ),
      ),
    );
  }
}

class _ManualIdInput extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSubmit;
  final bool isConnected;

  const _ManualIdInput({
    required this.controller,
    required this.onSubmit,
    required this.isConnected,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              enabled: isConnected,
              decoration: const InputDecoration(
                hintText: 'ID jednotky (napr. 1017)',
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              keyboardType: TextInputType.text,
              onSubmitted: (_) => onSubmit(),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: isConnected ? onSubmit : null,
            child: const Text('Overit'),
          ),
        ],
      ),
    );
  }
}

class _SelectionBar extends StatelessWidget {
  final AppState state;

  const _SelectionBar({required this.state});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Text(
            'Jednotky: ${state.totalCount}',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const Spacer(),
          TextButton(
            onPressed: state.selectAll,
            child: const Text('Vybrat vse'),
          ),
          TextButton(
            onPressed: state.deselectAll,
            child: const Text('Zrusit'),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool isConnected;

  const _EmptyState({required this.isConnected});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isConnected ? Icons.search : Icons.wifi_off,
              size: 64,
              color: Colors.grey[400],
            ),
            const SizedBox(height: 16),
            Text(
              isConnected
                  ? 'Cekam na ALIVE zpravy...\nNebo zadejte ID jednotky vyse.'
                  : 'Nejdrive se pripojte k brokeru\nv Nastaveni.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: Colors.grey[600]),
            ),
          ],
        ),
      ),
    );
  }
}

class _UnitListView extends StatelessWidget {
  final AppState state;

  const _UnitListView({required this.state});

  @override
  Widget build(BuildContext context) {
    final units = state.unitList;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: units.length,
      itemBuilder: (context, index) {
        final unit = units[index];
        final isSelected = state.selectedUnits.contains(unit.id);
        return _UnitCard(
          unit: unit,
          isSelected: isSelected,
          onToggle: () => state.toggleUnit(unit.id),
          onGetParam: () => state.sendGetParam(unit.id),
          onToggleBin: () => state.toggleBinMode(unit.id),
        );
      },
    );
  }
}

class _UnitCard extends StatelessWidget {
  final P2LUnit unit;
  final bool isSelected;
  final VoidCallback onToggle;
  final VoidCallback onGetParam;
  final VoidCallback onToggleBin;

  const _UnitCard({
    required this.unit,
    required this.isSelected,
    required this.onToggle,
    required this.onGetParam,
    required this.onToggleBin,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: !unit.isOnline
          ? Colors.grey.withAlpha(30)
          : isSelected
              ? Colors.blue.withAlpha(20)
              : null,
      child: InkWell(
        onTap: onToggle,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Checkbox(
                value: isSelected,
                onChanged: (_) => onToggle(),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          unit.displayName,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        if (unit.supportsBin) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.deepPurple.withAlpha(30),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text('BIN', style: TextStyle(fontSize: 10, color: Colors.deepPurple, fontWeight: FontWeight.bold)),
                          ),
                        ],
                        const SizedBox(width: 8),
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: unit.isOnline ? Colors.green : Colors.grey,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          unit.lastSeenText,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            [
                              if (unit.firmware != null) 'FW: ${unit.firmware}',
                              if (unit.ip != null) 'IP: ${unit.ip}',
                              if (unit.battery != null) 'Bat: ${unit.battery!.toStringAsFixed(1)}%',
                            ].join(' | '),
                            style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                          ),
                        ),
                        // BIN/OLD přepínač
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (unit.supportsBin)
                SizedBox(
                  height: 28,
                  child: SegmentedButton<bool>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: true, label: Text('BIN', style: TextStyle(fontSize: 11))),
                      ButtonSegment(value: false, label: Text('OLD', style: TextStyle(fontSize: 11))),
                    ],
                    selected: {unit.useBin},
                    onSelectionChanged: (_) => onToggleBin(),
                    style: ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ),
              IconButton(
                icon: const Icon(Icons.info_outline, size: 20),
                onPressed: () => _showUnitInfo(context, unit),
                tooltip: 'Info',
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 20, color: Colors.green),
                onPressed: onGetParam,
                tooltip: 'Get Param',
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showUnitInfo(BuildContext context, P2LUnit unit) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Jednotka ${unit.displayName}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ID: ${unit.id}'),
            if (unit.firmware != null) Text('FW: ${unit.firmware}'),
            if (unit.hwModel != null) Text('HW: ${unit.hwModel}'),
            if (unit.ip != null) Text('IP: ${unit.ip}'),
            if (unit.mac != null) Text('MAC: ${unit.mac}'),
            if (unit.ssid != null) Text('SSID: ${unit.ssid}'),
            if (unit.mqttServer != null) Text('MQTT: ${unit.mqttServer}:${unit.mqttPort}'),
            if (unit.battery != null) Text('Bat: ${unit.battery}%'),
            Text('Brightness: ${unit.brightness}'),
            if (unit.ledsPerPort.isNotEmpty)
              Text('LEDs: ${unit.ledsPerPort.entries.map((e) => 'P${e.key}:${e.value}').join(', ')}'),
            const SizedBox(height: 8),
            Text('Last seen: ${unit.lastSeenText}'),
            Text('BIN: ${unit.supportsBin ? "ano" : "ne"}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}

class _ActionBar extends StatelessWidget {
  final AppState state;

  const _ActionBar({required this.state});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(25),
              blurRadius: 8,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Vybrano: ${state.selectedCount} z ${state.totalCount}',
              style: TextStyle(fontSize: 13, color: Colors.grey[600]),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed:
                        state.selectedCount > 0 ? state.sendTest : null,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('TEST'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.green,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed:
                        state.selectedCount > 0 ? state.sendClear : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('CLEAR'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.red,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed:
                        state.totalCount > 0 ? state.scanAll : null,
                    icon: const Icon(Icons.refresh),
                    label: const Text('SCAN'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
