# 05 — Deployment topologie

> **Status:** Draft v0.1 · **Datum:** 2026-05-21 · **Parent:** [01-PRD.md](01-PRD.md)

Dvě cílové cesty: **Vercel** pro vývoj a staging, **firemní server** pro produkci.

---

## 1. Fáze 1–3: Vercel staging

### Topologie

```
Browser ──HTTPS──> Vercel (Flutter web static)
   │
   ├──HTTPS──> Vercel Function /api/login, /api/me, /api/logout
   │              └── Vercel Postgres (users)
   │
   └──WSS──> wss://<broker>.smartbox.smartci4.com:8884/mqtt
                  (Mosquitto WS listener s TLS)
```

### Frontend (Flutter Web)

- **Build:** `flutter build web --release --base-href /` (nebo `/p2l-tester/` pokud subpath).
- **Output:** `build/web/` → Vercel host jako static.
- **`vercel.json`** (root repa nebo `web/` podsložka):
  ```json
  {
    "buildCommand": "flutter build web --release",
    "outputDirectory": "build/web",
    "rewrites": [
      { "source": "/(.*)", "destination": "/index.html" }
    ]
  }
  ```
  Rewrite je nutný kvůli SPA routingu (jinak F5 na `/units` vrátí 404).

### Vercel + Flutter — instalace flutter SDK

Vercel buildery defaultně Flutter neumí. Volby:

- **A:** Vercel `buildCommand` instaluje Flutter inline:
  ```
  git clone https://github.com/flutter/flutter.git -b stable --depth 1 && \
    ./flutter/bin/flutter build web --release
  ```
- **B:** GitHub Actions build → commit do `gh-pages` branch → Vercel deploy z `gh-pages`.
- **C:** Použít existující Vercel preset / community starter (např. `cirruslabs/flutter` Docker).

→ rozhodnutí v M5.

### Backend (auth)

Vercel Functions (Node.js) pro `/api/login`, `/api/logout`, `/api/me`. Detail v [02-auth-bezpecnost.md §2](02-auth-bezpecnost.md).

DB:
- **Vercel Postgres** (free tier 256 MB stačí).
- nebo **Vercel KV** (Redis) — pro pár uživatelů stačí.

### MQTT broker

Vercel **nehostuje broker**. Broker musí mít WSS endpoint dostupný z internetu s validním certifikátem. CORS musí povolit Vercel preview domény (`*.vercel.app` ideálně + produkční doménu).

---

## 2. Fáze 4: firemní server (produkce)

### Topologie

```
Browser ──HTTPS──> Nginx na firemním serveru
                    ├── /              → Flutter web static (/var/www/p2l-tester/)
                    ├── /api/*         → Node auth backend (localhost:3001)
                    │                       └── SQLite/Postgres
                    └── /ws            → Mosquitto WS (localhost:9001)
                                            (TLS terminace v Nginx)
```

### Varianty hostingu

| Varianta | URL | Pro | Proti |
|----------|-----|-----|-------|
| Subdoména | `p2l.smartbox.smartci4.com` | Čistý oddělený scope, vlastní cert | Nutný DNS + cert per subdoména |
| Path pod ci4gui | `ci4gui.smartbox.smartci4.com/p2l-tester` | Sdílí cert a doménu, jeden login (pokud auth integrace) | `--base-href` build, sdílený CSP |
| Vlastní doména | `p2l-tester.smartbox.cz` | Nezávislé | Další doména k údržbě |

