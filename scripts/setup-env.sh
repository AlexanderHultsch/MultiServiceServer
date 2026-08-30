#!/usr/bin/env bash
# Interactive assistant for .env (SPEC Section 1 + 10).
# Asks for each value individually, explains where it comes from, suggests
# sensible defaults (LAN detection, age key generation) and writes .env at the end.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${REPO_ROOT}/.env"

if [[ "$(id -u)" -eq 0 ]]; then
  echo "ERROR: please run WITHOUT sudo:  bash scripts/setup-env.sh" >&2
  echo "Otherwise .env and the age key would belong to root instead of your user," >&2
  echo "and the age key would end up under /root instead of in your home directory." >&2
  exit 1
fi

if [[ -f "${ENV_FILE}" ]]; then
  read -r -p ".env already exists. Overwrite? [y/N] " confirm
  [[ "${confirm}" =~ ^[Yy]$ ]] || { echo "Aborted, existing .env left unchanged."; exit 0; }
fi

echo "=================================================================="
echo " pi-server setup assistant"
echo " Press Enter to accept the value suggested in [brackets]."
echo "=================================================================="

ask() {
  # ask <variable-name> <explanation-text> <default>
  local __varname="$1" __hint="$2" __default="$3" __input
  echo
  echo "--- ${__varname} ---"
  echo "${__hint}"
  read -r -p "> [${__default}] " __input
  printf -v "$__varname" '%s' "${__input:-${__default}}"
}

ask_secret() {
  # ask_secret <variable-name> <explanation-text>
  local __varname="$1" __hint="$2" __input
  echo
  echo "--- ${__varname} ---"
  echo "${__hint}"
  read -r -s -p "> " __input
  echo
  printf -v "$__varname" '%s' "${__input}"
}

# --- Network detection as a suggestion ---
DETECTED_IP=""
DETECTED_SUBNET=""
if command -v ip >/dev/null 2>&1; then
  DETECTED_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}')"
  if [[ -n "${DETECTED_IP}" ]]; then
    DETECTED_SUBNET="$(ip -4 addr show 2>/dev/null | awk -v ip="${DETECTED_IP}" '$0 ~ ip {print $2}' | head -1)"
  fi
fi
DETECTED_SUBNET="${DETECTED_SUBNET:-192.168.1.0/24}"
DETECTED_IP="${DETECTED_IP:-192.168.1.10}"
# Normalize to a /24 if a host address with /32 or similar was detected
DETECTED_SUBNET="$(echo "${DETECTED_SUBNET}" | sed -E 's#^([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+/.*#\1.0/24#')"

ask TZ "Time zone, e.g. 'Europe/Berlin'. List: https://en.wikipedia.org/wiki/List_of_tz_database_time_zones" "Europe/Berlin"

ask LAN_SUBNET "Your home network CIDR (the NETWORK address, not the Pi's own IP - e.g. 192.168.178.0/24).
If wrong: run 'ip -4 addr show' on the Pi and read off the network behind your IP (e.g. 192.168.1.0/24)." "${DETECTED_SUBNET}"
# If a host address was entered by mistake instead of the network address
# (e.g. 192.168.178.53/24 instead of 192.168.178.0/24), fix it automatically.
# Only for /24 or a missing prefix length - other networks (/16, /8, ...)
# are deliberately left untouched.
if [[ "${LAN_SUBNET}" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+(/24)?$ ]]; then
  LAN_SUBNET="${BASH_REMATCH[1]}.0/24"
fi

ask PI_STATIC_IP "The static IP the Pi should get on the LAN (DHCP reservation in the router -
see the README section on reserving a static IP for the Pi). Suggestion = the IP currently detected for this device." "${DETECTED_IP}"

# Sanity check: for a /24 network the first three octets must match.
if [[ "${LAN_SUBNET}" == */24 ]]; then
  NET_PREFIX="${LAN_SUBNET%.*}"
  if [[ "${PI_STATIC_IP}" != "${NET_PREFIX}."* ]]; then
    echo "WARNING: PI_STATIC_IP (${PI_STATIC_IP}) is not within LAN_SUBNET (${LAN_SUBNET})."
    echo "Firewall rules and port bindings will then not match up - please check."
  fi
fi

ask PORT_PIHOLE_UI "Host port for the Pi-hole web interface (reachable only on the LAN). Usually leave unchanged." "8080"
ask PORT_DNS "Port for DNS. Must be 53 unless you know exactly why you are changing it." "53"
ask PORT_UPTIME "Host port for Uptime Kuma (reachable only on the LAN)." "3001"

ask DOMAIN "Your public domain (e.g. example.com or status.example.com).
Must be managed as a 'Zone' in your Cloudflare account (nameservers pointing to Cloudflare).
If you do not have a domain yet: https://dash.cloudflare.com -> Registrar, or move an existing domain
to Cloudflare (Add a site -> switch nameservers at your current registrar)." ""
while [[ -z "${DOMAIN}" ]]; do
  echo "DOMAIN must not be empty."
  ask DOMAIN "Your public domain, see the note above." ""
