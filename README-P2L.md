# p2l-modul
Nová jednotka P2L

# Posilani requestu na jednotku
Requesty se posilaji na topic ve tvaru: `I/<device_to>/<device_from>/CMD`\
Odpovedi na request jdou na: `O/<device_to>/<request_from>/CMD`\
**device_from**: ID odesilatele\
**device_to**: ID prijemce


# Format requestu
```jsonc
{
  "request_id": "<number>",
  "cmds": [
    {
      "cmd": "<cmd_id>",
      "args": { 
        "<arg_name>": "<arg_value>"
      }
    },
    {
      "cmd": "<cmd_id>",
      "args": {
        "<arg_name>": "<arg_value>"
      }
    }
  ]
}
```

# Format odpovedi na request
```jsonc
{
    "request_id": "<number>", //optional ID requestu, pokud neni, znamena to ze volajici neceka odpoved\
    "status":"<response_code>",
    "data":<data> // optional data
}
```
**response_code**:
`received` = přijato \
`ok` = ok \
`err` = chyba

Jednoduche odpovedi bez dat mozne poslat jako jednoduchy string:
`{ "status": "ok" }` ekvivalentni s `"ok"`


---
1. Zhasnutí všech LEDek na portu nebo celé jednotce
    ```jsonc
    {
      "cmd": "clr_strips",
      "args": { //optional pokud namá args smaže LEDs na všech portech
            "ports": [<number>,<number>, ...] 
      }
    }
    ```  

2. Rozsvícení LEDek
    ```jsonc
    {
      "cmd": "set_leds",
      "args": {
         "port": <number>,
         "x1": <number>,
         "x2": <number>,
         "style_id": <number>,
         "color_id": <number>
              or
         "colors_id": [<number>,<number>,....] 
      }
    }
    style_id:
    0 : svítí
    1 : bliká
    2 : bliká inverzně
    4 : bliká s 1/2 intenzitou
    5 : bliká s 1/2 intenzitou inverzně
    5 : svicení střídání kombinace barev (využivá color2)
    6 : blikání střídání kombinace barev (využívá color2)
    7 : split svícení
    8 : split blikání
    
    color_id  color     color2
    0          RED      GREEN
    1          GREEN    RED
    2          BLUE     YELLOW
    3          YELLOW   BLUE
    4          PURPLE   WHITE
    5          WHITE    PURPLE
    ```  
3. Zhasnutí LEDek
    ```jsonc
    {
      "cmd": "clr_leds",
      "args": {
         "port": <number>,
         "x1": <number>,
         "x2": <number>,
      }
    }
    ```  

4. Nastaveni barvy
    ```jsonc
    {
      "cmd": "set_color",
      "args": {
        "color_id": <number>,
        "red": <number 0-255>
        "green": <number 0-255>
        "blue": <number 0-255>
        "red2": <number 0-255>    //color2 optional defaultně černá
        "green2": <number 0-255>  // využita u stylu 5 (střidaní barev) a 6 (blikání dvou barev)
        "blue2": <number 0-255>   //
        }
    }
    ```
5. Nastaveni ID
    ```jsonc
    {
      "cmd": "set_id",
      "args": {
        "id": <number>
        }
    }
    ```
6. Nastaveni počtu LED na portu
    ```jsonc
    {
      "cmd": "set_led_count",
      "args": {
        "port": <number>,
        "leds": <number>,
        }
    }
    ```
7. Update
    ```jsonc
    {
      "cmd": "update",
      "args": {
        "file_name": <String>
        }
    }
    ```
    ```
8. setup WiFi
    ```jsonc
    {
      "cmd": "set_WiFi",
      "args": {
        "SSID": "STRING"
        "PSWD": "STRING"
        }
    }
    ```
    ```
9. setup Mqtt
    ```jsonc
    {
      "cmd": "set_Mqtt",
      "args": {
        "address": <String>
        "port": <number>  //optional bez - zustane puvodni
        "user": <String>  //optional bez - ""
        "password": <String>  //optional bez - ""
        "certificate": <String> //optional bez defaultni
        "insercure": <Bool> //optional bez false
        }
    }
    ```
    ```
10. upload
    ```jsonc
    {
      "cmd": "upload",
      "args": {
        "name": "STRING"
        }
    }
    ```
    ```
11. restart
    ```jsonc
    {
      "cmd": "restart"
    }
    ```
    ```
11. nastavení jasu
    ```jsonc
    {
      "cmd":"set_brightness",
      "args":{
        "value":30 // 1-100
        }
    }
    ```
    ```
12. nastavení defaultních hodnot 
    ```jsonc
    {
      "cmd":"set_default",
      "args":{
        "param":<String> // "network", "leds", "all"
        }
    }
    ```
    ```
12. získání parametrů - jednotka pošle výpis parametru na topic pro ALIVE
    ```jsonc
    {
      "cmd":"get_param"
    }
    ```
    ```
