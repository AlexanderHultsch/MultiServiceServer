#!/usr/bin/env bash
# Step 7 of the SPEC (section 8.2): data backup, encryption, upload, rotation.
# Intended as a weekly cron job in the ROOT crontab (scripts/install-backup-cron.sh).
#
# WHY ROOT? The files under data/ belong to the container users
# (root, pihole, ...), not the login user. A tar run without root would fail
# with "Permission denied" - and during the weekly cron run, unnoticed.
# rclone still runs as the normal user (the repo owner), so that its
# rclone configuration (~/.config/rclone) is used and token renewals
# land back there too, instead of flipping the file's ownership to root.
#
# Before doing any work, the script checks that the rclone remote itself is
# reachable and its token is still valid, so an expired OAuth token is
# caught before an hour of tar and age work, not after.
#
# Rotation keeps the newest BACKUP_RETENTION_COUNT archives and deletes
# everything older - no separate daily/weekly scheme.
#
# If BACKUP_HEARTBEAT_URL is set (optional), the script pings an Uptime
# Kuma push monitor with an up status on success, and a down status naming
# the failing stage on any failure.
#
# RESTORE PROCEDURE (on a fresh system, referenced from the README):
#   1. Flash Raspberry Pi OS, set up SSH (README Quick Start, steps 1-2).
#   2. Clone the repo, run scripts/00-bootstrap.sh + scripts/01-harden.sh.
#      (Do NOT create .env via setup-env.sh - it comes from the backup instead.)
#   3. Copy the private age key back from its secure location (password
#      manager, USB) to ~/.config/age/pi-server.txt.
#   4. Run 'rclone config' again (same remote name as before).
#   5. Fetch the latest backup, decrypt it, unpack it (remote name/path =
#      BACKUP_REMOTE from before, e.g. onedrive:PiBackups):
#        cd ~/pi-server
#        LATEST="$(rclone lsf onedrive:PiBackups | sort | tail -1)"
#        rclone copy "onedrive:PiBackups/${LATEST}" .
#        age -d -i ~/.config/age/pi-server.txt -o restore.tar.gz "${LATEST}"
#        sudo tar -xzf restore.tar.gz    # restores data/ and .env
#        rm restore.tar.gz "${LATEST}"
#   6. docker compose up -d && bash scripts/verify.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: please run with sudo:  sudo bash scripts/backup.sh" >&2
  echo "Reason: data/ contains files owned by container users that only root can read." >&2
  exit 1
fi

if [[ ! -f "${REPO_ROOT}/.env" ]]; then
  echo "ERROR: ${REPO_ROOT}/.env is missing - run 'bash scripts/setup-env.sh' first." >&2
  exit 1
fi

# shellcheck disable=SC1091
set -a; source "${REPO_ROOT}/.env"; set +a

: "${BACKUP_REMOTE:?BACKUP_REMOTE is missing in .env}"
: "${BACKUP_RETENTION_COUNT:?BACKUP_RETENTION_COUNT is missing in .env - add e.g. BACKUP_RETENTION_COUNT=12, replacing the old BACKUP_RETENTION_DAILY and BACKUP_RETENTION_WEEKLY}"
: "${AGE_RECIPIENT:?AGE_RECIPIENT is missing in .env (age public key, see .env.example)}"

# Run rclone as the user who owns the repo (that's where the
# rclone configuration from 'rclone config' lives). -H sets HOME accordingly.
# Resolve the binary path beforehand, since sudo resets PATH (secure_path).
REPO_OWNER="$(stat -c '%U' "${REPO_ROOT}")"
RCLONE_BIN="$(command -v rclone)" || { echo "ERROR: rclone not installed (bash scripts/00-bootstrap.sh)" >&2; exit 1; }
run_rclone() { sudo -u "${REPO_OWNER}" -H "${RCLONE_BIN}" "$@"; }

# Optional Uptime Kuma push heartbeat. BACKUP_HEARTBEAT_URL is not a
# requirement: if it is unset or empty, this is a silent no-op and the
# backup runs exactly as if it did not exist. A short --max-time keeps a
# hanging monitor from ever blocking the backup, and a failed ping is
# swallowed - under set -e a heartbeat problem must never fail the backup.
heartbeat() {
  local status="$1" msg="$2"
  if [[ -z "${BACKUP_HEARTBEAT_URL:-}" ]]; then
    return 0
  fi
  curl -Gs --max-time 5 -o /dev/null \
    --data-urlencode "status=${status}" \
    --data-urlencode "msg=${msg}" \
    "${BACKUP_HEARTBEAT_URL}" \
    || echo "WARNING: heartbeat ping (${status}) to BACKUP_HEARTBEAT_URL failed" >&2
  return 0
}

