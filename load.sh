#!/bin/bash
# load.sh - pull the latest from git, load workflows into local n8n,
# then publish every catalog in catalogs/ to the catalog webhook.
#
# Settings come from a .env file next to this script (not committed):
#   N8N_CONTAINER=n8n
#   N8N_URL=http://localhost:5678
#   CATALOG_WEBHOOK_PATH=/webhook/catalog
#   CATALOG_AUTH_HEADER=X-API-Key
#   CATALOG_AUTH_VALUE=your-secret

set -euo pipefail
cd "$(dirname "$0")"

if [ -f .env ]; then
  set -a; . ./.env; set +a
fi

N8N_CONTAINER="${N8N_CONTAINER:-n8n}"
N8N_URL="${N8N_URL:-http://localhost:5678}"
CATALOG_WEBHOOK_PATH="${CATALOG_WEBHOOK_PATH:-/webhook/catalog}"
CATALOG_AUTH_HEADER="${CATALOG_AUTH_HEADER:-}"
CATALOG_AUTH_VALUE="${CATALOG_AUTH_VALUE:-}"

echo "==> Pulling from git"
git pull

echo "==> Importing workflows into n8n"
docker exec -u node "$N8N_CONTAINER" \
  n8n import:workflow --separate --input=/repo/workflows/ --activeState=fromJson

# A running n8n only registers webhooks for imported workflows after a restart.
echo "==> Restarting n8n"
docker restart "$N8N_CONTAINER" > /dev/null

echo "==> Waiting for n8n to come back"
for i in $(seq 1 60); do
  if curl -fsS "$N8N_URL/healthz" > /dev/null 2>&1; then
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "n8n did not come back within 60 seconds" >&2
    exit 1
  fi
  sleep 1
done

shopt -s nullglob
catalogs=(catalogs/*.json)
if [ ${#catalogs[@]} -eq 0 ]; then
  echo "==> No catalog files in catalogs/, skipping publish"
  exit 0
fi

auth_args=()
if [ -n "$CATALOG_AUTH_HEADER" ]; then
  auth_args=(-H "$CATALOG_AUTH_HEADER: $CATALOG_AUTH_VALUE")
fi

for file in "${catalogs[@]}"; do
  echo "==> Publishing $file"
  # Retries cover the few seconds between n8n starting and its webhooks registering.
  curl -fsS --retry 5 --retry-delay 2 --retry-all-errors \
    -X POST "$N8N_URL$CATALOG_WEBHOOK_PATH" \
    -H "Content-Type: application/json" \
    ${auth_args[@]+"${auth_args[@]}"} \
    --data @"$file"
  echo
done

echo "==> Done"
