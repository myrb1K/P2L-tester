import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../main.dart' show appVersion;
import '../models/device_template.dart';
import '../models/module.dart';
import '../models/unit.dart';
import '../providers/app_state.dart';
import '../services/template_io.dart';
import '../widgets/add_module_dialog.dart';
import '../widgets/apply_template_sheet.dart';
import '../widgets/replace_device_dialog.dart';
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
    final suggested = existing.isEmpty ? null : (existing.reduce((a, b) => a > b ? a : b) + 1);
    final result = await showDialog<AddModuleResult>(
      context: context,
      builder: (_) => AddModuleDialog(
        existingAddresses: existing,
        hasPumAWithRoom: hasPumAWithButtonRoom(currentModules),
        suggestedAddress: suggested,
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
    final result = await showDialog<ReplaceResult>(
      context: context,
      builder: (_) => ReplaceDeviceDialog(module: module),
    );
    if (result != null) {
      await state.replaceDevice(
        unitId: widget.unitId,
        type: result.type,
        oldAddress: result.oldAddress,
        newDefaultAddress: result.newDefaultAddress,
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

    if (share) {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$fileName');
      await file.writeAsString(json);
      await Share.shareXFiles([XFile(file.path)], subject: fileName);
    } else {
      if (kIsWeb || Platform.isAndroid || Platform.isIOS) {
        await FilePicker.platform.saveFile(
          fileName: fileName,
          bytes: Uint8List.fromList(json.codeUnits),
        );
      } else {
        final outPath = await FilePicker.platform.saveFile(
          fileName: fileName,
          allowedExtensions: ['json'],
          type: FileType.custom,
        );
        if (outPath != null) await File(outPath).writeAsString(json);
      }
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

        return Scaffold(
          appBar: AppBar(
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Načíst devices',
                onPressed: () => state.fetchDevices(widget.unitId),
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
                  color: Colors.blue.withAlpha(25),
                  child: Text(
                    state.deviceActionStatus,
                    style: TextStyle(fontSize: 12, color: Colors.blue[800]),
                  ),
                ),
              if (pending) const LinearProgressIndicator(minHeight: 2),
              Expanded(
                child: modules.isEmpty
                    ? _EmptyModules(pending: pending)
                    : _ModulesGroupedList(
                        unitId: widget.unitId,
                        modules: modules,
                        onReplace: (m) => _replaceModule(state, m),
                        onEdit: (m) => _editModule(state, m),
                        onDelete: (m) => _deleteModule(state, m),
                        onTestDisplay: (m) => state.sendDispData(
                          unitId: widget.unitId,
                          dispAddress: m.baseAddress,
                          data: 'AHOJ',
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
                        canReplace: _canReplace,
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  bool _canReplace(PumaModule m) => m.type == ModuleType.pumA || m.type == ModuleType.dist;
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
  final void Function(PumaModule) onReplace;
  final void Function(PumaModule) onEdit;
  final void Function(PumaModule) onDelete;
  final void Function(PumaModule) onTestDisplay;
  final void Function(PumaModule) onClearDisplay;
  final void Function(PumaModule) onLedsOn;
  final void Function(PumaModule) onLedsOff;
  final bool Function(PumaModule) canReplace;

  const _ModulesGroupedList({
    required this.unitId,
    required this.modules,
    required this.onReplace,
    required this.onEdit,
    required this.onDelete,
    required this.onTestDisplay,
    required this.onClearDisplay,
    required this.onLedsOn,
    required this.onLedsOff,
    required this.canReplace,
  });

  static const _order = [ModuleType.pumA, ModuleType.pumB, ModuleType.pumC, ModuleType.dist];

  String _label(ModuleType t) => switch (t) {
    ModuleType.pumA => 'PUM-A',
    ModuleType.pumB => 'PUM-B',
    ModuleType.pumC => 'PUM-C',
    ModuleType.dist => 'SENZOR',
  };

  Color _color(ModuleType t) => switch (t) {
    ModuleType.pumA => Colors.blue,
    ModuleType.pumB => Colors.orange,
    ModuleType.pumC => Colors.purple,
    ModuleType.dist => Colors.teal,
  };

  @override
  Widget build(BuildContext context) {
    final byType = <ModuleType, List<PumaModule>>{};
    for (final m in modules) {
      byType.putIfAbsent(m.type, () => []).add(m);
    }
    for (final list in byType.values) {
      list.sort((a, b) => a.baseAddress.compareTo(b.baseAddress));
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      children: [
        for (final type in _order)
          if (byType[type]?.isNotEmpty ?? false)
            _GroupSection(
              unitId: unitId,
              label: _label(type),
              color: _color(type),
              modules: byType[type]!,
              onReplace: onReplace,
              onEdit: type == ModuleType.dist ? onEdit : null,
              onDelete: onDelete,
              canReplace: canReplace,
              onTestDisplay: type == ModuleType.pumA ? onTestDisplay : null,
              onClearDisplay: type == ModuleType.pumA ? onClearDisplay : null,
              onLedsOn: (type == ModuleType.pumA || type == ModuleType.pumB)
                  ? onLedsOn
                  : null,
              onLedsOff: (type == ModuleType.pumA || type == ModuleType.pumB)
                  ? onLedsOff
                  : null,
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
  final void Function(PumaModule) onReplace;
  final void Function(PumaModule) onDelete;
  final void Function(PumaModule)? onEdit;
  final void Function(PumaModule)? onTestDisplay;
  final void Function(PumaModule)? onClearDisplay;
  final void Function(PumaModule)? onLedsOn;
  final void Function(PumaModule)? onLedsOff;
  final bool Function(PumaModule) canReplace;

  const _GroupSection({
    required this.unitId,
    required this.label,
    required this.color,
    required this.modules,
    required this.onReplace,
    required this.onDelete,
    required this.canReplace,
    this.onEdit,
    this.onTestDisplay,
    this.onClearDisplay,
    this.onLedsOn,
    this.onLedsOff,
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
                '$label  ${modules.length}x',
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
                  tooltip: 'AHOJ na všechny displeje (broadcast)',
                  icon: const Icon(Icons.text_fields, color: Colors.blue),
                  onPressed: () => _bulkDisp(context, 'AHOJ'),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  iconSize: 18,
                  tooltip: 'Smazat text na všech displejích (broadcast)',
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
                  onReplace: canReplace(m) ? () => onReplace(m) : null,
                  onEdit: onEdit != null ? () => onEdit!(m) : null,
                  onDelete: () => onDelete(m),
                  onTestDisplay: onTestDisplay != null ? () => onTestDisplay!(m) : null,
                  onClearDisplay: onClearDisplay != null ? () => onClearDisplay!(m) : null,
                  onLedsOn: onLedsOn != null && m.hasLeds ? () => onLedsOn!(m) : null,
                  onLedsOff: onLedsOff != null && m.hasLeds ? () => onLedsOff!(m) : null,
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
    // DISP adresa 0 = broadcast na všechny displeje jednotky (1 MQTT zpráva).
    await context.read<AppState>().sendDispData(unitId: unitId, dispAddress: 0, data: text);
  }
}

class _AddressChip extends StatelessWidget {
  final String unitId;
  final PumaModule module;
  final Color color;
  final VoidCallback? onReplace;
  final VoidCallback? onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onTestDisplay;
  final VoidCallback? onClearDisplay;
  final VoidCallback? onLedsOn;
  final VoidCallback? onLedsOff;

  const _AddressChip({
    required this.unitId,
    required this.module,
    required this.color,
    required this.onReplace,
    required this.onDelete,
    this.onEdit,
    this.onTestDisplay,
    this.onClearDisplay,
    this.onLedsOn,
    this.onLedsOff,
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
    return PopupMenuButton<String>(
      tooltip: module.displayLabel,
      offset: const Offset(0, 32),
      onSelected: (v) {
        if (v == 'replace') onReplace?.call();
        if (v == 'edit') onEdit?.call();
        if (v == 'delete') onDelete();
        if (v == 'test_disp') onTestDisplay?.call();
        if (v == 'clear_disp') onClearDisplay?.call();
        if (v == 'leds_on') onLedsOn?.call();
        if (v == 'leds_off') onLedsOff?.call();
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
            label: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  module.baseAddress.toString(),
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: effColor),
                ),
                if (showLed) ...[
                  const SizedBox(width: 4),
                  Icon(Icons.lightbulb, size: 14, color: Colors.amber.shade700),
                ],
              ],
            ),
            backgroundColor: effColor.withAlpha(30),
            side: BorderSide(color: effColor.withAlpha(110)),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          );

          // BTN press flash: levý a pravý okraj zazáří 1s, když přijde D/.../BTN/.../UPDATE.
          // Selector vrací jen relevantní timestampy — chip se rebuildne jen při novém stisku.
          return Selector<AppState, ({DateTime? left, DateTime? right})>(
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
                          _PressFlash(timestamp: presses.left, color: leftFlash),
                          const Spacer(),
                          _PressFlash(timestamp: presses.right, color: rightFlash),
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

/// Animovaný proužek na hraně chipu — naběhne na 1.0 a vyhasne za 1s.
/// Klíčuje TweenAnimationBuilder timestampem, aby se animace restartovala
/// při novém stisku.
class _PressFlash extends StatelessWidget {
  final DateTime? timestamp;
  final Color color;
  const _PressFlash({required this.timestamp, required this.color});

  @override
  Widget build(BuildContext context) {
    if (timestamp == null) return const SizedBox(width: 13);
    final age = DateTime.now().difference(timestamp!);
    if (age >= const Duration(seconds: 1)) {
      return const SizedBox(width: 13);
    }
    return TweenAnimationBuilder<double>(
      key: ValueKey(timestamp!.microsecondsSinceEpoch),
      tween: Tween(begin: 1.0, end: 0.0),
      duration: const Duration(seconds: 1),
      curve: Curves.easeOut,
      builder: (_, value, _) => Container(
        width: 13,
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
