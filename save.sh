#!/bin/bash
# save.sh - export all workflows from local n8n into workflows/,
# then commit and push workflows/ and catalogs/.
#
# Usage: ./save.sh "commit message"

set -euo pipefail
cd "$(dirname "$0")"

if [ -f .env ]; then
  set -a; . ./.env; set +a
fi

N8N_CONTAINER="${N8N_CONTAINER:-n8n}"
MESSAGE="${1:-Update workflows}"

# Clear old exports first so a workflow deleted in n8n is also removed from git.
echo "==> Exporting workflows from n8n"
rm -f workflows/*.json
if ! docker exec -u node "$N8N_CONTAINER" \
    n8n export:workflow --backup --output=/repo/workflows/; then
  echo "Export failed, restoring workflows/ from git" >&2
  git checkout -- workflows 2> /dev/null || true
  exit 1
fi

git add -A workflows catalogs

if git diff --cached --quiet; then
  echo "==> Nothing changed, nothing to commit"
  exit 0
fi

echo "==> Committing"
git commit -m "$MESSAGE"

echo "==> Pushing"
git push -u origin HEAD

echo "==> Done"
