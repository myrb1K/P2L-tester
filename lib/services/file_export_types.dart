/// Výsledek uložení/stažení textového souboru ([saveTextFile]).
class SaveResult {
  /// Uživatel akci zrušil (zavřel souborový dialog).
  final bool cancelled;

  /// Cesta uloženého souboru na nativní platformě. `null` na webu — soubor se
  /// stáhl přes prohlížeč do složky Stažené (web nemá nativní „Uložit jako").
  final String? path;

  const SaveResult.cancelled()
      : cancelled = true,
        path = null;
  const SaveResult.saved([this.path]) : cancelled = false;
}
