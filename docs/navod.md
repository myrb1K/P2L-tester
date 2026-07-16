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

V **Nastavení** (menu **☰** vpravo nahoře → *Nastavení*) v sekci *Uložené profily*:

- **Nový profil** — tlačítko nahoře. Vyplň *Název*, *Broker adresa*, *Port*, volitelně *Username* / *Password*.
- **SSL/TLS** — zapni pro šifrované připojení (MQTTS).
- **WebSocket** — zapni, když se broker připojuje přes WS (povinné na webové verzi; pole *WebSocket path*, typicky `/mqtt`).
- **Uložit nový profil** / **Uložit a připojit**.
- U každého profilu je vlevo **▶ Spustit** (připojí se k němu) a vpravo **⋮ menu** s akcemi **Upravit / Duplikovat / Smazat**. Klepnutí na řádek profil rozbalí k editaci. Pořadí změníš **podržením prstu na kartě** a přetažením (na PC podržením tlačítka myši). Duplikovat vytvoří kopii s názvem „… (2)" hned pod originálem.

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
- **Skenovat sběrnici** (`radar`) — diagnostika: read-only sken RS485 (`SCAN-DEVICES`), který zjistí **fyzicky připojené** čipy, aniž by cokoli přepsal. Po klepnutí vybereš rozsah — **Vše** / **PUM-X** (PUMA moduly) / **SENZORY** (DIST) / **ID…** (jedna konkrétní adresa — zadáš ji v dialogu, 1–247; typ DIST/PUM se odvodí z rozsahu). Rozsahový sken může chvíli trvat (i přes 10 s); sken jedné adresy je rychlý a porovnává se jen s tou jednou adresou. Nahoře se ukáže souhrnný proužek (počty OK / chybí / neuloženo), výsledek se ale promítne hlavně přímo do seznamu devices:
  - 🟢 normální barevný chip — device je v konfiguraci i na sběrnici,
  - 🔴 **červený okraj** — device je v konfiguraci, ale na sběrnici nekomunikuje (odpojené / vadné). Když modul sdružuje víc částí (PUM-A = displej + LEDS + tlačítka), přibude v chipu **červený odznak ⚠ s počtem** vadných částí; **která konkrétní část** nekomunikuje se ukáže v tooltipu (najetí myší / podržení prstu), např. „⚠ Nekomunikuje: displej, tlačítko 1". Poruchu hlásí periodické ALIVE nebo si ji vyžádáš akcí **Alive** (viz níže),
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

