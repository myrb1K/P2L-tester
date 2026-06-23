# Nápověda — P2L Tester

Návod k ovládání aplikace pro testování a konfiguraci **P2L hardwarových modulů** přes MQTT. Tento dokument je zároveň zobrazen přímo v aplikaci (ikona **?** v horní liště).

Pojmy: **P2L modul / jednotka** = celá ESP32 jednotka na brokeru (má ID, např. `1209`). **Device / modul** = jeden fyzický čip na sběrnici jednotky (PUM-A, PUM-B, PUM-C, DIST).

---

## 1. Začínáme — připojení k brokeru

Aplikace nic neukáže, dokud není připojená k MQTT brokeru.

1. Klepni na ikonu **broker** (`☰`, tooltip *Vybrat broker*) vlevo nahoře.
2. Vyber uložený profil ze seznamu — aplikace se rovnou připojí.
3. Když žádný profil nemáš, klepni na **Přidat nový profil** (otevře **Nastavení**).

Stav připojení ukazuje ikona Wi-Fi v liště:

- **zelená** = připojeno,
- **oranžová** = připojuji,
- **červená / šedá** = odpojeno nebo chyba.

Dlouhým stiskem broker ikony (nebo klepnutím na ikonu Wi-Fi) se od brokeru **odpojíš**.

### Založení / úprava broker profilu (Nastavení)

V **Nastavení** (ozubené kolo) v sekci *Uložené profily*:

- **Nový profil** — tlačítko nahoře. Vyplň *Název*, *Broker adresa*, *Port*, volitelně *Username* / *Password*.
- **SSL/TLS** — zapni pro šifrované připojení (MQTTS).
- **WebSocket** — zapni, když se broker připojuje přes WS (povinné na webové verzi; pole *WebSocket path*, typicky `/mqtt`).
- **Uložit nový profil** / **Uložit a připojit**.
- Profily lze **přetahovat** (drag handle vpravo) pro změnu pořadí, upravit (tužka) nebo smazat (koš).

---

## 2. Seznam P2L modulů (hlavní obrazovka)

### Jak se jednotky objeví

- **Automaticky:** jakmile jednotka pošle ALIVE zprávu, naskočí do seznamu (modrá vlna animace při prvním objevení).
- **Ručně:** do pole **ID P2L modulu** zadej ID (např. `1017`) a klepni na **Ověřit**. Pokud jednotka na brokeru existuje, doplní se; jinak pole zůstane vyplněné pro další pokus.

### Karta jednotky

Každý řádek ukazuje: zaškrtávátko pro výběr, ID, indikátor online (tečka), čas posledního ALIVE, firmware a napětí baterie. Vpravo jsou tři ikony:

- **Seznam devices** (`device_hub`, s počtem modulů v odznaku) — otevře detail jednotky. Po skenu sběrnice (viz §5) se ikona obarví podle výsledku: 🔴 červená = některý uložený device na sběrnici chybí, ⬜ šedá = na sběrnici je neuložený device, jinak zůstane původní.
- **Info** (`i`) — dialog s podrobnostmi (IP, MAC, SSID, MQTT, baterie, jas, LED na portech). Lze **kopírovat** do schránky, **Změnit ID** jednotky a přepnout režim LED příkazů **BIN/OLD**.
- **Obnovit** (`↻`) — vyžádá aktuální parametry a seznam devices.

> Ikona `?` (placeholder) u jednotky znamená, že ID bylo zadáno/naimportováno, ale jednotka ještě neodpověděla.

### Vyčištění seznamu

Ikona **úklidu** (`Vyčistit seznam`) v liště smaže celý seznam jednotek (na hardware to nemá vliv).

---

## 3. LED test

Spodní lišta (viditelná, když jsi připojen a máš jednotky):

1. **Vyber jednotky** zaškrtávátky (nebo *Vybrat vše*).
2. **Vyber porty** — 8 barevných tlačítek `0`–`7`. Aktivní port svítí barvou, neaktivní je šedý. Tlačítko **Vše / Zrušit** přepne všechny porty.
3. Barvu a vzor (kolik LED svítí / nesvítí) nastavíš v **Nastavení → Schéma LED pásku**.
4. Stiskni:
   - **TEST** (zelená) — rozsvítí LED podle schématu na vybraných jednotkách a portech.
   - **ZHASNI** (červená) — zhasne LED na vybraných jednotkách a portech.
   - **SCAN** — obnoví všechny jednotky.

---

## 4. Výběr jednotek a hromadná konfigurace

