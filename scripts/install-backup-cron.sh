#!/usr/bin/env bash
# Idempotently installs the nightly backup job into the ROOT crontab (SPEC 8.2.6).
# Root crontab, because backup.sh needs root privileges (see backup.sh for the reasoning).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
LOG_FILE="${REPO_ROOT}/backup.log"
CRON_CMD="cd ${REPO_ROOT} && ./scripts/backup.sh >> ${LOG_FILE} 2>&1"
CRON_LINE="0 3 * * * ${CRON_CMD}"

# Cleanup: earlier versions of this script installed the job into the
# USER crontab - there it would fail for lack of root privileges.
# Remove it if present.
if crontab -l 2>/dev/null | grep -qF "${CRON_CMD}"; then
  crontab -l 2>/dev/null | grep -vF "${CRON_CMD}" | crontab -
  echo "Removed stale entry from the user crontab."
fi

if sudo crontab -l 2>/dev/null | grep -qF "${CRON_CMD}"; then
  echo "Cron job already exists in the root crontab, no change needed:"
  sudo crontab -l | grep -F "${CRON_CMD}"
else
  (sudo crontab -l 2>/dev/null; echo "${CRON_LINE}") | sudo crontab -
  echo "Cron job installed (root crontab, daily at 03:00):"
  echo "${CRON_LINE}"
fi

echo "Log file: ${LOG_FILE}"
