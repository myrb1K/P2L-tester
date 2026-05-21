# 04 — Responzivita UX

> **Status:** Draft v0.3 — M3 ✅ dokončeno · **Datum:** 2026-05-22 · **Parent:** [01-PRD.md](01-PRD.md)
>
> **Update v0.3 (M3 hotový):**
> - Smoke test v Chrome DevTools device emulation: **Pixel 7 (412×915) ✓** a **iPad Mini (768×1024) ✓** — žádné overflow warningy, layout pluje, tap targety OK.
> - **iPhone SE (375×667)**: LED port bar v `HomeScreen` přetékal o ~12px (`RIGHT_OVERFLOWED BY 12 PIXELS`). Rozhodnuto **neopravovat** — 375px je dnes okrajový viewport, který Smartbox interní uživatelé reálně nemají.
> - Layout je tedy **funkční na všech relevantních viewportech bez úprav kódu**. APK responzivita se přenesla 1:1 na Flutter Web.
>
> **Update v0.2:** Stávající Android APK funguje na mobilu skvěle a Windows EXE při zmenšení okna na mobilní šířku také vypadá OK. Layout je **už responzivní**. Scope této fáze se proto mění z "postavit responzivní layout" na **"ověřit, že existující responzivní chování funguje i v browseru"**. Sekce §4 (Místa k úpravě) je ponechána jako *kontrolní seznam* — žádná z položek pravděpodobně nebude vyžadovat refactor, jen smoke test.

Cíl: aplikace musí být použitelná jak na desktop prohlížeči (1024–1920+ px), tak na mobilním prohlížeči (360–600 px). **Layout už tuto vlastnost má z Android/Windows verze — primárně ověřujeme.**

---

## 1. Breakpointy

| Šířka | Kategorie | Layout |
|-------|-----------|--------|
| < 600 px | mobil | Jeden sloupec, AppBar s hamburger menu, dialogy fullscreen |
| 600–1024 px | tablet / malý desktop | Jeden hlavní sloupec + plovoucí panely, dialogy menší |
| > 1024 px | desktop | Stávající layout zachován |

Flutter konstanty (`LayoutBuilder` / `MediaQuery.sizeOf(context).width`):
```dart
const double kMobileMax = 600;
const double kTabletMax = 1024;
```

---

## 2. Touch / tap target požadavky

- **Minimum tap target: 44×44 px** (Apple HIG, Material Design doporučuje 48×48 dp).
- Současné 28×28 LED port boxy v `HomeScreen` na mobilu **nesplňují** — viz §4.
- IconButton mají defaultně 48×48 hitbox i pokud ikona je menší → většinou OK.

---

## 3. Globální úpravy

### `MaterialApp`

Žádné `useMaterial3: true` změny netřeba (už je M3). Zvážit `themeMode` switch (light/dark) — out-of-scope MVP.

### AppBar na mobilu

Stávající ikony v AppBar `HomeScreen` (broker selector, BulkConfigMenu, settings) by se na 360 px **nemusely vejít**. Řešení:
- Pod 600 px přepnout na hamburger menu (Drawer) s těmito položkami.
- Nad 600 px nechat AppBar ikony jak jsou.

### Dialogy

Flutter dialogy se na mobilu zobrazují fullscreen, pokud použijeme `showDialog` s `useRootNavigator: true` a sami nastavíme `Dialog.fullscreen()` pod 600 px.

---

## 4. Místa v UI — kontrolní seznam (verify only)

> **Pozn. v0.2:** Tato sekce byla původně "Místa k úpravě". Po zjištění, že APK i zmenšené EXE okno fungují, je seznam přeznačený jako **kontrolní seznam pro web smoke test**. Pokud něco z toho v browseru zlobí, **pak** zvážit refactor — ne dřív.

### Místa v UI, která ověřit v Chrome DevTools device emulation

### 4.1 `HomeScreen` — LED ovládací lišta

**Současný stav:** řada port boxů 28×28 px s color picker, on/off duration, "Ověřit" button.

**Problém na mobilu:**
- 28×28 boxy jsou pod 44 px tap target.
- Lišta vodorovně přetéká.

**Řešení:**
- **A (preferováno):** přesunout LED ovládání do **bottom sheet** (otevírá se tlačítkem v AppBar nebo FAB). Bottom sheet má víc místa, port boxy můžou být 44×44.
- **B:** ponechat inline, ale na mobilu 2 řádky portů × větší boxy.

### 4.2 `HomeScreen` — seznam jednotek (`_UnitCard`)

**Současný stav:** karta s ID, statusem, 3 ikonami (Seznam zařízení / Info / Obnovit) v řádku.

**Mobil:** karty fungují, 3 IconButtony 48×48 jsou OK. Možná zvětšit padding mezi nimi. **Wave animace funguje plynule.**

→ Pravděpodobně stačí drobné padding úpravy.

### 4.3 `HomeScreen` — manuální vstup ID (`_ManualIdInput`)

**Současný stav:** text field + tlačítko "Ověřit" + import/export ikony.

**Mobil:** pravděpodobně OK, ale ověřit šířku — možná stack vertikálně pod 400 px.