Hromadné akce vyžadují **vybrané jednotky** (zaškrtávátka). Lišta nad seznamem ukazuje počet a nabízí **Vybrat vše** / **Zrušit**. Můžeš taky filtrovat offline jednotky klepnutím na text *„N offline"*.

Menu **Hromadná konfigurace** (ikona `settings_remote`) je aktivní jen při výběru. Mezi vybranými jednotkami se posílá s ~100 ms pauzou. Položky:

| Položka | Co dělá |
|---------|---------|
| **Změnit broker** | Přepne vybrané jednotky na jiný broker (`set_Mqtt`). Lze vybrat uložený profil nebo zadat nový (ten se zároveň uloží). Pozor: jednotky se odpojí z aktuálního brokera. |
| **Změnit WiFi** | Nastaví SSID + heslo (`set_WiFi`). |
| **Jas P2L LED** | Jas LED pásků jednotky, 0–100 % (`set_brightness`). |
| **Aktualizovat firmware** | OTA flash — zadej cestu k serveru, *Ověřit* načte dostupné `*.bin`, vyber a **FLASH**. Jednotky se restartují a budou pár minut nedostupné. |
| **Restartovat P2L modul** | Pošle restart vybraným jednotkám. |
| **Jas PUM-A** | Jas displejů PUM-A, 0–6 (DISP SET-CONFIG na každý displej zvlášť). |
| **Aplikovat šablonu** | Aplikuje device šablonu na vybrané jednotky (viz §6). |

---

## 5. Detail jednotky a správa devices

Otevřeš ikonou **Seznam devices** na kartě jednotky. Devices jsou seskupené podle typu (**PUM-A / PUM-B / PUM-C / SENZOR**).

### Akce v liště detailu

- **Načíst devices** (`↻`) — znovu načte seznam ze sběrnice (`GET-DEVICES`).
- **Skenovat sběrnici** (`radar`) — diagnostika: read-only sken RS485 (`SCAN-DEVICES`), který zjistí **fyzicky připojené** čipy, aniž by cokoli přepsal. Po klepnutí vybereš rozsah — **Vše** / **PUM-X** (PUMA moduly) / **SENZORY** (DIST). Sken může chvíli trvat (i přes 10 s). Nahoře se ukáže souhrnný proužek (počty OK / chybí / neuloženo), výsledek se ale promítne hlavně přímo do seznamu devices:
  - 🟢 normální barevný chip — device je v konfiguraci i na sběrnici,
  - 🔴 **červený okraj** — device je v konfiguraci, ale na sběrnici nekomunikuje (odpojené / vadné),
  - ⬜ **šedý chip** — device je na sběrnici, ale není uložený v jednotce; klepnutím ho **přidáš** (předvyplní se adresa i typ). Neznámý podtyp PUMA (`PUM-X`) se zobrazí jako samostatná šedá sekce — u něj typ doplníš ručně.
  
  Vyžaduje novější firmware jednotky; starší FW na sken neodpoví (proužek to oznámí). Proužek i zvýraznění zavřeš křížkem.
- **Přidat device** (`+`) — dialog pro přidání modulu (viz níže).
- **Aplikovat šablonu** — přepíše devices této jednotky šablonou.
- **Uložit jako šablonu** — uloží aktuální skladbu modulů jako novou šablonu.
- **Export / Import devices** do souboru (JSON).
- **Smazat všechny devices** (smeták) — vyprázdní jednotku (nevratné).

### Přidání modulu

V dialogu **Přidat device** zvol:

- **Typ:** PUM-A, PUM-B, PUM-C nebo SENZOR (DIST).
- **Adresu / číslo čipu** v platném rozsahu (viz §7).
- **PUM-A:** **0–4 tlačítka** okolo displeje. Vybíráš je klepnutím na vizuální dlaždice v řadě `3 · 1 · DISPLEJ · 0 · 2` (uprostřed displej, vlevo i vpravo až 2 tlačítka). Každá dlaždice ukazuje **číslo tlačítka** (0–3) a jeho **adresu** (např. `1132`); tlačítka jsou nezávislá, vyber libovolnou kombinaci. Dole zaškrtni, zda má **LEDS** (kroužek). Číslo tlačítka = tisícová číslice jeho adresy.
- **PUM-B:** zda má LEDS.
- **PUM-C:** lze přidat jen k PUM-A, které má 0 nebo 1 tlačítko.
- **SENZOR (DIST):** konfigurace měření (perioda, timeout, počet měření, max. odchylka, offset, dosah Short/Middle/Long).
- Volitelně **Po úpravě restartovat P2L modul**.

