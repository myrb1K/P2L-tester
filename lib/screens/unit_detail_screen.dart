import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/module.dart';
import '../models/unit.dart';
import '../providers/app_state.dart';
import '../widgets/add_module_dialog.dart';
import '../widgets/apply_template_sheet.dart';
import '../widgets/replace_device_dialog.dart';

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
    final suggested = existing.isEmpty
        ? null
        : (existing.reduce((a, b) => a > b ? a : b) + 1);
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
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Limit 100 čipů na jednotku dosažen.'),
        ));
        return;
      }
      await state.addModules(widget.unitId, [result.module],
          restartAfter: result.restartAfter);
    }
  }

  Future<void> _editModule(AppState state, PumaModule module) async {
    final existing = (state.modulesForUnit(widget.unitId) ?? const [])
        .map((m) => m.baseAddress)
        .toSet();
    final result = await showDialog<AddModuleResult>(
      context: context,
      builder: (_) => AddModuleDialog(
        existingAddresses: existing,
        initial: module,
      ),
    );
    if (result == null) return;
    if (result.module.type == ModuleType.dist &&
        result.module.distConfig != null) {
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
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Zrušit'),
          ),
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
      builder: (_) => ApplyTemplateSheet(preselectedUnitId: widget.unitId),
    );
  }

  Future<void> _wipeAll(AppState state) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Smazat všechny moduly?'),
        content: Text(
          'Z jednotky ${widget.unitId} se odstraní všechny moduly. Nelze vrátit.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Zrušit'),
          ),
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
        final unit = state.units[widget.unitId] ??
            P2LUnit(id: widget.unitId);
        final modules = state.modulesForUnit(widget.unitId) ?? const [];
        final pending = state.isModulesPending(widget.unitId);
        final fetchedAt = state.modulesFetchedAt(widget.unitId);

        return Scaffold(
          appBar: AppBar(
            title: Text('P2L modul ${unit.displayName}'),
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Načíst moduly',
                onPressed: () => state.fetchDevices(widget.unitId),
              ),
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: 'Přidat modul',
                onPressed: () => _addModule(state, modules),
              ),
              IconButton(
                icon: const Icon(Icons.dashboard_customize),
                tooltip: 'Aplikovat šablonu',
                onPressed: () => _applyTemplate(state),
              ),
              IconButton(
                icon: const Icon(Icons.delete_sweep, color: Colors.red),
                tooltip: 'Smazat všechny moduly',
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
      m.type == ModuleType.pumA || m.type == ModuleType.dist;
}

class _UnitInfoCard extends StatelessWidget {
  final P2LUnit unit;
  final List<PumaModule> modules;
  final DateTime? fetchedAt;

  const _UnitInfoCard({
    required this.unit,
    required this.modules,
    required this.fetchedAt,
  });

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
                    unit.id,
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
                            if (unit.battery != null) 'Bat: ${unit.battery}%',
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
  final List<PumaModule> modules;
  final void Function(PumaModule) onReplace;
  final void Function(PumaModule) onEdit;
  final void Function(PumaModule) onDelete;
  final void Function(PumaModule) onTestDisplay;
  final void Function(PumaModule) onClearDisplay;
  final bool Function(PumaModule) canReplace;

  const _ModulesGroupedList({
    required this.modules,
    required this.onReplace,
    required this.onEdit,
    required this.onDelete,
    required this.onTestDisplay,
    required this.onClearDisplay,
    required this.canReplace,
  });

  static const _order = [
    ModuleType.pumA,
    ModuleType.pumB,
    ModuleType.pumC,
    ModuleType.dist,
  ];

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
              label: _label(type),
              color: _color(type),
              modules: byType[type]!,
              onReplace: onReplace,
              onEdit: type == ModuleType.dist ? onEdit : null,
              onDelete: onDelete,
              canReplace: canReplace,
              onTestDisplay: type == ModuleType.pumA ? onTestDisplay : null,
              onClearDisplay: type == ModuleType.pumA ? onClearDisplay : null,
            ),
      ],
    );
  }
}

class _GroupSection extends StatelessWidget {
  final String label;
  final Color color;
  final List<PumaModule> modules;
  final void Function(PumaModule) onReplace;
  final void Function(PumaModule) onDelete;
  final void Function(PumaModule)? onEdit;
  final void Function(PumaModule)? onTestDisplay;
  final void Function(PumaModule)? onClearDisplay;
  final bool Function(PumaModule) canReplace;

  const _GroupSection({
    required this.label,
    required this.color,
    required this.modules,
    required this.onReplace,
    required this.onDelete,
    required this.canReplace,
    this.onEdit,
    this.onTestDisplay,
    this.onClearDisplay,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$label  ·  ${modules.length}',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: color,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final m in modules)
                _AddressChip(
                  module: m,
                  color: color,
                  onReplace: canReplace(m) ? () => onReplace(m) : null,
                  onEdit: onEdit != null ? () => onEdit!(m) : null,
                  onDelete: () => onDelete(m),
                  onTestDisplay:
                      onTestDisplay != null ? () => onTestDisplay!(m) : null,
                  onClearDisplay:
                      onClearDisplay != null ? () => onClearDisplay!(m) : null,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AddressChip extends StatelessWidget {
  final PumaModule module;
  final Color color;
  final VoidCallback? onReplace;
  final VoidCallback? onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onTestDisplay;
  final VoidCallback? onClearDisplay;

  const _AddressChip({
    required this.module,
    required this.color,
    required this.onReplace,
    required this.onDelete,
    this.onEdit,
    this.onTestDisplay,
    this.onClearDisplay,
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
            child: Row(children: [
              Icon(Icons.text_fields, size: 18, color: Colors.blue),
              SizedBox(width: 8),
              Text('Test displeje (AHOJ)'),
            ]),
          ),
        if (onClearDisplay != null)
          const PopupMenuItem(
            value: 'clear_disp',
            child: Row(children: [
              Icon(Icons.format_clear, size: 18),
              SizedBox(width: 8),
              Text('Smazat text'),
            ]),
          ),
        if (onEdit != null)
          const PopupMenuItem(
            value: 'edit',
            child: Row(children: [
              Icon(Icons.edit, size: 18, color: Colors.blue),
              SizedBox(width: 8),
              Text('Upravit'),
            ]),
          ),
        if (onReplace != null)
          const PopupMenuItem(
            value: 'replace',
            child: Row(children: [
              Icon(Icons.swap_horiz, size: 18),
              SizedBox(width: 8),
              Text('Vyměnit'),
            ]),
          ),
        const PopupMenuItem(
          value: 'delete',
          child: Row(children: [
            Icon(Icons.delete_outline, size: 18, color: Colors.red),
            SizedBox(width: 8),
            Text('Smazat', style: TextStyle(color: Colors.red)),
          ]),
        ),
      ],
      child: Builder(builder: (_) {
        final effColor = _effectiveColor();
        return Chip(
          label: Text(
            module.baseAddress.toString(),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: effColor,
            ),
          ),
          backgroundColor: effColor.withAlpha(30),
          side: BorderSide(color: effColor.withAlpha(110)),
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        );
      }),
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
                : 'P2L modul nemá žádné registrované moduly.\nPřidej první modul tlačítkem dole.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }
}
