#!/usr/bin/env bash
# Step 3 of the SPEC (Section 7.2): SSH hardening + ufw default-deny.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

if [[ "$(id -u)" -eq 0 ]]; then
  echo "ERROR: please run WITHOUT sudo:  bash scripts/01-harden.sh" >&2
  echo "(The script checks your SSH key under \$HOME and uses sudo itself where needed.)" >&2
  exit 1
fi

if [[ ! -f "${REPO_ROOT}/.env" ]]; then
  echo "ERROR: ${REPO_ROOT}/.env is missing." >&2
  echo "Run first:  bash scripts/setup-env.sh" >&2
  exit 1
fi

if ! command -v ufw >/dev/null 2>&1; then
  echo "ERROR: ufw is not installed." >&2
  echo "Run first:  bash scripts/00-bootstrap.sh" >&2
  exit 1
fi

# shellcheck disable=SC1091
set -a; source "${REPO_ROOT}/.env"; set +a

: "${LAN_SUBNET:?LAN_SUBNET missing in .env}"
: "${PORT_DNS:?PORT_DNS missing in .env}"
: "${PORT_PIHOLE_UI:?PORT_PIHOLE_UI missing in .env}"
: "${PORT_UPTIME:?PORT_UPTIME missing in .env}"

AUTH_KEYS="${HOME}/.ssh/authorized_keys"
if [[ ! -s "${AUTH_KEYS}" ]]; then
  echo "ERROR: ${AUTH_KEYS} is empty or does not exist." >&2
  echo "Before password login is disabled, your SSH public key must be present there," >&2
  echo "or you will lock yourself out. See the README section on setting up SSH access." >&2
  exit 1
fi

echo "==> SSH hardening (public-key only, no root login)"
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sudo systemctl restart ssh

echo "==> Firewall: default-deny inbound, access only from ${LAN_SUBNET}"
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from "${LAN_SUBNET}" to any port 22 proto tcp
sudo ufw allow from "${LAN_SUBNET}" to any port "${PORT_DNS}" proto tcp
sudo ufw allow from "${LAN_SUBNET}" to any port "${PORT_DNS}" proto udp
sudo ufw allow from "${LAN_SUBNET}" to any port "${PORT_PIHOLE_UI}" proto tcp
sudo ufw allow from "${LAN_SUBNET}" to any port "${PORT_UPTIME}" proto tcp
sudo ufw --force enable

echo "==> Hardening complete. Check with: sudo ufw status verbose"
