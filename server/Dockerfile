# syntax=docker/dockerfile:1

# Docker image serveru P2L Testeru (auth + databáze jednotek).
#
# Build kontext je `server/` (ne root repa) — image nese jen backend, ne Flutter.
#
#   docker build -t p2l-tester-server:latest server
#
# Dvě stage kvůli native modulům: `better-sqlite3` a `bcrypt` se pro Linux
# musí zkompilovat (prebuild nemusí být k dispozici), takže python3/make/g++
# žijí jen v build stage a do výsledného image se nedostanou. `mysql2`
# (MariaDB) je čistě JS a build nepotřebuje.
#
# Obě stage stojí na stejné base — zkompilované .node soubory z build stage
# proto v runtime stage platí. Při změně base image je nutný rebuild obojího.

# ── Build: závislosti (vč. kompilace native modulů) ─────────────────────────
FROM node:22-bookworm-slim AS deps

WORKDIR /app

RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 make g++ ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Nejdřív jen manifesty — layer s `npm ci` se pak recykluje, dokud se nezmění
# package.json / lock.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

# ── Runtime ────────────────────────────────────────────────────────────────
FROM node:22-bookworm-slim AS runtime

# `P2L_DATA_DIR` míří mimo /app: u SQLite tam leží users.db + units.db, u
# MariaDB jen server.pid. Volume na /data drží data přes rebuild image.
ENV NODE_ENV=production \
    PORT=3001 \
    P2L_DATA_DIR=/data

WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules
COPY package.json package-lock.json ./
COPY server.js ./
COPY db ./db
COPY routes ./routes
COPY scripts ./scripts

# `.env` se do image ZÁMĚRNĚ nekopíruje (JWT secret, heslo k DB) — konfigurace
# jde výhradně env proměnnými kontejneru. Viz .dockerignore.

RUN mkdir -p /data && chown -R node:node /data
VOLUME ["/data"]

USER node
EXPOSE 3001

# Stejný endpoint, kterým naběhnutí serveru pozná i Flutter appka. `fetch` je
# v Node 22 globální, takže v image nemusí být curl ani wget.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3001)+'/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

# Bez npm wrapperu — SIGTERM tak dojde přímo Node procesu a graceful shutdown
# v server.js (zavření DB spojení, smazání PID file) proběhne.
CMD ["node", "server.js"]
