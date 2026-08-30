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
sudo apt install -y git ufw fail2ban unattended-upgrades rclone age

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
