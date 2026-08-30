#!/usr/bin/env bash
# Brings the Pi up to date with all websites in one go:
#   1. update the pi-server repo (env)
#   2. clone or pull each website repo from sites.conf
#   3. set the shared admin password once (strength is shown,
#      but not enforced) and provide it to the admin apps as .env
#   4. optionally (--fresh) delete old databases/volumes (contents don't matter)
#   5. build & start containers, seed admin apps, reload Caddy
#   6. print status
#
# Usage:
#   bash scripts/deploy.sh            # normal update
#   bash scripts/deploy.sh --fresh    # also reset all app DBs
#   bash scripts/deploy.sh --set-password # set a new admin password
#
# Manifest: sites.conf (name repo_url host admin).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "${REPO_ROOT}"

FRESH=0
SET_PW=0
for a in "$@"; do
  case "$a" in
    --fresh) FRESH=1 ;;
    --set-password) SET_PW=1 ;;
    *) echo "Unknown option: $a" >&2; exit 1 ;;
  esac
done

if [[ "$(id -u)" -eq 0 ]]; then
  echo "ERROR: please run WITHOUT sudo (the script uses sudo itself where needed)." >&2
  exit 1
fi
[[ -f .env ]] || { echo "ERROR: .env is missing - run 'bash scripts/setup-env.sh' first." >&2; exit 1; }
[[ -f sites.conf ]] || { echo "ERROR: sites.conf is missing." >&2; exit 1; }
# shellcheck disable=SC1091
set -a; source .env; set +a
: "${DOMAIN:?DOMAIN is missing in .env}"

rand_secret() { head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 48; }

