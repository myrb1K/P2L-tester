import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../main.dart' show appVersion;
import '../models/bus_scan.dart';
import '../models/device_template.dart';
import '../models/module.dart';
import '../models/unit.dart';
import '../providers/app_state.dart';
import '../services/file_export.dart';
import '../services/template_io.dart';
import '../widgets/add_module_dialog.dart';
import '../widgets/apply_template_sheet.dart';
import '../widgets/replace_device_dialog.dart';
import '../widgets/set_device_id_dialog.dart';
import 'template_editor_screen.dart';

const int kMaxChipsPerUnit = 100;

class UnitDetailScreen extends StatefulWidget {
  final String unitId;
  const UnitDetailScreen({super.key, required this.unitId});

  @override
  State<UnitDetailScreen> createState() => _UnitDetailScreenState();
}

class _UnitDetailScreenState extends State<UnitDetailScreen> {
  @override
  void initState() {
    super.initState();
    // Načíst devices při otevření
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppState>().fetchDevices(widget.unitId);
    });
  }

  Future<void> _addModule(AppState state, List<PumaModule> currentModules) async {
    final existing = currentModules.map((m) => m.baseAddress).toSet();
    // Bez suggestedAddress → dialog navrhne první volnou adresu v rozsahu typu
    // (suggestedAddress se používá jen při přidání ze skenu sběrnice).
    final result = await showDialog<AddModuleResult>(
      context: context,
      builder: (_) => AddModuleDialog(
        existingAddresses: existing,
        hasPumAWithRoom: hasPumAWithButtonRoom(currentModules),
      ),
    );
    if (result != null) {
      if (currentModules.length >= kMaxChipsPerUnit) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Limit 100 entit na jednotku dosažen.')));
        return;
      }
      await state.addModules(widget.unitId, [result.module], restartAfter: result.restartAfter);
    }
  }

  /// Dialog pro sken jedné RS485 adresy (`SCAN-DEVICES {"Id":N}`). Firmware si
  /// typ (DIST 1–127 / PUM 128–247) odvodí z rozsahu adresy sám.
  Future<void> _promptScanId(BuildContext context, AppState state) async {
    final addr = await showDialog<int>(
      context: context,
      builder: (_) => const _ScanIdDialog(),
    );
    if (addr != null) {
      await state.scanBus(widget.unitId, scanId: addr);
    }
  }

  /// Přidání modulu z diagnostiky sběrnice — předvyplní adresu i typ nalezené
  /// scanem. U `PUM-X` (starší PUMA bez registru typu) typ neznáme → necháme
  /// na uživateli.
  Future<void> _addModuleAt(AppState state, List<PumaModule> currentModules,
      int address, String? busType) async {
    final existing = currentModules.map((m) => m.baseAddress).toSet();
    final suggestedType = switch (busType) {
      'PUM-A' => ModuleType.pumA,
      'PUM-B' => ModuleType.pumB,
      'PUM-C' => ModuleType.pumC,
      'DIST' => ModuleType.dist,
      _ => null, // PUM-X = neznámý podtyp
    };
    final result = await showDialog<AddModuleResult>(
      context: context,
      builder: (_) => AddModuleDialog(
        existingAddresses: existing,
        hasPumAWithRoom: hasPumAWithButtonRoom(currentModules),
        suggestedAddress: address,
        suggestedType: suggestedType,
      ),
    );
    if (result != null) {
      if (currentModules.length >= kMaxChipsPerUnit) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Limit 100 entit na jednotku dosažen.')),
        );
        return;
      }
      await state.addModules(widget.unitId, [result.module],
          restartAfter: result.restartAfter);
    }
  }

  /// Vyžádané změření DIST senzoru (GET-VALUE) — výsledek/poruchu ukáže hláškou.
  Future<void> _measureDist(AppState state, PumaModule module) async {
    final result =
        await state.requestDistValue(widget.unitId, module.baseAddress);
    if (!mounted || result == null) return; // null = timeout (hláška ve status baru)
    final messenger = ScaffoldMessenger.of(context);
    if (result.ok) {
      messenger.showSnackBar(SnackBar(
        content: Text('Senzor ${module.baseAddress}: '
            '${result.distance != null ? '${result.distance} mm' : 'bez hodnoty'}'),
      ));
    } else {
      messenger.showSnackBar(SnackBar(
        content: Text('Senzor ${module.baseAddress}: porucha'
            '${result.message != null ? ' — ${result.message}' : ''}'),
      ));
    }
  }

  Future<void> _editModule(AppState state, PumaModule module) async {
    final existing = (state.modulesForUnit(widget.unitId) ?? const [])
        .map((m) => m.baseAddress)
        .toSet();
    final result = await showDialog<AddModuleResult>(
      context: context,
      builder: (_) => AddModuleDialog(existingAddresses: existing, initial: module),
    );
    if (result == null) return;
    if (result.module.type == ModuleType.dist && result.module.distConfig != null) {
      await state.updateDistConfig(
        unitId: widget.unitId,
        distAddress: result.module.baseAddress,
        config: result.module.distConfig!,
      );
    }
  }

  Future<void> _replaceModule(AppState state, PumaModule module) async {
    final existing = (state.modulesForUnit(widget.unitId) ?? const [])
        .map((m) => m.baseAddress)
        .toSet();
    final result = await showDialog<ReplaceResult>(
      context: context,
      builder: (_) => ReplaceDeviceDialog(module: module, existingAddresses: existing),
    );
    if (result == null) return;

    // Před přečipováním ověříme, že nový kus je na své default adrese fyzicky
    // na sběrnici. Když není (nebo to nejde ověřit), zeptáme se, zda pokračovat.
    final found =
        await state.probeBusAddress(widget.unitId, result.newDefaultAddress);
    if (!mounted) return;
    if (found != true) {
      final msg = found == false
          ? 'Nový kus na adrese ${result.newDefaultAddress} nebyl na sběrnici nalezen — možná není připojený.'
          : 'Nový kus na adrese ${result.newDefaultAddress} se nepodařilo ověřit (starší firmware bez SCAN-DEVICES?).';
      final proceed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Nový kus neověřen'),
          content: Text('$msg\n\nPřesto provést výměnu?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Zrušit'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Přesto vyměnit'),
            ),
          ],
        ),
      );
      if (proceed != true) return;
    }

    await state.replaceDevice(
      unitId: widget.unitId,
      type: result.type,
      oldAddress: result.oldAddress,
      newDefaultAddress: result.newDefaultAddress,
      restartAfter: result.restartAfter,
    );
  }

  Future<void> _setIdModule(AppState state, PumaModule module) async {
    final existing = (state.modulesForUnit(widget.unitId) ?? const [])
        .map((m) => m.baseAddress)
        .toSet();
    final result = await showDialog<SetDeviceIdResult>(
      context: context,
      builder: (_) => SetDeviceIdDialog(module: module, existingAddresses: existing),
    );
    if (result != null) {
      await state.setDeviceId(
        unitId: widget.unitId,
        type: result.type,
        oldAddress: result.oldAddress,
        newAddress: result.newAddress,
        restartAfter: result.restartAfter,
      );
    }
  }

  Future<void> _deleteModule(AppState state, PumaModule module) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Smazat modul'),
        content: Text('Opravdu smazat ${module.displayLabel}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Zrušit')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Smazat'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await state.deleteModule(widget.unitId, module);
    }
  }

  Future<void> _applyTemplate(AppState state) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => ApplyTemplateSheet(preselectedUnitIds: {widget.unitId}),
    );
  }

  Future<void> _saveAsTemplate(List<PumaModule> modules) async {
    if (modules.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) {
            final displayId = int.tryParse(widget.unitId)?.toString() ?? widget.unitId;
            return TemplateEditorScreen(seedModules: modules, seedName: 'Z modulu $displayId');
          },
      ),
    );
  }

  Future<void> _exportModules(List<PumaModule> modules) async {
    final template = DeviceTemplate(
      name: 'Z unit ${widget.unitId}',
      modules: modules,
      created: DateTime.now(),
    );
    final displayId = int.tryParse(widget.unitId)?.toString() ?? widget.unitId;
    final json = TemplateBundle.encode([template], appVersion: appVersion);
    final fileName = 'Devices_${widget.unitId}.json';

    if (!mounted) return;
    final share = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Exportovat devices v P2L unit $displayId'),
        content: Text('${modules.length} devices'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Zrušit'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sdílet'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Uložit'),
          ),
        ],
      ),
    );
    if (share == null) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);

    try {
      // Sdílení (přes dočasný soubor) jen nativně — na webu path_provider
      // a Share API nefungují, tak vždy stáhneme.
      if (share && !kIsWeb) {
        final dir = await getTemporaryDirectory();
        final file = File('${dir.path}/$fileName');
        await file.writeAsString(json);
        await Share.shareXFiles([XFile(file.path)], subject: fileName);
      } else {
        final res = await saveTextFile(
          fileName: fileName,
          content: json,
          dialogTitle: 'Uložit devices',
        );
        if (res.cancelled) return;
        messenger.showSnackBar(SnackBar(
          content: Text(res.path != null ? 'Uloženo: ${res.path}' : 'Staženo: $fileName'),
        ));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export selhal: $e')));
    }
  }

  Future<void> _importModules(AppState state) async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;

    final file = picked.files.first;
    final String content;
    if (file.bytes != null) {
      content = String.fromCharCodes(file.bytes!);
    } else if (file.path != null) {
      content = await File(file.path!).readAsString();
    } else {
      return;
    }

    final parsed = TemplateBundle.decode(content);
    if (!parsed.isOk) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import selhal: ${parsed.error}')),
      );
      return;
    }

    final importedModules = parsed.templates![0].modules;
    final currentCount = state.modulesForUnit(widget.unitId)?.length ?? 0;

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Nahradit devices?'),
        content: Text(
          'Importem nahradíš v P2L unit ${int.tryParse(widget.unitId)?.toString() ?? widget.unitId} '
          '${currentCount == 0 ? 'prázdný seznam' : '$currentCount stávajících devices'} '
          '${importedModules.length} importovanými. Tato akce je nevratná.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Zrušit'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Nahradit'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await state.wipeDevices(widget.unitId);
    await state.addModules(widget.unitId, importedModules);
  }

  Future<void> _wipeAll(AppState state) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Smazat všechny devices?'),
        content: Text('Z P2L unit ${int.tryParse(widget.unitId)?.toString() ?? widget.unitId} se odstraní všechny devices. Nelze vrátit.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Zrušit')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Smazat vše'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await state.wipeDevices(widget.unitId);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        final unit = state.units[widget.unitId] ?? P2LUnit(id: widget.unitId);
        final modules = state.modulesForUnit(widget.unitId) ?? const [];
        final pending = state.isModulesPending(widget.unitId);
        final fetchedAt = state.modulesFetchedAt(widget.unitId);

        // Červený rámeček chipu: device chybí na sběrnici (sken) NEBO hlásí
        // poruchu v ALIVE (Code != 0). Šedé „ghost" chipy = nalezené neuložené.
        final diag = state.busDiagnosis(widget.unitId);
        final alertAddresses = {
          for (final r in diag)
            if (r.status == BusScanStatus.missing) r.address,
          ...state.deviceFaultAddresses(widget.unitId),
        };
        final ghosts = [
          for (final r in diag)
            if (r.status == BusScanStatus.unregistered) r,
        ];

        return Scaffold(
          appBar: AppBar(
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Načíst devices',
                onPressed: () => state.fetchDevices(widget.unitId),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.radar),
                tooltip: 'Skenovat sběrnici (diagnostika)',
                enabled: !state.isBusScanPending(widget.unitId),
                // Pozn.: hodnoty musí být nenulové — PopupMenuButton bere
                // `null` jako „zrušeno" a onSelected by se nezavolal.
                onSelected: (choice) {
                  switch (choice) {
                    case 'id':
                      _promptScanId(context, state);
                    case 'pum':
                      state.scanBus(widget.unitId, scope: BusScanScope.pum);
                    case 'dist':
                      state.scanBus(widget.unitId, scope: BusScanScope.dist);
                    default:
                      state.scanBus(widget.unitId, scope: BusScanScope.all);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'all', child: Text('Vše')),
                  PopupMenuItem(value: 'pum', child: Text('PUM-X')),
                  PopupMenuItem(value: 'dist', child: Text('SENZORY')),
                  PopupMenuItem(value: 'id', child: Text('ID…')),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: 'Přidat device',
                onPressed: () => _addModule(state, modules),
              ),
              IconButton(
                icon: const Icon(Icons.dashboard_customize),
                tooltip: 'Aplikovat šablonu',
                onPressed: () => _applyTemplate(state),
              ),
              IconButton(
                icon: const Icon(Icons.bookmark_add_outlined),
                tooltip: 'Uložit jako šablonu',
                onPressed: modules.isEmpty ? null : () => _saveAsTemplate(modules),
              ),
              IconButton(
                icon: const Icon(Icons.file_download_outlined),
                tooltip: 'Exportovat devices do souboru',
                onPressed: modules.isEmpty ? null : () => _exportModules(modules),
              ),
              IconButton(
                icon: const Icon(Icons.file_upload_outlined),
                tooltip: 'Importovat devices ze souboru',
                onPressed: () => _importModules(state),
              ),
              IconButton(
                icon: const Icon(Icons.delete_sweep, color: Colors.red),
                tooltip: 'Smazat všechny devices',
                onPressed: modules.isEmpty ? null : () => _wipeAll(state),
              ),
            ],
          ),
          body: Column(
            children: [
              _UnitInfoCard(unit: unit, modules: modules, fetchedAt: fetchedAt),
              if (state.deviceActionStatus.isNotEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  color: (state.deviceActionIsError ? Colors.red : Colors.blue)
                      .withAlpha(25),
                  child: Text(
                    state.deviceActionStatus,
                    style: TextStyle(
                      fontSize: 12,
                      color: state.deviceActionIsError
                          ? Colors.red[800]
                          : Colors.blue[800],
                      fontWeight: state.deviceActionIsError
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ),
              if (pending) const LinearProgressIndicator(minHeight: 2),
              if (state.isBusScanPending(widget.unitId))
                const LinearProgressIndicator(minHeight: 2),
              if (state.busScanFor(widget.unitId) != null)
                _BusScanPanel(
                  scan: state.busScanFor(widget.unitId)!,
                  modules: modules,
                  onClose: () => state.clearBusScan(widget.unitId),
                ),
              Expanded(
                child: (modules.isEmpty && ghosts.isEmpty)
                    ? _EmptyModules(pending: pending)
                    : _ModulesGroupedList(
                        unitId: widget.unitId,
                        modules: modules,
                        alertAddresses: alertAddresses,
                        ghosts: ghosts,
                        onAdd: (addr, busType) =>
                            _addModuleAt(state, modules, addr, busType),
                        onReplace: (m) => _replaceModule(state, m),
                        onSetId: (m) => _setIdModule(state, m),
                        onEdit: (m) => _editModule(state, m),
                        onDelete: (m) => _deleteModule(state, m),
                        onTestDisplay: (m) => state.sendDispData(
                          unitId: widget.unitId,
                          dispAddress: m.baseAddress,
                          data: 'AHOJ',
                        ),
                        onShowAddress: (m) => state.sendDispData(
                          unitId: widget.unitId,
                          dispAddress: m.baseAddress,
                          data: m.baseAddress.toString().padLeft(4, '0'),
                        ),
                        onClearDisplay: (m) => state.sendDispData(
                          unitId: widget.unitId,
                          dispAddress: m.baseAddress,
                          data: '',
                        ),
                        onLedsOn: (m) =>
                            state.sendLedsOn(unitId: widget.unitId, ledsAddress: m.baseAddress),
                        onLedsOff: (m) =>
                            state.sendLedsOff(unitId: widget.unitId, ledsAddress: m.baseAddress),
                        onMeasure: (m) => _measureDist(state, m),
                        onRescan: (m) =>
                            state.scanBus(widget.unitId, scanId: m.baseAddress),
                        onAlive: (m) => state.sendModuleAlive(
                          unitId: widget.unitId,
                          module: m,
                        ),
                        canReplace: _canReplace,
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  bool _canReplace(PumaModule m) =>
      m.type == ModuleType.pumA ||
      m.type == ModuleType.pumB ||
      m.type == ModuleType.pumC ||
      m.type == ModuleType.dist;
}

class _UnitInfoCard extends StatelessWidget {
  final P2LUnit unit;
  final List<PumaModule> modules;
  final DateTime? fetchedAt;

  const _UnitInfoCard({required this.unit, required this.modules, required this.fetchedAt});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: unit.isOnline ? Colors.green : Colors.grey,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    unit.displayName,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                if (unit.firmware != null)
                  Text(
                    'FW: ${unit.firmware}',
                    style: const TextStyle(fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: (unit.ip != null || unit.mac != null)
                      ? Text(
                          [
                            if (unit.ip != null) 'IP: ${unit.ip}',
                            if (unit.mac != null) 'MAC: ${unit.mac}',
                            if (unit.battery != null) 'Bat: ${unit.battery!.toStringAsFixed(1)} V',
                          ].join(' · '),
                          style: const TextStyle(fontSize: 11),
                          overflow: TextOverflow.ellipsis,
                        )
                      : const SizedBox.shrink(),
                ),
                if (fetchedAt != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    'načteno ${_fmtTime(fetchedAt!)}',
                    style: const TextStyle(fontSize: 10, color: Colors.grey),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _fmtTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    final s = t.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}

class _ModulesGroupedList extends StatelessWidget {
  final String unitId;
  final List<PumaModule> modules;
  // Adresy modulů k červenému okraji chipu (chybí na sběrnici ze skenu NEBO
  // hlásí poruchu v ALIVE).
  final Set<int> alertAddresses;
  // Devices nalezené skenem, ale neuložené v jednotce → šedé „ghost" chipy.
  final List<BusScanRow> ghosts;
  final void Function(int address, String? busType) onAdd;
  final void Function(PumaModule) onReplace;
  final void Function(PumaModule) onSetId;
  final void Function(PumaModule) onEdit;
  final void Function(PumaModule) onDelete;
  final void Function(PumaModule) onTestDisplay;
  final void Function(PumaModule) onShowAddress;
  final void Function(PumaModule) onClearDisplay;
  final void Function(PumaModule) onLedsOn;
  final void Function(PumaModule) onLedsOff;
  final void Function(PumaModule) onMeasure;
  final void Function(PumaModule) onRescan;
  final void Function(PumaModule) onAlive;
  final bool Function(PumaModule) canReplace;

  const _ModulesGroupedList({
    required this.unitId,
    required this.modules,
    required this.alertAddresses,
    required this.ghosts,
    required this.onAdd,
    required this.onReplace,
    required this.onSetId,
    required this.onEdit,
    required this.onDelete,
    required this.onTestDisplay,
    required this.onShowAddress,
    required this.onClearDisplay,
    required this.onLedsOn,
    required this.onLedsOff,
    required this.onMeasure,
    required this.onRescan,
    required this.onAlive,
    required this.canReplace,
  });

  // Pořadí kategorií. 'PUM-X' (starší PUMA bez registru typu) je jen pro ghost
  // chipy ze skenu — v konfiguraci nikdy není.
  static const _order = ['PUM-A', 'PUM-B', 'PUM-C', 'PUM-X', 'SENZOR'];

  /// Kategorie konfigurovaného modulu.
  static String _catForModule(ModuleType t) => switch (t) {
        ModuleType.pumA => 'PUM-A',
        ModuleType.pumB => 'PUM-B',
        ModuleType.pumC => 'PUM-C',
        ModuleType.dist => 'SENZOR',
      };

  /// Kategorie podle typu ze skenu sběrnice.
  static String _catForBusType(String? busType) => switch (busType) {
        'PUM-A' => 'PUM-A',
        'PUM-B' => 'PUM-B',
        'PUM-C' => 'PUM-C',
        'DIST' => 'SENZOR',
        _ => 'PUM-X',
      };

  Color _color(String cat) => switch (cat) {
        'PUM-A' => Colors.blue,
        'PUM-B' => Colors.orange,
        'PUM-C' => Colors.purple,
        'SENZOR' => Colors.teal,
        _ => Colors.grey, // PUM-X
      };

  @override
  Widget build(BuildContext context) {
    final configByCat = <String, List<PumaModule>>{};
    for (final m in modules) {
      configByCat.putIfAbsent(_catForModule(m.type), () => []).add(m);
    }
    for (final list in configByCat.values) {
      list.sort((a, b) => a.baseAddress.compareTo(b.baseAddress));
    }

    final ghostByCat = <String, List<BusScanRow>>{};
    for (final g in ghosts) {
      ghostByCat.putIfAbsent(_catForBusType(g.busType), () => []).add(g);
    }
    for (final list in ghostByCat.values) {
      list.sort((a, b) => a.address.compareTo(b.address));
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      children: [
        for (final cat in _order)
          if ((configByCat[cat]?.isNotEmpty ?? false) ||
              (ghostByCat[cat]?.isNotEmpty ?? false))
            _GroupSection(
              unitId: unitId,
              label: cat == 'SENZOR' ? 'SENZOR' : cat,
              color: _color(cat),
              modules: configByCat[cat] ?? const [],
              ghosts: ghostByCat[cat] ?? const [],
              alertAddresses: alertAddresses,
              onAdd: onAdd,
              onReplace: onReplace,
              onSetId: onSetId,
              onEdit: cat == 'SENZOR' ? onEdit : null,
              onDelete: onDelete,
              canReplace: canReplace,
              onTestDisplay: cat == 'PUM-A' ? onTestDisplay : null,
              onShowAddress: cat == 'PUM-A' ? onShowAddress : null,
              onClearDisplay: cat == 'PUM-A' ? onClearDisplay : null,
              onLedsOn: (cat == 'PUM-A' || cat == 'PUM-B') ? onLedsOn : null,
              onLedsOff: (cat == 'PUM-A' || cat == 'PUM-B') ? onLedsOff : null,
              onMeasure: cat == 'SENZOR' ? onMeasure : null,
              onRescan: onRescan,
              onAlive: onAlive,
            ),
      ],
    );
  }
}

class _GroupSection extends StatelessWidget {
  final String unitId;
  final String label;
  final Color color;
  final List<PumaModule> modules;
  final List<BusScanRow> ghosts;
  final Set<int> alertAddresses;
  final void Function(int address, String? busType) onAdd;
  final void Function(PumaModule) onReplace;
  final void Function(PumaModule) onSetId;
  final void Function(PumaModule) onDelete;
  final void Function(PumaModule)? onEdit;
  final void Function(PumaModule)? onTestDisplay;
  final void Function(PumaModule)? onShowAddress;
  final void Function(PumaModule)? onClearDisplay;
  final void Function(PumaModule)? onLedsOn;
  final void Function(PumaModule)? onLedsOff;
  final void Function(PumaModule)? onMeasure;
  final void Function(PumaModule) onRescan;
  final void Function(PumaModule) onAlive;
  final bool Function(PumaModule) canReplace;

  const _GroupSection({
    required this.unitId,
    required this.label,
    required this.color,
    required this.modules,
    required this.ghosts,
    required this.alertAddresses,
    required this.onAdd,
    required this.onReplace,
    required this.onSetId,
    required this.onDelete,
    required this.onRescan,
    required this.onAlive,
    required this.canReplace,
    this.onEdit,
    this.onTestDisplay,
    this.onShowAddress,
    this.onClearDisplay,
    this.onLedsOn,
    this.onLedsOff,
    this.onMeasure,
  });

  @override
  Widget build(BuildContext context) {
    final firstType = modules.isNotEmpty ? modules.first.type : null;
    final hasLedsSupport =
        firstType == ModuleType.pumA || firstType == ModuleType.pumB;
    final hasDispSupport = firstType == ModuleType.pumA;
    final ledModules =
        hasLedsSupport ? modules.where((m) => m.hasLeds).toList() : const <PumaModule>[];

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                modules.isEmpty
                    ? '$label  ${ghosts.length}× nové'
                    : ghosts.isEmpty
                        ? '$label  ${modules.length}x'
                        : '$label  ${modules.length}x  +${ghosts.length}',
                style: TextStyle(fontWeight: FontWeight.w700, color: color, fontSize: 13),
              ),
              if (hasLedsSupport || hasDispSupport) const Spacer(),
              if (hasLedsSupport) ...[
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  iconSize: 18,
                  tooltip: ledModules.isEmpty
                      ? 'Žádné devices s LEDS'
                      : 'Rozsvítit všechny LEDS (${ledModules.length})',
                  icon: Icon(
                    Icons.lightbulb,
                    color: ledModules.isEmpty ? Colors.grey : Colors.amber.shade700,
                  ),
                  onPressed: ledModules.isEmpty
                      ? null
                      : () => _bulkLeds(context, ledModules, on: true),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  iconSize: 18,
                  tooltip: ledModules.isEmpty
                      ? 'Žádné devices s LEDS'
                      : 'Zhasnout všechny LEDS (${ledModules.length})',
                  icon: const Icon(Icons.lightbulb_outline),
                  onPressed: ledModules.isEmpty
                      ? null
                      : () => _bulkLeds(context, ledModules, on: false),
                ),
              ],
              if (hasDispSupport) ...[
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  iconSize: 18,
                  tooltip: 'AHOJ na všechny displeje',
                  icon: const Icon(Icons.text_fields, color: Colors.blue),
                  onPressed: () => _bulkDisp(context, 'AHOJ'),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  iconSize: 18,
                  tooltip: 'Adresu na každý displej (0130, 0246, …)',
                  icon: const Icon(Icons.pin, color: Colors.blue),
                  onPressed: () => _bulkDispAddresses(context),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  iconSize: 18,
                  tooltip: 'Displeje ukážou své SKUTEČNÉ uložené ID z čipu '
                      '(„????") — odhalí fyzickou výměnu (Pum-A FW v3.01+)',
                  icon: const Icon(Icons.question_mark, color: Colors.blue),
                  onPressed: () => _bulkDisp(context, '????'),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  iconSize: 18,
                  tooltip: 'Smazat text na všech displejích',
                  icon: const Icon(Icons.format_clear),
                  onPressed: () => _bulkDisp(context, ''),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final m in modules)
                _AddressChip(
                  unitId: unitId,
                  module: m,
                  color: color,
                  alert: alertAddresses.contains(m.baseAddress),
                  onReplace: canReplace(m) ? () => onReplace(m) : null,
                  onSetId: () => onSetId(m),
                  onEdit: onEdit != null ? () => onEdit!(m) : null,
                  onDelete: () => onDelete(m),
                  onTestDisplay: onTestDisplay != null ? () => onTestDisplay!(m) : null,
                  onShowAddress: onShowAddress != null ? () => onShowAddress!(m) : null,
                  onClearDisplay: onClearDisplay != null ? () => onClearDisplay!(m) : null,
                  onLedsOn: onLedsOn != null && m.hasLeds ? () => onLedsOn!(m) : null,
                  onLedsOff: onLedsOff != null && m.hasLeds ? () => onLedsOff!(m) : null,
                  onMeasure: onMeasure != null ? () => onMeasure!(m) : null,
                  onRescan: () => onRescan(m),
                  onAlive: () => onAlive(m),
                ),
              for (final g in ghosts)
                _GhostChip(
                  address: g.address,
                  busType: g.busType,
                  onAdd: () => onAdd(g.address, g.busType),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _bulkLeds(
    BuildContext context,
    List<PumaModule> ledModules, {
    required bool on,
  }) async {
    final state = context.read<AppState>();
    for (final m in ledModules) {
      if (on) {
        await state.sendLedsOn(unitId: unitId, ledsAddress: m.baseAddress);
      } else {
        await state.sendLedsOff(unitId: unitId, ledsAddress: m.baseAddress);
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<void> _bulkDisp(BuildContext context, String text) async {
    // Broadcast na všechny displeje přes DISP 050000 (adresa 0) — jeden příkaz.
    // (Ověřeno na novém FW; starší FW broadcast odmítal, viz historie v2.71.)
    final state = context.read<AppState>();
    await state.sendDispData(unitId: unitId, dispAddress: 0, data: text);
  }

  Future<void> _bulkDispAddresses(BuildContext context) async {
    final state = context.read<AppState>();
    for (final m in modules) {
      await state.sendDispData(
        unitId: unitId,
        dispAddress: m.baseAddress,
        data: m.baseAddress.toString().padLeft(4, '0'),
      );
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }
}

class _AddressChip extends StatelessWidget {
  final String unitId;
  final PumaModule module;
  final Color color;
  // Device má problém (chybí na sběrnici ze skenu nebo hlásí poruchu v ALIVE)
  // → červený okraj.
  final bool alert;
  final VoidCallback? onReplace;
  final VoidCallback? onSetId;
  final VoidCallback? onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onTestDisplay;
  final VoidCallback? onShowAddress;
  final VoidCallback? onClearDisplay;
  final VoidCallback? onLedsOn;
  final VoidCallback? onLedsOff;
  final VoidCallback? onMeasure;
  final VoidCallback? onRescan;
  final VoidCallback? onAlive;

  const _AddressChip({
    required this.unitId,
    required this.module,
    required this.color,
    this.alert = false,
    required this.onReplace,
    required this.onSetId,
    required this.onDelete,
    this.onEdit,
    this.onTestDisplay,
    this.onShowAddress,
    this.onClearDisplay,
    this.onLedsOn,
    this.onLedsOff,
    this.onMeasure,
    this.onRescan,
    this.onAlive,
  });

  Color _effectiveColor() {
    if (module.type != ModuleType.pumA) return color;
    switch (module.buttonCount) {
      case 0:
        return Colors.lightBlue;
      case 1:
        return Colors.blue;
      case 2:
        return Colors.indigo;
    }
    return color;
  }

  /// Barva flash indikátoru stisku tlačítka podle typu modulu a strany.
  /// PUM-A i PUM-B: zelená (obě strany). PUM-C: levé modré, pravé červené.
  Color _pressColor({required bool left}) {
    switch (module.type) {
      case ModuleType.pumA:
      case ModuleType.pumB:
        return Colors.green;
      case ModuleType.pumC:
        return left ? Colors.blue : Colors.red;
      case ModuleType.dist:
        return Colors.redAccent;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Vadné části modulu (device ALIVE Code != 0 / timeout). Reaktivita řídí
    // Consumer<AppState> ve stromu výš (_handleDeviceAlive volá notifyListeners).
    final faultParts = context.read<AppState>().faultyPartsForModule(unitId, module);
    return PopupMenuButton<String>(
      tooltip: faultParts.isEmpty
          ? module.displayLabel
          : '${module.displayLabel}\n⚠ Nekomunikuje: '
              '${faultParts.map(module.partLabel).join(", ")}',
      offset: const Offset(0, 32),
      onSelected: (v) {
        if (v == 'replace') onReplace?.call();
        if (v == 'set_id') onSetId?.call();
        if (v == 'edit') onEdit?.call();
        if (v == 'delete') onDelete();
        if (v == 'test_disp') onTestDisplay?.call();
        if (v == 'show_addr') onShowAddress?.call();
        if (v == 'clear_disp') onClearDisplay?.call();
        if (v == 'leds_on') onLedsOn?.call();
        if (v == 'leds_off') onLedsOff?.call();
        if (v == 'measure') onMeasure?.call();
        if (v == 'rescan') onRescan?.call();
        if (v == 'alive') onAlive?.call();
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          enabled: false,
          child: Text(
            module.displayLabel,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
          ),
        ),
        const PopupMenuDivider(),
        if (onAlive != null)
          const PopupMenuItem(
            value: 'alive',
            child: Row(
              children: [
                Icon(Icons.monitor_heart, size: 18, color: Colors.pink),
                SizedBox(width: 8),
                Text('Alive'),
              ],
            ),
          ),
        if (onRescan != null)
          const PopupMenuItem(
            value: 'rescan',
            child: Row(
              children: [
                Icon(Icons.radar, size: 18, color: Colors.teal),
                SizedBox(width: 8),
                Text('Rescan'),
              ],
            ),
          ),
        if (onMeasure != null)
          const PopupMenuItem(
            value: 'measure',
            child: Row(
              children: [
                Icon(Icons.straighten, size: 18, color: Colors.teal),
                SizedBox(width: 8),
                Text('Změřit teď'),
              ],
            ),
          ),
        if (onTestDisplay != null)
          const PopupMenuItem(
            value: 'test_disp',
            child: Row(
              children: [
                Icon(Icons.text_fields, size: 18, color: Colors.blue),
                SizedBox(width: 8),
                Text('Test displeje (AHOJ)'),
              ],
            ),
          ),
        if (onShowAddress != null)
          PopupMenuItem(
            value: 'show_addr',
            child: Row(
              children: [
                const Icon(Icons.pin, size: 18, color: Colors.blue),
                const SizedBox(width: 8),
                Text('Adresa na displej (${module.baseAddress.toString().padLeft(4, '0')})'),
              ],
            ),
          ),
        if (onClearDisplay != null)
          const PopupMenuItem(
            value: 'clear_disp',
            child: Row(
              children: [
                Icon(Icons.format_clear, size: 18),
                SizedBox(width: 8),
                Text('Smazat text'),
              ],
            ),
          ),
        if (onLedsOn != null)
          const PopupMenuItem(
            value: 'leds_on',
            child: Row(
              children: [
                Icon(Icons.lightbulb, size: 18, color: Colors.amber),
                SizedBox(width: 8),
                Text('Rozsvítit LED'),
              ],
            ),
          ),
        if (onLedsOff != null)
          const PopupMenuItem(
            value: 'leds_off',
            child: Row(
              children: [
                Icon(Icons.lightbulb_outline, size: 18),
                SizedBox(width: 8),
                Text('Zhasnout LED'),
              ],
            ),
          ),
        if (onEdit != null)
          const PopupMenuItem(
            value: 'edit',
            child: Row(
              children: [
                Icon(Icons.edit, size: 18, color: Colors.blue),
                SizedBox(width: 8),
                Text('Upravit'),
              ],
            ),
          ),
        if (onReplace != null)
          const PopupMenuItem(
            value: 'replace',
            child: Row(
              children: [Icon(Icons.swap_horiz, size: 18), SizedBox(width: 8), Text('Vyměnit')],
            ),
          ),
        if (onSetId != null)
          const PopupMenuItem(
            value: 'set_id',
            child: Row(
              children: [
                Icon(Icons.tag, size: 18),
                SizedBox(width: 8),
                Text('Přečíslovat'),
              ],
            ),
          ),
        const PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline, size: 18, color: Colors.red),
              SizedBox(width: 8),
              Text('Smazat', style: TextStyle(color: Colors.red)),
            ],
          ),
        ),
      ],
      child: Builder(
        builder: (_) {
          final effColor = _effectiveColor();
          final showLed =
              (module.type == ModuleType.pumA || module.type == ModuleType.pumB) && module.hasLeds;
          final leftFlash = _pressColor(left: true);
          final rightFlash = _pressColor(left: false);
          final chip = Chip(
            label: module.type == ModuleType.dist
                // DIST: adresa nahoře, živá naměřená vzdálenost pod ní (menší).
                // Pevná šířka celého obsahu (max 4 cifry, „4000") + tabulkové
                // číslice → všechny senzorové chipy mají stejnou šířku bez ohledu
                // na počet cifer adresy i hodnoty.
                ? SizedBox(
                    width: 34,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          module.baseAddress.toString(),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: effColor,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        Selector<AppState, int?>(
                          selector: (_, s) => s.distanceFor(unitId, module.baseAddress),
                          builder: (_, dist, _) => Text(
                            dist == null ? '—' : '$dist',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 10,
                              height: 1.0,
                              color: effColor.withAlpha(200),
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        module.baseAddress.toString(),
                        style: TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600, color: effColor),
                      ),
                      if (showLed) ...[
                        const SizedBox(width: 4),
                        Icon(Icons.lightbulb, size: 14, color: Colors.amber.shade700),
                      ],
                      if (faultParts.isNotEmpty) ...[
                        const SizedBox(width: 4),
                        const Icon(Icons.warning_amber_rounded,
                            size: 13, color: Colors.red),
                        Text(
                          '${faultParts.length}',
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: Colors.red,
                          ),
                        ),
                      ],
                    ],
                  ),
            backgroundColor: effColor.withAlpha(30),
            side: alert
                ? const BorderSide(color: Colors.red, width: 2)
                : BorderSide(color: effColor.withAlpha(110)),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          );

          // BTN press flash: levý a pravý okraj zazáří 1s, když přijde D/.../BTN/.../UPDATE.
          // Selector vrací jen relevantní timestampy — chip se rebuildne jen při novém stisku.
          return Selector<AppState,
              ({({DateTime ts, int number})? left, ({DateTime ts, int number})? right})>(
            selector: (_, s) => (
              left: s.lastButtonPress(unitId, module.baseAddress, left: true),
              right: s.lastButtonPress(unitId, module.baseAddress, left: false),
            ),
            builder: (_, presses, child) {
              return Stack(
                children: [
                  child!,
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Row(
                        children: [
                          _PressFlash(press: presses.left, color: leftFlash),
                          const Spacer(),
                          _PressFlash(press: presses.right, color: rightFlash),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
            child: chip,
          );
        },
      ),
    );
  }
}

/// Šedý „ghost" chip — device nalezený skenem sběrnice, ale neuložený
/// v konfiguraci jednotky. Klepnutím se otevře dialog Přidat (předvyplní adresu).
class _GhostChip extends StatelessWidget {
  final int address;
  final String? busType;
  final VoidCallback onAdd;

  const _GhostChip({
    required this.address,
    required this.busType,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '${busType ?? "?"} @$address — na sběrnici, neuloženo.\nKlepni pro přidání.',
      child: ActionChip(
        onPressed: onAdd,
        avatar: const Icon(Icons.add, size: 14, color: Colors.grey),
        label: Text(
          address.toString(),
          style: const TextStyle(
              fontSize: 12, fontWeight: FontWeight.w600, color: Colors.grey),
        ),
        backgroundColor: Colors.grey.withAlpha(20),
        side: BorderSide(color: Colors.grey.withAlpha(130)),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

/// Animovaný proužek na hraně chipu — naběhne na 1.0 a vyhasne za 1s.
/// Klíčuje TweenAnimationBuilder timestampem, aby se animace restartovala
/// při novém stisku.
class _PressFlash extends StatelessWidget {
  final ({DateTime ts, int number})? press;
  final Color color;
  const _PressFlash({required this.press, required this.color});

  static const double _width = 15;

  @override
  Widget build(BuildContext context) {
    final p = press;
    if (p == null) return const SizedBox(width: _width);
    final age = DateTime.now().difference(p.ts);
    if (age >= const Duration(seconds: 1)) {
      return const SizedBox(width: _width);
    }
    return TweenAnimationBuilder<double>(
      key: ValueKey(p.ts.microsecondsSinceEpoch),
      tween: Tween(begin: 1.0, end: 0.0),
      duration: const Duration(seconds: 1),
      curve: Curves.easeOut,
      builder: (_, value, _) => Container(
        width: _width,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: value),
          borderRadius: BorderRadius.circular(3),
          boxShadow: value > 0.05
              ? [
                  BoxShadow(
                    color: color.withValues(alpha: value * 0.8),
                    blurRadius: 6,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        // Číslo stisknutého tlačítka (0–3) v zazářené hraně.
        child: Text(
          '${p.number}',
          style: TextStyle(
            fontSize: 10,
            height: 1.0,
            fontWeight: FontWeight.bold,
            color: Colors.white.withValues(alpha: value),
          ),
        ),
      ),
    );
  }
}

class _EmptyModules extends StatelessWidget {
  final bool pending;
  const _EmptyModules({required this.pending});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            pending ? Icons.hourglass_top : Icons.devices_other,
            size: 56,
            color: Colors.grey[400],
          ),
          const SizedBox(height: 12),
          Text(
            pending
                ? 'Načítám devices…'
                : 'P2L modul nemá žádné registrované devices.\nPřidej první device tlačítkem dole.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }
}

/// Souhrnný proužek diagnostiky skenu sběrnice (SCAN-DEVICES). Počty OK /
/// chybí / nezaregistr.; detail (červené a šedé chipy) je inline v seznamu
/// devices níže.
class _BusScanPanel extends StatelessWidget {
  final BusScanResult scan;
  final List<PumaModule> modules;
  final VoidCallback onClose;

  const _BusScanPanel({
    required this.scan,
    required this.modules,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final rows = diagnoseBus(modules, scan);
    final okCount = rows.where((r) => r.status == BusScanStatus.ok).length;
    final missing =
        rows.where((r) => r.status == BusScanStatus.missing).length;
    final extra =
        rows.where((r) => r.status == BusScanStatus.unregistered).length;

    return Card(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        child: Row(
          children: [
            const Icon(Icons.radar, size: 18),
            const SizedBox(width: 8),
            Text(
                '${scan.scanId != null ? 'ID ${scan.scanId}' : _scopeLabel(scan.scope)} · ${scan.total} čipů',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(width: 16),
            Expanded(
              child: Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  _summaryChip(Icons.check_circle, Colors.green, '$okCount OK'),
                  if (missing > 0)
                    _summaryChip(
                        Icons.error_outline, Colors.red, '$missing chybí'),
                  if (extra > 0)
                    _summaryChip(Icons.warning_amber, Colors.grey,
                        '$extra neuloženo'),
                  if (rows.isEmpty)
                    Text('nic nenalezeno',
                        style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              tooltip: 'Zavřít diagnostiku',
              visualDensity: VisualDensity.compact,
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }

  String _scopeLabel(BusScanScope scope) => switch (scope) {
        BusScanScope.all => 'Vše',
        BusScanScope.pum => 'PUM-X',
        BusScanScope.dist => 'SENZORY',
      };

  Widget _summaryChip(IconData icon, Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 12, color: color)),
      ],
    );
  }
}

/// Dialog na zadání jedné RS485 adresy pro sken (`SCAN-DEVICES {"Id":N}`).
/// Vrací zadanou adresu přes `Navigator.pop`, nebo `null` při zrušení.
/// Vlastní StatefulWidget (ne inline StatefulBuilder), aby controller žil
/// po dobu života dialogu a uvolnil se až v dispose() — jinak by se
/// dispose-ul ještě během zavírací animace a TextField by spadl.
class _ScanIdDialog extends StatefulWidget {
  const _ScanIdDialog();

  @override
  State<_ScanIdDialog> createState() => _ScanIdDialogState();
}

class _ScanIdDialogState extends State<_ScanIdDialog> {
  final _controller = TextEditingController();
  String? _errorText;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final v = int.tryParse(_controller.text.trim());
    if (v == null || v < 1 || v > 247) {
      setState(() => _errorText = 'Zadej adresu 1–247');
      return;
    }
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Skenovat adresu'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: 'RS485 adresa',
          hintText: '1–247 (DIST 1–127, PUM 128–247)',
          errorText: _errorText,
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Zrušit'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Skenovat'),
        ),
      ],
    );
  }
}
