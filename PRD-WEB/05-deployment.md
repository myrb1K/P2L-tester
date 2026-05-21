# 05 — Deployment topologie

> **Status:** Draft v0.3 · **Datum:** 2026-05-22 · **Parent:** [01-PRD.md](01-PRD.md)
>
> **Update v0.3:** Vercel jako mezikrok vyřazen — nasazení rovnou na firemní server vedle [`ci4gui.smartbox.smartci4.com`](https://ci4gui.smartbox.smartci4.com). Důvody: jediný vývojář (Radek), lokální dev (`flutter run -d chrome` + lokální Mosquitto) pokrývá většinu iterací, mobilní testování přes `flutter run -d web-server --web-hostname 0.0.0.0`, Vercel build pipeline pro Flutter je netriviální, Hobby plán šedá zóna pro komerční use, auth backend by se psal dvakrát (Vercel Functions vs. Node).

Jeden cíl: **firemní server vedle `ci4gui.smartbox.smartci4.com`**.

---

## 1. Cílová topologie

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

→ open question — viz [01-PRD.md §9.3](01-PRD.md#9-open-questions).

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

## 2. Lokální dev workflow

Bez Vercel mezikroku zůstává pro vývoj **jen lokální prostředí**:

| Účel | Příkaz |
|------|--------|
| Desktop iterace | `flutter run -d chrome` |
| Mobilní real-device test (telefon na stejné WiFi) | `flutter run -d web-server --web-hostname 0.0.0.0 --web-port 8080` → na telefonu `http://<IP-počítače>:8080` |
| Lokální broker | `& "C:\Program Files\mosquitto\mosquitto.exe" -c .dev\mosquitto.conf -v` (viz [.dev/README.md](../.dev/README.md)) |
| Build produkce | `flutter build web --release --base-href /` |

Pro responzivita testing dostačuje **Chrome DevTools mobile emulation** (`Ctrl+Shift+M`).

---

## 3. CI/CD (M5)

GitHub Actions job:
- Build `flutter build web` v container.
- `rsync` výsledek na server přes SSH (deploy key v GH Secrets).
- `systemctl reload nginx`.

Pro MVP fáze 5 stačí ruční deploy přes SSH; CI/CD doladíme až později.

---

## 4. Versioning

- Verze v UI: stále z `appVersion` v [main.dart](../lib/main.dart).
- Web verze následuje stejné číslování jako native (žádné `2.65-web`, jen `2.65`).
- Pravidlo "neměnit `appVersion` automaticky" zůstává platné.

---

## 5. Rollback strategie

- Před deploy: `cp -r /var/www/p2l-tester /var/www/p2l-tester.bak`.
- Při potížích: `mv /var/www/p2l-tester.bak /var/www/p2l-tester && systemctl reload nginx`.
- DB migrations (až budou): vždy backward-compatible.

---

## 6. Monitoring (nice-to-have)

- Nginx access log → standardní.
- Backend (Node) → `pm2` logs nebo systemd journal.
- MQTT broker → Mosquitto log.
- Uptime: jednoduchý health endpoint `/api/health` + externí pinger.

---

## 7. Open questions

- [9.3 v 01-PRD.md — doména](01-PRD.md#9-open-questions)
- [9.4 v 01-PRD.md — Mosquitto auth](01-PRD.md#9-open-questions)
- Bude broker na stejném serveru jako web, nebo zůstane samostatně? (viz §1 výše)

---

## 8. Akceptační kritéria M5 (firemní server)

- [ ] Nginx servíruje Flutter web static na zvolené doméně.
- [ ] HTTPS s validním certifikátem (Let's Encrypt).
- [ ] `/api/*` proxy na Node backend funguje.
- [ ] `/ws` proxy na Mosquitto WS funguje.
- [ ] CSP header je nastavený a aplikace neporušuje policy.
- [ ] Systemd service auto-startuje backend po restartu serveru.
- [ ] Rollback skript otestovaný.
