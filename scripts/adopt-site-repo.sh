#!/usr/bin/env bash
# Replaces a site/app bundled in the main repo (e.g. the
# example sites/main) with its own, separate git clone - and automatically
# adds the path to the main repo's .gitignore, so the two repos don't
# get in each other's way.
#
# Usage:   bash scripts/adopt-site-repo.sh <sites/name|apps/name> <git-url>
# Example: bash scripts/adopt-site-repo.sh sites/main https://github.com/<you>/my-homepage.git
#
# Background (the bug this script prevents): if the folder stays part of
# the main repo, a `git pull` inside it silently resolves against the MAIN
# REPO'S REMOTE - not the actual website. The result is a misleading
# "Already up to date", even though the site is never updated.
# See README "Each site as its own git repo".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

TARGET="${1:-}"
GIT_URL="${2:-}"

if [[ -z "${TARGET}" || -z "${GIT_URL}" ]]; then
  echo "Usage: bash scripts/adopt-site-repo.sh <sites/name|apps/name> <git-url>" >&2
  exit 1
fi

DIR="${REPO_ROOT}/${TARGET}"

if [[ ! -d "${DIR}" ]]; then
  echo "ERROR: ${DIR} does not exist." >&2
  exit 1
fi

# Important: "git -C DIR rev-parse --git-dir" alone is not enough as a check -
# it also finds the main repo's .git in a parent folder and falsely reports
# success (exactly the bug this script is meant to fix). Instead, check
# whether DIR itself is the repo's root.
TOPLEVEL="$(git -C "${DIR}" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -n "${TOPLEVEL}" && "$(cd "${DIR}" && pwd -P)" == "$(cd "${TOPLEVEL}" && pwd -P)" ]]; then
  echo "ERROR: ${DIR} is already its own git repo - nothing to do." >&2
  exit 1
fi

cd "${REPO_ROOT}"

echo "==> Removing ${TARGET} from the main repo's version control (files stay in place for now)"
git rm -r --cached "${TARGET}" >/dev/null

if ! grep -qxF "/${TARGET}/" .gitignore 2>/dev/null; then
  echo "/${TARGET}/" >> .gitignore
  git add .gitignore
  echo "==> Added /${TARGET}/ to .gitignore"
fi

git commit -m "Main repo: ignore ${TARGET} (now its own git repo)" >/dev/null
echo "==> Commit created in the main repo - don't forget to push it (git push)"

BACKUP_DIR="${DIR}.bak-$(date +%Y%m%d%H%M%S)"
echo "==> Moved old content to ${BACKUP_DIR}, now cloning fresh from ${GIT_URL}"
mv "${DIR}" "${BACKUP_DIR}"
git clone "${GIT_URL}" "${DIR}"

echo "==> Done. ${TARGET} is now its own git repo (clone of ${GIT_URL})."
echo "    The old content is kept in ${BACKUP_DIR} for review - delete it manually afterwards:"
echo "      rm -rf ${BACKUP_DIR}"
echo "    From now on, update it with: bash scripts/deploy-site.sh $(basename "${TARGET}")"
