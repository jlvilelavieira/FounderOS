# Linux dev environment (Debian/Ubuntu, VMs and containers)

The README's quick start is written for macOS/Homebrew. This page is the
equivalent for a Debian/Ubuntu machine — a laptop, a cloud VM, a dev container
or a CI runner — including one where you only have `root`. It was verified
end to end on Ubuntu 24.04 (root-only container, 4 vCPU, 15 GB RAM, no Docker
daemon, no display).

## Versions the repo pins

| Tool | Version | Pinned by |
| --- | --- | --- |
| Node | 22 | `.nvmrc`, `frontend/Dockerfile`, CI |
| pnpm | 9.15.4 | `frontend/package.json` `packageManager` |
| Go | 1.26.2 | `desktop/backend-go/go.mod`, `backend-tests.yml` (the backend Dockerfile builds with 1.26.4) |
| PostgreSQL | 16 (17 also works) | `docker-compose.yml` uses `pgvector/pgvector:pg16` |
| pgvector | any packaged for your PG major (Ubuntu 24.04: 0.6.0) | migrations `CREATE EXTENSION vector` |
| Redis | 7 | `docker-compose.yml` `redis:7-alpine` |
| Elixir / OTP | Elixir ~> 1.17 (1.17.3) on OTP 26 | `optimal-engine/mix.exs`, `optimal-engine/deploy/Dockerfile.engine` |
| Python | 3.x | `scripts/dev-local.sh` uses it to detach processes |

Distro Elixir is too old on current Ubuntu LTS (24.04 ships 1.14), so the
setup script installs the precompiled OTP and Elixir builds from
`builds.hex.pm`, verified against their published sha256.

## Setup

```bash
make setup-linux ARGS=--dry-run      # print the plan, change nothing
make setup-linux ARGS=--deps         # system packages + toolchains + project deps
. /opt/founderos-tools/env.sh        # (~/.local/founderos-tools/env.sh when not root)
```

What it does (`scripts/setup-linux-dev.sh`):

1. `apt-get install` only the missing packages among `postgresql-16`,
   `postgresql-16-pgvector`, `postgresql-client-16`, `redis-server`,
   `redis-tools`, `build-essential`, `cmake`, `libzstd-dev`, `liblz4-dev`,
   `libsnappy-dev`, `curl`, `openssl`, `unzip`, `lsof` and `python3`.
2. Checks that Node matches `.nvmrc` (it does not install Node), then activates
   pnpm with `corepack prepare pnpm@9.15.4 --activate`.
3. Lets any installed Go (1.21 or newer) download the exact `go.mod` toolchain via
   `GOTOOLCHAIN=go1.26.2`.
4. Installs OTP 26.2.5.9 and Elixir 1.17.3 into `$FOUNDEROS_TOOLS`, outside the repo.
5. Writes `env.sh`, which sets `PATH`, `GOTOOLCHAIN`, a UTF-8 locale (Elixir warns
   under `latin1`) and `MIX_HOME`/`HEX_HOME`.
6. With `--deps`, it also runs `go mod download`,
   `pnpm install --frozen-lockfile && pnpm run build:optimal-sdks`, and
   `mix deps.get && mix compile` in `optimal-engine/`. Compiling the engine the
   first time takes a few minutes because of the rocksdb NIF, and the launcher
   only waits 60 s for the engine to come up.

## Run

```bash
BUSINESSOS_HEADLESS=1 make dev-local   # Postgres :25432, Redis :26379, engine :4200, backend :8801, frontend :5273
# create the account at http://localhost:5273/register (or POST /api/auth/sign-up/email
# with the X-CSRF-Token from GET /api/auth/csrf), then:
make demo OWNER=<that email>
make dev-local-status
```

All generated config stays out of git. `.env.dev`, `desktop/backend-go/.env`
(chmod 600, with random local secrets), `frontend/.env.development.local` and
`.run/` are all ignored. The engine's connector key is generated into
`.run/optimal-engine-data/.optimal/connector_key`.

Health checks:

```bash
curl -s localhost:8801/healthz          # {"status":"ok"}
curl -s localhost:8801/ready            # database + redis connected
curl -s localhost:4200/api/health       # engine live, store/migrations ok
```

The rest of `/api/founderos/...` requires a session cookie.

## Tests

```bash
cd frontend && npx vitest run src/lib/founderos "src/routes/(founderos)"
cd frontend && npx svelte-check --threshold error
cd desktop/backend-go && go test ./internal/founderos/... ./cmd/...
make test                                # full Go + frontend suites
cd optimal-engine && mix test            # engine suite
make test-dev-local-launcher             # launcher bootstrap test
```

Go tests create throwaway databases on the dev Postgres, so start
`make dev-local` first or set `FOUNDEROS_PG_ADMIN_URL`.

## Problems found and their fixes

| Symptom | Cause | Fix |
| --- | --- | --- |
| `initdb: error: cannot be run as root` and `make dev-local` exits 2 | PostgreSQL refuses to run as root, and container/VM shells are often root | `dev-local.sh` now runs `initdb`/`pg_ctl` through `runuser` as `BUSINESSOS_PG_OS_USER` (default `postgres`, created by the distro package) and gives it ownership of `.run/pgdata`. Non-root runs are unchanged. |
| `Could not compile dependency :rocksdb` … `No download info given for 'zstd'` | The rocksdb hex package ships without the bundled zstd sources | Install `libzstd-dev` (plus `liblz4-dev` and `libsnappy-dev`); the build then uses the system libraries |
| `the VM is running with native name encoding of latin1` | No UTF-8 locale in minimal images | `LANG=C.UTF-8`, `ELIXIR_ERL_OPTIONS=+fnu` (set in `env.sh`) |
| Sign-up returns 403 `csrf_token_missing` when scripted | CSRF middleware | `GET /api/auth/csrf`, then send the cookie and an `X-CSRF-Token` header |
| Sign-up returns 400 for the password | The policy requires an uppercase letter, and more | Use a stronger password |

## Known limitations

- **Optimal Engine shows "offline" in the console.** The engine is running and
  `/api/health` returns 200, but `OptimalEngine.Health.status/0` also checks the
  Ollama embedder (`nomic-embed-text` on `localhost:11434`). Without Ollama it
  reports `degraded`, and the FounderOS connector
  (`connectors/optimalengine`) only treats `"up"` as connected. To get a
  green status, install Ollama and run `ollama pull nomic-embed-text`.
  Ingestion and keyword retrieval work without it, and `make demo` loads all
  114 brain pages.
- **The `optimal-engine/bin/optimal` CLI that AGENTS.md refers to is not in
  this repo.** Use `go run ./cmd/optimal-cli` in `desktop/backend-go`, or the
  engine's HTTP API. `mix optimal.health` cannot run while the engine is up,
  because it boots a second copy that collides on port 4200.
- **No Docker daemon.** `make dev` / `docker compose` need one, so the native
  `dev-local` path above is the supported one here. `/ready` reports
  `"containers":"unavailable"`, and `CONTAINER_MANAGER_ENABLED`/`SANDBOX_ENABLED`
  stay off.
- **Electron.** `BUSINESSOS_HEADLESS=1` skips the window, but `dev-local` still
  runs `npm install` in `desktop/`, which can rewrite `desktop/package-lock.json`.
  Don't commit that change by accident.
- Connectors report `not_configured` (22 of 24) because no credentials are set,
  and `FOUNDEROS_WRITES`/`FOUNDEROS_CRONS` stay off. That is the intended demo state.
