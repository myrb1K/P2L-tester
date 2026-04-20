import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../main.dart';
import '../models/device.dart';
import '../models/module.dart';
import '../models/unit.dart';
import '../providers/app_state.dart';
import '../services/mqtt_service.dart';
import 'settings_screen.dart';
import 'templates_screen.dart';
import 'unit_detail_screen.dart';

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
                title: Text(
                  p.name,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
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
              title: const Text('Přidat nový profil'),
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
                      (state.activeProfileIndex >= 0 &&
                              state.activeProfileIndex < state.profiles.length)
                          ? state.profiles[state.activeProfileIndex].name
                          : state.broker,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
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
              IconButton(
                icon: const Icon(Icons.folder_special),
                tooltip: 'Šablony',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const TemplatesScreen()),
                ),
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
            : 'Připojeno';

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
            child: const Text('Ověřit'),
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
          if (state.offlineCount > 0)
            GestureDetector(
              onTap: state.toggleOfflineFilter,
              child: Container(
                margin: const EdgeInsets.only(left: 8),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: state.filterOffline ? Colors.red.withAlpha(30) : Colors.grey.withAlpha(30),
                  borderRadius: BorderRadius.circular(12),
                  border: state.filterOffline ? Border.all(color: Colors.red) : null,
                ),
                child: Text(
                  '${state.offlineCount} offline',
                  style: TextStyle(
                    fontSize: 12,
                    color: state.filterOffline ? Colors.red : Colors.grey[600],
                    fontWeight: state.filterOffline ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ),
            ),
          const Spacer(),
          TextButton(
            onPressed: state.selectAll,
            child: const Text('Vybrat vše'),
          ),
          TextButton(
            onPressed: state.deselectAll,
            child: const Text('Zrušit'),
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
                  ? 'Čekám na ALIVE zprávy…\nNebo zadejte ID jednotky výše.'
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
          moduleCount: state.modulesForUnit(unit.id)?.length,
          onToggle: () => state.toggleUnit(unit.id),
          onGetParam: () {
            state.sendGetParam(unit.id);
            state.fetchDevices(unit.id);
          },
          onToggleBin: () => state.toggleBinMode(unit.id),
          onOpenDetail: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => UnitDetailScreen(unitId: unit.id),
            ),
          ),
        );
      },
    );
  }
}

class _UnitCard extends StatelessWidget {
  final P2LUnit unit;
  final bool isSelected;
  final int? moduleCount;
  final VoidCallback onToggle;
  final VoidCallback onGetParam;
  final VoidCallback onToggleBin;
  final VoidCallback onOpenDetail;

  const _UnitCard({
    required this.unit,
    required this.isSelected,
    required this.moduleCount,
    required this.onToggle,
    required this.onGetParam,
    required this.onToggleBin,
    required this.onOpenDetail,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: !unit.isOnline
            ? Colors.grey.withAlpha(30)
            : isSelected
                ? Colors.blue.withAlpha(20)
                : null,
        border: Border(bottom: BorderSide(color: Colors.grey.withAlpha(50))),
      ),
      child: InkWell(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
          child: Row(
            children: [
              Checkbox(
                value: isSelected,
                onChanged: (_) => onToggle(),
              ),
              Expanded(
                child: Row(
                  children: [
                    SizedBox(
                      width: 80,
                      child: Row(
                        children: [
                          Text(
                            unit.displayName,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          if (unit.supportsBin) ...[
                            const SizedBox(width: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                              decoration: BoxDecoration(
                                color: Colors.deepPurple.withAlpha(30),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text('BIN', style: TextStyle(fontSize: 10, color: Colors.deepPurple, fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ],
                      ),
                    ),
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: unit.isOnline ? Colors.green : Colors.grey,
                      ),
                    ),
                    const SizedBox(width: 4),
                    SizedBox(
                      width: 50,
                      child: Text(
                        unit.lastSeenText,
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        [
                          if (unit.firmware != null) unit.firmware!,
                          if (unit.battery != null) '${unit.battery!.toStringAsFixed(1)}%',
                        ].join(' | '),
                        style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              if (unit.supportsBin) ...[
                const SizedBox(width: 8),
                _BinOldToggle(useBin: unit.useBin, onToggle: onToggleBin),
                const SizedBox(width: 8),
              ],
              Stack(
                clipBehavior: Clip.none,
                children: [
                  IconButton(
                    icon: const Icon(Icons.device_hub, size: 20, color: Colors.blueGrey),
                    onPressed: onOpenDetail,
                    tooltip: 'Detail jednotky',
                  ),
                  if (moduleCount != null)
                    Positioned(
                      right: -2,
                      top: -2,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.blueGrey,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        constraints: const BoxConstraints(minWidth: 16),
                        child: Text(
                          '$moduleCount',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                ],
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
    final modules = context.read<AppState>().modulesForUnit(unit.id) ?? const [];
    final pumA = modules.where((m) => m.type == ModuleType.pumA).length;
    final pumB = modules.where((m) => m.type == ModuleType.pumB).length;
    final pumC = modules.where((m) => m.type == ModuleType.pumC).length;
    final dist = modules.where((m) => m.type == ModuleType.dist).length;
    final allDevices = modules.expand((m) => m.toDevices()).toList();
    final totalDevices = allDevices.length;
    final btnCount = allDevices.where((d) => d.type == DeviceType.btn).length;
    final dispCount = allDevices.where((d) => d.type == DeviceType.disp).length;
    final ledsCount = allDevices.where((d) => d.type == DeviceType.leds).length;
    final distCount = allDevices.where((d) => d.type == DeviceType.dist).length;
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
            Text('Devices: $totalDevices'),
            Text('PUM-A: $pumA · PUM-B: $pumB · PUM-C: $pumC · DIST: $dist'),
            Text('BTN: $btnCount · DISP: $dispCount · LEDS: $ledsCount · DIST: $distCount'),
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
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('Porty: ', style: TextStyle(fontSize: 12)),
                for (int p = 0; p < 8; p++)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: GestureDetector(
                      onTap: () => state.togglePort(p),
                      child: Container(
                        width: 28,
                        height: 28,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: state.selectedPorts.contains(p)
                              ? const [Colors.red, Colors.green, Colors.blue, Colors.yellow, Colors.purple, Colors.red, Colors.green, Colors.blue][p]
                              : Colors.grey[300],
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '$p',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: state.selectedPorts.contains(p) ? Colors.white : Colors.grey[600],
                          ),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: state.selectedPorts.length == 8
                      ? state.deselectAllPorts
                      : state.selectAllPorts,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.blue),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      state.selectedPorts.length == 8 ? 'Zrušit' : 'Vše',
                      style: const TextStyle(fontSize: 11, color: Colors.blue, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
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

class _BinOldToggle extends StatelessWidget {
  final bool useBin;
  final VoidCallback onToggle;
  const _BinOldToggle({required this.useBin, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onToggle,
      child: Container(
        height: 22,
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade400),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _seg('BIN', useBin),
            _seg('OLD', !useBin),
          ],
        ),
      ),
    );
  }

  Widget _seg(String text, bool active) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: active ? Colors.blue.withAlpha(60) : Colors.transparent,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: active ? Colors.blue.shade800 : Colors.grey.shade600,
        ),
      ),
    );
  }
}
