import '../models/device.dart';
import '../models/module.dart';

/// Rekonstrukce fyzických PUMA modulů z atomického seznamu Device (GET-DEVICES payload).
/// Algoritmus viz POSTUP.MD sekce "Rekonstrukce fyzických modulů z GET-DEVICES".
List<PumaModule> reconstructModules(List<Device> rawDevices) {
  final dispIds = rawDevices.where((d) => d.type == DeviceType.disp).map((d) => d.id).toSet();
  final ledsIds = rawDevices.where((d) => d.type == DeviceType.leds).map((d) => d.id).toSet();
  final btnIds = rawDevices.where((d) => d.type == DeviceType.btn).map((d) => d.id).toSet();
  final distIds = rawDevices.where((d) => d.type == DeviceType.dist).map((d) => d.id).toSet();

  final claimedBtn = <int>{};
  final modules = <PumaModule>[];

  // 1. PUM-A za každý DISP
  // PUM-A tlačítka vždy s prefixem: 1000+N=levé, 2000+N=pravé. 1 tlačítko PUM-A je vždy levé.
  final sortedDisps = dispIds.toList()..sort();
  for (final n in sortedDisps) {
    int buttonCount = 0;
    final hasLeft = btnIds.contains(1000 + n);
    final hasRight = btnIds.contains(2000 + n);

    if (hasLeft && hasRight) {
      buttonCount = 2;
      claimedBtn.add(1000 + n);
      claimedBtn.add(2000 + n);
    } else if (hasLeft) {
      buttonCount = 1;
      claimedBtn.add(1000 + n);
    }

    modules.add(PumaModule.pumA(
      address: n,
      buttonCount: buttonCount,
      hasLeds: ledsIds.contains(n),
    ));
  }

  // 2. PUM-C: dvojice (BTN 1000+M, BTN M) bez DISP M
  final remainingForPumC = btnIds.difference(claimedBtn).toList()..sort();
  for (final id in remainingForPumC) {
    if (claimedBtn.contains(id)) continue;
    if (id > 1000 && id < 2000) {
      final m = id - 1000;
      if (btnIds.contains(m) && !dispIds.contains(m) && !claimedBtn.contains(m)) {
        modules.add(PumaModule.pumC(address: m));
        claimedBtn.add(id);
        claimedBtn.add(m);
      }
    }
  }

  // 3. Zbylé osamocené BTN → PUM-B
  final remainingPumB = btnIds.difference(claimedBtn).toList()..sort();
  for (final id in remainingPumB) {
    modules.add(PumaModule.pumB(address: id));
  }

  // 4. DIST
  final sortedDists = distIds.toList()..sort();
  for (final id in sortedDists) {
    modules.add(PumaModule.dist(address: id));
  }

  modules.sort((a, b) {
    final c = a.baseAddress.compareTo(b.baseAddress);
    if (c != 0) return c;
    return a.type.index.compareTo(b.type.index);
  });

  return modules;
}

/// Parsování surového JSON payloadu z GET-DEVICES odpovědi.
/// Formát: `[{"Type":"DIST","Id":[[98,40,10,0,20,4,1,[...]]]}, {"Type":"DISP","Id":[128]}, ...]`
/// Nebo zjednodušená verze: `[{"Type":"DIST","Id":[98]}, ...]`
List<Device> parseGetDevicesPayload(dynamic payload) {
  final result = <Device>[];
  if (payload is! List) return result;

  for (final entry in payload) {
    if (entry is! Map) continue;
    final typeStr = entry['Type'] as String?;
    final ids = entry['Id'];
    if (typeStr == null || ids is! List) continue;

    final type = deviceTypeFromCode(typeStr);
    if (type == null) continue;

    for (final rawId in ids) {
      if (rawId is int) {
        result.add(Device(type: type, id: rawId));
      } else if (rawId is List && rawId.isNotEmpty && rawId[0] is int) {
        // DIST s configem: [id, period, timeout, offset, maxDev, count, type, [segments...]]
        result.add(Device(type: type, id: rawId[0] as int));
      }
    }
  }

  return result;
}

/// Extrahuje DIST config z GET-DEVICES payloadu (vnořené pole).
Map<int, DistConfig> parseDistConfigs(dynamic payload) {
  final result = <int, DistConfig>{};
  if (payload is! List) return result;

  for (final entry in payload) {
    if (entry is! Map) continue;
    if (entry['Type'] != 'DIST') continue;
    final ids = entry['Id'];
    if (ids is! List) continue;

    for (final rawId in ids) {
      if (rawId is List && rawId.length >= 7) {
        try {
          result[rawId[0] as int] = DistConfig(
            measurePeriod: rawId[1] as int,
            timeout: rawId[2] as int,
            offset: rawId[3] as int,
            maxDeviation: rawId[4] as int,
            countMeasures: rawId[5] as int,
            measureType: rawId[6] as int,
          );
        } catch (_) {
          // ignore malformed entries
        }
      }
    }
  }

  return result;
}
