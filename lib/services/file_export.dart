// Entry point pro uložení/stažení textového souboru napříč platformami.
// Conditional export vybere implementaci podle dostupné knihovny:
//   dart:io (native)  → souborový dialog / SAF přes file_export_io.dart
//   dart:html (web)   → browser download přes file_export_web.dart
// Volající jen volá saveTextFile(...) a dostane SaveResult.
//
// Web nemá nativní „Uložit jako" dialog — prohlížeč soubor stáhne do složky
// Stažené (SaveResult.path == null). Nativně se vrátí cesta uloženého souboru.

export 'file_export_types.dart';
export 'file_export_stub.dart'
    if (dart.library.io) 'file_export_io.dart'
    if (dart.library.html) 'file_export_web.dart';
