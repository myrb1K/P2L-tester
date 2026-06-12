import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import 'file_export_types.dart';

/// Nativní implementace.
/// - Android/iOS: `saveFile` se `bytes` (SAF) — uloží a vrátí cestu.
/// - Desktop (Windows/Linux/macOS): `saveFile` vrátí cestu, obsah zapíšeme sami.
Future<SaveResult> saveTextFile({
  required String fileName,
  required String content,
  String dialogTitle = 'Uložit soubor',
}) async {
  if (Platform.isAndroid || Platform.isIOS) {
    final path = await FilePicker.platform.saveFile(
      dialogTitle: dialogTitle,
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: const ['json'],
      bytes: Uint8List.fromList(utf8.encode(content)),
    );
    if (path == null) return const SaveResult.cancelled();
    return SaveResult.saved(path);
  }

  final path = await FilePicker.platform.saveFile(
    dialogTitle: dialogTitle,
    fileName: fileName,
    type: FileType.custom,
    allowedExtensions: const ['json'],
  );
  if (path == null) return const SaveResult.cancelled();
  final outPath = path.toLowerCase().endsWith('.json') ? path : '$path.json';
  await File(outPath).writeAsString(content);
  return SaveResult.saved(outPath);
}
