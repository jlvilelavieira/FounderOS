#!/usr/bin/env bash
# Prepare a Debian/Ubuntu machine (VM, container, CI runner) for
# `BUSINESSOS_HEADLESS=1 make dev-local`, with the versions the repo pins:
#
#   Go        go.mod `go` line, fetched by the Go toolchain itself (GOTOOLCHAIN)
#   pnpm      frontend/package.json `packageManager`, activated with corepack
#   Postgres  the distro's PostgreSQL 16 + pgvector
#   Redis     the distro's redis-server
#   Erlang    OTP 26.2.5.x + Elixir 1.17.3, the pair optimal-engine's
#             deploy/Dockerfile.engine builds with, as precompiled builds from
#             builds.hex.pm, checked against the published sha256
#
# Nothing is installed into the repo. Toolchains go under $FOUNDEROS_TOOLS
# (default /opt/founderos-tools as root, ~/.local/founderos-tools otherwise),
# plus an env.sh to source before `make dev-local`.
#
# Usage:
#   scripts/setup-linux-dev.sh --dry-run   # print the plan, change nothing
#   scripts/setup-linux-dev.sh             # install system packages + toolchains
#   scripts/setup-linux-dev.sh --deps      # also fetch Go/pnpm/mix deps and compile the engine
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OTP_VERSION="${FOUNDEROS_OTP_VERSION:-26.2.5.9}"
ELIXIR_VERSION="${FOUNDEROS_ELIXIR_VERSION:-1.17.3}"
PG_MAJOR="${FOUNDEROS_PG_MAJOR:-16}"
if [ "$(id -u)" -eq 0 ]; then
    TOOLS="${FOUNDEROS_TOOLS:-/opt/founderos-tools}"
else
    TOOLS="${FOUNDEROS_TOOLS:-$HOME/.local/founderos-tools}"
fi

DRY_RUN=0
WITH_DEPS=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --deps) WITH_DEPS=1 ;;
        -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY_RUN" = 1 ]; then printf '   + %s\n' "$*"; else "$@"; fi; }

[ -r /etc/os-release ] || die "no /etc/os-release; this script supports Debian/Ubuntu only"
# shellcheck disable=SC1091
. /etc/os-release
command -v apt-get >/dev/null || die "apt-get not found; this script supports Debian/Ubuntu only"
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null || die "run as root or install sudo"
    SUDO="sudo"
fi

GO_VERSION=$(awk '$1 == "go" { print $2; exit }' "$ROOT/desktop/backend-go/go.mod")
PNPM_SPEC=$(sed -n 's/.*"packageManager": *"\([^"]*\)".*/\1/p' "$ROOT/frontend/package.json")
NODE_MAJOR=$(tr -d '[:space:]' < "$ROOT/.nvmrc")

# --- 1. System packages ------------------------------------------------------
# cmake/build-essential + zstd/lz4/snappy headers: the rocksdb NIF the engine
# depends on builds from C sources and its hex package ships without the
# bundled zstd sources, so it needs the system libraries.
APT_PACKAGES=(
    "postgresql-$PG_MAJOR" "postgresql-$PG_MAJOR-pgvector" "postgresql-client-$PG_MAJOR"
    redis-server redis-tools
    build-essential cmake libzstd-dev liblz4-dev libsnappy-dev
    curl ca-certificates openssl unzip lsof python3
)
missing=()
for pkg in "${APT_PACKAGES[@]}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
done
if [ "${#missing[@]}" -gt 0 ]; then
    info "Installing system packages: ${missing[*]}"
    run $SUDO apt-get update
    run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
else
    ok "System packages present"
fi

# --- 2. Node + pnpm -------------------------------------------------------------
if ! command -v node >/dev/null || [ "$(node -p 'process.versions.node.split(".")[0]')" != "$NODE_MAJOR" ]; then
    die "Node $NODE_MAJOR is required (.nvmrc); install it with nvm or NodeSource, then re-run"
fi
ok "Node $(node --version)"
info "Activating $PNPM_SPEC with corepack"
run corepack enable
run corepack prepare "$PNPM_SPEC" --activate

# --- 3. Go -------------------------------------------------------------------
# Any Go >= 1.21 can download the exact toolchain go.mod pins.
command -v go >/dev/null || die "Go is required (any 1.21+; it downloads go$GO_VERSION itself). Install golang-go or from go.dev/dl"
info "Fetching Go toolchain go$GO_VERSION"
run env GOTOOLCHAIN="go$GO_VERSION" go version

