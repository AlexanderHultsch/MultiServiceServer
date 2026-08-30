#!/usr/bin/env bash
# Updates a single website to the latest state of its git repo.
# Usage:  bash scripts/deploy-site.sh <name>
#
# Finds the folder automatically:
#   sites/<name>/  -> static site: git pull is enough (Caddy serves it live)
#   apps/<name>/   -> dynamic app: git pull + rebuild/restart the container
#
# Prerequisite: the folder in question is its own git repo (see README
# "Hosting more websites"). If it is NOT a git repo (e.g. the bundled
# examples that live in the main repo), the git-pull step is skipped.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

NAME="${1:-}"
if [[ -z "${NAME}" ]]; then
  echo "Usage: bash scripts/deploy-site.sh <name>" >&2
  echo "Existing sites:" >&2
  ls -1 "${REPO_ROOT}/sites" 2>/dev/null | sed 's/^/  sites\//' >&2 || true
  ls -1 "${REPO_ROOT}/apps" 2>/dev/null | sed 's/^/  apps\//' >&2 || true
  exit 1
fi

pull_if_git_repo() {
  local dir="$1"
  if git -C "${dir}" rev-parse --git-dir >/dev/null 2>&1; then
    echo "==> git pull in ${dir}"
    git -C "${dir}" pull --ff-only
  else
    echo "==> ${dir} is not its own git repo - skipping git pull"
    echo "    (changes live directly in the main repo, commit/pull there instead.)"
  fi
}

if [[ -d "${REPO_ROOT}/apps/${NAME}" ]]; then
  pull_if_git_repo "${REPO_ROOT}/apps/${NAME}"
  echo "==> Rebuilding and starting the dynamic app: ${NAME}"
  docker compose -f "${REPO_ROOT}/docker-compose.yml" up -d --build "${NAME}"
elif [[ -d "${REPO_ROOT}/sites/${NAME}" ]]; then
  pull_if_git_repo "${REPO_ROOT}/sites/${NAME}"
  echo "==> Static site '${NAME}' updated - Caddy serves the files"
  echo "    live, no restart needed."
else
  echo "ERROR: found neither sites/${NAME} nor apps/${NAME}." >&2
  exit 1
fi

echo "==> Done."
