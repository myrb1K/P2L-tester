import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../main.dart' show appVersion;
import '../models/broker_profile.dart';
import '../models/device.dart';
import '../models/module.dart';
import '../models/unit.dart';
import '../providers/app_state.dart';
import '../services/mqtt_service.dart';
import '../services/unit_ids_io.dart';
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
  /// ID, na které jsme právě poslali `get_param` přes "Ověřit". Jakmile se
  /// jednotka objeví v `state.units`, pole se v build() vyčistí a tento
  /// indikátor se resetuje. Pokud modul neodpoví (neexistuje na brokeru),
  /// zůstane vyplněn a pole tedy uživatel může upravit a zkusit znovu.
  String? _pendingVerifyId;

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
    final canonical = canonicalUnitId(input);
    if (canonical == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Neplatné ID (zadej 1–6 cifer)')),
      );
      return;
    }
    setState(() => _pendingVerifyId = canonical);
    context.read<AppState>().sendGetParam(canonical);
    FocusScope.of(context).unfocus();
  }

  Future<void> _onLoadList() async {
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);

    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Načíst seznam P2L modulů',
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.single;
    String? content;
    try {
      if (file.bytes != null) {
        content = utf8.decode(file.bytes!);
      } else if (file.path != null) {
        content = await File(file.path!).readAsString();
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Nelze přečíst soubor: $e')));
      return;
    }
    if (content == null) {
      messenger.showSnackBar(const SnackBar(content: Text('Prázdný soubor.')));
      return;
    }

    final parsed = UnitIdsBundle.decode(content);
    if (!parsed.isOk) {
      messenger.showSnackBar(SnackBar(content: Text(parsed.error!)));
      return;
    }

    // Pokud JSON nese broker profile a v uložených profilech ještě není
    // (podle názvu, case-insensitive), tiše ho přidá bez aktivace —
    // analogie addProfileWithoutActivating z BulkConfigMenu.
    var profileAdded = false;
    final profileJson = parsed.brokerProfile;
    if (profileJson != null) {
      try {
        final profile = BrokerProfile.fromJson(profileJson);
        if (!state.isProfileNameTaken(profile.name)) {
          await state.addProfileWithoutActivating(profile);
          profileAdded = true;
        }
      } catch (_) {
        // Neplatný profile v JSON — ignoruj, pokračuj s ID.
      }
    }

    final created = await state.importUnitIds(parsed.ids!);
    final parts = <String>['Naimportováno $created nových ID'];
    if (parsed.skipped.isNotEmpty) {
      parts.add('${parsed.skipped.length} přeskočeno (neplatné)');
    }
    if (profileAdded) {
      parts.add('broker profil přidán');
    }
    messenger.showSnackBar(SnackBar(content: Text(parts.join(' · '))));
  }

  Future<void> _onExportList() async {
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final ids = state.allUnitIds;
    if (ids.isEmpty) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Žádné P2L moduly k exportu')));
      return;
    }
    final brokerName = state.activeBrokerName ?? 'P2L';
    final fileName = unitIdsFileName(brokerName, ids.length, DateTime.now());
    final activeIdx = state.activeProfileIndex;
    final profileJson =
        (activeIdx >= 0 && activeIdx < state.profiles.length)
            ? state.profiles[activeIdx].toJson()
            : null;
    final json = UnitIdsBundle.encode(
      ids,
      brokerName: brokerName,
      appVersion: appVersion,
      brokerProfile: profileJson,
    );

    final choice = await showDialog<_ExportChoice>(
      context: context,
      builder: (_) => const _ExportChoiceDialog(),
    );
    if (choice == null) return;
    if (!mounted) return;

    try {
      if (choice == _ExportChoice.share) {
        final dir = await getTemporaryDirectory();
        final file = File('${dir.path}/$fileName');
        await file.writeAsString(json);
        await Share.shareXFiles(
          [XFile(file.path, mimeType: 'application/json')],
          subject: fileName,
        );
      } else {
        final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
        if (isMobile) {
          final bytes = utf8.encode(json);
          final path = await FilePicker.platform.saveFile(
            dialogTitle: 'Uložit seznam P2L modulů',
            fileName: fileName,
            type: FileType.custom,
            allowedExtensions: const ['json'],
            bytes: Uint8List.fromList(bytes),
          );
          if (path == null) return;
          messenger.showSnackBar(SnackBar(content: Text('Uloženo: $path')));
        } else {
          final path = await FilePicker.platform.saveFile(
            dialogTitle: 'Uložit seznam P2L modulů',
            fileName: fileName,
            type: FileType.custom,
            allowedExtensions: const ['json'],
          );
          if (path == null) return;
          final outPath =
              path.toLowerCase().endsWith('.json') ? path : '$path.json';
          await File(outPath).writeAsString(json);
          messenger.showSnackBar(SnackBar(content: Text('Uloženo: $outPath')));
        }
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export selhal: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        // Pokud jsme čekali na verify a jednotka se objevila v seznamu
        // (odpověděla na get_param nebo poslala ALIVE), vyčisti pole.
        final pending = _pendingVerifyId;
        if (pending != null && state.units.containsKey(pending)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            if (_pendingVerifyId != pending) return;
            _manualIdController.clear();
            setState(() => _pendingVerifyId = null);
          });
        }
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
                  icon: const Icon(Icons.dns_outlined),
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
                    onLoad: _onLoadList,
                    onExport: _onExportList,
                    isConnected: state.isConnected,
                    hasUnits: state.units.isNotEmpty,
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
  final VoidCallback onLoad;
  final VoidCallback onExport;
  final bool isConnected;
  final bool hasUnits;

  const _ManualIdInput({
    required this.controller,
    required this.onSubmit,
    required this.onLoad,
    required this.onExport,
    required this.isConnected,
    required this.hasUnits,
  });

  @override
  Widget build(BuildContext context) {
    final compactStyle = FilledButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      minimumSize: const Size(0, 40),
    );
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
          IconButton(
            icon: const Icon(Icons.file_upload_outlined),
            tooltip: 'Načíst seznam P2L modulů',
            onPressed: onLoad,
          ),
          IconButton(
            icon: const Icon(Icons.file_download_outlined),
            tooltip: 'Exportovat seznam P2L modulů',
            onPressed: hasUnits ? onExport : null,
          ),
          const SizedBox(width: 4),
          FilledButton(
            onPressed: isConnected ? onSubmit : null,
            style: compactStyle,
            child: const Text('Ověřit'),
          ),
        ],
      ),
    );
  }
}