### Akce na čipu (popup menu na adrese)

- **Test displeje (AHOJ)** / **Adresa na displej** / **Smazat text** — jen PUM-A.
- **Rozsvítit / Zhasnout LED** — moduly s LEDS.
- **Upravit** — konfigurace DIST.
- **Vyměnit** — výměna vadného kusu (viz §7).
- **Přečíslovat** — změna adresy funkčního device (viz §7).
- **Smazat** — odebere device z jednotky.

Hlavičky skupin mají rychlé akce: rozsvítit/zhasnout všechny LEDS, u PUM-A poslat „AHOJ" / adresu / smazat text na všechny displeje (postupně na každý se 100ms pauzou).

**Stisk tlačítka naživo:** když na sběrnici stiskneš fyzické tlačítko, na chvíli (1 s) se zvýrazní příslušná hrana buňky devicu a v ní se ukáže **číslo stisknutého tlačítka** (0–3). Tlačítka 1 a 3 (levá strana displeje) zvýrazní levou hranu, tlačítka 0 a 2 (pravá strana) pravou. U SENZORU (DIST) chip průběžně ukazuje naměřenou vzdálenost v mm.

---

## 6. Šablony

Šablona = pojmenovaná skladba modulů pro rychlé nasazení na jednotku.

Otevři **Šablony** (`folder_special`) v liště:

- **Nová šablona** (tlačítko `+`) — otevře editor: pojmenuj a přidávej moduly stejně jako v detailu jednotky.
- **Upravit / Duplikovat / Exportovat / Smazat** — v menu (`⋮`) u každé šablony.
- **Export / Import** šablon (ikony v liště) — JSON. Při importu konfliktních názvů nabídne *Přeskočit / Přejmenovat / Přepsat*.

**Aplikace šablony** (ikona `rocket_launch` nebo přes Hromadnou konfiguraci):

1. Vyber šablonu a cílové jednotky.
2. Potvrď **Aplikovat**.

> **Pozor — RECREATE:** aplikace šablony **smaže všechny existující devices** na cílových jednotkách a nahradí je obsahem šablony.

---

## 7. Výměna a přečíslování device

Nový firmware řeší obojí příkazy na úrovni jednotky; firmware atomicky přemapuje celý fyzický čip (displej + tlačítka + LEDS).

### Platné rozsahy adres (default = horní mez)

| Modul | Rozsah | Factory default |
|-------|--------|-----------------|
| PUM-A | 128–246 | 246 |
| PUM-B | 128–247 | 247 |
| PUM-C | 128–247 | 247 |
| DIST  | 1–127  | 127 |

### Vyměnit (vadný kus)

Když je device fyzicky vadný, vyměníš ho za nový kus s **factory default adresou**. V menu čipu zvol **Vyměnit**, potvrď default adresu nového kusu — jednotka přečipuje nový na ID původního (`DEVICE-REPLACE`).

### Přečíslovat (funkční device)

Změna adresy funkčního device: v menu čipu **Přečíslovat**, zadej novou adresu v platném rozsahu (aplikace hlídá kolize). Jednotka přemapuje device (`DEVICE-SET-ID`).

Po obou operacích jednotka potvrdí a aplikace si automaticky vyžádá aktuální `GET-DEVICES`.

---

## 8. Export / Import seznamu ID

V řádku pro zadání ID jsou dvě ikony:

- **Načíst seznam P2L modulů** (`⬆`) — naimportuje JSON se seznamem ID (volitelně i broker profil).
- **Exportovat seznam P2L modulů** (`⬇`) — uloží/sdílí aktuální seznam ID jako JSON.

Na webu se export vždy **stáhne** jako soubor; nativně lze i sdílet.

---

## 9. Nastavení

- **Schéma LED pásku** — kolik LED svítí / nesvítí a barva pro LED test.
- **Broker profily** — viz §1.
- **Export / Import nastavení** (`import_export`) — kompletní záloha profilů, šablon a LED schématu do JSON. Import přepíše stávající.
- **Administrace uživatelů** — jen ve webové verzi pro adminy (správa přihlašovacích účtů).

---

## 10. Webová verze

- Vyžaduje **přihlášení** (uživatel + heslo); *Zapamatovat (7 dní)* prodlouží platnost session.
- Broker musí mít **WebSocket listener** a profil musí mít zapnutý přepínač **WebSocket**.
- Export souborů probíhá stažením přes prohlížeč.

---

*Verze aplikace je uvedena v patičce obrazovky Nastavení.*
