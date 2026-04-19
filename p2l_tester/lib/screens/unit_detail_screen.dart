import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/module.dart';
import '../models/unit.dart';
import '../providers/app_state.dart';
import '../widgets/add_module_dialog.dart';
import '../widgets/apply_template_sheet.dart';
import '../widgets/module_tile.dart';
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
    final result = await showDialog<PumaModule>(
      context: context,
      builder: (_) => AddModuleDialog(
        existingAddresses: existing,
        hasPumAWithRoom: hasPumAWithButtonRoom(currentModules),
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
      await state.addModules(widget.unitId, [result]);
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
            title: Text('Jednotka ${unit.displayName}'),
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Načíst devices',
                onPressed: () => state.fetchDevices(widget.unitId),
              ),
              IconButton(
                icon: const Icon(Icons.dashboard_customize),
                tooltip: 'Aplikovat šablonu',
                onPressed: () => _applyTemplate(state),
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
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: modules.length,
                        itemBuilder: (context, i) {
                          final m = modules[i];
                          return ModuleTile(
                            module: m,
                            compact: true,
                            onReplace: _canReplace(m)
                                ? () => _replaceModule(state, m)
                                : null,
                            onDelete: () => _deleteModule(state, m),
                          );
                        },
                      ),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            icon: const Icon(Icons.add),
            label: const Text('Přidat modul'),
            onPressed: () => _addModule(state, modules),
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
    final chipCount = modules.length;
    final pct = chipCount / kMaxChipsPerUnit;
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
                Text(
                  unit.id,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const Spacer(),
                if (unit.firmware != null)
                  Text('FW: ${unit.firmware}', style: const TextStyle(fontSize: 11)),
              ],
            ),
            const SizedBox(height: 8),
            if (unit.ip != null || unit.mac != null)
              Text(
                [
                  if (unit.ip != null) 'IP: ${unit.ip}',
                  if (unit.mac != null) 'MAC: ${unit.mac}',
                  if (unit.battery != null) 'Bat: ${unit.battery}%',
                ].join(' · '),
                style: const TextStyle(fontSize: 11),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Čipů: $chipCount / $kMaxChipsPerUnit',
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: pct.clamp(0.0, 1.0),
                          minHeight: 6,
                          color: pct > 0.9 ? Colors.red : Colors.blue,
                          backgroundColor: Colors.grey.withAlpha(50),
                        ),
                      ),
                    ],
                  ),
                ),
                if (fetchedAt != null) ...[
                  const SizedBox(width: 12),
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
                : 'Jednotka nemá žádné registrované moduly.\nPřidej první modul tlačítkem dole.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }
}
