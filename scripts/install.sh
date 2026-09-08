#!/usr/bin/env bash
# Prepare fresh-install bootstrap configuration without starting services.
# An existing database volume needs its original protected credentials.
set -euo pipefail
umask 077

cd "$(dirname "$0")/.."
ENV_FILE=".env"

if [ -e "$ENV_FILE" ] || [ -L "$ENV_FILE" ]; then
  echo "[install] $ENV_FILE already exists; leaving it alone."
  echo "[install] Add NOCODB_BASE_URL and both ECHO_*_NOCODB_API_TOKEN values securely."
  echo "[install] Preserve the MySQL passwords used to initialize the database volume."
  exit 0
fi

gen() { head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# Noclobber also prevents concurrent installers from replacing this file.
(
  set -o noclobber
  cat > "$ENV_FILE" <<EOF
# Fresh-install bootstrap. Preserve this file with the database volume.
# Generated passwords are for a NEW volume only; restore originals for an existing one.
MYSQL_ROOT_PASSWORD=$(gen)
MYSQL_DATABASE=echo_db
MYSQL_USER=echo_app
MYSQL_PASSWORD=$(gen)

# Fill these before starting; each service owns its own NocoDB token.
NOCODB_BASE_URL=
ECHO_WEB_NOCODB_API_TOKEN=
ECHO_SERVICE_NOCODB_API_TOKEN=
EOF
)

echo "[install] wrote $ENV_FILE with fresh MySQL bootstrap passwords (mode 0600)."
echo "[install] Fill in NocoDB coordinates/tokens and seed PlatformConfig (README.md)."
echo "[install] Complete the deployment gate, then run docker compose config --quiet."
