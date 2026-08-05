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

Každý řádek ukazuje: zaškrtávátko pro výběr, ID, indikátor online (tečka), čas posledního ALIVE, firmware a napětí baterie. Vpravo jsou ikony:

- **⚠ Nesouhlasí s evidencí** (oranžová, `warning_amber`) — objeví se **jen když jsi přihlášený** (viz §10) a daná jednotka má v centrální databázi rozpor mezi evidencí a skutečností. Klepnutím se otevře karta jednotky v databázi, kde je rozdíl rozepsaný. (Bez přihlášení a u jednotek bez rozporu se ikona nezobrazuje.)
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

> **Potvrzení příjmu (nová generace).** U změny brokera, WiFi i firmwaru appka čeká, až jednotka příkaz **potvrdí** („jednotka potvrdila příjem"). Do evidence (databáze) se změna zapíše **až po potvrzení** — když je jednotka offline a příkaz nedostane, uvidíš „**NEPOTVRDILA (offline?)**" a evidence zůstane pravdivá (nezapíše se něco, co reálně neproběhlo). Stará generace potvrzení neumí, tam se zapíše rovnou jako dřív.
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
  - *Windows/Android:* **volitelné** přihlášení k serveru (stejné účty jako webová verze). Bez přihlášení appka funguje beze změny; přihlášení je potřeba pro centrální databázi jednotek (§10). Zadává se adresa serveru (např. `192.168.1.10:3001`), jméno a heslo. Přihlášení se pamatuje (7 dní) — po restartu appky se obnoví samo. Když je server nedostupný, sekce ukáže „Server nedostupný" s tlačítkem *Zkusit znovu*; na zbytek aplikace to nemá vliv.
  - *Web:* ukazuje přihlášeného uživatele a tlačítko **Odhlásit se** (přihlášení řeší vstupní obrazovka).
- **Lokální server (databáze)** — viz §9.1. Zobrazí se jen ve Windows verzi, která má server přiložený. Volba databáze (soubor / sdílená MariaDB) je v §9.2.

### 9.1 Lokální server (databáze) — Windows

Databáze P2L modulů (§10) potřebuje server. Windows verze si ho **může nosit s sebou**: pokud je ve složce s aplikací podadresář `server\`, appka server **automaticky spustí při svém startu a ukončí při zavření**. Nemusíš nic instalovat ani spouštět ručně — databáze prostě funguje.

Sekce **Lokální server (databáze)** v *Nastavení* (dole, pod *Účtem*) ukazuje:

| Stav | Význam |
|------|--------|
| 🟢 **Běží (spuštěn aplikací)** | Server nastartovala appka a při zavření ho ukončí. |
| 🟢 **Běží (spuštěn zvlášť)** | Na portu už někdo odpovídal (např. server spuštěný v příkazové řádce). Appka ho jen používá a při zavření ho **nechá běžet**. |
| ⏳ **Startuje…** | Naskakuje (obvykle 1–3 s). |
| ⏹ **Neběží** | Vypnutý — spustíš tlačítkem *Spustit*. |
| 🔴 **Start selhal** | Něco se pokazilo; tlačítko *Log* ukáže výpis serveru. |

- **Databáze** — kam server ukládá data: **SQLite** (soubor v tomto počítači, výchozí) nebo **MariaDB** (sdílená databáze na serveru). Viz §9.2.
- **Spouštět se aplikací** — přepínač automatického startu. Když ho vypneš, server se spustí až tlačítkem *Spustit*.
- **Založit účet správce** — objeví se **jen při prvním spuštění**, kdy je databáze prázdná a není se čím přihlásit. Zadáš jméno a heslo (min. 8 znaků), appka účet vytvoří a hned tě přihlásí.
- **Spustit / Zastavit** a **Log** — ruční ovládání a diagnostika.

**Kde jsou data.** Při volbě *SQLite* leží databáze v `%APPDATA%\P2L-Tester\server-data` (tj. `C:\Users\<jméno>\AppData\Roaming\P2L-Tester\server-data`), **ne** ve složce aplikace. Díky tomu můžeš novou verzi rozbalit přes starou nebo do jiné složky a **o data nepřijdeš**. Zálohu si můžeš udělat i z appky: *Databáze P2L modulů* → ☰ → *Exportovat databázi* (§10).

**Poznámky:**
- Appka nikdy nezabije server, který nespustila — když si ho pustíš zvlášť v příkazové řádce, zůstane běžet i po zavření appky.
- Když appku ukončíš násilím (Správce úloh), server může zůstat běžet; při dalším spuštění ho appka najde a uklidí.
- Přihlašovací účty jsou uložené v té databázi, kterou server používá — u *SQLite* jsou tedy jen v tomto počítači, u *MariaDB* společné pro všechny.

### 9.2 Sdílená databáze (MariaDB)

Když má být evidence **společná pro víc počítačů**, nasměruj server na MariaDB. Klepni v sekci *Lokální server* na **Databáze**, přepni na **MariaDB** a vyplň:

| Pole | Co zadat |
|------|----------|
| **Server** / **Port** | adresa databázového serveru, port obvykle `3306` |
| **Databáze** | jméno databáze (např. `P2Lunits`) — **musí už existovat**, tabulky si server vytvoří sám |
| **Uživatel** / **Heslo** | databázový účet s právy na tu databázi |

Po *Uložit* se server sám restartuje s novým nastavením. Když se k databázi nedostane, dialog to napíše (detail v *Log*).

Poznámky:
- Údaje se pamatují, takže přepnutím zpět na *SQLite* o ně nepřijdeš.
- Když *Databáze* svítí **oranžově**, běžící server jede nad jinou databází, než máš nastavenou — typicky proto, že ho spustil někdo jiný (stav *Běží (spuštěn zvlášť)*). Pak ho restartuj ručně, jinak by se zápisy ukládaly jinam.
- Účty pro přihlášení do appky jsou v té samé databázi, takže při MariaDB se přihlásíš stejným účtem z každého počítače.

**Android a web server spustit nemohou** (nemají Node runtime a prohlížeč se na databázi přímo nepřipojí). Tam se appka přihlašuje k serveru **na síti** — adresu zadáš v *Nastavení → Účet*. Když má být evidence dostupná i z mobilu nebo z webu, musí být jeden server spuštěný trvale (typicky na tom stroji, kde je MariaDB) a všichni se hlásí na něj.

---

## 10. Databáze P2L modulů

Centrální evidence P2L modulů. Otevři přes menu **☰** → *Databáze P2L modulů* — položka je vidět **jen po přihlášení** (na Windows/Android přes *Nastavení → Účet*, na webu vždy).

Databáze běží na serveru. Ve Windows verzi ho appka může mít **přiložený a spouštět ho sama** (§9.1) — pak stačí spustit aplikaci a přihlásit se; data si drží buď lokálně, nebo ve sdílené MariaDB (§9.2). Android a web se vždy přihlašují k serveru na síti (adresa v *Nastavení → Účet*).

Karty jednotek **vznikají a aktualizují se samy** běžnou prací s appkou: jakmile je uživatel přihlášený, každé ALIVE, načtení detailu (`get_param`), seznam devices i každá konfigurační akce (broker, WiFi, jas, firmware) se zapíší na kartu jednotky. Nic se nezadává ručně — kromě údajů níže.

**Seznam:** vyhledávací pole (filtruje najednou přes ID, název i umístění) a pod ním tři rozevírací pole filtru — **Zákazník**, **Broker** a **Stav** (každé s volbou *Vše*); nabídky zákazníků a brokerů se plní z jednotek v evidenci, u položek filtru **Stav** je barevná tečka daného stavu. Filtry se kombinují s vyhledáváním; ikona ⌦ vpravo od filtrů je zruší najednou. Řádek ukazuje ID, název a broker na prvním řádku, na druhém barevnou tečku stavu (barvy odpovídají filtru Stav), jak dávno se jednotka ozvala, umístění a firmware; jednotka s rozporem mezi evidencí a skutečným stavem má **oranžový trojúhelník ⚠** (detail rozdílů na kartě). Tažením dolů se seznam obnoví.

**Hromadné úpravy** (stejně jako výběr na hlavní obrazovce): každý řádek má vlevo **zaškrtávátko**, nad seznamem je **Vybrat vše** (vybere vše, co právě projde filtrem — např. všechny jednotky jednoho zákazníka) a **Zrušit**. Když je něco vybráno, tlačítko **Hromadné úpravy** (ikona v liště) nabídne menu:
- **Změnit parametry** — hromadně zapíše broker / WiFi / jas do evidence vybraných jednotek (stejný dialog jako ruční editace evidence, prázdné pole se nemění). Neposílá se do jednotek, jen do DB.
- **Změnit stav / zákazníka / umístění** — hromadná změna meta polí (stav má volbu „beze změny").
- **Smazat** — nevratné smazání vybraných jednotek z databáze (jen pro **admina**, s potvrzením opsáním počtu). Pokud se smazaná jednotka znovu ozve a jsi přihlášený, karta se může založit znovu.

**Karta jednotky** (klepnutím na řádek) má tři části:

- **Údaje (meta)** — název, umístění, poznámka, stav. Jediná ručně editovatelná část — ikona **✏** v liště.
- **Konfigurace** — jeden řádek na parametr (broker, MQTT uživatel, hesla, WiFi, IP, jas…), který **slučuje až tři pohledy**: *evidence* (co appka poslala), *uloženo* (co má jednotka uložené v paměti, z GET-CONFIG) a *běží* (co reálně jede). Když všechny zdroje sedí, je jedna hodnota s **✓**; když se liší, rozepíšou se pod sebou popsané *evidence / uloženo / běží* — rozdíl je hned vidět. Hesla jsou maskovaná, **oko** je odkryje (skutečné hodnoty zná appka z evidence, u nového firmwaru i přímo z jednotky). Pohled *uloženo* (a pole navíc — MQTT uživatel, TLS validace, certifikát, DNS/brána/maska) mají jen jednotky s novým firmwarem (P2L_26071501NT a vyšší); u starších se ukáže jen to, co jednotka hlásí přes `get_param`. Ikona **✎** v hlavičce sekce otevře **ruční editaci evidence** (broker, WiFi, jas) — hodí se pro jednotky nasazené u zákazníka, na které už appka přes MQTT nedosáhne: zapíšeš, co má jednotka mít. **Neposílá se to do jednotky**, jen se to uloží do evidence (a do historie); prázdné pole se nemění.
- **Jednotka** — observed metadata: firmware, HW model, generace, MAC, baterie, kdy se naposledy ozvala, seznam devices.

Pod tím je **historie** změn (kdo, kdy, co — hesla se do historie nikdy nezapisují). Když se to, co jednotka hlásí, liší od evidence, karta nahoře ukáže oranžové **„Nesouhlasí s evidencí"** s konkrétními rozdíly. Nově rozlišuje tři druhy: **evidence × uloženo v jednotce** (nedorazila naše konfigurace?), **uloženo × reálně běží** (statická IP nastavená, ale jede DHCP / jiná WiFi) a **evidence × kde jednotku vidíme** (hlásí se přes jiný broker). Pokud je změna záměrná, tlačítko **„Převzít skutečnost do evidence"** srovná evidenci podle reálného stavu (hesla v evidenci zůstávají původní — jednotka je nehlásí; pokud se změnila taky, pošli konfiguraci přes appku).

**Import / export databáze.** Hamburger **☰** vpravo nahoře v hlavičce obrazovky nabízí:
- **Exportovat databázi** — stáhne **kompletní zálohu** celé databáze do JSON souboru: všechny jednotky se všemi vrstvami (evidence včetně hesel, observed / GET-CONFIG, meta) i historií. Vhodné pro zálohu nebo přenos na jiný server.
- **Importovat databázi** — načte dřív exportovaný soubor a **sloučí** ho do databáze: jednotky, které v souboru jsou, se podle ID **aktualizují** (nové se přidají), jednotky mimo soubor zůstanou beze změny — **nic se nemaže**. Před zápisem appka ukáže potvrzení s počtem jednotek. Opakovaný import stejného souboru nic nepokazí.

**Export jen vybraných jednotek.** Nemusíš exportovat celou databázi:
- **Několik jednotek** — zaškrtni je v seznamu (stejný výběr jako u hromadných úprav) a v hamburgeru **☰** zvol **Exportovat vybrané** (položka se objeví, jen když je něco vybráno). Soubor pak obsahuje jen tyhle jednotky (stejný formát jako plná záloha).
- **Jednu jednotku** — na kartě jednotky je v hlavičce ikona **⭳** („Exportovat jednotku").
- **Import podmnožiny** nepotřebuje nic navíc: import vždy jen sloučí, co je v souboru — tj. soubor s jednou nebo pár jednotkami naimportuje právě je.

---

## 11. Webová verze

- Vyžaduje **přihlášení** (uživatel + heslo); *Zapamatovat (7 dní)* prodlouží platnost session.
- **Odhlásit se** lze v *Nastavení → Účet* (dole).
- Broker musí mít **WebSocket listener** a profil musí mít zapnutý přepínač **WebSocket**.
- Export souborů probíhá stažením přes prohlížeč.

---

*Verze aplikace je uvedena v patičce obrazovky Nastavení.*