### 4.4 `SettingsScreen` — profily brokerů

**Současný stav:** `ReorderableListView` s drag handle.

**Mobil:** drag handle funguje touch-friendly. OK.

### 4.5 `UnitDetailScreen`

**Současný stav:** grid s info kartami (IP, MAC, firmware, baterie, ID...) + seznam modulů.

**Problém na mobilu:**
- Grid 2 sloupců pod 400 px vypadá těsně.
- Tabulka modulů s několika sloupci přetéká.

**Řešení:**
- Grid info karet: pod 600 px → 1 sloupec.
- Tabulka modulů: pod 600 px → list of cards místo tabulky.

### 4.6 `TemplateEditorScreen`

**Současný stav:** formuláře s řadami `TextField`, dropdowny, checkboxy.

**Mobil:** vertikální stack OK, ale dlouhé formuláře vyžadují víc scrollování. Akceptovatelné.

### 4.7 `BulkConfigMenu` dialogy

**Současný stav:** `AlertDialog` s formuláři pro broker / WiFi / firmware update.

**Problém:** fixed šířky se na mobilu zužují.

**Řešení:** pod 600 px → `Dialog.fullscreen()` místo `AlertDialog`.

### 4.8 `BulkConfigMenu` PopupMenu

PopupMenu funguje touch OK, jen ověřit že položky mají dost paddingu (Material default je dostatečný).

---

## 5. Layout helpers (pouze pokud bude potřeba)

> **Pozn. v0.2:** Pravděpodobně nebudeme potřebovat, protože stávající layout v APK funguje. Necháno jako reference, kdyby web smoke test odhalil edge case.

Doporučený přístup — malá utility:

```dart
// lib/utils/responsive.dart
enum ScreenSize { mobile, tablet, desktop }

extension ResponsiveContext on BuildContext {
  ScreenSize get screenSize {
    final w = MediaQuery.sizeOf(this).width;
    if (w < 600) return ScreenSize.mobile;
    if (w < 1024) return ScreenSize.tablet;
    return ScreenSize.desktop;
  }

  bool get isMobile => screenSize == ScreenSize.mobile;
}
```

---

## 6. Browser-specific edge cases (web ≠ APK)

Tohle jsou jediná místa, kde web reálně může vyžadovat úpravu (APK chování se nepřenese 1:1):

| Edge case | Co může zlobit | Mitigation |
|-----------|----------------|------------|
| Mobilní browser klávesnice | `viewInsets` má delay vs. nativní; někdy překryje TextField | Wrap login screen + ID input do `SingleChildScrollView`, `resizeToAvoidBottomInset: true` |
| Touch vs. mouse hover | Material widgety s hover state na touch ne vždy fungují | Většinou OK z native verze, otestovat tooltipy |
| Browser back button | `Navigator.push` bez ochrany → user vyskočí ze stránky | Pro MVP akceptovatelné, případně přidat `PopScope` na klíčové obrazovky |
| iOS Safari quirks | Rounded scrollbars, momentum scroll | Otestovat pokud bude appka chodit na iPhonu |
| Browser zoom (Ctrl+`+`) | Layout se může rozsypat | Akceptovatelné, není user expected scenario |

---

## 7. Test plán pro M4 (zkráceno na ~0.5 dne)

| Test | Šířka | Co ověřit |
|------|-------|-----------|
| Mobil portrét | 360 × 800 | Žádný horizontální scroll, tap targety ≥ 44 px, čitelné fonty |
| Mobil landscape | 800 × 360 | AppBar nevypadá natěsnaně |
| Tablet portrét | 768 × 1024 | Layout přechod plynulý |
| Desktop | 1920 × 1080 | Beze změny oproti stávajícímu |
| Chrome DevTools device emulation | iPhone SE, iPhone 14 Pro, Pixel 7, iPad | Vše pluje |

---

## 8. Risks

| Risk | Mitigation |
|------|------------|
| Refactor stávajícího layoutu na responzivní rozbije Windows/Android | Použít `LayoutBuilder` a podmíněné větve, native zůstane v `desktop` větvi |
| Bottom sheet pro LED ovládání zhorší UX na desktopu | Nepřesouvat na desktopu, podmíněně podle screenSize |
| Mobilní browser klávesnice překryje TextField | Wrap obrazovek do `SingleChildScrollView` + `resizeToAvoidBottomInset: true` |

---

## 9. Akceptační kritéria (v0.2)

- [ ] Žádný horizontální scroll na 360 px šířce v Chrome DevTools mobile emulation.
- [ ] LED ovládání, BulkConfig dialogy a TemplateEditor jsou použitelné na 360 px (klikatelné, čitelné).
- [ ] Mobilní browser klávesnice nepřekryje aktivní TextField (hlavně login + manuální ID input).
- [ ] Desktop layout (> 1024 px) je vizuálně beze změny oproti pre-WEB main.
- [ ] Tap-mimo skrytí klávesnice funguje stejně jako v APK.

**Pokud něco z výše uvedeného selže → fix; jinak responzivita je hotová.**