# ------------------------------------------------------------------ #
# 1) Shared admin password (set once in admin.env, gitignored)       #
# ------------------------------------------------------------------ #
ADMIN_ENV="${REPO_ROOT}/admin.env"
if [[ ! -f "${ADMIN_ENV}" || "${SET_PW}" -eq 1 ]]; then
  echo "=================================================================="
  echo " Shared admin account for all sites with a login"
  echo "=================================================================="
  read -r -p "Admin username [admin]: " AU; AU="${AU:-admin}"
  while :; do
    read -r -s -p "Admin password: " AP; echo
    read -r -s -p "Repeat password: " AP2; echo
    [[ -n "${AP}" ]] || { echo "  Password must not be empty."; continue; }
    [[ "${AP}" == "${AP2}" ]] || { echo "  Passwords do not match."; continue; }
    len=${#AP}
    if   (( len < 8  )); then echo "  Strength: weak (${len} characters) - allowed, but not recommended.";
    elif (( len < 12 )); then echo "  Strength: ok (${len} characters).";
    else                      echo "  Strength: good (${len} characters)."; fi
    break
  done
  # Set umask ONLY in the subshell - otherwise 077 stays in effect for the
  # rest of the script and every repo cloned afterwards would end up mode 600/700.
  ( umask 077; { echo "ADMIN_USER=${AU}"; echo "ADMIN_PASSWORD=${AP}"; } > "${ADMIN_ENV}" )
  chmod 600 "${ADMIN_ENV}"
  echo "-> admin.env saved (gitignored)."
else
  echo "==> Using existing admin.env (to set a new one: --set-password)."
fi
# shellcheck disable=SC1091
set -a; source "${ADMIN_ENV}"; set +a

# ------------------------------------------------------------------ #
# 2) Update the pi-server repo itself                                #
# ------------------------------------------------------------------ #
echo "==> Updating the pi-server repo (git pull)"
git pull --ff-only || echo "  WARN: fast-forward not possible - please check manually."

# ------------------------------------------------------------------ #
# 3) Clone/pull website repos + write admin .env files               #
# ------------------------------------------------------------------ #
# The manifest is deliberately read on FD 3, NOT on stdin: a command in the
# loop body (e.g. "docker compose exec") would otherwise inherit the same open
# file as stdin, read it empty to EOF - and the loop would end after the first
# entry. FD 3 alone isn't enough though, see seed_site().
process_sites() {  # $1 = callback function name per line
  local cb="$1" name url host admin _rest
  while read -r name url host admin _rest <&3; do
    [[ -z "${name}" || "${name}" == \#* ]] && continue
    "${cb}" "${name}" "${url}" "${host}" "${admin}"
  done 3< "${REPO_ROOT}/sites.conf"
}

prepare_site() {
  local name="$1" url="$2" host="$3" admin="$4"
  local dir="apps/${name}"
  echo "== ${name} (${host}.${DOMAIN}) =="

  # Clone or pull (only if dir/.git is the repo's OWN root)
  if [[ -d "${dir}/.git" ]]; then
    echo "  git pull"
    git -C "${dir}" pull --ff-only || echo "  WARN: pull failed"
  elif [[ -e "${dir}" ]]; then
    echo "  WARN: ${dir} exists but is not a git clone - skipped."
    return 0
  else
    echo "  git clone ${url}"
    git clone "${url}" "${dir}"
  fi

  # Admin apps: provide .env with secrets (keep SESSION_SECRET if it already
  # exists, so not every deploy kills all sessions)
  if [[ "${admin}" == "yes" ]]; then
    local envf="${dir}/.env" sec=""
    [[ -f "${envf}" ]] && sec="$(grep -E '^SESSION_SECRET=' "${envf}" 2>/dev/null | cut -d= -f2- || true)"
    [[ -n "${sec}" ]] || sec="$(rand_secret)"
    ( umask 077
      {
        echo "SESSION_SECRET=${sec}"
        echo "ADMIN_USER=${ADMIN_USER}"
        echo "ADMIN_PASSWORD=${ADMIN_PASSWORD}"
      } > "${envf}" )
    # Required IN ADDITION to the umask: ">" on an ALREADY EXISTING file
    # keeps its old mode, umask only applies on creation. Without this
    # chmod, a .env once created too open would stay open forever -
    # it holds SESSION_SECRET and the shared ADMIN_PASSWORD.
    chmod 600 "${envf}"
    echo "  .env written (admin access set, mode 600)"
  fi

  # Optionally reset the DB/volume
  if (( FRESH )); then
    echo "  --fresh: deleting data/${name}"
    sudo rm -rf "data/${name}"
  fi
}
process_sites prepare_site

# ------------------------------------------------------------------ #
# 4) Build & start containers                                        #
# ------------------------------------------------------------------ #
echo "==> docker compose up -d --build"
docker compose up -d --build

# ------------------------------------------------------------------ #
# 5) Seed admin apps                                                 #
# ------------------------------------------------------------------ #
seed_site() {
  local name="$1" _url="$2" _host="$3" admin="$4"
  [[ "${admin}" == "yes" ]] || return 0
  echo "==> ${name}: seeding admin (npm run seed:admin)"
  # "< /dev/null" is mandatory, not cosmetic: "docker compose exec" ALWAYS
  # attaches stdin to the container - "-T" only disables the TTY, there is no
  # stdin switch. Without this redirect the call empties the manifest file
  # (see process_sites) or blocks on the terminal's stdin.
  docker compose exec -T "${name}" npm run seed:admin < /dev/null ||
    echo "  WARN: seed:admin failed"
}
process_sites seed_site

echo "==> Reloading Caddy"
docker compose restart caddy

# ------------------------------------------------------------------ #
# 6) Status                                                          #
# ------------------------------------------------------------------ #
echo "==> Status:"
docker compose ps
echo
echo "Done. Check the sites, e.g. with:"
process_sites_print() {
  local name="$1" _url="$2" host="$3" _admin="$4" fqdn
  if [[ "${host}" == "apex" ]]; then fqdn="${DOMAIN}"; else fqdn="${host}.${DOMAIN}"; fi
  echo "  curl -I https://${fqdn}"
}
process_sites process_sites_print
