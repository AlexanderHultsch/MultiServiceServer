#!/usr/bin/env bash
# Idempotently installs the weekly backup job into the ROOT crontab (SPEC 8.2.6).
# Root crontab, because backup.sh needs root privileges (see backup.sh for the reasoning).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
LOG_FILE="${REPO_ROOT}/backup.log"
CRON_CMD="cd ${REPO_ROOT} && ./scripts/backup.sh >> ${LOG_FILE} 2>&1"
CRON_LINE="30 3 * * 1 ${CRON_CMD}"

# Cleanup: earlier versions of this script installed the job into the
# USER crontab - there it would fail for lack of root privileges.
# Remove it if present.
if crontab -l 2>/dev/null | grep -qF "${CRON_CMD}"; then
  crontab -l 2>/dev/null | grep -vF "${CRON_CMD}" | crontab -
  echo "Removed stale entry from the user crontab."
fi

# Match on CRON_CMD alone (not the full line): an existing line carrying this
# command but a different, older schedule (e.g. from a previous nightly
# setup) must be replaced, not mistaken for "already installed" and left
# running on the old schedule forever.
EXISTING_LINE="$(sudo crontab -l 2>/dev/null | grep -F "${CRON_CMD}" || true)"
if [[ -z "${EXISTING_LINE}" ]]; then
  (sudo crontab -l 2>/dev/null; echo "${CRON_LINE}") | sudo crontab -
  echo "Cron job installed (root crontab, weekly, Mondays at 03:30):"
  echo "${CRON_LINE}"
elif [[ "${EXISTING_LINE}" == "${CRON_LINE}" ]]; then
  echo "Cron job already exists in the root crontab, no change needed:"
  echo "${EXISTING_LINE}"
else
  (sudo crontab -l 2>/dev/null | grep -vF "${CRON_CMD}"; echo "${CRON_LINE}") | sudo crontab -
  echo "Cron job schedule changed - replaced old entry:"
  echo "  old: ${EXISTING_LINE}"
  echo "  new: ${CRON_LINE}"
fi

echo "Log file: ${LOG_FILE}"