# --- 4. Erlang/OTP + Elixir -----------------------------------------------------
OTP_DIR="$TOOLS/otp-$OTP_VERSION"
ELIXIR_DIR="$TOOLS/elixir-$ELIXIR_VERSION"
OTP_MAJOR="${OTP_VERSION%%.*}"
HEX_BUILDS="https://builds.hex.pm/builds"

fetch_verified() { # <url> <sha256> <dest>
    local url="$1" sha="$2" dest="$3"
    curl -fsSL "$url" -o "$dest"
    echo "$sha  $dest" | sha256sum -c --quiet - || die "checksum mismatch for $url"
}

if [ -x "$OTP_DIR/bin/erl" ] && [ -x "$ELIXIR_DIR/bin/elixir" ]; then
    ok "OTP $OTP_VERSION and Elixir $ELIXIR_VERSION already in $TOOLS"
else
    otp_list="$HEX_BUILDS/otp/${ID}-${VERSION_ID}/builds.txt"
    info "Installing OTP $OTP_VERSION + Elixir $ELIXIR_VERSION (otp-$OTP_MAJOR) into $TOOLS"
    if [ "$DRY_RUN" = 0 ]; then
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        otp_sha=$(curl -fsSL "$otp_list" | awk -v v="OTP-$OTP_VERSION" '$1 == v { print $4 }') ||
            die "no OTP builds for ${ID}-${VERSION_ID} at $otp_list"
        [ -n "$otp_sha" ] || die "OTP-$OTP_VERSION is not published for ${ID}-${VERSION_ID}"
        fetch_verified "$HEX_BUILDS/otp/${ID}-${VERSION_ID}/OTP-$OTP_VERSION.tar.gz" "$otp_sha" "$tmp/otp.tar.gz"
        ex_sha=$(curl -fsSL "$HEX_BUILDS/elixir/builds.txt" | awk -v v="v$ELIXIR_VERSION-otp-$OTP_MAJOR" '$1 == v { print $4 }')
        [ -n "$ex_sha" ] || die "Elixir v$ELIXIR_VERSION-otp-$OTP_MAJOR is not published"
        fetch_verified "$HEX_BUILDS/elixir/v$ELIXIR_VERSION-otp-$OTP_MAJOR.zip" "$ex_sha" "$tmp/elixir.zip"
        mkdir -p "$OTP_DIR" "$ELIXIR_DIR"
        tar -xzf "$tmp/otp.tar.gz" -C "$OTP_DIR" --strip-components=1
        (cd "$OTP_DIR" && ./Install -minimal "$OTP_DIR" >/dev/null)
        unzip -q -o "$tmp/elixir.zip" -d "$ELIXIR_DIR"
    else
        printf '   + download %s (sha256 from builds.txt) -> %s\n' "OTP-$OTP_VERSION" "$OTP_DIR"
        printf '   + download %s (sha256 from builds.txt) -> %s\n' "v$ELIXIR_VERSION-otp-$OTP_MAJOR" "$ELIXIR_DIR"
    fi
fi

# --- 5. env.sh -----------------------------------------------------------------
ENV_SH="$TOOLS/env.sh"
info "Writing $ENV_SH"
if [ "$DRY_RUN" = 0 ]; then
    mkdir -p "$TOOLS"
    cat > "$ENV_SH" <<EOF
# Generated by scripts/setup-linux-dev.sh. Source before make dev-local / make test.
export PATH="$ELIXIR_DIR/bin:$OTP_DIR/bin:\$PATH"
export LANG=C.UTF-8 LC_ALL=C.UTF-8 ELIXIR_ERL_OPTIONS=+fnu
export GOTOOLCHAIN=go$GO_VERSION
export MIX_HOME="$TOOLS/mix" HEX_HOME="$TOOLS/hex"
EOF
fi

# --- 6. Project dependencies (optional) -----------------------------------------
if [ "$WITH_DEPS" = 1 ]; then
    if [ "$DRY_RUN" = 0 ]; then
        # shellcheck disable=SC1090
        . "$ENV_SH"
    fi
    info "Fetching project dependencies"
    run bash -c "cd '$ROOT/desktop/backend-go' && go mod download"
    run bash -c "cd '$ROOT/frontend' && CI=true pnpm install --frozen-lockfile && pnpm run build:optimal-sdks"
    run bash -c "cd '$ROOT/optimal-engine' && mix local.hex --force && mix local.rebar --force && mix deps.get && mix compile"
fi

ok "Done. Next:"
cat <<EOF
   . $ENV_SH
   BUSINESSOS_HEADLESS=1 make dev-local
   # register at http://localhost:5273/register, then:
   make demo OWNER=<that email>
EOF
