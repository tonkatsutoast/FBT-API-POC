#!/bin/bash
# load.sh - pull the latest from git, load workflows into local n8n,
# re-publish the ones marked active, then publish every catalog in catalogs/ to the catalog webhook.
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

# Import leaves every imported workflow unpublished (inactive).
echo "==> Importing workflows into n8n"
docker exec -u node "$N8N_CONTAINER" \
  n8n import:workflow --separate --input=/repo/workflows/

# Re-publish the workflows whose file says "active": true.
active_ids=$(docker exec -u node "$N8N_CONTAINER" node -e '
  const fs = require("fs");
  const dir = "/repo/workflows/";
  for (const f of fs.readdirSync(dir)) {
    if (!f.endsWith(".json")) continue;
    const w = JSON.parse(fs.readFileSync(dir + f, "utf8"));
    if (w.active && !w.isArchived) console.log(w.id);
  }
')
if [ -z "$active_ids" ]; then
  echo "==> No workflows are marked active in workflows/, none published"
else
  for id in $active_ids; do
    echo "==> Publishing workflow $id"
    docker exec -u node "$N8N_CONTAINER" n8n publish:workflow --id="$id" \
      || echo "    Could not publish $id, publish it in the n8n editor" >&2
  done
fi

# Imports and publishes only take effect in a running n8n after a restart.
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
  if ! curl -fsS --retry 5 --retry-delay 2 --retry-all-errors \
    -X POST "$N8N_URL$CATALOG_WEBHOOK_PATH" \
    -H "Content-Type: application/json" \
    ${auth_args[@]+"${auth_args[@]}"} \
    --data @"$file"; then
    echo >&2
    echo "Could not publish $file to $N8N_URL$CATALOG_WEBHOOK_PATH" >&2
    echo "Check that the catalog workflow is published in n8n and that .env matches its webhook." >&2
    exit 1
  fi
  echo
done

echo "==> Done"
