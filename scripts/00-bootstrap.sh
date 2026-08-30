#!/usr/bin/env bash
# Step 2 of the SPEC (Section 7.1): OS update, base packages, Docker.
# Idempotent: can be run again safely at any time.
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "ERROR: please run WITHOUT sudo:  bash scripts/00-bootstrap.sh" >&2
  echo "(Otherwise root would be added to the docker group instead of your user." >&2
  echo " The script uses sudo itself where needed.)" >&2
  exit 1
fi

echo "==> Updating system"
sudo apt update && sudo apt full-upgrade -y

echo "==> Installing base packages"
sudo apt install -y git ufw fail2ban unattended-upgrades unzip age

# ---------------------------------------------------------------------------
# rclone: installed from the official download, NOT from apt.
#
# WHY: Raspberry Pi OS ships rclone 1.60.1 (released late 2022). That
# version can still LIST a OneDrive Personal remote just fine ('rclone lsd
# <remote>:' works), but every UPLOAD fails with
# "unauthenticated: Unauthenticated" - it uses an upload-session endpoint
# Microsoft has since changed. This is a genuinely misleading failure: since
# listing works, it looks like the remote/token is fine, so the natural
# reaction is to spend hours re-authorising accounts and checking tokens -
# when the actual cause is just an ancient client version. Installing a
# current rclone from the official download made the identical upload
# succeed immediately, with no change to the rclone config or token at all.
# Do not "simplify" this back to 'apt install rclone'.
#
# If OneDrive uploads ever start failing this way again, RCLONE_VERSION
# below is what to bump.
#
# Also note: scripts/backup.sh resolves the binary via 'command -v rclone'
# while running under sudo. sudo's secure_path lists /usr/local/bin before
# /usr/bin, so installing to /usr/local/bin (rather than /usr/bin, where apt
# would put it) is what makes the backup pick up this binary instead of any
# apt-installed one - hence also removing the apt package below, so the two
# can never disagree.
# ---------------------------------------------------------------------------
RCLONE_VERSION="1.75.0"
if [[ -x /usr/local/bin/rclone ]] && /usr/local/bin/rclone version | head -n1 | grep -qx "rclone v${RCLONE_VERSION}"; then
  echo "==> rclone v${RCLONE_VERSION} already installed, skipping"
else
  echo "==> Installing rclone v${RCLONE_VERSION} from the official download"

  ARCH="$(dpkg --print-architecture)"
  case "$ARCH" in
    arm64) RCLONE_ARCH="linux-arm64" ;;
    armhf) RCLONE_ARCH="linux-arm-v7" ;;
    *)
      echo "ERROR: unsupported architecture '${ARCH}' for the pinned rclone v${RCLONE_VERSION} download." >&2
      echo "Add a mapping for it in scripts/00-bootstrap.sh, or install rclone manually." >&2
      exit 1
      ;;
  esac

  if [[ -e /usr/bin/rclone ]]; then
    echo "==> Removing apt-installed rclone (superseded by /usr/local/bin/rclone)"
    sudo apt remove -y rclone
  fi

  RCLONE_TMP="$(mktemp -d)"
  curl -fsSL "https://downloads.rclone.org/v${RCLONE_VERSION}/rclone-v${RCLONE_VERSION}-${RCLONE_ARCH}.zip" -o "${RCLONE_TMP}/rclone.zip"
  unzip -q "${RCLONE_TMP}/rclone.zip" -d "${RCLONE_TMP}"
  sudo install -o root -g root -m 755 "${RCLONE_TMP}/rclone-v${RCLONE_VERSION}-${RCLONE_ARCH}/rclone" /usr/local/bin/rclone
  rm -rf "${RCLONE_TMP}"
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "==> Installing Docker"
  curl -fsSL https://get.docker.com | sh
else
  echo "==> Docker already installed, skipping"
fi

if ! groups "$USER" | grep -q '\bdocker\b'; then
  sudo usermod -aG docker "$USER"
  echo "==> Added '$USER' to the docker group"
fi

sudo dpkg-reconfigure -plow unattended-upgrades

echo "Bootstrap done. Please log in again (docker group) if you were just added."