STAGE="reachability check"
on_error() {
  local rc=$?
  echo "ERROR: backup failed during stage: ${STAGE} (exit code ${rc})" >&2
  heartbeat down "backup failed during ${STAGE} (exit ${rc})"
}
trap on_error ERR

# Check the remote itself, not BACKUP_REMOTE's path: BACKUP_REMOTE has the
# form "remote:path", and on the very first run that path does not exist
# yet, so listing the path would fail for the wrong reason. Listing the
# bare remote proves it is reachable and its token is still valid, before
# an hour of tar and age work is spent.
BACKUP_REMOTE_NAME="${BACKUP_REMOTE%%:*}"
echo "==> Checking that remote '${BACKUP_REMOTE_NAME}' is reachable"
run_rclone lsf "${BACKUP_REMOTE_NAME}:" >/dev/null

DATE="$(date +%F)"
STAGING_DIR="$(mktemp -d)"
chmod 755 "${STAGING_DIR}"   # so REPO_OWNER (rclone) is allowed to read into it
ARCHIVE="backup-${DATE}.tar.gz"
ENCRYPTED="${ARCHIVE}.age"

cleanup() { rm -rf "${STAGING_DIR}"; }
trap cleanup EXIT

STAGE="tar"
echo "==> Packing data/ and .env into ${ARCHIVE}"
# Accept tar exit code 1 ("file changed as we read it"): the containers
# keep running during the backup and writing to their databases.
# Only exit code >1 (a real error) aborts. The ERR trap is untrapped for
# this call since the trap fires on any nonzero exit regardless of set -e,
# and exit code 1 here is expected, not a failure.
set +e
trap - ERR
tar --warning=no-file-changed -czf "${STAGING_DIR}/${ARCHIVE}" -C "${REPO_ROOT}" data .env
TAR_RC=$?
trap on_error ERR
set -e
if (( TAR_RC > 1 )); then
  echo "ERROR: tar failed (exit code ${TAR_RC})" >&2
  heartbeat down "backup failed during ${STAGE} (exit ${TAR_RC})"
  exit "${TAR_RC}"
fi

STAGE="age"
echo "==> Encrypting with age"
age -r "${AGE_RECIPIENT}" -o "${STAGING_DIR}/${ENCRYPTED}" "${STAGING_DIR}/${ARCHIVE}"
rm -f "${STAGING_DIR}/${ARCHIVE}"
chown "${REPO_OWNER}" "${STAGING_DIR}/${ENCRYPTED}"

STAGE="upload"
echo "==> Uploading to ${BACKUP_REMOTE} (as user ${REPO_OWNER})"
run_rclone copy "${STAGING_DIR}/${ENCRYPTED}" "${BACKUP_REMOTE}"

STAGE="rotation"
echo "==> Applying rotation (keep newest ${BACKUP_RETENTION_COUNT})"

# All existing backups (filename carries the date), newest first.
mapfile -t ALL_BACKUPS < <(run_rclone lsf "${BACKUP_REMOTE}" --files-only | grep -E '^backup-[0-9]{4}-[0-9]{2}-[0-9]{2}\.tar\.gz\.age$' | sort -r)

KEPT_COUNT=0
for i in "${!ALL_BACKUPS[@]}"; do
  f="${ALL_BACKUPS[$i]}"
  if (( i < BACKUP_RETENTION_COUNT )); then
    KEPT_COUNT=$((KEPT_COUNT + 1))
  else
    echo "    deleting old backup: ${f}"
    run_rclone deletefile "${BACKUP_REMOTE}/${f}"
  fi
done

echo "==> Backup complete: ${ENCRYPTED} (kept: ${KEPT_COUNT} of ${#ALL_BACKUPS[@]})"
heartbeat up "uploaded ${ENCRYPTED}, kept ${KEPT_COUNT} of ${#ALL_BACKUPS[@]} archives"