enum _ExportChoice { share, save }

class _ExportChoiceDialog extends StatelessWidget {
  const _ExportChoiceDialog();

  @override
  Widget build(BuildContext context) {
    final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    return AlertDialog(
      title: const Text('Exportovat seznam'),
      content: const Text('Jak chceš soubor uložit?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Zrušit'),
        ),
        if (isMobile)
          FilledButton.icon(
            icon: const Icon(Icons.share),
            label: const Text('Sdílet'),
            onPressed: () => Navigator.pop(context, _ExportChoice.share),
          ),
        FilledButton.icon(
          icon: const Icon(Icons.save_alt),
          label: const Text('Uložit'),
          onPressed: () => Navigator.pop(context, _ExportChoice.save),
        ),
      ],
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
          key: ValueKey(unit.id),
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

class _UnitCard extends StatefulWidget {
  final P2LUnit unit;
  final bool isSelected;
  final int? moduleCount;
  final VoidCallback onToggle;
  final VoidCallback onGetParam;
  final VoidCallback onOpenDetail;

  const _UnitCard({
    super.key,
    required this.unit,
    required this.isSelected,
    required this.moduleCount,
    required this.onToggle,
    required this.onGetParam,
    required this.onOpenDetail,
  });

  @override
  State<_UnitCard> createState() => _UnitCardState();
}

class _UnitCardState extends State<_UnitCard> with SingleTickerProviderStateMixin {
  late final AnimationController _waveController;
  // P2LUnit je mutable a AppState přepisuje pole `isOnline` na téže instanci,
  // takže oldWidget.unit a widget.unit v `didUpdateWidget` ukazují na stejný
  // objekt s už aktualizovanou hodnotou. Proto si držíme předchozí stav
  // ručně a srovnáváme proti němu.
  late bool _lastOnline;