13. setup Config - všechny parametry jsou volitelné, 
    ```jsonc
    {
      "cmd": "set_Config",
      "args": {
        "SSID": <String>
        "PSWD": <String>
        "mqttAddress": <String>
        "mqttPort": <number>  
        "mqttUser": <String>  
        "mqttPassword": <String>  
        "mqttCert": <String> 
        "mqttInsec": <Bool> 
        "ip":<String>  //"0.0.0.0" vypne statickou IP, přejde na DHCP
        "dns":<String>
        "gateway":<String>
        "subnet":<String>
        }
    }
    ```

## Examples
``` 
{"request_id":-1,"cmds":[{"cmd":"set_id","args":{"id": 491}}]}
``` 
``` 
{"request_id": -1,"cmds":[{"cmd": "clr_strips"}]}
```
``` 
{"request_id": -1,"cmds":[{"cmd": "clr_strips", "args":{"ports": [0]}}]}
```
``` 
{"request_id": -1,"cmds":[{"cmd": "clr_leds","args":{"port": 0,"x1": 0,"x2": 0}}]}
``` 
``` 
{"request_id": -1,"cmds":[{"cmd": "set_leds","args":{"port": 0,"x1": 0,"x2": 0,"style_id": 0,"color_id": 1}}]}
``` 
``` 
{"request_id": -1,"cmds": [{"cmd": "clr_strips","args":{"ports": [0]}}, {"cmd": "set_leds","args": {"port": 0,"x1": 0,"x2": 9,"style_id": 0,"color_id": 0}}, {"cmd": "set_leds","args": {"port": 0,"x1": 10,"x2": 19,"style_id": 1,"color_id": 1}}]}
``` 
``` 
{"request_id": -1,"cmds": [{"cmd": "clr_strips","args": {	"ports": [0]}}, {"cmd": "set_leds","args": {"port": 0,"x1": 0,"x2": 9,"style_id": 0,"color_id": 0}}, {"cmd": "set_leds","args": {"port": 0,"x1": 10,"x2": 19,"style_id": 1,"color_id": 1}}, {"cmd": "set_leds","args": {"port": 0,"x1": 20,"x2": 29,"style_id": 3,"color_id": 2}}]}
``` 
``` 
{ "request_id": -1,"cmds": [{"cmd": "set_led_count","args": {"port": 0,"leds": 60}}]}
``` 
``` 
{"request_id": -1,"cmds":[{"cmd":"update","args":{"file_name": "data/P2L_23091201OT.bin"}}]}
``` 
``` 
{"request_id":-1,"cmds":[{"cmd": "set_color","args":{"color_id": 4,"red": 128,"green": 84,"blue": 0}}]}
``` 
``` 
{"request_id": -1,"cmds":[{"cmd": "set_WiFi","args":{"SSID": "ssid","PSWD": "password"}}]}
``` 
``` 
{"request_id": -1,"cmds":[{"cmd": "set_Mqtt","args":{"address":"mqtt.demo1.smartci4.com","port":8883,"user":"smartbox_user","password":"smartbox2022","insecure":false}}]}
```
```
{"request_id": -1,"cmds":[{"cmd": "set_Config","args":{"SSID":"ssid","PSWD":"password","mqttAddress":"mqtt.demo1.smartci4.com","mqttPort":1883,"mqttUser":"smartbox_user","mqttPassword":"smartbox2022","mqttInsec":false,"ip":"10.0.0.72","dns":"10.0.0.10","gateway":"10.0.0.10","subnet":"255.255.255.0"}}]}
```
``` 
{"request_id": -1,"cmds":[{"cmd": "set_Mqtt","args":{"address":"config.smartbox4you.com","port":8883,"user":"smartbox_user","password":"smartbox2022","insecure":true, "certificate":"-----BEGIN CERTIFICATE-----
MIIDjzCCAnegAwIBAgIUJHunZrpSB++N7Bp8/3vY3lSkRDIwDQYJKoZIhvcNAQEL
BQAwVzELMAkGA1UEBhMCQ1oxEzARBgNVBAgMClNvbWUtU3RhdGUxETAPBgNVBAoM
CFNNQVJUQk9YMSAwHgYDVQQDDBdjb25maWcuc21hcnRib3g0eW91LmNvbTAeFw0y
MzA4MjYwNjQzNTZaFw0zMzA4MjMwNjQzNTZaMFcxCzAJBgNVBAYTAkNaMRMwEQYD
VQQIDApTb21lLVN0YXRlMREwDwYDVQQKDAhTTUFSVEJPWDEgMB4GA1UEAwwXY29u
ZmlnLnNtYXJ0Ym94NHlvdS5jb20wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEK
AoIBAQC3MeEM6hDpq0vuaoS/3Se2E1KWVhFyl+WNME0RECKKsHRJCWxeWbz8OHet
PkKL+oVyYO+hsreYBR1IG4Ao8a5OaYhNjdiwNfI2RCiaUEwmjVi1P3qBz7s2n6hm
026eLi2QZuRZXvMbfmBqMkxU4D0IgIqSXTu4JyQkWk80/eDHLMCFoXMMbKRMX5Ng
/HQQbp2p49DTAiUhPh7LT6Ku5+/QklqxI7TjAXN4qmp5RNgBmVUzMPS3cBg0lD68
2pJVeyROp5vFVasn8R0uKzBRpjCLmTGMQz+KQCkSOSYfKv/r47en4yY5OwEB+QB/
To8fmULqGu4bBbuYc5jZM4TtSZQ5AgMBAAGjUzBRMB0GA1UdDgQWBBQ5lQ10X2lF
2ghQpMASAkEYmAng5jAfBgNVHSMEGDAWgBQ5lQ10X2lF2ghQpMASAkEYmAng5jAP
BgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQCVypn+HzF9zY2GcbMJ
ngjLR6IsD+bIN5JtnmHAJjb3dB1cLO3G8n/Spr17eA5mPc2oJk6vbRsApxBSThb3
HKFazGgMri8ISShJzRFCd19mf3fDVzay6xghBIdMXKgq5SGiy203rhIniECv4pyF
1IyIaSjPaLvv7HHr9aidsiKephY18dGacB1UT6wcbp8P6w5luT4KdZSXNiIE/xyU
8uOvda5NfJzvWnZasru9gpBweDTf8BD22jQbGOtxw9XW4kjOuvjuuIouhDibds9z
03IPKMMBUAcwlPpDGS0y6DeslwwKnSm19bBZn6y8vIT2Jul5RKkKCIUDS+1zjwcj
JNY9
-----END CERTIFICATE-----"}}]}
``` 
``` 
{"request_id": 1,"cmds": [{"cmd": "clr_strips","args":{"ports": [0]}}, {"cmd": "set_leds","args": {"port": 0,"x1": 0,"x2": 9,"style_id": 0,"color_id": 0}}, {"cmd": "set_leds","args": {"port": 0,"x1": 10,"x2": 19,"style_id": 0,"color_id": 1}}, {"cmd": "set_leds","args": {"port": 0,"x1": 20,"x2": 29,"style_id": 0,"color_id": 2}}, {"cmd": "set_leds","args": {"port": 0,"x1": 30,"x2": 39,"style_id": 0,"color_id": 3}}, {"cmd": "set_leds","args": {"port": 0,"x1": 40,"x2": 49,"style_id": 0,"color_id": 4}}, {"cmd": "set_leds","args": {"port": 0,"x1": 50,"x2": 59,"style_id": 0,"color_id": 5}}]}
``` 
``` 
{"request_id":689638,"cmds":[{"cmd":"set_leds","args":{"port":0,"x1":50,"x2":57,"style_id":1,"color_id":2}},{"cmd":"set_leds","args":{"port":0,"x1":42,"x2":49,"style_id":2,"color_id":2}},{"cmd":"set_leds","args":{"port":0,"x1":33,"x2":41,"style_id":0,"color_id":2}},{"cmd":"set_leds","args":{"port":0,"x1":25,"x2":32,"style_id":0,"color_id":2}},{"cmd":"set_leds","args":{"port":0,"x1":16,"x2":24,"style_id":0,"color_id":2}},{"cmd":"set_leds","args":{"port":0,"x1":8,"x2":15,"style_id":0,"color_id":2}},{"cmd":"set_leds","args":{"port":0,"x1":0,"x2":7,"style_id":0,"color_id":1}},{"cmd":"set_leds","args":{"port":1,"x1":50,"x2":57,"style_id":0,"color_id":2}},{"cmd":"set_leds","args":{"port":1,"x1":42,"x2":49,"style_id":0,"color_id":2}},{"cmd":"set_leds","args":{"port":1,"x1":33,"x2":41,"style_id":0,"color_id":2}},{"cmd":"set_leds","args":{"port":1,"x1":25,"x2":32,"style_id":0,"color_id":2}},{"cmd":"set_leds","args":{"port":1,"x1":16,"x2":24,"style_id":0,"color_id":2}},{"cmd":"set_leds","args":{"port":1,"x1":8,"x2":15,"style_id":0,"color_id":2}},{"cmd":"set_leds","args":{"port":1,"x1":0,"x2":7,"style_id":0,"color_id":2}},{"cmd":"set_leds","args":{"port":2,"x1":50,"x2":57,"style_id":0,"color_id":1}},{"cmd":"set_leds","args":{"port":2,"x1":42,"x2":49,"style_id":0,"color_id":2}},{"cmd":"set_leds","args":{"port":2,"x1":33,"x2":41,"style_id":0,"color_id":1}},{"cmd":"set_leds","args":{"port":2,"x1":25,"x2":32,"style_id":0,"color_id":0}},{"cmd":"set_leds","args":{"port":2,"x1":16,"x2":24,"style_id":0,"color_id":2}},{"cmd":"set_leds","args":{"port":2,"x1":8,"x2":15,"style_id":0,"color_id":1}},{"cmd":"set_leds","args":{"port":2,"x1":0,"x2":7,"style_id":0,"color_id":0}}]}
``` 
``` 
{"request_id":1,"cmds":[{"cmd":"restart"}]}
``` 
``` 
{"request_id": 1,"cmds": [{"cmd":"set_brightness","args":{"value":30}}]}
``` 
``` 
{"request_id": -1,"cmds":[{"cmd": "get_param"}]}
``` 
``` 
{"request_id": 1,"cmds": [{"cmd":"set_default","args":{"param":"all"}}]}
``` 
``` 
{"request_id": 1,"cmds":[{"cmd": "set_leds","args":{"port": 0,"x1": 0,"x2": 60,"style_id": 0,"colors_id": [0,0,0,1,1,1]}}]}
``` 
``` 
{"request_id": 1,"cmds":[{"cmd": "set_leds","args":{"port": 0,"x1": 0,"x2": 60,"style_id": 5,"colors_id": [0]}}]}
``` 
``` 
{"request_id": -1,"cmds":[
{"cmd": "set_leds","args":{"port": 0,"x1": 0,"x2": 1000,"style_id": 0,"colors_id": [0,0,0,0,0,0,1,1,1,1,1,1,2,2,2,2,2,2]}},
{"cmd": "set_leds","args":{"port": 1,"x1": 0,"x2": 1000,"style_id": 0,"colors_id": [0,0,0,0,0,0,1,1,1,1,1,1,2,2,2,2,2,2]}},
{"cmd": "set_leds","args":{"port": 2,"x1": 0,"x2": 1000,"style_id": 0,"colors_id": [0,0,0,0,0,0,1,1,1,1,1,1,2,2,2,2,2,2]}},
{"cmd": "set_leds","args":{"port": 3,"x1": 0,"x2": 1000,"style_id": 0,"colors_id": [0,0,0,0,0,0,1,1,1,1,1,1,2,2,2,2,2,2]}},
{"cmd": "set_leds","args":{"port": 4,"x1": 0,"x2": 1000,"style_id": 0,"colors_id": [0,0,0,0,0,0,1,1,1,1,1,1,2,2,2,2,2,2]}},
{"cmd": "set_leds","args":{"port": 5,"x1": 0,"x2": 1000,"style_id": 0,"colors_id": [0,0,0,0,0,0,1,1,1,1,1,1,2,2,2,2,2,2]}},
{"cmd": "set_leds","args":{"port": 6,"x1": 0,"x2": 1000,"style_id": 0,"colors_id": [0,0,0,0,0,0,1,1,1,1,1,1,2,2,2,2,2,2]}},
{"cmd": "set_leds","args":{"port": 7,"x1": 0,"x2": 1000,"style_id": 0,"colors_id": [0,0,0,0,0,0,1,1,1,1,1,1,2,2,2,2,2,2]}}
]}
```
```
{"request_id": -1,"cmds":[{"cmd": "set_Network","args":{"ip":"10.138.150.37","gateway":"10.138.150.33","subnet":"255.255.255.224"
,"dns":"10.138.150.33"}}]}
```

# Prikazy co posila jednotka serveru

1. Alive
Alive se posilá na topic ve tvaru: `A/<server_id>/<device_id>/CMD`\
**server_id**: ID serveru (zatim konfigurovatelne v nastaveni appky)\
**device_id**: ID jednotky (zatim konfigurovatelne v nastaveni appky)\
    ```jsonc
    {
      "cmd": "alive",
      "args": {
        "id": <string>,
        "mac": <string>
        "battery": <number>
      }
    }
    ```

    Server neodpovídá
    
2. Log
Log se posilá na topic ve tvaru: `L/<server_id>/<device_id>/CMD`\
**server_id**: ID serveru (zatim konfigurovatelne v nastaveni appky)\
**device_id**: ID jednotky (zatim konfigurovatelne v nastaveni appky)\
    ```jsonc
    {
      "cmd":"log",
      "args":{
        "id": <string>,
        "level":<string>,
        "text": <string>
    }
    ```
    **level**: DEBUG, INFO, WARNING, ERROR\
    **text**: Popis

    Server neodpovídá
