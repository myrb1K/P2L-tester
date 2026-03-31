# P2L32-modul
P2L32-modul může pro ovládání LED používat identický format jako stará verze P2L viz. [P2L-modul](https://github.com/Smart-Product-Solution-s-r-o/p2l-modul/blob/main/README.md) 


# Obecný formát nového requestu na jednotku
Requesty se posilaji na topic ve tvaru: `I/<UNIT_ID>/<DEVICE_TYPE>/<DEVICE_ID>\<COMMAND>`\
**UNIT_ID**: ID jednotky.\
**DEVICE_TYPE**: Typ zařízení ovladaného jednotkou: UNIT, DIST, DISP,BTN, P2L.\
**DEVICE_ID**: ID zařízení ovladaného jednotkou. ID se skláda z kódu pro zařízení 2-cifry a jeho adresy 4-cifry.\
***kód zařízení:***  
  *  00 UNIT
  *  01 P2L
  *  04 DIST
  *  05 DISP
  *  11 LEDS
    
**COMMAND**: Příkazy pro jednotlivá zařízení např. SET-CONFIG, GET-CONFIG, SCAN ..., popsáno dále.

Payload obsahuje požadované parametry ve formátu JSON dle jednotlivých `<COMMAND>`s, popsáno dále.

# Obecný formát nového response na request.
Response se posilaji na topic ve tvaru: `O/<UNIT_ID>/<DEVICE_TYPE>/<DEVICE_ID>\<COMMAND>`\
Payload je ve formátu: `{"Code":"STATUS_CODE","Message":"Message"}`\
**STATUS**: kód chyby. 0 = OK\
**Message**: popis stavu

# Formát pro jednotlivá zařízení
## UNIT - jednotka - kód zařízení 00
***COMANDs:***
* **SET-ID**: změna ID jednotky   \
  Parametr:
  * **Id**\
    ***Example:***\
    TOPIC:
    ```
    I/001001/UNIT/001001/SET-ID 
    ```
    PAYLOAD:
    ```jsonc
    {"Id":1002}
    ```
* **SCAN**: hledání nových zařízení na RS485   \
  Parametr:
  * **Type**: nepovinné, ale doporučené. Určuje jaký typ zařízení se má hledat. Možnosti: DIST, DISP
  * **Id**:  Adresa zařízení. Nepovinné, pokud známe adresu tak doporučené.\
    ***Example:***\
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

* **SET-CONFIG**: Zatím nepodporováno\
* **GET-CONFIG**: Zatím nepodporováno\
## P2L - ovládání LED - kód zařízení 01
***COMANDs:***
* **CMD**:   \
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
* **REPLACE-FROM**:  funční od verze P2L_06033101NT\
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
***COMANDs:***
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
  DeviceId 050000 je možno použít jako broadcast a data se zobrazí na všech dostumných displejích\
  Parametr:
  * **Data**: 4 místný text\
    ***Example:***\
    TOPIC:
    ```
    I/001001/DISP/050247/SET-DATA 
    ```
    PAYLOAD:
    ```jsonc
    {"Data":"AHOJ"}
    ```
    PAYLOAD smazání dispeje:
    ```jsonc
    {"Data":""}
    ```  
* **SET-CONFIG**: \
  DeviceId 050000 je možno použít jako broadcast a parametry se změní na všech dostumných displejích\
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
* **REPLACE-FROM**: funční od verze P2L_06033101NT\
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
***COMANDs:***
* **SET-LEDS**:\
  Rozsvícení Ledek.\
    ```jsonc
    {
       "Style": 0,
       "Color": 1
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