  @override
  void initState() {
    super.initState();
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1300),
    );
    _lastOnline = widget.unit.isOnline;
    if (_lastOnline) {
      // Wave spustit jen při úplně prvním objevení jednotky v listu.
      // Při remountu karty (scrolování) AppState vrátí false.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (context.read<AppState>().consumeFirstAppearAnimation(widget.unit.id)) {
          _waveController.forward(from: 0);
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant _UnitCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nowOnline = widget.unit.isOnline;
    if (!_lastOnline && nowOnline) {
      _waveController.forward(from: 0);
      context.read<AppState>().markUnitWaved(widget.unit.id);
    }
    _lastOnline = nowOnline;
  }

  @override
  void dispose() {
    _waveController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final unit = widget.unit;
    final isSelected = widget.isSelected;

    final card = Container(
      decoration: BoxDecoration(
        color: !unit.isOnline
            ? Colors.grey.withAlpha(30)
            : isSelected
            ? Colors.blue.withAlpha(20)
            : null,
        border: Border(bottom: BorderSide(color: Colors.grey.withAlpha(50))),
      ),
      child: Stack(
        children: [
          InkWell(
            onTap: widget.onToggle,
            child: Padding(
              padding: const EdgeInsets.only(left: 0, right: 8, top: 1, bottom: 1),
              child: Row(
                children: [
                  Checkbox(
                    value: isSelected,
                    onChanged: (_) => widget.onToggle(),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  Expanded(
                    child: Row(
                      children: [
                        if (unit.isPlaceholder) ...[
                          Tooltip(
                            message:
                                'Čeká na první odpověď — možná není na brokeru',
                            child: Icon(
                              Icons.help_outline,
                              size: 16,
                              color: Theme.of(context).colorScheme.outline,
                            ),
                          ),
                          const SizedBox(width: 4),
                        ],
                        SizedBox(
                          width: 40,
                          child: Text(
                            unit.displayName,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                              color: unit.isPlaceholder
                                  ? Theme.of(context).colorScheme.outline
                                  : null,
                            ),
                          ),
                        ),
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: unit.isPlaceholder
                                ? Colors.grey.shade300
                                : (unit.isOnline ? Colors.green : Colors.grey),
                          ),
                        ),
                        const SizedBox(width: 4),
                        SizedBox(
                          width: 42,
                          child: Text(
                            unit.isPlaceholder ? '—' : unit.lastSeenText,
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
                  Stack(
                    clipBehavior: Clip.none,
                    alignment: Alignment.center,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.device_hub, size: 28, color: Colors.blueGrey),
                        onPressed: widget.onOpenDetail,
                        tooltip: 'Seznam devices',
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      ),
                      if (widget.moduleCount != null)
                        IgnorePointer(
                          child: Badge(
                            backgroundColor: Colors.blueGrey,
                            textColor: Colors.white,
                            offset: const Offset(-2, 2),
                            label: Text('${widget.moduleCount}'),
                            child: const SizedBox(width: 32, height: 32),
                          ),
                        ),
                    ],
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
                    onPressed: widget.onGetParam,
                    tooltip: 'Obnovit',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  ),
                ],
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _waveController,
                builder: (_, _) {
                  if (!_waveController.isAnimating) return const SizedBox.shrink();
                  return ClipRect(
                    child: LayoutBuilder(
                      builder: (_, constraints) {
                        final w = constraints.maxWidth;
                        final waveW = w * 0.35;
                        final t = Curves.easeInOut.transform(_waveController.value);
                        final dx = -waveW + t * (w + waveW);
                        return Stack(
                          children: [
                            Positioned(
                              left: dx,
                              top: 0,
                              bottom: 0,
                              width: waveW,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.centerLeft,
                                    end: Alignment.centerRight,
                                    colors: [
                                      Colors.lightBlueAccent.withAlpha(0),
                                      Colors.lightBlueAccent.withAlpha(220),
                                      Colors.lightBlueAccent.withAlpha(0),
                                    ],
                                    stops: const [0.0, 0.5, 1.0],
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.lightBlueAccent.withAlpha(110),
                                      blurRadius: 18,
                                      spreadRadius: 2,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );

    return card;
  }

  void _showUnitInfo(BuildContext context, P2LUnit unit) {
    final state = context.read<AppState>();
    // Auto-fetch při otevření Info: pošli get_param + GET-DEVICES, aby se
    // chybějící údaje (IP/MAC/SSID/MQTT, počty devices) doplnily samy.
    // Dialog rebuilduje přes Consumer, takže se pole objeví hned po odpovědi.
    if (state.isConnected && !unit.isPlaceholder) {
      state.sendGetParam(unit.id);
      state.fetchDevices(unit.id);
    }

    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('P2L modul ${unit.displayName}'),
        content: Consumer<AppState>(
          builder: (_, state, _) {
            final liveUnit = state.units[unit.id] ?? unit;
            final modules = state.modulesForUnit(liveUnit.id) ?? const [];
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
            // "Načítání…" pokud kompletní info ještě nedorazilo (klíčové = MAC).
            // Vlastní waiting indikátor lze schovat, jakmile přijde get_param odpověď.
            final waiting = liveUnit.mac == null;
            return SelectionArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (waiting)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Theme.of(context).colorScheme.outline,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Načítání podrobností…',
                            style: TextStyle(
                              fontSize: 12,
                              fontStyle: FontStyle.italic,
                              color: Theme.of(context).colorScheme.outline,
                            ),
                          ),
                        ],
                      ),
                    ),
                  Text('ID: ${int.tryParse(liveUnit.id)?.toString() ?? liveUnit.id}'),
                  Text('FW: ${liveUnit.firmware ?? '—'}'),
                  Text('HW: ${liveUnit.hwModel ?? '—'}'),
                  Text('IP: ${liveUnit.ip ?? '—'}'),
                  Text('MAC: ${liveUnit.mac ?? '—'}'),
                  Text('SSID: ${liveUnit.ssid ?? '—'}'),
                  Text(liveUnit.mqttServer != null
                      ? 'MQTT: ${liveUnit.mqttServer}:${liveUnit.mqttPort}'
                      : 'MQTT: —'),
                  Text(liveUnit.battery != null
                      ? 'Bat: ${liveUnit.battery!.toStringAsFixed(1)} V'
                      : 'Bat: —'),
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
              ),
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
              final live = context.read<AppState>().units[unit.id] ?? unit;
              final mods = context.read<AppState>().modulesForUnit(live.id) ?? const [];
              final pA = mods.where((m) => m.type == ModuleType.pumA).length;
              final pB = mods.where((m) => m.type == ModuleType.pumB).length;
              final pC = mods.where((m) => m.type == ModuleType.pumC).length;
              final d = mods.where((m) => m.type == ModuleType.dist).length;
              final devs = mods.expand((m) => m.toDevices()).toList();
              final btn = devs.where((x) => x.type == DeviceType.btn).length;
              final disp = devs.where((x) => x.type == DeviceType.disp).length;
              final leds = devs.where((x) => x.type == DeviceType.leds).length;
              final distD = devs.where((x) => x.type == DeviceType.dist).length;
              final lines = <String>[
                'P2L modul ${live.displayName}',
                'ID: ${int.tryParse(live.id)?.toString() ?? live.id}',
                if (live.firmware != null) 'FW: ${live.firmware}',
                if (live.hwModel != null) 'HW: ${live.hwModel}',
                if (live.ip != null) 'IP: ${live.ip}',
                if (live.mac != null) 'MAC: ${live.mac}',
                if (live.ssid != null) 'SSID: ${live.ssid}',
                if (live.mqttServer != null) 'MQTT: ${live.mqttServer}:${live.mqttPort}',
                if (live.battery != null) 'Bat: ${live.battery!.toStringAsFixed(1)} V',
                'Brightness: ${live.brightness}',
                if (live.ledsPerPort.isNotEmpty)
                  'LEDs: ${live.ledsPerPort.entries.map((e) => 'P${e.key}:${e.value}').join(', ')}',
                'Devices: ${devs.length}',
                'PUM-A: $pA · PUM-B: $pB · PUM-C: $pC · DIST: $d',
                'BTN: $btn · DISP: $disp · LEDS: $leds · DIST: $distD',
                'Last seen: ${live.lastSeenText}',
                'BIN: ${live.supportsBin ? "ano" : "ne"}',
              ];
              await Clipboard.setData(ClipboardData(text: lines.join('\n')));
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
                      'Jednotka ${unit.displayName} bude přepsána na ID ${int.tryParse(newKey)?.toString() ?? newKey}.\n'
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
                FilledButton(
                  onPressed: state.selectedPorts.length == 8
                      ? state.deselectAllPorts
                      : state.selectAllPorts,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: const StadiumBorder(),
                    textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                  child: Text(state.selectedPorts.length == 8 ? 'Zrušit' : 'Vše'),
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