Po přidání jednoho device se jeho adresa **automaticky ověří cíleným skenem** (`SCAN-DEVICES` na danou adresu) — hned po načtení configu uvidíš, jestli je device fyzicky připojený (🟢 OK) nebo na sběrnici chybí (🔴). Pokud jsi předtím skenoval celou sběrnici (např. přidáváš device z šedého „ghostu"), výsledek ověření se do toho skenu **vmerguje** — aktualizuje se jen ověřovaná adresa a **ostatní ghost devices v seznamu zůstanou**, takže je můžeš přidat taky. Vyžaduje firmware se `SCAN-DEVICES`. Při importu více devices najednou se auto-ověření nedělá — sken spusť ručně.

### Akce na čipu (popup menu na adrese)

- **Alive** — vynutí okamžité ohlášení (`GET-ALIVE`, od FW `P2L_26070201NT`) na **všech částech** modulu bez čekání na periodický 5min interval: u PUM-A na displeji, LEDS i všech tlačítkách, u PUM-B na tlačítku (+ LEDS), u PUM-C na obou tlačítkách, u SENZORU na senzoru. Zdraví částí se pak promítne do jejich stavu (🟢 OK / 🔴 porucha) stejně jako u periodického ALIVE. Vyžaduje novější firmware.
- **Rescan** — pošle cílený sken adresy toho device (`SCAN-DEVICES` na jeho adresu) a podle odpovědi ho označí 🟢 OK (fyzicky na sběrnici) nebo 🔴 chybí (nekomunikuje). Hláška dole napíše konkrétní výsledek. Ostatní devices v seznamu zůstanou beze změny. Vyžaduje firmware se `SCAN-DEVICES`.
- **Test displeje (AHOJ)** / **Adresa na displej** / **Smazat text** — jen PUM-A.
- **Rozsvítit / Zhasnout LED** — moduly s LEDS.
- **Změřit teď** — jen SENZOR (DIST): vyžádá si okamžité změření vzdálenosti (`GET-VALUE`, od FW `P2L_26062301NT`). Výsledek se ukáže v hlášce dole (vzdálenost v mm, nebo porucha / TIMEOUT). Vyžaduje novější firmware — starší jednotka neodpoví a po ~10 s se hlásí „bez odpovědi".
- **Nastavení** (u senzoru; u ostatních modulů „Upravit") — konfigurace DIST v modalu **„Nastavení senzoru (adresa)"**. Typ ani adresa se tu needitují (senzor už na sběrnici je). Modal ukazuje **aktuální nastavení senzoru** načtené z `GET-DEVICES` (perioda, timeout, offset, max. odchylka, počet měření, dosah). Vedle popisku **Měření** se průběžně vypisuje **naměřená vzdálenost v mm** — objeví se sama, jakmile senzor pošle hodnotu (`D/.../DIST/.../UPDATE`), tedy **i bez zaškrtnutí**. Zaškrtávátko **Měření** navíc spustí **aktivní polling** (každých 750 ms se vyžádá `GET-VALUE`), který se hodí, když senzor hodnoty sám neposílá. Užitečné při seřizování senzoru přímo v konfiguraci. Odškrtnutím nebo zavřením modalu se polling zastaví. Je-li senzor v **segmentovém režimu**, dole je i výpis segmentů (název + rozsah `od – do mm`) — **jen ke čtení**. Segment, do kterého objekt právě padá, se ve výpisu **živě zvýrazňuje zeleně** (podle `D/.../DIST/.../UPDATE` z jednotky) — vidíš tak přímo v editu, co senzor právě detekuje. Tlačítko **Obnovit** (vlevo dole) vrátí konfiguraci na tovární výchozí (50 / 10 / 0 / 20 / 4 / Middle); **adresu ani segmenty nemění**. Změny se odešlou až po **OK**.
- **Vyměnit** — výměna vadného kusu (viz §7).
- **Přečíslovat** — změna adresy funkčního device (viz §7).
- **Smazat** — odebere device z jednotky. Poté se adresa ověří skenem: pokud je čip pořád fyzicky na sběrnici, zobrazí se jako šedý „ghost" (v configu už není, ale připojený je) — můžeš ho rovnou zase přidat, nebo fyzicky odpojit.

Hlavičky skupin mají rychlé akce: rozsvítit/zhasnout všechny LEDS, u PUM-A poslat „AHOJ" / smazat text na všechny displeje (jeden broadcast), poslat každému displeji jeho adresu (ikona `pin` — postupně na každý se 100ms pauzou), nebo nechat displeje ukázat jejich **skutečné uložené ID** (ikona `?`, „????").

**Rozdíl mezi oběma „adresovými" akcemi je důležitý:**

- **`pin` (adresa na každý displej)** — appka pošle na displej adresu **z konfigurace** (co si appka o modulu myslí).
- **`?` („????")** — jeden broadcast, každý displej vykreslí **skutečné ID uložené ve svém čipu** (funkce Pum-A FW v3.01+, funguje i na displeje mimo `GET-DEVICES`).

Proto je `?` diagnostický nástroj: když někdo fyzicky vymění kus za jiný s jiným uloženým ID (např. místo 128 osadí 222), na displeji uvidíš **222** místo očekávané 128 — nesoulad mezi konfigurací a fyzickým čipem poznáš hned. Pokud se skutečné ID liší od konfigurace, adresu srovnáš přes **Přečíslovat** (viz §7).

**Stisk tlačítka naživo:** když na sběrnici stiskneš fyzické tlačítko, na chvíli (1 s) se zvýrazní příslušná hrana buňky devicu a v ní se ukáže **číslo stisknutého tlačítka** (0–3). Tlačítka 1 a 3 (levá strana displeje) zvýrazní levou hranu, tlačítka 0 a 2 (pravá strana) pravou. U SENZORU (DIST) chip průběžně ukazuje naměřenou vzdálenost v mm; v **segmentovém režimu** pod ní i **název aktuálního segmentu** — zeleně, když je měřená hodnota uvnitř pásma, šedě, když mimo.

---

## 6. Šablony

Šablona = pojmenovaná skladba modulů pro rychlé nasazení na jednotku.

Otevři **Šablony** (menu **☰** vpravo nahoře → *Šablony*):

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

Když je device fyzicky vadný, vyměníš ho za nový kus s **factory default adresou**. V menu čipu zvol **Vyměnit**, potvrď default adresu nového kusu. Aplikace nejdřív **ověří skenem, že je nový kus na své default adrese fyzicky na sběrnici**, a teprve pak pošle přečipování nového na ID původního (`DEVICE-REPLACE`). Když nový kus nenajde (nebo to nejde ověřit — starší firmware), zeptá se, jestli přesto pokračovat.

### Přečíslovat (funkční device)

Změna adresy funkčního device: v menu čipu **Přečíslovat**, zadej novou adresu v platném rozsahu (aplikace hlídá kolize). Jednotka přemapuje device (`DEVICE-SET-ID`). U **PUM-A** se po přečíslování nová adresa rovnou zobrazí na jeho displeji (pro fyzické ověření).

Po obou operacích jednotka potvrdí a aplikace si automaticky vyžádá aktuální `GET-DEVICES`.

---

## 8. Export / Import seznamu ID

V řádku pro zadání ID jsou dvě ikony:

- **Načíst seznam P2L modulů** (`⬆`) — naimportuje JSON se seznamem ID (volitelně i broker profil).
- **Exportovat seznam P2L modulů** (`⬇`) — uloží/sdílí aktuální seznam ID jako JSON.

Na webu se export vždy **stáhne** jako soubor; nativně lze i sdílet.

---

## 9. Nastavení

Otevři přes menu **☰** vpravo nahoře → *Nastavení*.

- **Schéma LED pásku** — kolik LED svítí / nesvítí a barva pro LED test.
- **Broker profily** — viz §1.
- **Export / Import nastavení** (`import_export`) — kompletní záloha profilů, šablon a LED schématu do JSON. Import přepíše stávající.
- **Administrace uživatelů** — jen ve webové verzi pro adminy (správa přihlašovacích účtů).
- **Účet** (sekce dole) — jediné místo pro správu účtu (v horní liště žádná ikona účtu není).
  - *Windows/Android:* **volitelné** přihlášení k firemnímu serveru (stejné účty jako webová verze). Bez přihlášení appka funguje beze změny; přihlášení je potřeba pro centrální databázi jednotek (§10). Zadává se adresa serveru (např. `192.168.1.10:3001`), jméno a heslo. Přihlášení se pamatuje (7 dní) — po restartu appky se obnoví samo. Když je server nedostupný, sekce ukáže „Server nedostupný" s tlačítkem *Zkusit znovu*; na zbytek aplikace to nemá vliv.
  - *Web:* ukazuje přihlášeného uživatele a tlačítko **Odhlásit se** (přihlášení řeší vstupní obrazovka).

---

## 10. Databáze jednotek

Centrální evidence P2L modulů na firemním serveru. Otevři přes menu **☰** → *Databáze jednotek* — položka je vidět **jen po přihlášení** (na Windows/Android přes *Nastavení → Účet*, na webu vždy).

Karty jednotek **vznikají a aktualizují se samy** běžnou prací s appkou: jakmile je uživatel přihlášený, každé ALIVE, načtení detailu (`get_param`), seznam devices i každá konfigurační akce (broker, WiFi, jas, firmware) se zapíší na kartu jednotky. Nic se nezadává ručně — kromě údajů níže.

**Seznam:** vyhledávací pole (filtruje najednou přes ID, název i umístění) + chipy stavu (*Vše / Aktivní / Vadná / Sklad / Vyřazená*). Řádek ukazuje ID, název, stav, jak dávno se jednotka ozvala a firmware; jednotka s rozporem mezi evidencí a skutečným stavem má **oranžový trojúhelník ⚠** (detail rozdílů na kartě). Tažením dolů se seznam obnoví.

**Karta jednotky** (klepnutím na řádek) má tři části:

- **Údaje (meta)** — název, umístění, poznámka, stav. Jediná ručně editovatelná část — ikona **✏** v liště.
- **Jednotka hlásí (observed)** — co jednotka sama naposledy ohlásila: firmware, IP, MAC, baterie, aktuální WiFi/broker/jas, seznam devices.
- **Odesláno appkou (desired)** — co bylo na jednotku poslané přes appku: broker a WiFi **včetně hesel** (maskovaná, oko je odkryje), jasy, poslední OTA. Tohle jinde neexistuje — jednotka hesla zpětně nevrací.

Pod tím je **historie** změn (kdo, kdy, co — hesla se do historie nikdy nezapisují). Když se to, co jednotka hlásí, liší od evidence (např. ji někdo přenastavil mimo appku), karta nahoře ukáže oranžové **„Nesouhlasí s evidencí"** s konkrétními rozdíly. Pokud je změna záměrná, tlačítko **„Převzít skutečnost do evidence"** srovná evidenci podle reálného stavu (hesla v evidenci zůstávají původní — jednotka je nehlásí; pokud se změnila taky, pošli konfiguraci přes appku).

---

## 11. Webová verze

- Vyžaduje **přihlášení** (uživatel + heslo); *Zapamatovat (7 dní)* prodlouží platnost session.
- **Odhlásit se** lze v *Nastavení → Účet* (dole).
- Broker musí mít **WebSocket listener** a profil musí mít zapnutý přepínač **WebSocket**.
- Export souborů probíhá stažením přes prohlížeč.

---

*Verze aplikace je uvedena v patičce obrazovky Nastavení.*
