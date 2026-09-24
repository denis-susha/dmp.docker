# dmp.docker

Docker Compose infrastructure for **DMP**, a marketplace for digital goods and data with crypto payments.
This repository has no application code. It holds the Compose files, the nginx reverse proxy and the
Redis configs that build and wire together the other DMP repositories: the .NET API and background
jobs, the Next.js storefront and the seller SPA. It also runs the [Bitcart](https://bitcart.ai) crypto
payment processor.

## Tech stack

| Component | Image / version |
| --- | --- |
| Docker Compose | v2.24+ (uses `env_file.required`, `additional_contexts`) |
| PostgreSQL (DMP) | `postgres:16-bookworm` |
| Redis Stack (DMP cache, RediSearch + RedisJSON) | `redis/redis-stack:7.4.0-v8` |
| MinIO (S3 storage) | `quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z` |
| nginx (reverse proxy + seller SPA) | `nginx:1.30`, seller built with `node:24-alpine` |
| .NET services | built from their repos (`mcr.microsoft.com/dotnet/aspnet:10.0` / `runtime:10.0`, non-root `app` user) |
| Storefront | built from `dmp.client` (Next.js, port 3000) |
| Bitcart | `bitcart/bitcart:0.9.0.0`, `bitcart/bitcart-admin:0.9.0.0`, coin daemons built from vendored sources |
| Bitcart database / cache | `postgres:12-alpine`, `redis:8-alpine` |
| Dev tools | `dpage/pgadmin4:9`, `axllent/mailpit:v1` |

## Project structure

```
compose.yaml                  DMP core stack: databases, Redis, MinIO, .NET services, storefront, nginx
compose.override.dev.yaml     development: pgAdmin, Mailpit, Redis on localhost, .NET user secrets
compose.override.prod.yaml    production: environment names, production Redis config
compose.bitcart.yml           Bitcart stack: admin, backend, worker, coin daemons, Postgres, Redis
*.env.example                 templates of the --env-file files (copy to *.env)
env/*.env.example             optional per-service runtime settings for the .NET services
prepare-build.sh              clones missing sibling repositories from GitHub
nginx/
  Dockerfile                  builds the dmp.seller SPA and the nginx image
  nginx.conf                  global settings (Cloudflare real IP, gzip, TLS sessions, log format)
  templates/*.conf.template   one server file per public host, rendered with DMP_DOMAIN at start
  include/                    shared snippets (TLS, proxy defaults, robots, access list, MIME types)
  certs/                      (git-ignored) cert.pem + key.pem for all HTTPS hosts
redis/
  dev-loc-redis.conf          Redis Stack config for development
  master-redis.conf           Redis Stack config for production
coins/
  *.Dockerfile                Bitcart coin daemon images (btc, ltc, bch, eth, bnb, matic, trx, xmr)
  bitcart/                    vendored Bitcart 0.9.0.0 sources (MIT, see coins/bitcart/LICENSE)
```

## System topology

All containers join one bridge network, `dmp-ntw`. Compose prefixes it with the project name, e.g.
`dmpdocker_dmp-ntw`. Only nginx listens on public ports. The databases are bound to `127.0.0.1`, and
the dev tools use their own ports (see the table below). The services talk to each other by container
or service name.

```
                 Internet / Cloudflare
                          │ 80, 443
                   ┌──────▼──────┐
                   │  dmp-nginx  │  serves the seller SPA itself
                   └──┬──┬──┬──┬─┘
   ${DMP_DOMAIN} ─────┘  │  │  └──── bitcart.* ──► bitcart-admin:4000 / bitcart-backend:8000
   api.* ────────────────┘  └─ s3.*, minioui.*, jobserver.*
     │                          │        │           │
dmp-api-web:80   dmp-ui-client:3000   dmp-minio:9000/9001   dmp-job-server:80
     │
     ├─ postgres-dmp (dmp-postgres):5432   dmp-db-billing:5432   dmp-redis:6379
     └─ http://bitcart-backend:8000 ──► coin daemons (bitcart-bitcoin:5000, ...), bitcart-database, bitcart-redis
dmp-job-invoiceworker ── ws://bitcart-backend:8000/ws/invoices, http://dmp-api-web:80
dmp-job-trxworker ────── http://bitcart-backend:8000/invoices, both databases
```

### Services and ports

DMP core (`compose.yaml` + override):

| Service | Container / DNS name | Container port(s) | Published on host | Purpose |
| --- | --- | --- | --- | --- |
| `postgres-dmp` | `dmp-postgres` | 5432 | `127.0.0.1:5442` | Main marketplace database (`dmarketplace`) |
| `billing-db-dmp` | `dmp-db-billing` | 5432 | `127.0.0.1:5452` | Billing database (`billing`) |
| `redis-dmp` | `dmp-redis` | 6379 | dev only: `127.0.0.1:6379` | Cache, search indexes, pub/sub |
| `minio-dmp` | `dmp-minio` | 9000 (S3 API), 9001 (console) | – (through nginx) | Product files and images |
| `api.web-dmp` | `dmp-api-web` | 80 | – (through nginx) | Public REST API + SignalR `/paymenthub` |
| `job.invoiceworker-dmp` | `dmp-job-invoiceworker` | – | – | Follows Bitcart invoices over WebSocket |
| `job.trxworker-dmp` | `dmp-job-trxworker` | – | – | Processes payment transactions |
| `job.server-dmp` | `dmp-job-server` | 80 | – (through nginx) | Hangfire jobs and e-mails, dashboard |
| `client-ui-dmp` | `dmp-ui-client` | 3000 | – (through nginx) | Next.js storefront |
| `nginx-dmp` | `dmp-nginx` | 80, 443 | `80`, `443` | Reverse proxy, TLS, seller SPA |
| `pgadmin-dmp` (dev) | `pgadmin-dmp` | 80 | `5155` | pgAdmin |
| `mailpit-dmp` (dev) | alias `mailhog-dmp` | 1025 (SMTP), 8025 (UI) | `1025`, `8025` | Catches outgoing e-mail |

Bitcart (`compose.bitcart.yml`, nothing is published on the host):

| Service / container | Port | Purpose |
| --- | --- | --- |
| `bitcart-admin` | 4000 | Admin panel (served at `/admin`) |
| `bitcart-backend` | 8000 | Bitcart API (served at `/api`), runs DB migrations at start |
| `bitcart-worker` | 9020 | Background tasks |
| `bitcart-bitcoin` | 5000 | BTC daemon |
| `bitcart-litecoin` | 5001 | LTC daemon |
| `bitcart-ethereum` | 5002 | ETH daemon |
| `bitcart-bitcoincash` | 5004 | BCH daemon |
| `bitcart-binancecoin` | 5006 | BNB (BSC) daemon |
| `bitcart-polygon` | 5008 | MATIC (Polygon) daemon |
| `bitcart-tron` | 5009 | TRX daemon |
| `bitcart-monero` | 5011 | XMR daemon |
| `bitcart-database` | 5432 | PostgreSQL 12 for Bitcart (trust auth, internal only) |
| `bitcart-redis` | 6379 | Redis for Bitcart |

### Public hosts (nginx)

`DMP_DOMAIN` sets the base domain, e.g. `example.com`. Every host also accepts the `loc.`, `dev<N>.`
and `stage*.` prefixes, e.g. `loc.api.example.com`. Plain HTTP requests are redirected to HTTPS, and
`www.` hosts are redirected to the bare host.

| Host | Upstream | Access |
| --- | --- | --- |
| `${DMP_DOMAIN}` | `dmp-ui-client:3000`; `/api/` → `dmp-api-web:80` | public |
| `api.${DMP_DOMAIN}` | `dmp-api-web:80` (WebSocket at `/paymenthub`) | public |
| `seller.${DMP_DOMAIN}` | static seller SPA from the nginx image | public |
| `s3.${DMP_DOMAIN}` | `dmp-minio:9000` | public |
| `minioui.${DMP_DOMAIN}` | `dmp-minio:9001` | `include/restrict-access.conf` |
| `jobserver.${DMP_DOMAIN}` | `dmp-job-server:80` | `include/restrict-access.conf` |
| `bitcart.${DMP_DOMAIN}` | `/admin` → `bitcart-admin:4000`, `/api/` and `/ws/` → `bitcart-backend:8000` | `include/restrict-access.conf` |

Requests for unknown hosts are dropped (`444`, TLS handshake rejected). nginx takes the real client
IP from `CF-Connecting-IP` for Cloudflare edge addresses. TLS uses the Mozilla "intermediate"
profile (TLS 1.2/1.3) with HTTP/2. `robots.txt` blocks crawlers on the API, S3 and seller hosts, and
`loc.`/`dev.`/`stage.` storefront hosts send `X-Robots-Tag: noindex, nofollow`.

### Volumes

| Volume | Used by | Notes |
| --- | --- | --- |
| `postgres-dmp-data` | `postgres-dmp` | named |
| `dmp-db-billing-data` | `billing-db-dmp` | named |
| `./redis/redisdata` | `redis-dmp` | bind mount (RDB + AOF) |
| `./minio/data` | `minio-dmp` | bind mount (all stored objects) |
| `bitcart_datadir`, `backup_datadir` | `bitcart-backend`, `bitcart-worker` | named |
| `dbdata` | `bitcart-database` | named |
| `bitcoin_datadir`, `litecoin_datadir`, `ethereum_datadir`, `bitcoincash_datadir`, `binancecoin_datadir`, `polygon_datadir`, `tron_datadir`, `monero_datadir` | coin daemons | named, contain the wallets |
| `./plugins/*` | `bitcart-backend`, `bitcart-worker` | Bitcart plugins |

Compose prefixes named volumes with the project name. The project name defaults to the directory
name (`dmp.docker` → `dmpdocker`). If you move an existing deployment to a new directory, set
`COMPOSE_PROJECT_NAME` in the env file or pass `-p <old-name>`. Otherwise Compose creates new, empty
volumes.

## Configuration

### Compose variables (`--env-file`)

| File (copy from `*.example`) | Used with |
| --- | --- |
| `development.env` | `compose.yaml` + `compose.override.dev.yaml` |
| `production.env` | `compose.yaml` + `compose.override.prod.yaml` |
| `loc.bitcart.env` | `compose.bitcart.yml` on a developer machine (test networks, `loc.` hosts) |
| `development.bitcart.env` | `compose.bitcart.yml` on the shared dev server (test networks, `dev.` hosts) |
| `production.bitcart.env` | `compose.bitcart.yml` in production (main networks) |

Git ignores all real `*.env` files. Variables marked "yes" must be set, and Compose stops with an
error if one is missing.

| Variable | Required | Description |
| --- | --- | --- |
| `DMP_DOMAIN` | yes | Base domain used in the nginx server names |
| `POSTGRES_DMP_USER` / `POSTGRES_DMP_PASSWORD` / `POSTGRES_DMP_DB` | yes | Main database credentials and name (`dmarketplace`) |
| `POSTGRES_DMP_BILLING_USER` / `POSTGRES_DMP_BILLING_PASSWORD` / `POSTGRES_DMP_BILLING_DB` | yes | Billing database credentials and name (`billing`) |
| `REDIS_PASSWORD` | yes | Redis password, also passed to `dmp.api.web` and `dmp.job.server` |
| `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` | yes | MinIO root credentials (password at least 8 characters) |
| `PGADMIN_DEFAULT_EMAIL` / `PGADMIN_DEFAULT_PASSWORD` | dev | pgAdmin login |
| `USER_ID` | no | UID of the nginx worker user (default `1000`) |
| `SELLER_DIR` | no | Path of the `dmp.seller` checkout (default `../dmp.seller`) |
| `APPDATA` | no | Base directory of .NET user secrets for the dev override (on Windows, `%APPDATA%` is used automatically) |
| `COMPOSE_PROJECT_NAME` | no | Pins the project name and therefore the volume and network names |

Bitcart variables (see the `*.bitcart.env.example` files for full examples):

| Variable | Description |
| --- | --- |
| `BITCART_HOST`, `BITCART_STORE_HOST`, `BITCART_ADMIN_HOST` | Public host names (single-domain mode: `bitcart.<domain>`, admin at `/admin`) |
| `BITCART_ADMIN_API_URL` | API URL used by the admin panel in the browser (`https://bitcart.<domain>/api`) |
| `BITCART_REVERSEPROXY`, `BITCART_HTTPS_ENABLED` | Reverse-proxy mode reported to Bitcart |
| `BITCART_ADMIN_ROOTPATH`, `BITCART_BACKEND_ROOTPATH`, `BITCART_STORE_ROOTPATH` | Path prefixes (defaults `/admin`, `/api`, `/`) |
| `BITCART_CRYPTOS` | Enabled coins, e.g. `btc,ltc,trx,bch,xmr,eth,bnb,matic` |
| `<COIN>_NETWORK`, `<COIN>_LIGHTNING`, `<COIN>_DEBUG`, `BTC_LIGHTNING_GOSSIP` | Network per coin (`mainnet`, `testnet`, `sepolia`, `amoy`, `nile`, `stagenet`, ...) |
| `ETH_SERVER`, `BNB_SERVER`, `MATIC_SERVER`, `TRX_SERVER`, `XMR_SERVER`, `*_ARCHIVE_SERVER` | RPC endpoints of the account-based coins |
| `BITCART_SSH_KEY_FILE`, `BITCART_SSH_AUTHORIZED_KEYS`, `BITCART_HOST_SSH_AUTHORIZED_KEYS`, `BASH_PROFILE_SCRIPT` | Bitcart "server management" over SSH to the host |
| `BITCART_UPDATE_URL` | Update-check URL |

### Per-service settings (`env/*.env`)

The .NET services read their settings from `appsettings*.json` and user secrets, so no secrets are
stored in their repositories. To configure a deployment, copy the matching
`env/<service>.env.example` to `env/<service>.env`. Every `Section__Key=value` line overrides the
matching configuration key: connection strings, JWT keys, MinIO keys, SMTP, Bitcart URLs and public
hosts. These files are optional, and a missing file is skipped.

| File | Service |
| --- | --- |
| `env/api.web.env` | `api.web-dmp` (`dmp.api.web`) |
| `env/job.invoiceworker.env` | `job.invoiceworker-dmp` |
| `env/job.trxworker.env` | `job.trxworker-dmp` |
| `env/job.server.env` | `job.server-dmp` |

Compose sets `ASPNETCORE_HTTP_PORTS=80`, `REDIS_HOST`, `REDIS_PORT` and `REDIS_PASSWORD` for the API and
the job server. `ASPNETCORE_ENVIRONMENT` / `DOTNET_ENVIRONMENT` come from the override. The .NET 10
images run as the non-root `app` user. They can still bind port 80 because Docker allows
unprivileged ports inside containers by default (`net.ipv4.ip_unprivileged_port_start=0`).

### TLS certificates

nginx expects `nginx/certs/cert.pem` and `nginx/certs/key.pem`, mounted at `/etc/ssl/cloudflare`. In
production, use a Cloudflare Origin CA certificate for `*.<domain>` and `<domain>`. For local
development, create a self-signed certificate:

```bash
mkdir -p nginx/certs
openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
  -keyout nginx/certs/key.pem -out nginx/certs/cert.pem \
  -subj "/CN=example.com" \
  -addext "subjectAltName=DNS:example.com,DNS:*.example.com,DNS:*.api.example.com,DNS:*.seller.example.com,DNS:*.s3.example.com,DNS:*.bitcart.example.com"
```

### Admin access list

`nginx/include/restrict-access.conf` protects the Bitcart, MinIO console and Hangfire hosts. By
default it allows only loopback and private networks. Add your office or VPN IPs there.

## Getting started

### Prerequisites

- Docker Engine 24+ with Docker Compose v2.24+ (Docker Desktop on Windows/macOS)
- Git and Bash (Git Bash or WSL on Windows) for `prepare-build.sh`
- All DMP repositories checked out side by side, because the build contexts are `../<repo>`:

```bash
./prepare-build.sh          # clones missing repos from https://github.com/denis-susha/<repo>.git
./prepare-build.sh --pull   # also fast-forwards existing checkouts
```

The seller SPA is built inside the nginx image with `npm run build:dev` or `npm run build:prod`, which
read `dmp.seller/.env.development` or `dmp.seller/.env.production`. Create the file for the target
environment before building.

The storefront (dmp.client) takes its public URLs as Docker build arguments, because Next.js inlines
`NEXT_PUBLIC_*` values into the bundle. Compose fills them from the `CLIENT_*` variables in
`development.env` / `production.env`; rebuild the `client-ui-dmp` image after changing them.

### Development

1. Create the configuration files:
   ```bash
   cp development.env.example development.env                   # then set the passwords and DMP_DOMAIN
   cp loc.bitcart.env.example loc.bitcart.env                   # when running Bitcart locally
   cp env/api.web.env.example env/api.web.env                   # optional, per service
   ```
2. Create the TLS certificate (see above).
3. Add the local hosts to the hosts file (`C:\Windows\System32\drivers\etc\hosts` or `/etc/hosts`):
   ```
   127.0.0.1 loc.example.com loc.api.example.com loc.seller.example.com loc.s3.example.com loc.bitcart.example.com
   ```
4. Start the stacks:
   ```bash
   docker compose -f compose.bitcart.yml --env-file ./loc.bitcart.env up -d
   docker compose -f compose.yaml -f compose.override.dev.yaml --env-file ./development.env up -d --build
   ```

For services you run from the IDE, Postgres is on `localhost:5442` (billing on `5452`) and Redis on
`localhost:6379`. pgAdmin runs at <http://localhost:5155>. To connect, add a server with host
`dmp-postgres` (or `dmp-db-billing`) and port `5432`. Mailpit runs at <http://localhost:8025>.

### Production

```bash
cp production.env.example production.env                 # strong secrets, real DMP_DOMAIN
cp production.bitcart.env.example production.bitcart.env
cp env/api.web.env.example env/api.web.env               # and the other env/*.env files
# put the Cloudflare origin certificate into nginx/certs/, adjust nginx/include/restrict-access.conf

docker compose -f compose.bitcart.yml --env-file ./production.bitcart.env up -d
docker compose -f compose.yaml -f compose.override.prod.yaml --env-file ./production.env up -d --build
```

Services with healthchecks (Postgres, Redis, MinIO, Bitcart DB/Redis) gate their dependents through
`depends_on: condition: service_healthy`. All services use `restart: unless-stopped`.

### Bitcart setup

1. Start the Bitcart stack (see above). `bitcart-backend` runs `alembic upgrade head` on every start.
2. Open `https://bitcart.<domain>/admin` from an allowed IP and create the admin account. The first
   registered user becomes the server admin.
3. Create a wallet for each enabled coin and a store that uses these wallets.
4. Save the store id in the DMP database. It is the application setting with key
   `settings:application:bitcart` and value `{"storeId": "<bitcart store id>"}`. `dmp.api.web` caches
   it in Redis.
5. DMP talks to Bitcart only over the internal network:
   - `dmp.api.web` → `BitcartBackend__Url=http://bitcart-backend:8000/`
   - `dmp.job.invoiceworker` → `BitcartOptions__WebSocketUri=ws://bitcart-backend:8000/ws/invoices`
   - `dmp.job.trxworker` → `BitcartOptions__ApiUrl=http://bitcart-backend:8000/invoices`

Both stacks must run in the same Compose project (the default when both are started from this
directory) so that they share the `dmp-ntw` network. nginx resolves the Bitcart hosts per request, so
you can start the Bitcart stack before or after the core stack.

The coin daemons are built from `coins/bitcart`, a vendored copy of Bitcart 0.9.0.0. To upgrade
Bitcart, replace that directory with the sources of the new release, update the `bitcart/bitcart*`
image tags in `compose.bitcart.yml` and rebuild with `--build`. Inside the BTC container, the wallets
are in `/home/electrum/.electrum/testnet/wallets/` on testnet. They live in the `bitcoin_datadir`
volume.

## Commands

```bash
# Rebuild and recreate one service (dev; use the prod files/env for production)
docker compose -f compose.yaml -f compose.override.dev.yaml --env-file ./development.env up -d --build --force-recreate --no-deps api.web-dmp

# Rebuild without cache
docker compose -f compose.yaml -f compose.override.prod.yaml --env-file ./production.env build --no-cache nginx-dmp

# Recreate a Bitcart service
docker compose -f compose.bitcart.yml --env-file ./production.bitcart.env up -d --force-recreate --no-deps bitcart-admin

# Validate the merged configuration
docker compose -f compose.yaml -f compose.override.dev.yaml --env-file ./development.env config --quiet

# Reload nginx after changing include/ files (template changes need a container restart)
docker exec dmp-nginx nginx -t && docker exec dmp-nginx nginx -s reload

# Container IP on the Docker network
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' dmp-postgres
```

Redis:

```bash
docker exec -it dmp-redis redis-cli -a "$REDIS_PASSWORD"
# delete all cached products:
docker exec dmp-redis redis-cli -a "$REDIS_PASSWORD" --no-auth-warning --scan --pattern 'product:*' \
  | xargs -r docker exec -i dmp-redis redis-cli -a "$REDIS_PASSWORD" --no-auth-warning del
```

Database backup and restore:

```bash
# Backup (plain SQL, UTF-8) to the host
docker exec dmp-postgres pg_dump -U admin -d dmarketplace --encoding=UTF8 > dmarketplace-$(date +%F).sql

# Restore into a fresh database
docker exec dmp-postgres psql -U admin -d postgres -c 'DROP DATABASE IF EXISTS dmarketplace' -c 'CREATE DATABASE dmarketplace'
docker exec -i dmp-postgres psql -U admin -d dmarketplace < dmarketplace-2025-01-01.sql

# Bitcart database
docker exec bitcart-database psql -U postgres -d bitcart
```

### Upgrading PostgreSQL to a new major version

The DMP databases stay on PostgreSQL 16, and Bitcart's database stays on 12. A new major version
cannot open an older data directory, so do not just change the image tag. Upgrade with a dump and
restore:

```bash
# 1. Stop the writers and dump everything (roles included)
docker compose -f compose.yaml -f compose.override.prod.yaml --env-file ./production.env stop api.web-dmp job.invoiceworker-dmp job.trxworker-dmp job.server-dmp
docker exec dmp-postgres pg_dumpall -U admin > dmp-all.sql

# 2. Remove the container and its volume (keep dmp-all.sql safe!)
docker compose -f compose.yaml -f compose.override.prod.yaml --env-file ./production.env rm -sf postgres-dmp
docker volume rm dmpdocker_postgres-dmp-data

# 3. Change the image tag in compose.yaml (e.g. postgres:17-bookworm), start it and restore
docker compose -f compose.yaml -f compose.override.prod.yaml --env-file ./production.env up -d postgres-dmp
docker exec -i dmp-postgres psql -U admin -d postgres < dmp-all.sql
```

Repeat for `billing-db-dmp` (`dmp-db-billing`, volume `dmp-db-billing-data`) and for
`bitcart-database` (user `postgres`, volume `dbdata`). PostgreSQL 12 is end-of-life, so upgrading
Bitcart's database is recommended. From PostgreSQL 18 on, the official image keeps its data in
`/var/lib/postgresql/<major>/docker`, so mount the volume at `/var/lib/postgresql` instead of
`/var/lib/postgresql/data`.

## Related repositories

- [dmp](https://github.com/denis-susha/dmp): umbrella repository and system overview
- [dmp.api.web](https://github.com/denis-susha/dmp.api.web): public REST API and SignalR payment hub
- [dmp.job.invoiceworker](https://github.com/denis-susha/dmp.job.invoiceworker): Bitcart invoice watcher
- [dmp.job.trxworker](https://github.com/denis-susha/dmp.job.trxworker): payment transaction worker
- [dmp.job.server](https://github.com/denis-susha/dmp.job.server): Hangfire job server (e-mail, maintenance)
- [dmp.client](https://github.com/denis-susha/dmp.client): Next.js storefront
- [dmp.seller](https://github.com/denis-susha/dmp.seller): seller dashboard SPA (built into the nginx image)
- [dmp.api.notifications](https://github.com/denis-susha/dmp.api.notifications): Bitcart webhook receiver. It is not part of these Compose files.