done
# Common copy-paste mistake: a URL pasted instead of a domain -> clean it up.
DOMAIN="${DOMAIN#https://}"
DOMAIN="${DOMAIN#http://}"
DOMAIN="${DOMAIN%%/*}"

ask_secret PIHOLE_PASSWORD "Admin password for the Pi-hole web interface. Choose freely; it is only stored locally
in .env right now (not sent to any server). Leave empty = a random, secure password will be generated."
if [[ -z "${PIHOLE_PASSWORD}" ]]; then
  PIHOLE_PASSWORD="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
  echo "Generated Pi-hole password: ${PIHOLE_PASSWORD}"
  echo "(Write it down now - it is shown only once and afterwards lives in .env.)"
elif [[ "${#PIHOLE_PASSWORD}" -lt 8 ]]; then
  echo "WARNING: this is a very short password (${#PIHOLE_PASSWORD} characters)."
  echo "The Pi-hole UI is reachable only on the LAN, but it is still recommended to"
  echo "set a longer one later in the Pi-hole UI under Settings > Web Interface / API."
fi

ask_secret CLOUDFLARE_TUNNEL_TOKEN "Tunnel token from the Cloudflare Zero Trust dashboard:
https://one.dash.cloudflare.com -> Networks -> Tunnels -> Create a tunnel -> Cloudflared ->
give it a name -> click 'Docker' under 'Choose your environment'.
A 'docker run ...--token eyJ...' command is shown there - copy ONLY the value after --token.
If you do not have this ready right now: press Enter and add it to .env manually later."

ask BACKUP_REMOTE "rclone remote destination for encrypted backups, format '<remote-name>:<path>'.
The remote name must be set up with 'rclone config' on this Pi (README backup section)." "onedrive:PiBackups"
ask BACKUP_RETENTION_COUNT "How many weekly backup archives should be kept? Older ones are deleted." "12"
ask BACKUP_HEARTBEAT_URL "Push URL of an Uptime Kuma monitor of type Push (optional).
The backup pings it on success and on failure. Leave empty to skip this - press Enter -
you can always add it to .env later." ""

# --- Automatically generate an age keypair if none exists yet ---
AGE_KEY_FILE="${HOME}/.config/age/pi-server.txt"
echo
echo "--- AGE_RECIPIENT (backup encryption) ---"
if [[ -f "${AGE_KEY_FILE}" ]]; then
  echo "Existing age keypair found: ${AGE_KEY_FILE}"
else
  echo "No age keypair found - generating one at ${AGE_KEY_FILE}"
  mkdir -p "$(dirname "${AGE_KEY_FILE}")"
  age-keygen -o "${AGE_KEY_FILE}" 2>/tmp/age-keygen.$$.log
  cat /tmp/age-keygen.$$.log
  rm -f /tmp/age-keygen.$$.log
fi
AGE_RECIPIENT="$(grep 'public key' "${AGE_KEY_FILE}" -i | awk '{print $NF}')"
echo "Using public key: ${AGE_RECIPIENT}"
echo "IMPORTANT: ${AGE_KEY_FILE} contains the PRIVATE key and is NOT backed up"
echo "automatically. Copy it now to a safe place outside the Pi (password manager, USB drive)."

cat > "${ENV_FILE}" <<EOF
TZ=${TZ}
LAN_SUBNET=${LAN_SUBNET}
PI_STATIC_IP=${PI_STATIC_IP}
PORT_PIHOLE_UI=${PORT_PIHOLE_UI}
PORT_DNS=${PORT_DNS}
PORT_UPTIME=${PORT_UPTIME}
DOMAIN=${DOMAIN}
PIHOLE_PASSWORD=${PIHOLE_PASSWORD}
CLOUDFLARE_TUNNEL_TOKEN=${CLOUDFLARE_TUNNEL_TOKEN}
BACKUP_REMOTE=${BACKUP_REMOTE}
BACKUP_RETENTION_COUNT=${BACKUP_RETENTION_COUNT}
BACKUP_HEARTBEAT_URL=${BACKUP_HEARTBEAT_URL}
AGE_RECIPIENT=${AGE_RECIPIENT}
EOF
chmod 600 "${ENV_FILE}"

echo
echo "=================================================================="
echo ".env written to ${ENV_FILE} (chmod 600)."
if [[ -z "${CLOUDFLARE_TUNNEL_TOKEN}" ]]; then
  echo "NOTE: CLOUDFLARE_TUNNEL_TOKEN is still empty - add it to .env before running"
  echo "'docker compose up -d', otherwise the cloudflared container will fail to start."
fi
echo "Next step: bash scripts/01-harden.sh"
echo "=================================================================="
