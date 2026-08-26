#!/usr/bin/env bash
# Bringt den Pi in einem Rutsch auf den aktuellen Stand aller Websites:
#   1. pi-server-Repo (env) aktualisieren
#   2. jedes Website-Repo aus sites.conf klonen bzw. pullen
#   3. gemeinsames Admin-Passwort einmalig festlegen (Staerke wird angezeigt,
#      aber nicht erzwungen) und den Admin-Apps als .env bereitstellen
#   4. optional (--fresh) alte Datenbanken/Volumes loeschen (Inhalte egal)
#   5. Container bauen & starten, Admin-Apps seeden, Caddy neu laden
#   6. Status ausgeben
#
# Nutzung:
#   bash scripts/deploy.sh            # normales Update
#   bash scripts/deploy.sh --fresh    # zusaetzlich alle App-DBs zuruecksetzen
#   bash scripts/deploy.sh --set-password   # Admin-Passwort neu setzen
#      - Passwort wird nur hier ueberschrieben
#      - rotate wird an npm run seed:admin uebergeben
#
# Manifest: sites.conf (name repo_url host admin rotate).
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
    *) echo "Unbekannte Option: $a" >&2; exit 1 ;;
  esac
done

if [[ "$(id -u)" -eq 0 ]]; then
  echo "FEHLER: bitte OHNE sudo starten (das Skript nutzt sudo selbst, wo noetig)." >&2
  exit 1
fi
[[ -f .env ]] || { echo "FEHLER: .env fehlt - zuerst 'bash scripts/setup-env.sh'." >&2; exit 1; }
[[ -f sites.conf ]] || { echo "FEHLER: sites.conf fehlt." >&2; exit 1; }
# shellcheck disable=SC1091
set -a; source .env; set +a
: "${DOMAIN:?DOMAIN fehlt in .env}"

rand_secret() { head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 48; }

