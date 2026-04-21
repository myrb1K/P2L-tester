# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**P2L Tester** is a Flutter application for testing P2L hardware modules via MQTT communication. The app connects to a broker to control LED modules and perform diagnostics on physical units. Version is tracked in `main.dart` as `appVersion = '2.X'`.

## Architecture

### State Management
- **Provider pattern** with `ChangeNotifier` for reactive state
- Main state holder: `AppState` (`providers/app_state.dart`)
- Profiles stored in `SharedPreferences` (broker settings, LED patterns, device templates)

### Core Services
- **MqttService** (`services/mqtt_service.dart`): Wraps mqtt_client, manages connection state, publishes/subscribes to topics
- **CommandService** (`services/command_service.dart`): Builds command payloads for old/new units (JSON and BIN formats)
- **ModuleReconstruction** (`services/module_reconstruction.dart`): Reconstructs PUMA module config from hardware responses

### Data Models
- **P2LUnit** (`models/unit.dart`): Represents a P2L hardware unit
- **PumaModule** (`models/module.dart`): Physical module types (PUM-A, PUM-B, PUM-C, DIST) with config
- **DeviceTemplate** (`models/device_template.dart`): Named hardware configs for quick reuse
- **BrokerProfile** (`models/broker_profile.dart`): Named broker connection presets

### UI Structure
- **HomeScreen**: Main list of units with test controls and live status. AppBar contains `BulkConfigMenu` (ikona `Icons.settings_remote`) pro hromadnou změnu brokera/WiFi na vybraných jednotkách.
- **SettingsScreen**: Broker profiles (s přetahováním pořadí přes `ReorderableListView`), LED pattern config, device templates
- **UnitDetailScreen**: In-depth unit info (IP, MAC, firmware, module details)
- **TemplateEditorScreen**: Create/edit device template configurations
- **BulkConfigMenu** (`widgets/bulk_config_menu.dart`): PopupMenu v AppBar → dialogy pro hromadný `set_Mqtt` / `set_WiFi` na vybrané jednotky s 100ms pauzou mezi publishi. Dialog brokera umí buď vybrat uložený profil (bez aktuálního) nebo zadat nový, který se zároveň uloží.

### MQTT Protocol
Topics and message formats documented in `MQTT-TOPICS.md` and `README-P2L.md`. Key points:
- Subscribe to `D/+/UNIT/+/ALIVE` for automatic unit discovery
- Subscribe to `A/SERVER/+/CMD` for unit detail responses
- Publish test commands to `I/<unit_id>/P2L/<device_id>/CMD` (new units) or `I/u<4digit>/SERVER/CMD` (old units)
- Unit responses on topics with prefixes: D (discovery), A (async replies), L (logs)

---

## Common Development Tasks

### Build and Run
```bash
cd p2l_tester
flutter pub get           # Install dependencies
flutter run -d windows    # Run on Windows
flutter run -d <device>   # Run on connected device or emulator
```

### Analyze and Format
```bash
cd p2l_tester
flutter analyze                    # Lint check (configured in analysis_options.yaml)
dart format lib/                   # Auto-format Dart files
dart fix --apply                   # Apply suggested fixes
```

### Testing
```bash
cd p2l_tester
flutter test                       # Run all tests
flutter test test/widget_test.dart # Run specific test file
flutter test --coverage            # Generate coverage report
```

### Build Distributions
```bash
cd p2l_tester
flutter build windows --release    # Windows exe
flutter build apk --release        # Android APK
flutter build ipa --release        # iOS app
```

---

## Key Implementation Details

### LED Test Pattern
- Controlled via `ledsOn` (duration on), `ledsOff` (duration off), `ledColor` (0-5 for different colors)
- Pattern applies to all selected ports: `selectedPorts` (Set<int>)
- Saved to SharedPreferences for persistence

### Unit Discovery
- Units are discovered automatically when they broadcast ALIVE messages to `D/+/UNIT/+/ALIVE`
- Payload contains HWModel, firmware version, battery level
- Unit ID normalized: leading 'u' prefix is optional in code, always stored without it

### Device Templates
- Pre-configured module layouts (PUMA layout) for different hardware variants
- Stored as JSON in SharedPreferences under `device_templates` key
- Used to populate unit configuration dialogs without manual setup

### Command Formats
- **Old units** (ID < 1000): JSON only, topic `I/u{4digit}/SERVER/CMD`
- **New units** (ID ≥ 1000): Both JSON and BIN formats supported, topic `I/{6digit}/P2L/{device_id}/CMD`
- Binary format handled by CommandService for firmware >= P2L_25092501NT
- See `command_service.dart` for full encoding logic
- **Config builders**: `buildSetMqttCommand` a `buildSetWifiCommand` generují JSON payloady pro hromadnou změnu brokera/WiFi (používané z `AppState.sendBulkBroker/sendBulkWifi`)

### Broker Profiles
- Uloženy v `SharedPreferences` pod klíčem `broker_profiles`, aktivní index pod `active_profile`.
- Duplicitní názvy nejsou povoleny — kontrolováno přes `AppState.isProfileNameTaken(name, {excludeIndex})` (case-insensitive, trim).
- `addProfile`, `addProfileWithoutActivating` a `updateProfile` vrací `Future<String?>` (`null` = OK, jinak chybová zpráva).
- `addProfileWithoutActivating` uloží profil, ale nepřepne aktivní připojení — používá se při hromadné změně brokera, kdy uživatel zadá nový broker pro vybrané moduly, ale aplikace má zůstat na aktuálním.
- `reorderProfiles(oldIndex, newIndex)` přesouvá profily a přepočítává `_activeProfileIndex` tak, aby dál ukazoval na stejný profil.

### Error Handling
- MQTT errors stored in `_lastError` and exposed via AppState
- Connection state tracked via `AppMqttState` enum (disconnected, connecting, connected, error)
- Status messages updated in `_statusMessage` for UI feedback

---

## Testing Notes

- **Unit tests** check command serialization (`command_service_devices_test.dart`, `module_reconstruction_test.dart`)
- **Widget tests** verify UI interactions
- Run tests after changes to command format or module parsing logic

---

## Version and Recent Changes

Current version: **2.23** (see `main.dart`)  
Recent themes: bulk broker/WiFi change (`BulkConfigMenu`), reorderable broker profiles, duplicate-name guard, tučné názvy profilů, tlačítko Kopírovat v info dialogu jednotky.  
Always increment `appVersion` in `main.dart` when shipping user-facing changes.
