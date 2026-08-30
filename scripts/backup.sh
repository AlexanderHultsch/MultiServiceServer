#!/usr/bin/env bash
# Step 7 of the SPEC (section 8.2): data backup, encryption, upload, rotation.
# Intended as a nightly cron job in the ROOT crontab (scripts/install-backup-cron.sh).
#
# WHY ROOT? The files under data/ belong to the container users
# (root, pihole, ...), not the login user. A tar run without root would fail
# with "Permission denied" - and during the nightly cron run, unnoticed.
# rclone still runs as the normal user (the repo owner), so that its
# rclone configuration (~/.config/rclone) is used and token renewals
# land back there too, instead of flipping the file's ownership to root.
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
: "${BACKUP_RETENTION_DAILY:?BACKUP_RETENTION_DAILY is missing in .env}"
: "${BACKUP_RETENTION_WEEKLY:?BACKUP_RETENTION_WEEKLY is missing in .env}"
: "${AGE_RECIPIENT:?AGE_RECIPIENT is missing in .env (age public key, see .env.example)}"

# Run rclone as the user who owns the repo (that's where the
# rclone configuration from 'rclone config' lives). -H sets HOME accordingly.
# Resolve the binary path beforehand, since sudo resets PATH (secure_path).
REPO_OWNER="$(stat -c '%U' "${REPO_ROOT}")"
RCLONE_BIN="$(command -v rclone)" || { echo "ERROR: rclone not installed (bash scripts/00-bootstrap.sh)" >&2; exit 1; }
run_rclone() { sudo -u "${REPO_OWNER}" -H "${RCLONE_BIN}" "$@"; }

DATE="$(date +%F)"
STAGING_DIR="$(mktemp -d)"
chmod 755 "${STAGING_DIR}"   # so REPO_OWNER (rclone) is allowed to read into it
ARCHIVE="backup-${DATE}.tar.gz"
ENCRYPTED="${ARCHIVE}.age"

cleanup() { rm -rf "${STAGING_DIR}"; }
trap cleanup EXIT

echo "==> Packing data/ and .env into ${ARCHIVE}"
# Accept tar exit code 1 ("file changed as we read it"): the containers
# keep running during the backup and writing to their databases.
# Only exit code >1 (a real error) aborts.
set +e
tar --warning=no-file-changed -czf "${STAGING_DIR}/${ARCHIVE}" -C "${REPO_ROOT}" data .env
TAR_RC=$?
set -e
if (( TAR_RC > 1 )); then
  echo "ERROR: tar failed (exit code ${TAR_RC})" >&2
  exit "${TAR_RC}"
fi

echo "==> Encrypting with age"
age -r "${AGE_RECIPIENT}" -o "${STAGING_DIR}/${ENCRYPTED}" "${STAGING_DIR}/${ARCHIVE}"
rm -f "${STAGING_DIR}/${ARCHIVE}"
chown "${REPO_OWNER}" "${STAGING_DIR}/${ENCRYPTED}"

echo "==> Uploading to ${BACKUP_REMOTE} (as user ${REPO_OWNER})"
run_rclone copy "${STAGING_DIR}/${ENCRYPTED}" "${BACKUP_REMOTE}"

echo "==> Applying rotation (${BACKUP_RETENTION_DAILY} daily, ${BACKUP_RETENTION_WEEKLY} weekly)"

# All existing backups (filename carries the date), newest first.
mapfile -t ALL_BACKUPS < <(run_rclone lsf "${BACKUP_REMOTE}" --files-only | grep -E '^backup-[0-9]{4}-[0-9]{2}-[0-9]{2}\.tar\.gz\.age$' | sort -r)

declare -A KEEP
DAILY_KEPT=0
WEEKLY_KEPT=0
declare -A WEEKLY_SEEN

for f in "${ALL_BACKUPS[@]}"; do
  file_date="${f#backup-}"
  file_date="${file_date%.tar.gz.age}"
  week_key="$(date -d "${file_date}" +%G-%V 2>/dev/null || true)"

  if [[ -z "${week_key}" ]]; then
    continue
  fi

  if (( DAILY_KEPT < BACKUP_RETENTION_DAILY )); then
    KEEP["${f}"]=1
    DAILY_KEPT=$((DAILY_KEPT + 1))
    continue
  fi

  if [[ -z "${WEEKLY_SEEN[${week_key}]:-}" ]] && (( WEEKLY_KEPT < BACKUP_RETENTION_WEEKLY )); then
    KEEP["${f}"]=1
    WEEKLY_SEEN["${week_key}"]=1
    WEEKLY_KEPT=$((WEEKLY_KEPT + 1))
  fi
done

for f in "${ALL_BACKUPS[@]}"; do
  if [[ -z "${KEEP[${f}]:-}" ]]; then
    echo "    deleting old backup: ${f}"
    run_rclone deletefile "${BACKUP_REMOTE}/${f}"
  fi
done

echo "==> Backup complete: ${ENCRYPTED} (kept: ${#KEEP[@]} of ${#ALL_BACKUPS[@]})"
