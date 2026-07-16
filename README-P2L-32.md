# P2L32-modul
P2L32-modul může pro ovládání LED používat identický format jako stará verze P2L viz. [P2L-modul](https://github.com/Smart-Product-Solution-s-r-o/p2l-modul/blob/main/README.md) 


# Obecný formát nového requestu na jednotku
Requesty se posilaji na topic ve tvaru: `I/<UNIT_ID>/<DEVICE_TYPE>/<DEVICE_ID>/<COMMAND>`\
**UNIT_ID**: ID jednotky.\
**DEVICE_TYPE**: Typ zařízení ovladaného jednotkou: UNIT, DIST, DISP,BTN, P2L.\
**DEVICE_ID**: ID zařízení ovladaného jednotkou. ID se skláda z kódu pro zařízení 2-cifry a jeho adresy 4-cifry.\
***kód zařízení:***  
  *  00 UNIT
  *  01 P2L
  *  04 DIST
  *  05 DISP
  *  06 BTN
  *  11 LEDS

**Broadcast (RS485 adresa 0):**\
Pro hromadné ovládání všech zařízení daného typu na sběrnici RS485 lze použít DeviceId s adresou `0000`:
  * **DISP:** `050000` — příkaz se provede na všech displejích
  * **LEDS:** `110000` — příkaz se provede na všech LED modulech Pum-A

Broadcast je virtuální zařízení v P2L (není uloženo v NVS). Na MQTT neposílá periodické ALIVE. Příkazy `GET-ALIVE`, `SET-ID` a `REPLACE-FROM` na broadcast ID nejsou podporovány (`unknown ID`).\
Na RS485 adrese 0 zařízení na broadcast neodpovídají; P2L po odeslání příkazu vrátí `{"Code":0,"Message":"OK"}` (u DISP `SET-DATA`/`SET-CONFIG` je odpověď OK ihned, RS485 proběhne asynchronně).

**COMMAND**: Příkazy pro jednotlivá zařízení např. SET-CONFIG, GET-CONFIG, GET-ALIVE, SCAN, SCAN-DEVICES ..., popsáno dále.

Payload obsahuje požadované parametry ve formátu JSON dle jednotlivých <COMMAND>s, popsáno dále.

# Obecný formát nového response na request.
Response se posilaji na topic ve tvaru: `O/<UNIT_ID>/<DEVICE_TYPE>/<DEVICE_ID>/<COMMAND>`\
Payload je ve formátu: ```{"Code":<STATUS>,"Message":"<Message>"}```\
**STATUS**: kód chyby. 0 = OK\
**Message**: popis stavu

# Formát pro jednotlivá zařízení
## UNIT - jednotka - kód zařízení 00
***COMANDs:***
* **SET-ID**: změna ID jednotky   
  Parametr:
  * **Id**
    ***Example:***
    TOPIC:
    ```
    I/001001/UNIT/001001/SET-ID 
    ```
    PAYLOAD:
    ```jsonc
    {"Id":1002}
    ```
* **SCAN**: hledání nových zařízení na RS485   
  Parametr:
  * **Type**: nepovinné, ale doporučené. Určuje jaký typ zařízení se má hledat. Možnosti: DIST, DISP
  * **Id**:  Adresa zařízení. Nepovinné, pokud známe adresu tak doporučené.
    ***Example:***
    TOPIC:
    ```
    I/001001/UNIT/001001/SCAN
    ```
    PAYLOAD:
    ```jsonc
    {"Type":"DIST", "Id":50}
    ```
    PAYLOAD hledání všech zažízení:
    ```jsonc
    {}
    ```
* **SCAN-DEVICES**: od verze P2L_26061801NT. Read-only scan RS485 sběrnice – zjistí připojená zařízení **bez zápisu** do konfigurace jednotky (na rozdíl od SCAN)   \
  Parametr:
  * **Type**: nepovinné. Omezí rozsah scanu. Možnosti: `DIST`, `PUM`. Chybí-li → scan obou rozsahů (nebo auto podle `Id`, viz níže).
    * **DIST**: adresy 1–127 (WIT senzory)
    * **PUM**: adresy 128–247 (PUMA moduly)
  * **Id**: nepovinné. RS485 adresa pro scan jednoho zařízení. Bez `Type` se typ probe určí z rozsahu (`Id` 1–127 → DIST, 128–247 → PUM).
  ***Example scan jedné adresy:***\
  TOPIC:
  ```
  I/001001/UNIT/001001/SCAN-DEVICES
  ```
  PAYLOAD:
  ```jsonc
  {"Id":132}
  ```
  ***Example scan PUM:***\
  TOPIC:
  ```
  I/001001/UNIT/001001/SCAN-DEVICES
  ```
  PAYLOAD:
  ```jsonc
  {"Type":"PUM"}
  ```
  ***Example scan DIST + PUM:***\
  TOPIC:
  ```
  I/001001/UNIT/001001/SCAN-DEVICES
  ```
  PAYLOAD:
  ```jsonc
  {}
  ```
  ***Response:*** (stejně jako GET-DEVICES, není formát Code/Message, ale přímo JSON objekt)\
  TOPIC:
  ```
  O/001001/UNIT/001001/SCAN-DEVICES
  ```
  PAYLOAD:
  ```jsonc
  {
    "DIST": [1, 2, 67],
    "PUM-A": [128],
    "PUM-X": [129, 130, 131, 133]
  }
  ```
  Klíče s prázdným polem se neposílají. Typy PUMA: `PUM-A`, `PUM-B`, `PUM-C` (z HW registru), `PUM-X` (starší PUMA bez registru typu). Verze firmware se neuvádí.\
  Chybové odpovědi (formát Code/Message): `unknown Type` (-1), `response too large` (-2), `mqtt publish failed` (-3), `invalid Id` (-4).
* **DELETE**: smazání zařízení   \
  Parametr:
  * **Id**:  Id zařízení včetně typu např 050246\
    ***Example:***\
    TOPIC:
    ```
    I/001001/UNIT/001001/DELETE
    ```
    PAYLOAD:
    ```jsonc
    {"Id":050246}
    ```
* **RESTART**: SW restart jednotky   \
  bez parametru\
  ***Example:***\
  TOPIC:
  ```
  I/001001/UNIT/001001/RESTART
  ```
  PAYLOAD:
  ```jsonc
  {}
  ```
* **RECREATE-DEVICES**: smaž všechny zařízeni a přidá zařízení ze seznamu   \
  Parametry:
  * **Type**:  Typ zařízení DISP, LEDS, BTN, DIST
  * **Id**: pole Id. \
            U DIST je možno zadat parametry včetně segmentů\
            [Id, Period, Timeout, Offset, MaxDeviation, CountMeasures, MeasureType, ["LocationName", From, To, LocationId]] \
    ***Example:***\
    TOPIC:
    ```
    I/001001/UNIT/001001/RECREATE-DEVICES
    ```
    PAYLOAD:
    ```jsonc
    [{"Type":"DISP", "Id":[128]},
     {"Type":"LEDS", "Id":[128]},
     {"Type":"BTN", "Id":[1128,1129,129]},
     {"Type":"DIST", "Id":[[98,40,10,0,20,4,1,[["R01.A01",0,50,1],["R01.A02",130,170,2]]]]}
    ]
    ```
* **ADD-DEVICES**: Stejné jako RECREATE-DEVICES pouze nemaže původní zařízení pouze přidá zařízení ze seznamu   \
* **DELETE-DEVICES**: Smaže zařízení ze seznamu\
    ***Example:***\
    TOPIC:
    ```
    I/001001/UNIT/001001/DELETE-DEVICES
    ```
    PAYLOAD:
    ```jsonc
    [{"Type":"DISP", "Id":[128]},
     {"Type":"LEDS", "Id":[128]},
     {"Type":"BTN", "Id":[1128,1129,129]},
     {"Type":"DIST", "Id":[98]}
    ]
    ```
* **GET-DEVICES**: Vrátí seznam zařízení ve formátu stejném jako používá RECREATE-DEVICES včetně konfigurace DIST   \
* **DEVIC-REPLACE**: od verze P2L_06061201NT\
Nahradí nefunkční (nepřipojené) zařízení "To" novým funkčním zařizenim "From". Prakticky ověří zda původní zařízení nekomunikuje, pokud ano změní adresu nového na adresu původního. Využitelné při instalci, kdy mám jednotku nakonfigurovánu a postupně připojuji zařízení s univerzální adresou, nebo při nahradě poškozeného zařízení  
    ***Example:***\
    TOPIC:
    ```
    I/001001/UNIT/001001/DEVICE-REPLACE
    ```
    PAYLOAD:
    ```jsonc
    {"From":247, "To":128}
    ```
* **DEVIC-SET-ID**: od verze P2L_06061201NT\
Změní ID (RS485 adresu) všech nastavených zařizení na adrese "From" na "To", nahrazuje SET-ID přímo u jednotlivých zařízení.\
    ***Example:***\
    TOPIC:
    ```
    I/001001/UNIT/001001/DEVICE-SET-ID
    ```
    PAYLOAD:
    ```jsonc
    {"From":128, "To":130}
    ```
* **BIN**: hromandne commands v binarním formatu pro zrychleni a zkrácení komunikace \
  TOPIC:
  ```
  I/%06d/UNIT/%06d/BIN
  ```
  PAYLOAD:
    ```jsonc
   [type1],[id1],[data1[0], ...,[data1[n]],
	  [type2],[id2],[data2[0], ...,[data2[n]],
	  ....
	  ....
	  [typem],[idm],[datam[0], ...,[datam[n]],0
    ```
  ***types :***
  * 0x01 LEDS
  * 0x02 DISP
  * 0x03 P2L-Set_leds

  ***data***
  * pro typ 0x01-LEDS: [color],[style]  Pokud color nebo style==0xFF -> clear>Leds
  * pro typ 0x02-DISP  "text ukončený 0"
  * pro typ 0x03-P2L [port] [x1-low] [x1-high] [x2-low] [x2-high] [style] [count_of_color] [color1] .... [colorX]

  ***Example:***\
  *Rozsvítí LED 128-140 barvou +, stylem 0*\
  ```0180 0100 0181 0100 0182 0100 0183 0100 0184 0100 0185 0100 0186 0100 0187 0100 0188 0100 0189 0100 018A 0100 018B 010 018C 0100 00```
  
  *Zobrazi na DISP 128-136 čísla 1-9*\
  ```0280 3100 0281 3200 0282 3300 0283 3400 0284 3500 0285 3600 0286 3700 0287 3800 0288 3900 00```
 
  *Zobrazí "AHOJ" na DISP 128-135 a 140, nastaví různé barvy na LEDS 128-140*\
  ```0280 412E 482E 4F2C 4A2C 00 0281 412E 482E 4F2C 4A2C 00 0282 412E 482E 4F2C 4A2C 00 0283 412E 482E 4F2C 4A2C 00 0284 412E 482E 4F2C 4A2C 00 0285 412E 482E 4F2C 4A2C 00 0286 412E 482E 4F2C 4A2C 00 0287 412E 482E 4F2C 4A2C 00 028C 412E 482E 4F2C 4A2C 00 0180 0101 0181 0201 0182 0301 0183 0401 0184 0101 0185 0201 0186 0301 0187 0401 0188 0101 0189 0201 018A 0301 018B 0401 018C 0101 00```

  *Rozsviti prvnich 16 Ledek na portu 0 stylem 7 barvami 0,1*\
  ```0300 0000 0F00 07 02 00 01 00```

  *Rozsviti prvnich 16 Ledek na portu 1 stylem 0 barvou 2*\
  ```0301 0000 0F00 00 01 02``` 

* **SET-CONFIG**: od verze P2L_26071501NT. Nastavení konfigurace jednotky (Id, WiFi, MQTT, síť). Všechny parametry jsou volitelné — změní se jen ty, které payload obsahuje. Po změně sítě/Id/certifikátu se jednotka restartuje.\
  Parametry:
  * **Id**: nové Id jednotky (nahrazuje i samostatný SET-ID)
  * **SSID**, **PSWD**: přihlášení k WiFi
  * **mqttAddress**, **mqttPort**, **mqttUser**, **mqttPassword**: připojení k MQTT brokeru
  * **mqttCertUrl**: URL (http) CA certifikátu ve formátu PEM. Jednotka si certifikát stáhne a uloží do NVS — při TLS připojení má pak přednost před kořenem zabudovaným ve firmware (ISRG Root X1, Let's Encrypt, platí do 2035). Pro brokery s certifikátem od Let's Encrypt tedy není potřeba. Slouží pro self-signed/privátní CA a pro budoucí výměnu kořene bez nového firmware. Pokud se s uloženým certifikátem nejde připojit, jednotka automaticky zkusí zabudovaný kořen.
  * **mqttInsec**: true = nevalidovat certifikát serveru
  * **ip**, **dns**, **gateway**, **subnet**: statická IP konfigurace ("0.0.0.0" v "ip" vypne statickou IP, přejde na DHCP)

  ***Example:***\
  TOPIC:
  ```
  I/001001/UNIT/001001/SET-CONFIG
  ```
  PAYLOAD:
  ```jsonc
  {"SSID":"ssid","PSWD":"password","mqttAddress":"mqtt.demo1.smartci4.com","mqttPort":1883,"mqttUser":"smartbox_user","mqttPassword":"smartbox2022","mqttInsec":false,"ip":"10.0.0.72","dns":"10.0.0.10","gateway":"10.0.0.10","subnet":"255.255.255.0"}
  ```
  ***Response:*** na topic `O/001001/UNIT/001001/SET-CONFIG` ve formátu `{"Level":"INFO","Code":0,"Message":"OK"}`. Při chybě stahování certifikátu je Code záporný a konfigurace se nezmění.
* **GET-CONFIG**: od verze P2L_26071501NT. Vrátí aktuální konfiguraci jednotky. Nepotřebuje parametry, PAYLOAD musí být ve formátu JSON, tedy `{}`.\
  Hesla se maskují — místo hodnoty se vrací jen `true`/`false` (zda jsou nastavena), u certifikátu `mqttCert` jen zda je uložen.\
  ***Example:***\
  TOPIC:
  ```
  I/001001/UNIT/001001/GET-CONFIG
  ```
  ***Response:*** na topic `O/001001/UNIT/001001/GET-CONFIG`:
  ```jsonc
  {"Id":1001,"ver":"26071501NT","mac":"AA:BB:CC:DD:EE:FF","SSID":"ssid","PSWD":true,"mqttAddress":"mqtt.demo1.smartci4.com","mqttPort":1883,"mqttUser":"smartbox_user","mqttPassword":true,"mqttInsec":false,"mqttCert":false,"ip":"10.0.0.72","dns":"10.0.0.10","gateway":"10.0.0.10","subnet":"255.255.255.0","actualIp":"10.0.0.72","actualSSID":"ssid"}
  ```
* **UPDATE**: od verze P2L_26071501NT. OTA update firmware z plné URL (http i https). Jednotka pošle odpověď OK, stáhne firmware a restartuje se.\
  ***Example:***\
  TOPIC:
  ```
  I/001001/UNIT/001001/UPDATE
  ```
  PAYLOAD:
  ```jsonc
  {"url": "http://185.149.129.164/download/P2L_26071501NT.bin"}
  ```
* **GET-ALIVE**: od verze P2L_26070201NT. Okamžitě odešle ALIVE jednotky na topic `D/<UNIT_ID>/UNIT/<UNIT_ID>/ALIVE` bez čekání na periodický interval (5 min). Nepotřebuje parametry, PAYLOAD musí být ve formátu JSON, tedy `{}`.\
  ***Example:***\
  TOPIC:
  ```
  I/001001/UNIT/001001/GET-ALIVE
  ```
  PAYLOAD:
  ```jsonc
  {}
  ```
  ***Response:*** ALIVE na topic `D/001001/UNIT/001001/ALIVE` (stejný formát jako periodické ALIVE – HWModel, HWPart, Firmware, Battery, Code, Message, Level). Extra odpověď na `O/` topic se neposílá.
## P2L - ovládání LED - kód zařízení 01
Od verze P2L_26071501NT je povel přímo v topicu `I/<UNIT_ID>/P2L/<P2L_ID>/<POVEL>` a payload je plochý JSON objekt (nebo pole objektů) bez obalu `cmds`. `<P2L_ID>` je Id LED zařízení = Id jednotky + 10000 (jednotka `001001` → P2L `011001`). Odpovědi se posílají na `O/<UNIT_ID>/P2L/<P2L_ID>/<POVEL>` ve formátu `{"Code":0,"Message":"OK"}`.

***COMANDs:***
* **CLR-STRIPS**: zhasne LED na zadaných portech; bez parametrů (payload `{}`) zhasne všechny porty.\
  ***Example:***\
  TOPIC:
  ```
  I/001001/P2L/011001/CLR-STRIPS
  ```
  PAYLOAD:
  ```jsonc
  {"ports":[0,1]}
  ```
* **CLR-LEDS**: zhasne LED v rozsahu x1–x2 na portu. Payload může být jeden objekt nebo pole objektů.\
  ***Example:***\
  TOPIC:
  ```
  I/001001/P2L/011001/CLR-LEDS
  ```
  PAYLOAD:
  ```jsonc
  {"port":0,"x1":0,"x2":9}
  ```
* **SET-LEDS**: rozsvítí LED v rozsahu x1–x2 na portu daným stylem a barvou. Payload může být jeden objekt nebo pole objektů (více bloků najednou). Místo `color_id` lze použít pole `colors_id`.\
  Významy `style_id` a `color_id` viz [P2L-modul](https://github.com/Smart-Product-Solution-s-r-o/p2l-modul/blob/main/README.md).\
  ***Example:***\
  TOPIC:
  ```
  I/001001/P2L/011001/SET-LEDS
  ```
  PAYLOAD:
  ```jsonc
  {"port":0,"x1":0,"x2":10,"style_id":0,"color_id":1}
  ```
  PAYLOAD (více bloků):
  ```jsonc
  [{"port":0,"x1":0,"x2":9,"style_id":0,"color_id":0},{"port":0,"x1":10,"x2":19,"style_id":1,"color_id":1}]
  ```
* **SET-CONFIG**: nastavení počtu LED na portech, barev a jasu. Všechny parametry jsou volitelné.\
  Parametry:
  * **brightness**: jas 1-100
  * **ledCounts**: pole `{"port":<number>,"leds":<number>}` — počet LED na portu
  * **colors**: pole `{"color_id":<number>,"red":<0-255>,"green":<0-255>,"blue":<0-255>,"red2":...,"green2":...,"blue2":...}` — definice barev (red2/green2/blue2 volitelné, využívají styly se střídáním barev)

  ***Example:***\
  TOPIC:
  ```
  I/001001/P2L/011001/SET-CONFIG
  ```
  PAYLOAD:
  ```jsonc
  {"brightness":50,"ledCounts":[{"port":0,"leds":60}],"colors":[{"color_id":4,"red":128,"green":84,"blue":0}]}
  ```
* **GET-CONFIG**: vrátí aktuální LED konfiguraci (počty LED, barvy hex, jas). Nepotřebuje parametry, PAYLOAD musí být ve formátu JSON, tedy `{}`.\
  ***Example:***\
  TOPIC:
  ```
  I/001001/P2L/011001/GET-CONFIG
  ```
  ***Response:*** na topic `O/001001/P2L/011001/GET-CONFIG`:
  ```jsonc
  {"brightness":50,"leds port0":60,"leds port1":60,"color0":"ff0000","color2_0":"00ff00", /* ... */ }
  ```
* **CMD** *(starý formát, zachován pro zpětnou kompatibilitu)*:   \
  Parametry stejné jako u P2L jednotky viz. [P2L-modul](https://github.com/Smart-Product-Solution-s-r-o/p2l-modul/blob/main/README.md)\
  ***Example:***\
  TOPIC:
  ```
  I/001001/P2L/011001/CMD
  ```
  PAYLOAD:
  ```jsonc
  {"request_id": -1,"cmds":[{"cmd": "set_leds","args":{"port": 0,"x1": 0,"x2": 10,"style_id": 0,"color_id": 1}}]}
  ``` 
## DIST - sensor vzdálenosti - kód zařízení 04
***COMANDs:***
* **SET-ID**: změna ID sensoru, stačí zadat novou adresu sensoru, typ device se doplní automaticky v tomto připadě 04   \
  Rozsah adres je 0-126\
  Parametr:
  * **Id**\
    ***Example:***\
    TOPIC:
    ```
    I/001001/DIST/040001/SET-ID 
    ```
    PAYLOAD:
    ```jsonc
    {"Id":2}
    ```
* **SET-CONFIG**:  Nastavení sensoru vzdálenosti\
  Parametry:
  * **MeasurePeriod**: Perioda měření sensoru v ms.
  * **Timeout**: Timeout čekání na odpověď sensoru. Pokud vyprší pomocí ALIVu hlášena porucha.
  * **CountMeasures**: Počet požadovaných měření v rozsahu "MaxDeviation" pro vyhodnocení stabilního měření.
  * **MaxDeviation**: Rozsah v mm, ve kterém je hodnota považována za stabilní.
  * **Offset**: Tato hodnota v mm se přičítá ke skutečně naměřené hodnotě.
  * **MeasureType**: Určuje typ měření: 1 - Short (do 1m), 2 - Middle (do 2m), 3 - Long (do 3m) 
  * **Segments**: Nastavení segmentu pro měření senzoru v segmentovém režimu. Pokud Segments není nastaveno, sensor pracuje v rezimu měření vzdálenosti.\
    Jedná se o pole paramentrů pro jednotlivé Segmenty\
    Parametry segmentu:
    * **SegmentId**: název segmentu/pozice.
    * **From**: začátek segmentu v mm.
    * **To**: konec segmentu v mm.
    * **PositionId**: Id pozice. V jednotce se neukládá, ale je duležitý pro CI4 ke spárování segmentu s pozicí    
  ***Example:***\
  TOPIC:
  ```
  I/001001/DIST/040001/SET-CONFIG
  ```
  PAYLOAD režim měření vzdálenosti:
  ```jsonc
  {"MeasurePeriod":50, "Timeout":10, "CountMeasures":4, "MaxDeviation":20, "Offset":0, "MeasureType":2}
  ```
  PAYLOAD Segmentový režim:
  ```jsonc
  {
    "MeasurePeriod":50, "Timeout":10, "CountMeasures":4, "MaxDeviation":20, "Offset":0, "MeasureType":1,
    "Segments":[
      {
      "SegmentId": "RA01",
      "From": 50,
      "To": 150,
      "PositionId": 278
      },
      {
      "SegmentId": "RA02",
      "From": 200,
      "To": 300,
      "PositionId": 279
      }
    ]
  }
  ```
  
* **GET-CONFIG**: Vrátí aktuální nastavení sensoru. Napotřebuje žádne parametry, ale PAYLOAD musí být ve formátu JSON, tedy  {}\
  ***Example:***\
  TOPIC:
  ```
  I/001001/DIST/040001/GET-CONFIG 
  ```
  PAYLOAD:
  ```jsonc
  {}
  ```
* **GET-VALUE**: od verze P2L_26062301NT. Vrátí poslední surové naměřenou vzdálenost v mm a stav senzoru (stejná pole Code/Message/Level jako ALIVE).\
  ***Example:***\
  TOPIC:
  ```
  I/001001/DIST/040001/GET-VALUE
  ```
  PAYLOAD:
  ```jsonc
  {}
  ```
  ***Response*** (topic `O/001001/DIST/040001/GET-VALUE`):
  ```jsonc
  {"Distance": 1234, "Code": 0, "Message": "OK", "Level": "INFO"}
  ```
  Při poruše (např. timeout RS485):
  ```jsonc
  {"Distance": 1234, "Code": -10, "Message": "TIMEOUT", "Level": "INFO"}
  ```
* **GET-ALIVE**: od verze P2L_26070201NT. Okamžitě odešle ALIVE senzoru na topic `D/<UNIT_ID>/DIST/<DEVICE_ID>/ALIVE` bez čekání na periodický interval (5 min). Použije aktuální stav senzoru v paměti (Code/Message/Level). Nepotřebuje parametry.\
  ***Example:***\
  TOPIC:
  ```
  I/001001/DIST/040001/GET-ALIVE
  ```
  PAYLOAD:
  ```jsonc
  {}
  ```
  ***Response:*** ALIVE na topic `D/001001/DIST/040001/ALIVE` (stejný formát jako periodické ALIVE).\
  Chybové odpovědi na `O/001001/DIST/040001/GET-ALIVE`: `unknown ID` (-2), `not DIST sensor` (-3).
* **REPLACE-FROM**:  od verze P2L_26033101NT. Od verze P2L_26061101NT možno nahradit univerzalnim REPLACE-DEVICE v UNIT \
  Používá se pro náhradu vadného. Pokud dane zařízení nefunguje, vymění se fyzicky za nové s unikatnim ID (standartně 127). Tento povel změní ID nového na ID původního. Tím dojde k náhradě poškozeného \
  Parametr:
  * **ID**: Id ( addr) funčního zařízení standartně 127.   \
***Example:***\
    TOPIC:
    ```
    I/001001/DIST/040001/REPLACE-FROM
    ```
    PAYLOAD:
    ```jsonc
    {"Id": 127}
    ```
## DISP - PUMA DISPLAY - kód zařízení 05
***COMANDs:***\
**Broadcast `050000`:** viz [Broadcast](#obecný-formát-nového-requestu-na-jednotku). Podporované příkazy: `SET-DATA`, `SET-CONFIG`.
* **SET-ID**: změna ID displeje , stačí zadat novou adresu displeje, typ device se doplní automaticky v tomto připadě 05   \
  Rozsah adres je 127-246, 247 je defaultni adresa nového disleje, kterou je nutno změnit.\
  Parametr:
  * **Id**\
    ***Example:***\
    TOPIC:
    ```
    I/001001/DISP/050247/SET-ID 
    ```
    PAYLOAD:
    ```jsonc
    {"Id":127}
    ```
* **SET-DATA**: nastavení textu na displeji   \
  Parametr:
  * **Data**: 4 místný text. Od firmware Pum-A v3.01 lze pro zobrazení RS485 adresy displeje použít `"????"` (adresu zobrazí samotné zařízení Pum-A).\
    ***Example:***\
    TOPIC:
    ```
    I/001001/DISP/050247/SET-DATA 
    ```
    PAYLOAD:
    ```jsonc
    {"Data":"AHOJ"}
    ```
    ***Example broadcast (všechny displeje):***\
    TOPIC:
    ```
    I/001001/DISP/050000/SET-DATA
    ```
    PAYLOAD:
    ```jsonc
    {"Data":"AHOJ"}
    ```
    PAYLOAD zobrazení adresy (Pum-A v3.01+):
    ```jsonc
    {"Data":"????"}
    ```
    PAYLOAD smazání dispeje:
    ```jsonc
    {"Data":""}
    ```  
* **SET-CONFIG**: \
  Parametr:
  * **Intesity**: nastavení intensity displeje, rozsah 0-6   \
    ***Example:***\
    TOPIC:
    ```
    I/001001/DISP/050246/SET-CONFIG
    ```
    PAYLOAD:
    ```jsonc
    {"Intensity": 3}
    ```
    ***Example broadcast (všechny displeje):***\
    TOPIC:
    ```
    I/001001/DISP/050000/SET-CONFIG
    ```
    PAYLOAD:
    ```jsonc
    {"Intensity": 3}
    ```
* **GET-ALIVE**: od verze P2L_26070201NT. Okamžitě odešle ALIVE displeje na topic `D/<UNIT_ID>/DISP/<DEVICE_ID>/ALIVE` bez čekání na periodický interval (5 min). Před odesláním provede kontrolu displeje přes RS485 (stejně jako periodické ALIVE). Nepotřebuje parametry.\
  ***Example:***\
  TOPIC:
  ```
  I/001001/DISP/050246/GET-ALIVE
  ```
  PAYLOAD:
  ```jsonc
  {}
  ```
  ***Response:*** ALIVE na topic `D/001001/DISP/050246/ALIVE`.\
  Chybové odpovědi na `O/001001/DISP/050246/GET-ALIVE`: `unknown ID` (-2), `not DISP` (-3).
* **REPLACE-FROM**: funční od verze P2L_26033101NT. Od verze P2L_26061101NT možno nahradit univerzalnim REPLACE-DEVICE v UNIT \
  Používá se pro náhradu vadného. Pokud dane zařízení nefunguje, vymění se fyzicky za nové s unikatnim ID (standartně 247). Tento povel změní ID nového na ID původního. Tím dojde k náhradě poškozeného \
  Parametr:
  * **ID**: Id ( addr) funčního zařízení standartně 247.   \
    ***Example:***\
    TOPIC:
    ```
    I/001001/DISP/050128/REPLACE-FROM
    ```
    PAYLOAD:
    ```jsonc
    {"Id": 247}
    ```
## LEDS - PUMA LEDS - kód zařízení 11
***COMANDs:***\
**Broadcast `110000`:** viz [Broadcast](#obecný-formát-nového-requestu-na-jednotku). Podporované příkazy: `SET-LEDS`, `SET-RGB`, `CLEAR-LEDS`.
* **SET-LEDS**:\
  Rozsvícení Ledek.\
    ```jsonc
    {
       "Style": <number>,
       "Color": <number>
    }
    Style:
    0 : svítí
    1 : bliká
    2 : bliká inverzně
    4 : bliká s 1/2 intenzitou
    5 : bliká s 1/2 intenzitou inverzně
    5 : svicení střídání kombinace barev (využivá color2)
    6 : blikání střídání kombinace barev (využívá color2)
    7 : split svícení NELZE POUŽÍT
    8 : split blikání NELZE POUŽÍT
    
    Color     color     color2
    0          RED      GREEN
    1          GREEN    RED
    2          BLUE     YELLOW
    3          YELLOW   BLUE
    4          PURPLE   WHITE
    5          WHITE    PURPLE
    ```  
    ***Example:***\
    TOPIC:
    ```
    I/001001/LEDS/110247/SET-LEDS
    ```
    PAYLOAD:
    ```jsonc
    {"Style": 0,"Color": 1}
    ```
    ***Example broadcast (všechny LED moduly):***\
    TOPIC:
    ```
    I/001001/LEDS/110000/SET-LEDS
    ```
    PAYLOAD:
    ```jsonc
    {"Style": 0,"Color": 1}
    ```
* **CLEAR-LEDS**:\
  Zhasnutí Ledek, payload může být prázdný.
    ***Example:***\
    TOPIC:
    ```
    I/001001/LEDS/110247/CLEAR-LEDS
    ```
    PAYLOAD:
    ```jsonc
    {}
    ```
    ***Example broadcast (všechny LED moduly):***\
    TOPIC:
    ```
    I/001001/LEDS/110000/CLEAR-LEDS
    ```
    PAYLOAD:
    ```jsonc
    {}
    ```

* **SET-RGB**: \
    Nastaveni konkretní barvy, nepovině i stylu (R, G, B: 0-255) \
    ***Example:***\
    TOPIC:
    ```
    I/001001/LEDS/110247/SET-RGB
    ```
    PAYLOAD:
    ```jsonc
    {"R":255,"G":0,"B":0,"Style":0}
    ```
    ***Example broadcast (všechny LED moduly):***\
    TOPIC:
    ```
    I/001001/LEDS/110000/SET-RGB
    ```
    PAYLOAD:
    ```jsonc
    {"R":255,"G":255,"B":0,"Style":0}
    ```
* **GET-ALIVE**: od verze P2L_26070201NT. Okamžitě odešle ALIVE LED modulu na topic `D/<UNIT_ID>/LEDS/<DEVICE_ID>/ALIVE` bez čekání na periodický interval (5 min). Před odesláním provede kontrolu modulu přes RS485 (stejně jako periodické ALIVE). Nepotřebuje parametry.\
  ***Example:***\
  TOPIC:
  ```
  I/001001/LEDS/110247/GET-ALIVE
  ```
  PAYLOAD:
  ```jsonc
  {}
  ```
  ***Response:*** ALIVE na topic `D/001001/LEDS/110247/ALIVE`.\
  Chybové odpovědi na `O/001001/LEDS/110247/GET-ALIVE`: `unknown ID` (-2), `not LEDS` (-3).
* **REPLACE-FROM**: funční od verze P2L_26061001NT. Od verze P2L_26061101NT možno nahradit univerzalnim REPLACE-DEVICE v UNIT \
  Používá se pro náhradu vadného. Pokud dane zařízení nefunguje, vymění se fyzicky za nové s unikatnim ID (standartně 247). Tento povel změní ID nového na ID původního. Tím dojde k náhradě poškozeného \
  Parametr:
  * **ID**: Id ( addr) funčního zařízení standartně 247.   \
    ***Example:***\
    TOPIC:
    ```
    I/001001/LEDS/110128/REPLACE-FROM
    ```
    PAYLOAD:
    ```jsonc
    {"Id": 247}
    ```
## BTN - PUMA BTN - kód zařízení 06
***COMANDs:***
* **GET-ALIVE**: od verze P2L_26070201NT. Okamžitě odešle ALIVE konkrétního tlačítka na topic `D/<UNIT_ID>/BTN/<DEVICE_ID>/ALIVE` bez čekání na periodický interval (5 min). Použije aktuální stav v paměti. U modulu s více tlačítky se ALIVE odešle jen pro `DEVICE_ID` zadané v topicu (např. `060128`, `061128`). Nepotřebuje parametry.\
  ***Example:***\
  TOPIC:
  ```
  I/001001/BTN/060128/GET-ALIVE
  ```
  PAYLOAD:
  ```jsonc
  {}
  ```
  ***Response:*** ALIVE na topic `D/001001/BTN/060128/ALIVE`.\
  Chybové odpovědi na `O/001001/BTN/060128/GET-ALIVE`: `unknown ID` (-2), `not BTN` (-3).
* **REPLACE-FROM**: funční od verze P2L_26061001NT. Od verze P2L_26061101NT možno nahradit univerzalnim REPLACE-DEVICE v UNIT \
  Používá se pro náhradu vadného. Pokud dane zařízení nefunguje, vymění se fyzicky za nové s unikatním ID (standartně 247). Tento povel změní ID nového na ID původního. Tím dojde k náhradě poškozeného \
  Parametr:
  * **ID**: Id ( addr) funčního zařízení standartně 247.   \
    ***Example:***\
    TOPIC:
    ```
    I/001001/BTN/060128/REPLACE-FROM
    ```
    PAYLOAD:
    ```jsonc
    {"Id": 247}
    ```
