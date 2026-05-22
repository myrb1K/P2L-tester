# 01 — PRD: P2L Tester Web

> **Status:** Draft v0.8 · **Datum:** 2026-05-22 · **Autor:** Radek Brym · **Branch:** `WEB`
>
> **Změny v v0.8:**
> - **M4.5 ✅ dokončeno 2026-05-22** — Admin UI ve Flutter pro správu uživatelů z aplikace (místo SSH/CLI). Strukturální fix: `AuthGate` přesunut nad `MaterialApp.Navigator` přes `builder:` parametr — bez toho `_AuthScope` InheritedWidget nebyl viditelný pro routy pushnuté přes `Navigator.push` (Settings, AdminUsersScreen). Sdílená user-management knihovna `server/db/users.js` (DRY guardy mezi admin endpointy a CLI skripty). Skip splash na webu (LoginScreen už má branding). Rate limit zvolněn z 5 na 50/IP/15min. Všech 7 akceptačních kritérií [02-auth-bezpecnost.md §9.2](02-auth-bezpecnost.md#92-m45-admin-ui--dokon%C4%8Deno-2026-05-22) odškrtnutých.
>
> **Změny v v0.7:**
> - **M4 ✅ kód hotový a lokálně ověřený** (commits `93874d0`, `6a14043`, `a747ea9` na `web` větvi). Node + SQLite + JWT backend v `server/`, LoginScreen + AuthGate ve Flutteru, CLI skripty pro správu uživatelů. Všech 11 akceptačních kritérií [02-auth-bezpecnost.md §9.1](02-auth-bezpecnost.md#91-m4-login--cli-správa) odškrtnutých. Produkční deploy (Secure cookie flag, Nginx, systemd) řeší až M5.
>
> **Změny v v0.6:**
> - **Varianta A pro auth ROZHODNUTA** (vlastní Node + SQLite + JWT v httpOnly cookie). Detaily viz [02-auth-bezpecnost.md §3](02-auth-bezpecnost.md#3-rozhodnutí-2026-05-22).
> - **M4 rozdělen na M4 + M4.5**:
>   - **M4** = login pro běžné uživatele, správa přes CLI skripty na serveru. `is_admin` sloupec + `isAdmin` JWT claim už od první migrace.
>   - **M4.5** = volitelně později; `AdminUsersScreen` ve Flutteru pro správu uživatelů z UI. Pure additive change, žádná DB migrace.
> - Detailní spec v [02-auth-bezpecnost.md §6](02-auth-bezpecnost.md#6-admin-správa-uživatelů--m4--m45).
>
> **Změny v v0.5:**
> - **M2 plně dokončeno i proti produkčnímu brokeru** `wss://mqtt.smartbox.smartci4.com:443/mqtt` (WSS na 443, SSL/TLS + WebSocket s path `/mqtt`). Všech 6 akceptačních kritérií [03-mqtt-web.md §10](03-mqtt-web.md#10-akceptační-kritéria) odškrtnutých — discovery, refresh reconnect i network-drop reconnect ověřeny live.
> - Open question [§9.2](#9-open-questions) (broker pro web testing) tím dořešená — produkční broker s WSS je živý.
>
> **Změny v v0.4:**
> - **Vercel jako mezikrok vyřazen** — nasazujeme rovnou na firemní server vedle `ci4gui`. Důvody: jediný vývojář, lokální dev pokrývá iterace, Vercel build pipeline pro Flutter je netriviální, Hobby plán šedá zóna, auth backend by se psal 2× (Vercel Functions vs. Node).
> - **5 milestones místo 6** (M4 staging deploy spadl).
> - Placeholder login zrušen — M4 píše rovnou plnohodnotnou auth.
>
> **Změny v v0.3 (M1–M3 ✅):**
> - M1 web build, M2 MQTT WSS, M3 responzivita dokončeny.
>
> **Změny v v0.2:**
> - Pořadí fází přeskupeno — auth jako poslední milestone, MQTT a responzivita dřív.
> - Responzivita zkrácena na verify-only (APK i zmenšené Windows okno už fungují).

Hlavní dokument PRD. Detailní návrhy jsou v sourozeneckých dokumentech:
- Auth a security → [02-auth-bezpecnost.md](02-auth-bezpecnost.md)
- MQTT na webu → [03-mqtt-web.md](03-mqtt-web.md)
- Responzivita → [04-responzivita.md](04-responzivita.md)
- Deployment → [05-deployment.md](05-deployment.md)

---

## 1. Cíl projektu

Rozšířit P2L Tester (dosud Windows / Android) o **webovou variantu**, která:

1. Poběží v prohlížeči (desktop + mobil) bez instalace.
2. Je **responzivní** — použitelná jak na desktopu, tak na mobilu.
3. Je **chráněná uživatelským přihlášením** (admin zakládá účty, žádná self-registrace).
4. Komunikuje s MQTT brokery přes **WebSockets** (broker už WS endpoint má povolený).
5. Nasadí se na **firemní server** vedle [`ci4gui.smartbox.smartci4.com`](https://ci4gui.smartbox.smartci4.com).

### Co tento projekt **není**

- Není to refactor existujícího Flutter kódu na jiný framework. Cílíme na **Flutter Web** build stejného codebase.
- Není to nová verze MQTT protokolu. Topicy a payloady zůstávají identické.
- Nezavádíme tenant isolaci, role ani per-user data. Po přihlášení **všichni uživatelé vidí to samé**.

---

## 2. Cílový stav a fázování (v0.4)

Pořadí je voleno tak, aby **nejvyšší technické riziko (MQTT WSS)** šlo nejdřív a **auth byla naposledy** těsně před produkcí.

### Fáze 1 — Web build běží lokálně
- `flutter build web` projde bez chyb.
- Aplikace se otevře v Chrome bez crashe (zatím bez MQTT, bez auth).
- Identifikace `dart:io` použití mimo `MqttService` a zabalení do `kIsWeb` guards.

### Fáze 2 — MQTT přes WebSockets (high risk milestone)
- `MqttClientFactory` s conditional importem (`MqttServerClient` ↔ `MqttBrowserClient`).
- Lokální Mosquitto s WS listenerem → connect z `flutter run -d chrome`.
- Lokální WSS přes `mkcert` → ověřit, že TLS endpoint funguje.
- Otestovat na reálném produkčním brokeru (subscribe + publish).

Detaily viz [03-mqtt-web.md](03-mqtt-web.md).

### Fáze 3 — Responzivita (verify only)
- Smoke test v Chrome DevTools device emulation (iPhone, Pixel).
- Opravit edge cases specifické pro browser (klávesnice, hover).
- **Žádný velký refactor — APK už je responzivní.**

Detaily viz [04-responzivita.md](04-responzivita.md).

### Fáze 4 — Plnohodnotná auth (rozdělená na M4 + M4.5)

**M4 — login pro běžné uživatele (povinné pro produkci):**
- Login obrazovka (Flutter) před přístupem ke zbytku aplikace.
- Backend `/api/login`, `/api/logout`, `/api/me` (Node.js + JWT v httpOnly cookie).
- Session persistence, logout button, rate limiting na login endpoint.
- Schéma DB obsahuje `is_admin` od první migrace; JWT obsahuje `isAdmin` claim.
- Initial admin se zakládá z env při prvním startu (`INITIAL_ADMIN_USER` / `INITIAL_ADMIN_PASSWORD`).
- Správa uživatelů v M4 = CLI skripty na serveru (`add-user.js`, `del-user.js`, `reset-pwd.js`).
- Native APK / Windows EXE login NEPOUŽÍVAJÍ (`kIsWeb` guard).

**M4.5 — Admin UI ve Flutteru (volitelné, dělané později):**
- `AdminUsersScreen` se seznamem + dialogy pro přidat / reset hesla / smazat.
- Backend admin endpointy `/api/admin/users` (CRUD) chráněné middleware `requireAdmin`.
- Položka "Administrace uživatelů" v Settings, viditelná jen pro `isAdmin=true` uživatele.
- Pure additive change — žádná DB migrace, existující uživatelé / session se nemění.

Detaily a kompletní akceptační kritéria viz [02-auth-bezpecnost.md](02-auth-bezpecnost.md).

### Fáze 5 — Produkční nasazení na firemní server
- Deploy na server kde běží `ci4gui`.
- HTTPS s validním certifikátem (Let's Encrypt nebo firemní CA).
- Reverse proxy (Nginx) pro statický web + proxy `/ws` na Mosquitto + `/api/*` na Node backend.
- Systemd service pro auth backend.
- Rollback strategie (záloha předchozí verze před deploy).

Detaily viz [05-deployment.md](05-deployment.md).

---

## 3. Funkční požadavky

### 3.1 Paritní funkce s desktop/mobile verzí

Webová varianta musí podporovat **všechny současné funkce** P2L Testeru:

- Discovery jednotek (ALIVE topic subscribe)
- Manuální přidání ID jednotky
- Detail jednotky (IP, MAC, firmware, baterie)
- LED test pattern (color, on/off duration, port selection)
- Konfigurace devices (ADD/RECREATE-DEVICES)
- REPLACE-FROM workflow pro výměnu vadného čipu
- Hromadná změna brokera / WiFi (`BulkConfigMenu`)
- Hromadný OTA firmware update
- Šablony zařízení (vč. export/import)
- Profily brokerů (přidávání, reorder, mazání)
- Export/import seznamu ID jednotek

### 3.2 Webově specifické funkce

- **Persistent storage**: `SharedPreferences` na webu používá `localStorage` — funguje out-of-the-box. Ověřit limity (~5 MB / origin).
- **File picker pro import/export**: `file_picker` a `share_plus` mají web implementaci, ale chování je odlišné (download místo share, browse místo path). Otestovat.
- **Clipboard**: kopírování ID/IP přes browser clipboard API.
- **Window title**: nastavit `<title>` v `web/index.html`.
- **Favicon + PWA manifest**: použít existující `Smartboxlogo.png`.

### 3.3 Autentizace

Krátký souhrn (detaily v [02-auth-bezpecnost.md](02-auth-bezpecnost.md)):

- Login obrazovka před přístupem ke zbytku aplikace.
- Po úspěšném loginu se zobrazí standardní `HomeScreen`.
- **Žádné role** — všichni přihlášení mají plný přístup.
- **Žádná self-registrace** — účty zakládá admin.
- Session timeout: 7 dní s "remember me", jinak 24 h.

---

## 4. Technický stack

| Vrstva | Volba |
|--------|-------|
| Frontend | **Flutter Web** (existující codebase, target `web`) |
| MQTT klient | `mqtt_client` — `MqttServerClient` na native, `MqttBrowserClient` na webu (conditional import) |
| Auth backend | Node.js (Express) + JWT v httpOnly cookie (nebo integrace s ci4gui auth) |
| DB | SQLite (vývoj) / Postgres (prod) — vlastní `users` tabulka |
| Hosting (vývoj) | Lokální (`flutter run -d chrome`) + lokální Mosquitto (viz [.dev/](../.dev/)) |
| Hosting (prod) | Firemní server (Nginx + Node + Mosquitto WS) |
| CI/CD | GitHub Actions: `flutter build web` → `rsync` na server přes SSH (M5+) |

Detail MQTT klienta na webu viz [03-mqtt-web.md](03-mqtt-web.md).
Detail deployment topologie viz [05-deployment.md](05-deployment.md).

---

## 5. Out of scope (zatím)

- **Multi-tenant / per-user data isolation** — všichni vidí všechno.
- **Role (admin/technik/read-only)** — všichni přihlášení mají plný přístup.
- **OAuth / SSO s Google/Microsoft** — jen username/password.
- **Password reset přes email** — admin reset přes DB / admin obrazovku.
- **2FA / TOTP** — nice-to-have pro pozdější iteraci.
- **PWA offline mode** — appka stejně bez brokeru nic nedělá, offline cache nemá smysl.
- **Audit log** — odsunuto do fáze 4+.

---

## 6. Risks summary

Detailní rizika jsou v jednotlivých dokumentech podle oblasti. Zde top 5 napříč:

| Risk | Pravděpodobnost | Dopad | Kam pro detail |
|------|-----------------|-------|----------------|
| Mixed content: HTTPS site ↔ ws:// broker | Vysoká | App nefunguje | [03-mqtt-web.md](03-mqtt-web.md) |
| Browser CORS na MQTT WS endpoint | Vysoká | Connect selže | [03-mqtt-web.md](03-mqtt-web.md) |
| `dart:io` použití v existujícím kódu | Střední | Runtime chyby na webu | [03-mqtt-web.md](03-mqtt-web.md) |
| ci4gui auth integrace komplikovanější než vlastní backend | Střední | Posun harmonogramu | [02-auth-bezpecnost.md](02-auth-bezpecnost.md) |
| Refresh page = ztráta MQTT connection a in-memory state | Jistota | UX issue | [03-mqtt-web.md](03-mqtt-web.md) |

---

## 7. Akceptační kritéria MVP

- [ ] Web build běží na firemním serveru pod HTTPS.
- [ ] Nepřihlášený uživatel vidí jen login obrazovku, žádný jiný route.
- [ ] Po loginu existuje session, refresh stránky uživatele neodhlásí.
- [ ] Logout button funguje a invaliduje session.
- [ ] Aplikace se připojí přes WSS k brokeru s validním certem.
- [ ] Discovery jednotek funguje (ALIVE topic).
- [ ] LED test pattern funguje na vybrané jednotce.
- [ ] Hromadné konfigurace (broker / WiFi / firmware) projdou bez chyb.
- [ ] Layout je použitelný na 360 px šířce (žádný horizontální scroll).
- [ ] Tap targety na mobilu ≥ 44 px.
- [ ] Smartbox logo a název v záhlaví.

---

## 8. Out-of-scope decisions / commitments

- Všichni uživatelé vidí to samé (žádné role).
- Admin zakládá účty manuálně, žádná self-registrace.
- Nasazení rovnou na firemní server (žádný staging mezikrok).

---

## 9. Open questions

### 9.1 Integrace s `ci4gui` auth

Má `ci4gui.smartbox.smartci4.com` REST API / JWT endpoint, který by P2L Tester mohl konzumovat? Pokud ano:
- Ušetříme implementaci vlastního auth backend.
- Uživatelé budou mít jeden login pro obě appky.

**Akce:** zjistit s kolegou, jak je `ci4gui` postavený a jestli má SSO-friendly auth.

### 9.2 Konkrétní broker pro web testing — ✅ DOŘEŠENO (2026-05-22)

Produkční broker `mqtt.smartbox.smartci4.com:443` má WSS endpoint na path `/mqtt` s validním certem. Profil `SM-SMARTBOX-WSS` (SSL/TLS + WebSocket) připojení potvrdil, discovery jednotek funguje.

### 9.3 Doména pro produkční nasazení

- Subdoména `p2l.smartbox.smartci4.com`?
- Path pod `ci4gui` (`ci4gui.../p2l-tester`)?
- Jiné?

### 9.4 Mosquitto user/password vs. anonymous

Má broker zapnutý `allow_anonymous false`? Pokud ano, jsou MQTT credentials per-user (uvedené při loginu) nebo shared (zaháknuté v backendu)?

### 9.5 Branding a launch

- Loga, název v záhlaví, favicon — použít existující `Smartboxlogo.png`?
- Verze v UI — z `appVersion` v [`main.dart`](../lib/main.dart) (stávající mechanismus stačí).

---

## 10. Milestones (v0.6 — M1–M3 ✅, M4 rozdělen na M4 + M4.5)

| # | Milestone | Stav | Pozn. |
|---|-----------|:----:|-------|
| M1 | `flutter build web` projde, app se otevře v Chrome | ✅ | Web build prošel out-of-the-box; `kIsWeb` guards už v kódu; brand polish v `web/index.html` + `manifest.json` |
| M2 | MQTT WS klient přes `MqttBrowserClient`, connect k lokálnímu **i produkčnímu** brokeru | ✅ | `MqttClientFactory` s conditional importem; klíčový fix: `websocketProtocols = ['mqtt']`; E2E ověřeno proti lokálnímu Mosquitto + ALIVE roundtrip; **2026-05-22 dokončeno i proti `wss://mqtt.smartbox.smartci4.com:443/mqtt` — discovery 3 jednotek, refresh reconnect, network-drop reconnect (viz [03-mqtt-web.md §9.0](03-mqtt-web.md#90-ověření-proti-produkčnímu-brokeru-2026-05-22))** |
| M3 | Responzivita smoke test | ✅ | Pixel 7 + iPad Mini OK bez úprav; iPhone SE (375px) skipnuto (relevance) |
| **M4** | Login (Varianta A) — Node backend + SQLite + LoginScreen + session + CLI správa uživatelů | ✅ | **Kód hotový a lokálně ověřený 2026-05-22** (commits `93874d0`, `6a14043`, `a747ea9`). Backend v `server/`, Flutter v `lib/services/auth_*` + `lib/screens/{auth_gate,login_screen}.dart`, kIsWeb guard v `main.dart`. Initial admin `radek` seed z env funguje, CLI skripty fungují vč. last-admin guardu. Smoke test: login → /api/me → logout → MQTT WSS discovery dál funguje. Detail v [02-auth-bezpecnost.md](02-auth-bezpecnost.md) |
| **M4.5** | Admin UI ve Flutteru — `AdminUsersScreen` + admin endpointy v backendu | ✅ | **Dokončeno 2026-05-22.** Admin endpointy [server/routes/admin.js](../server/routes/admin.js), [lib/screens/admin_users_screen.dart](../lib/screens/admin_users_screen.dart), sdílená lib [server/db/users.js](../server/db/users.js). Strukturální fix: AuthGate přes MaterialApp.builder pro route-isolation InheritedWidgetu. |
| **M5** | Produkční deploy na firemní server (Nginx, HTTPS, systemd) | čeká M4 | Včetně WS endpointu na brokeru ([§9.4](#9-open-questions)) |

---

**Příští krok:** M4 i M4.5 hotové → M5 (produkční deploy na firemní server). Blokované na dořešení open questions §9.3 (doména) a §9.4 (Mosquitto credentials s IT/kolegou).