# ------------------------------------------------------------------ #
# 1) Gemeinsames Admin-Passwort (einmalig in admin.env, gitignored)  #
# ------------------------------------------------------------------ #
ADMIN_ENV="${REPO_ROOT}/admin.env"
if [[ ! -f "${ADMIN_ENV}" || "${SET_PW}" -eq 1 ]]; then
  echo "=================================================================="
  echo " Gemeinsamer Admin-Account fuer alle Seiten mit Login"
  echo "=================================================================="
  read -r -p "Admin-Benutzername [admin]: " AU; AU="${AU:-admin}"
  while :; do
    read -r -s -p "Admin-Passwort: " AP; echo
    read -r -s -p "Passwort wiederholen: " AP2; echo
    [[ -n "${AP}" ]] || { echo "  Passwort darf nicht leer sein."; continue; }
    [[ "${AP}" == "${AP2}" ]] || { echo "  Passwoerter stimmen nicht ueberein."; continue; }
    len=${#AP}
    if   (( len < 8  )); then echo "  Staerke: schwach (${len} Zeichen) - erlaubt, aber nicht empfohlen.";
    elif (( len < 12 )); then echo "  Staerke: ok (${len} Zeichen).";
    else                      echo "  Staerke: gut (${len} Zeichen)."; fi
    break
  done
  # umask NUR in der Subshell setzen - sonst wirkt 077 im weiteren Skript
  # fort und alle danach geklonten Repos bekaemen Modus 600/700.
  ( umask 077; { echo "ADMIN_USER=${AU}"; echo "ADMIN_PASSWORD=${AP}"; } > "${ADMIN_ENV}" )
  chmod 600 "${ADMIN_ENV}"
  echo "-> admin.env gespeichert (gitignored)."
else
  echo "==> Vorhandenes admin.env wird verwendet (Neu setzen: --set-password)."
fi
# shellcheck disable=SC1091
set -a; source "${ADMIN_ENV}"; set +a

# ------------------------------------------------------------------ #
# 2) pi-server-Repo selbst aktualisieren                             #
# ------------------------------------------------------------------ #
echo "==> pi-server-Repo aktualisieren (git pull)"
git pull --ff-only || echo "  WARN: kein Fast-Forward moeglich - bitte manuell pruefen."

# ------------------------------------------------------------------ #
# 3) Website-Repos klonen/pullen + Admin-.env schreiben              #
# ------------------------------------------------------------------ #
# Das Manifest wird bewusst auf FD 3 gelesen, NICHT auf stdin: ein Kommando im
# Schleifenkoerper (z.B. "docker compose exec") erbt sonst dieselbe offene Datei
# als stdin, liest sie bis EOF leer - und die Schleife endet nach dem ersten
# Eintrag. FD 3 allein genuegt aber nicht, siehe seed_site().
process_sites() {  # $1 = callback-Funktionsname je Zeile
  local cb="$1" name url host admin rotate _rest
  while read -r name url host admin rotate _rest <&3; do
    [[ -z "${name}" || "${name}" == \#* ]] && continue
    "${cb}" "${name}" "${url}" "${host}" "${admin}" "${rotate}"
  done 3< "${REPO_ROOT}/sites.conf"
}

prepare_site() {
  local name="$1" url="$2" host="$3" admin="$4"
  local dir="apps/${name}"
  echo "== ${name} (${host}.${DOMAIN}) =="

  # Klonen oder pullen (nur, wenn dir/.git die EIGENE Repo-Wurzel ist)
  if [[ -d "${dir}/.git" ]]; then
    echo "  git pull"
    git -C "${dir}" pull --ff-only || echo "  WARN: pull fehlgeschlagen"
  elif [[ -e "${dir}" ]]; then
    echo "  WARN: ${dir} existiert, ist aber kein Git-Klon - uebersprungen."
    return 0
  else
    echo "  git clone ${url}"
    git clone "${url}" "${dir}"
  fi

  # Admin-Apps: .env mit Secrets bereitstellen (SESSION_SECRET erhalten,
  # falls schon vorhanden, damit nicht bei jedem Deploy alle Sessions sterben)
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
    # Zwingend ZUSAETZLICH zur umask: ">" auf eine BEREITS BESTEHENDE Datei
    # behaelt deren alten Modus bei, umask greift nur beim Neuanlegen. Ohne
    # dieses chmod bleibt eine einmal zu offen angelegte .env dauerhaft offen -
    # sie enthaelt SESSION_SECRET und das gemeinsame ADMIN_PASSWORD.
    chmod 600 "${envf}"
    echo "  .env geschrieben (Admin-Zugang gesetzt, Modus 600)"
  fi

  # DB/Volume optional zuruecksetzen
  if (( FRESH )); then
    echo "  --fresh: data/${name} wird geloescht"
    sudo rm -rf "data/${name}"
  fi
}
process_sites prepare_site

# ------------------------------------------------------------------ #
# 4) Container bauen & starten                                       #
# ------------------------------------------------------------------ #
echo "==> docker compose up -d --build"
docker compose up -d --build

# ------------------------------------------------------------------ #
# 5) Admin-Apps seeden                                               #
# ------------------------------------------------------------------ #
seed_site() {
  local name="$1" _url="$2" _host="$3" admin="$4" rotate="$5"
  [[ "${admin}" == "yes" ]] || return 0
  local -a rotate_arg=()
  if [[ "${SET_PW}" -eq 1 && -n "${rotate}" && "${rotate}" != "-" ]]; then
    rotate_arg=(-- "${rotate}")
    echo "==> ${name}: Admin seeden (npm run seed:admin, Passwort-Rotation)"
  else
    echo "==> ${name}: Admin seeden (npm run seed:admin)"
  fi
  # "< /dev/null" ist Pflicht, nicht Kosmetik: "docker compose exec" haengt
  # stdin IMMER an den Container - "-T" schaltet nur das TTY ab, einen
  # stdin-Schalter gibt es nicht. Ohne die Umleitung leert der Aufruf die
  # Manifest-Datei (siehe process_sites) bzw. blockiert am Terminal-stdin.
  docker compose exec -T "${name}" npm run seed:admin "${rotate_arg[@]}" < /dev/null ||
    echo "  WARN: seed:admin fehlgeschlagen"
}
process_sites seed_site

echo "==> Caddy neu laden"
docker compose restart caddy

# ------------------------------------------------------------------ #
# 6) Status                                                          #
# ------------------------------------------------------------------ #
echo "==> Status:"
docker compose ps
echo
echo "Fertig. Pruefe die Seiten z.B. mit:"
process_sites_print() {
  local name="$1" _url="$2" host="$3" _admin="$4" fqdn
  if [[ "${host}" == "apex" ]]; then fqdn="${DOMAIN}"; else fqdn="${host}.${DOMAIN}"; fi
  echo "  curl -I https://${fqdn}"
}
process_sites process_sites_print
