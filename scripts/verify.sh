#!/usr/bin/env bash
# Runs all verification checks from README/CLAUDE.md in one bundle.
# Does NOT abort on errors, but shows a PASS/FAIL summary at the end.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "${REPO_ROOT}"

PASS=0
FAIL=0

check() {
  local desc="$1"; shift
  echo "--- ${desc} ---"
  if "$@"; then
    echo "PASS: ${desc}"
    PASS=$((PASS + 1))
  else
    echo "FAIL: ${desc}"
    FAIL=$((FAIL + 1))
  fi
  echo
}

check_compose_config() { docker compose config >/dev/null; }
check_compose_running() {
  local down
  down="$(docker compose ps --services --filter 'status=running' | wc -l)"
  local total
  total="$(docker compose config --services | wc -l)"
  [[ "${down}" -eq "${total}" ]] && [[ "${total}" -gt 0 ]]
}
check_no_secrets_in_git() {
  ! git ls-files | grep -qE '(^|/)\.env$|^data/'
}
check_ufw_default_deny() {
  command -v ufw >/dev/null 2>&1 || return 1
  sudo ufw status verbose | grep -q "Status: active" &&
  sudo ufw status verbose | grep -q "Default: deny (incoming)"
}
check_domain_reachable() {
  [[ -f .env ]] || return 1
  # shellcheck disable=SC1091
  set -a; source .env; set +a
  [[ -n "${DOMAIN:-}" && "${DOMAIN}" != "<<DOMAIN>>" ]] || return 1
  curl -fsI --max-time 10 "https://${DOMAIN}" >/dev/null
}
check_static_ip_bound() {
  # Detects drift between .env and the actually active network IP
  # (e.g. wrong interface reserved in the router, or WiFi/LAN swapped).
  [[ -f .env ]] || return 1
  # shellcheck disable=SC1091
  set -a; source .env; set +a
  [[ -n "${PI_STATIC_IP:-}" ]] || return 1
  ip -4 addr show | grep -q "inet ${PI_STATIC_IP}/"
}
check_wifi_not_unexpectedly_blocked() {
  # Warns if WiFi is blocked via rfkill WHILE no Ethernet cable is
  # active - that would cut the Pi off the network entirely (see README
  # Troubleshooting "No connection after reboot, WiFi dead").
  command -v rfkill >/dev/null 2>&1 || return 0
  rfkill list wifi 2>/dev/null | grep -qi "Soft blocked: yes" || return 0
  ip -4 addr show eth0 2>/dev/null | grep -q "inet " && return 0
  return 1
}

check "docker compose config is valid" check_compose_config
check "All compose services are running" check_compose_running
check "No secrets/data/ in git" check_no_secrets_in_git
check "ufw: active + default-deny inbound" check_ufw_default_deny
check "Public website reachable at https://\${DOMAIN}" check_domain_reachable
check "PI_STATIC_IP is actually active on an interface" check_static_ip_bound
check "WiFi not blocked while no Ethernet is active" check_wifi_not_unexpectedly_blocked

echo "=================================================================="
echo "Result: ${PASS} passed, ${FAIL} failed"
echo "=================================================================="
[[ "${FAIL}" -eq 0 ]]