→ open question — viz [01-PRD.md §9.3](01-PRD.md#93-dom%C3%A9na-pro-produk%C4%8Dn%C3%AD-nasazen%C3%AD).

### Nginx config skica

```nginx
server {
  listen 443 ssl http2;
  server_name p2l.smartbox.smartci4.com;

  ssl_certificate /etc/letsencrypt/live/p2l.smartbox.smartci4.com/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/p2l.smartbox.smartci4.com/privkey.pem;

  # Flutter web static
  root /var/www/p2l-tester;
  index index.html;
  location / {
    try_files $uri $uri/ /index.html;
  }

  # Auth backend
  location /api/ {
    proxy_pass http://127.0.0.1:3001;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  }

  # MQTT WebSocket proxy
  location /ws {
    proxy_pass http://127.0.0.1:9001;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "Upgrade";
    proxy_set_header Host $host;
    proxy_read_timeout 86400;
  }

  # CSP
  add_header Content-Security-Policy "default-src 'self'; connect-src 'self' wss://p2l.smartbox.smartci4.com; img-src 'self' data:; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline';" always;
}
```

### Backend (Node) jako systemd service

```ini
# /etc/systemd/system/p2l-tester-auth.service
[Unit]
Description=P2L Tester Auth Backend
After=network.target

[Service]
Type=simple
User=p2l-tester
WorkingDirectory=/opt/p2l-tester-auth
ExecStart=/usr/bin/node server.js
Restart=on-failure
Environment=NODE_ENV=production
Environment=PORT=3001
Environment=JWT_SECRET=<from /etc/p2l-tester/secrets.env>

[Install]
WantedBy=multi-user.target
```

### MQTT broker (Mosquitto) na stejném serveru

Pokud broker neběží zatím na tomto stroji, je k diskusi, jestli:
- **A:** přesunout broker sem (jeden box, méně sítě),
- **B:** nechat broker kde je a Nginx jen WS proxy přes internet → broker (overhead).

→ otázka pro IT / kolegu.

---

## 3. CI/CD

### Vercel (Fáze 1–3)

- Push do `WEB` branch → automatic Vercel deploy do preview URL.
- Vercel preview URL přijde na PR / Slack.
- Pro produkci na firemní server: po merge `WEB` → `main` ručně.

### Firemní server (Fáze 4)

- **A (preferováno):** GitHub Actions job:
  - Build `flutter build web` v container.
  - `rsync` výsledek na server přes SSH (deploy key v GH Secrets).
  - `systemctl reload nginx`.
- **B:** ruční deploy přes SSH (pro MVP fáze 4 stačí).

---

## 4. Versioning

- Verze v UI: stále z `appVersion` v [main.dart](../lib/main.dart).
- Web verze následuje stejné číslování jako native (žádné `2.65-web`, jen `2.65`).
- Pravidlo "neměnit `appVersion` automaticky" zůstává platné.

---

## 5. Rollback strategie

### Vercel

Vercel drží předchozí deploy → 1-click rollback v UI.

### Firemní server

- Před deploy: `cp -r /var/www/p2l-tester /var/www/p2l-tester.bak`.
- Při potížích: `mv /var/www/p2l-tester.bak /var/www/p2l-tester && systemctl reload nginx`.
- DB migrations (až budou): vždy backward-compatible.

---

## 6. Monitoring (nice-to-have)

- **Vercel:** built-in analytics (free).
- **Firemní server:**
  - Nginx access log → standardní.
  - Backend (Node) → `pm2` logs nebo systemd journal.
  - MQTT broker → Mosquitto log.
  - Uptime: jednoduchý health endpoint `/api/health` + externí pinger.

---

## 7. Open questions

- [9.3 v 01-PRD.md — doména](01-PRD.md#93-dom%C3%A9na-pro-produk%C4%8Dn%C3%AD-nasazen%C3%AD)
- [9.4 v 01-PRD.md — Mosquitto auth](01-PRD.md#94-mosquitto-userpassword-vs-anonymous)
- Bude broker na stejném serveru jako web, nebo zůstane samostatně? (viz §2 výše)

---

## 8. Akceptační kritéria

### Vercel (M5)

- [ ] `flutter build web` projde v Vercel buildu.
- [ ] Web je dostupný na Vercel preview URL pod HTTPS.
- [ ] SPA routing funguje (F5 na sub-route nehází 404).
- [ ] Login přes Vercel Functions funguje.
- [ ] WSS connect na testovací broker funguje z Vercel preview.

### Firemní server (M6)

- [ ] Nginx servíruje Flutter web static na zvolené doméně.
- [ ] HTTPS s validním certifikátem (Let's Encrypt).
- [ ] `/api/*` proxy na Node backend funguje.
- [ ] `/ws` proxy na Mosquitto WS funguje.
- [ ] CSP header je nastavený a aplikace neporušuje policy.
- [ ] Systemd service auto-startuje backend po restartu serveru.
- [ ] Rollback skript otestovaný.
