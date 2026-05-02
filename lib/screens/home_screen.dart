import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/device.dart';
import '../models/module.dart';
import '../models/unit.dart';
import '../providers/app_state.dart';
import '../services/mqtt_service.dart';
import '../widgets/bulk_config_menu.dart';
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
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final maxHeight = MediaQuery.of(ctx).size.height * 0.8;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Vybrat broker',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: state.profiles.length,
                    itemBuilder: (_, i) {
                      final p = state.profiles[i];
                      final isActive = i == state.activeProfileIndex;
                      return ListTile(
                        leading: Icon(
                          isActive ? Icons.check_circle : Icons.circle_outlined,
                          color: isActive ? Colors.green : Colors.grey,
                        ),
                        title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text('${p.broker}:${p.port}'),
                        onTap: () async {
                          Navigator.pop(ctx);
                          state.disconnect();
                          await state.selectProfile(i);
                          await state.connect();
                        },
                      );
                    },
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.add),
                  title: const Text('Přidat nový profil'),
                  onTap: () {
                    Navigator.pop(ctx);
                    Navigator.of(
                      context,
                    ).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
                  },
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
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
        return Listener(
          behavior: HitTestBehavior.deferToChild,
          onPointerDown: (_) => FocusManager.instance.primaryFocus?.unfocus(),
          child: Scaffold(
          appBar: AppBar(
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
                onPressed: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const TemplatesScreen())),
              ),
              const BulkConfigMenu(),
              if (state.units.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Vymazat seznam',
                  onPressed: () => state.clearUnits(),
                ),
              IconButton(
                icon: const Icon(Icons.settings),
                tooltip: 'Nastavení',
                onPressed: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
              ),
            ],
          ),
          body: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => FocusScope.of(context).unfocus(),
            child: Column(
              children: [
                _StatusBar(state: state),
                _ManualIdInput(
                  controller: _manualIdController,
                  onSubmit: _sendManualGetParam,
                  isConnected: state.isConnected,
                ),
                if (state.units.isNotEmpty) _SelectionBar(state: state),
                Expanded(
                  child: state.units.isEmpty
                      ? _EmptyState(isConnected: state.isConnected)
                      : _UnitListView(state: state),
                ),
              ],
            ),
          ),
          bottomNavigationBar: state.isConnected && state.units.isNotEmpty
              ? _ActionBar(state: state)
              : null,
          ),
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
        ? 'Odpojeno – otevřete Nastavení'
        : state.statusMessage.isNotEmpty
        ? state.statusMessage
        : 'Připojeno';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: state.isConnected ? Colors.green.withAlpha(25) : Colors.orange.withAlpha(25),
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
                hintText: 'ID P2L modulu (např. 1017)',
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              keyboardType: TextInputType.text,
              onSubmitted: (_) => onSubmit(),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(onPressed: isConnected ? onSubmit : null, child: const Text('Ověřit')),
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
            'P2L moduly: ${state.totalCount}',
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
          TextButton(onPressed: state.selectAll, child: const Text('Vybrat vše')),
          TextButton(onPressed: state.deselectAll, child: const Text('Zrušit')),
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
            Icon(isConnected ? Icons.search : Icons.wifi_off, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              isConnected
                  ? 'Čekám na ALIVE zprávy…\nNebo zadejte ID P2L modulu výše.'
                  : 'Nejdříve se připojte k brokeru\nv Nastavení.',
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
            if (state.filterOffline) state.toggleOfflineFilter();
          },
          onOpenDetail: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => UnitDetailScreen(unitId: unit.id))),
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
  final VoidCallback onOpenDetail;

  const _UnitCard({
    required this.unit,
    required this.isSelected,
    required this.moduleCount,
    required this.onToggle,
    required this.onGetParam,
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
          padding: const EdgeInsets.only(left: 0, right: 8, top: 1, bottom: 1),
          child: Row(
            children: [
              Checkbox(
                value: isSelected,
                onChanged: (_) => onToggle(),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              Expanded(
                child: Row(
                  children: [
                    SizedBox(
                      width: 40,
                      child: Text(
                        unit.displayName,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
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
                      width: 42,
                      child: Text(
                        unit.lastSeenText,
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        [
                          if (unit.firmware != null) unit.firmware!,
                          if (unit.battery != null) '${unit.battery!.toStringAsFixed(1)} V',
                        ].join(' | '),
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              Badge(
                isLabelVisible: moduleCount != null,
                backgroundColor: Colors.blueGrey,
                textColor: Colors.white,
                offset: const Offset(-2, 2),
                label: Text('$moduleCount'),
                child: IconButton(
                  icon: const Icon(Icons.device_hub, size: 28, color: Colors.blueGrey),
                  onPressed: onOpenDetail,
                  tooltip: 'Seznam zařízení',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                icon: const Icon(Icons.info_outline, size: 28),
                onPressed: () => _showUnitInfo(context, unit),
                tooltip: 'Info',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
              const SizedBox(width: 6),
              IconButton(
                icon: const Icon(Icons.refresh, size: 28, color: Colors.green),
                onPressed: onGetParam,
                tooltip: 'Obnovit',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
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

    final infoLines = <String>[
      'P2L modul ${unit.displayName}',
      'ID: ${unit.id}',
      if (unit.firmware != null) 'FW: ${unit.firmware}',
      if (unit.hwModel != null) 'HW: ${unit.hwModel}',
      if (unit.ip != null) 'IP: ${unit.ip}',
      if (unit.mac != null) 'MAC: ${unit.mac}',
      if (unit.ssid != null) 'SSID: ${unit.ssid}',
      if (unit.mqttServer != null) 'MQTT: ${unit.mqttServer}:${unit.mqttPort}',
      if (unit.battery != null) 'Bat: ${unit.battery!.toStringAsFixed(1)} V',
      'Brightness: ${unit.brightness}',
      if (unit.ledsPerPort.isNotEmpty)
        'LEDs: ${unit.ledsPerPort.entries.map((e) => 'P${e.key}:${e.value}').join(', ')}',
      'Devices: $totalDevices',
      'PUM-A: $pumA · PUM-B: $pumB · PUM-C: $pumC · DIST: $dist',
      'BTN: $btnCount · DISP: $dispCount · LEDS: $ledsCount · DIST: $distCount',
      'Last seen: ${unit.lastSeenText}',
      'BIN: ${unit.supportsBin ? "ano" : "ne"}',
    ];

    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('P2L modul ${unit.displayName}'),
        content: Consumer<AppState>(
          builder: (_, state, _) {
            final liveUnit = state.units[unit.id] ?? unit;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('ID: ${liveUnit.id}'),
                if (liveUnit.firmware != null) Text('FW: ${liveUnit.firmware}'),
                if (liveUnit.hwModel != null) Text('HW: ${liveUnit.hwModel}'),
                if (liveUnit.ip != null) Text('IP: ${liveUnit.ip}'),
                if (liveUnit.mac != null) Text('MAC: ${liveUnit.mac}'),
                if (liveUnit.ssid != null) Text('SSID: ${liveUnit.ssid}'),
                if (liveUnit.mqttServer != null)
                  Text('MQTT: ${liveUnit.mqttServer}:${liveUnit.mqttPort}'),
                if (liveUnit.battery != null)
                  Text('Bat: ${liveUnit.battery!.toStringAsFixed(1)} V'),
                Text('Brightness: ${liveUnit.brightness}'),
                if (liveUnit.ledsPerPort.isNotEmpty)
                  Text(
                    'LEDs: ${liveUnit.ledsPerPort.entries.map((e) => 'P${e.key}:${e.value}').join(', ')}',
                  ),
                const SizedBox(height: 8),
                Text('Devices: $totalDevices'),
                Text('PUM-A: $pumA · PUM-B: $pumB · PUM-C: $pumC · DIST: $dist'),
                Text('BTN: $btnCount · DISP: $dispCount · LEDS: $ledsCount · DIST: $distCount'),
                const SizedBox(height: 8),
                Text('Last seen: ${liveUnit.lastSeenText}'),
                const SizedBox(height: 8),
                if (liveUnit.supportsBin)
                  Row(
                    children: [
                      const Text('Režim LED příkazů:'),
                      const SizedBox(width: 8),
                      _BinOldToggle(
                        useBin: liveUnit.useBin,
                        onToggle: () => state.toggleBinMode(liveUnit.id),
                      ),
                    ],
                  )
                else
                  const Text('Režim LED příkazů: OLD (BIN nepodporován)'),
              ],
            );
          },
        ),
        actionsPadding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
        actionsAlignment: MainAxisAlignment.spaceEvenly,
        actions: [
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 36),
              foregroundColor: Colors.red,
              side: const BorderSide(color: Colors.red),
            ),
            onPressed: () {
              Navigator.pop(dialogCtx);
              _showChangeUnitIdDialog(context, unit);
            },
            child: const Text('Změnit ID'),
          ),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 36),
            ),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: infoLines.join('\n')));
              if (!dialogCtx.mounted) return;
              ScaffoldMessenger.of(dialogCtx).showSnackBar(
                const SnackBar(
                  content: Text('Info zkopírováno do schránky'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            child: const Text('Kopírovat'),
          ),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 36),
            ),
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  /// Dialog pro změnu ID jednotky. Validace: 0–9999 (4-místné), nesmí
  /// kolidovat s jinou jednotkou. Po Potvrdit pošle SET-ID; firmware se
  /// sám restartuje a nahlásí se s novým ID novým ALIVE.
  void _showChangeUnitIdDialog(BuildContext context, P2LUnit unit) {
    final state = context.read<AppState>();
    final currentNum = int.tryParse(unit.id.startsWith('u') ? unit.id.substring(1) : unit.id) ?? 0;
    final ctrl = TextEditingController(text: currentNum.toString().padLeft(4, '0'));
    String? error;

    showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Změnit ID jednotky'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Aktuální ID: ${unit.displayName}'),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                autofocus: true,
                keyboardType: TextInputType.number,
                maxLength: 4,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: 'Nové ID (0000–9999)',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  errorText: error,
                  counterText: '',
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Nová jednotka má defaultně ID 0000.\n'
                'Po potvrzení se firmware sám restartuje a přihlásí se s novým ID.',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogCtx), child: const Text('Zrušit')),
            FilledButton(
              onPressed: () async {
                final raw = ctrl.text.trim();
                final newId = int.tryParse(raw);
                if (newId == null || newId < 0 || newId > 9999) {
                  setLocal(() => error = 'Zadej číslo 0–9999');
                  return;
                }
                if (newId == currentNum) {
                  setLocal(() => error = 'Stejné jako aktuální ID');
                  return;
                }
                final newKey = newId.toString().padLeft(newId >= 1000 ? 6 : 4, '0');
                // Kolize: porovnej numericky proti všem jednotkám.
                final clash = state.units.values.any((u) {
                  final n = int.tryParse(u.id.startsWith('u') ? u.id.substring(1) : u.id) ?? -1;
                  return n == newId && u.id != unit.id;
                });
                if (clash) {
                  setLocal(() => error = 'ID $newKey už používá jiná jednotka');
                  return;
                }
                final confirmed = await showDialog<bool>(
                  context: dialogCtx,
                  builder: (confirmCtx) => AlertDialog(
                    title: const Text('Opravdu změnit ID?'),
                    content: Text(
                      'Jednotka ${unit.displayName} bude přepsána na ID $newKey.\n'
                      'Firmware se po přijetí příkazu restartuje.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(confirmCtx, false),
                        child: const Text('Zrušit'),
                      ),
                      FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: Colors.red),
                        onPressed: () => Navigator.pop(confirmCtx, true),
                        child: const Text('Ano, změnit'),
                      ),
                    ],
                  ),
                );
                if (confirmed != true) return;
                if (!dialogCtx.mounted) return;
                Navigator.pop(dialogCtx);
                state.setUnitId(unit.id, newId);
              },
              child: const Text('Potvrdit'),
            ),
          ],
        ),
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
              'Vybráno: ${state.selectedCount} z ${state.totalCount}',
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
                              ? const [
                                  Colors.red,
                                  Colors.green,
                                  Colors.blue,
                                  Colors.yellow,
                                  Colors.purple,
                                  Colors.red,
                                  Colors.green,
                                  Colors.blue,
                                ][p]
                              : Colors.grey[300],
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '$p',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: state.selectedPorts.contains(p)
                                ? Colors.white
                                : Colors.grey[600],
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
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.blue,
                        fontWeight: FontWeight.bold,
                      ),
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
                    onPressed: state.selectedCount > 0 ? state.sendTest : null,
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
                    onPressed: state.selectedCount > 0 ? state.sendClear : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('ZHASNI'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.red,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: state.totalCount > 0 ? state.scanAll : null,
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
          children: [_seg('BIN', useBin), _seg('OLD', !useBin)],
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
