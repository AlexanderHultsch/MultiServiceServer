# SPEC: Raspberry Pi 4 – Sicherer Multi-Service-Server

**Version:** 2.4 (hardware-agnostisch)
**Zielgruppe dieses Dokuments:** KI-Coding-Agent (Claude Code)
**Format:** Deklarative Spezifikation. Alle Werte in Abschnitt 1 sind die *einzige Quelle der Wahrheit* (Single Source of Truth) und werden überall referenziert.

---

## 0. AUFTRAG AN DEN CODING-AGENTEN

Du bist ein Coding-Agent. Erzeuge aus dieser Spezifikation:

1. Ein vollständiges, lauffähiges Repository gemäß der Struktur in **Abschnitt 4**.
2. Eine `docker-compose.yml`, die alle Dienste aus **Abschnitt 5** startet.
3. Alle Konfigurationsdateien aus **Abschnitt 6** (fertig ausgefüllt bis auf `<<PLACEHOLDER>>`-Werte).
4. Setup- und Härtungs-Skripte gemäß **Abschnitt 7**.
5. Ein Backup-/Restore-Skript gemäß **Abschnitt 8**.
6. Eine `README.md` mit Setup-Anleitung **und** getesteter Restore-Prozedur.

**Regeln:**
- Halte **jede** MUST/MUST-NOT-Regel aus **Abschnitt 3** ein.
- Verwende ausschließlich die Parameter aus **Abschnitt 1**; erfinde keine Werte.
- `<<PLACEHOLDER>>` = vom Nutzer auszufüllen → als solchen belassen und in **Abschnitt 10** auflisten.
- Wo eine Image-Version oder ein Environment-Variablenname versionsabhängig ist, **verifiziere** ihn gegen die offizielle Doku der gepinnten Version und dokumentiere den verwendeten Stand.
- Kein Schritt gilt als erledigt ohne das zugehörige *Definition of Done* aus **Abschnitt 9**.

---

## 1. GLOBALE PARAMETER (Single Source of Truth)

Konvention:
- `${VAR}` → Wert lebt in `.env` (nicht committen).
- `<<PLACEHOLDER>>` → Nutzer muss ihn vor dem Deployment setzen.

| Parameter | Default | Nutzer-anpassbar | Beschreibung |
|---|---|---|---|
| `TZ` | `Europe/Berlin` | ja | Zeitzone aller Container |
| `LAN_SUBNET` | `192.168.1.0/24` | **ja** | Heimnetz-CIDR für Firewall-Regeln |
| `PI_STATIC_IP` | `192.168.1.10` | **ja** | Feste IP des Pi (DHCP-Reservierung) |
| `PORT_PIHOLE_UI` | `8080` | nein | Host-Port Pi-hole Web-Admin (nur LAN) |
| `PORT_DNS` | `53` | nein | DNS (TCP+UDP, nur LAN) |
| `PORT_UPTIME` | `3001` | nein | Host-Port Uptime Kuma (nur LAN) |
| `DOMAIN` | `<<DOMAIN>>` | **ja** | Öffentliche Domain der Webseite |
| `CLOUDFLARE_TUNNEL_TOKEN` | `<<CLOUDFLARE_TUNNEL_TOKEN>>` | **ja** | Tunnel-Token (Secret) |
| `PIHOLE_PASSWORD` | `<<PIHOLE_PASSWORD>>` | **ja** | Passwort Pi-hole Admin (Secret) |
| `REPO_ROOT` | `~/pi-server` | ja | Wurzelverzeichnis des Repos auf dem Pi |
| `BACKUP_REMOTE` | `onedrive:PiBackups` | ja | rclone-Remote-Ziel für Daten-Backups |
| `BACKUP_RETENTION_DAILY` | `7` | ja | Anzahl täglicher Backup-Stände |
| `BACKUP_RETENTION_WEEKLY` | `4` | ja | Anzahl wöchentlicher Stände |
| `AGE_RECIPIENT` | `<<AGE_RECIPIENT_PUBLIC_KEY>>` | **ja** | age-Public-Key zur Backup-Verschlüsselung (technisch notwendig für Abschnitt 8.2, in v2.0 ergänzt) |

**Image-Tag-Policy:** Alle Images MÜSSEN auf eine **konkrete veröffentlichte Version** gepinnt werden (siehe Abschnitt 5). `:latest` ist verboten. Der Agent trägt zum Umsetzungszeitpunkt die aktuelle stabile Version ein und notiert sie in der `README.md`.

---

## 2. ZIELARCHITEKTUR

```
                     Internet
                        │  (nur AUSGEHEND, verschlüsselt)
                 ┌──────▼──────┐
                 │ Cloudflare  │  DNS · TLS · DDoS-Schutz · versteckt Heim-IP
                 └──────┬──────┘
                        │  outbound-only Tunnel
╔═══════════════════════▼════════════════════════════════╗
║ Raspberry Pi · ufw Default-Deny (eingehend)            ║
║                                                        ║
║  cloudflared ──▶ caddy ──▶ statische Seiten (sites/)   ║
║                     └────▶ dynamische Apps (apps/)     ║
║                                                        ║
║  pihole (DNS+Adblock, nur LAN)   uptime-kuma (nur LAN) ║
╚════════════════════════════════════════════════════════╝
                        │
                   LAN (${LAN_SUBNET})
          alle Geräte nutzen ${PI_STATIC_IP} als DNS
```

**Invariante:** Von außen ist **kein Port offen**. Der einzige externe Pfad zu den Websites führt durch den vom Pi aufgebauten Cloudflare-Tunnel; intern verteilt `caddy` anhand des Hostnamens.

---

## 3. HARTE CONSTRAINTS

### MUST
- [M1] Jeder Container: `restart: unless-stopped`.
- [M2] Alle Images auf konkrete Version gepinnt.
- [M3] Admin-UIs (`pihole`, `uptime-kuma`) werden **nur** an `${PI_STATIC_IP}` gebunden.
- [M4] `ufw` Default-Deny eingehend; Zugriff auf Admin-Ports/SSH nur aus `${LAN_SUBNET}`.
- [M5] Secrets ausschließlich in `.env` (gitignored) + verschlüsselte Kopie im Backup-Remote.
- [M6] SSH nur per Public Key; `PasswordAuthentication no`; `PermitRootLogin no`.
- [M7] Backup-Restore muss vor Abschluss **einmal real getestet** werden.
- [M8] Web-/Proxy-Dienst (`caddy`) und alle App-Container besitzen **keinen** `ports:`-Eintrag (nur internes Docker-Netz, erreichbar ausschließlich über cloudflared).

### MUST NOT
- [N1] Keine eingehende Portfreigabe am Router.
- [N2] Kein `:latest`-Tag.
- [N3] `.env`, `data/` und Backup-Artefakte niemals committen.
- [N4] Keine Bindung eines Dienstes an `0.0.0.0`, außer implizit über den Tunnel.
- [N5] Kein Passwort-basierter SSH-Login.

---

## 4. REPO-STRUKTUR (Soll-Zustand)

```
pi-server/
├── docker-compose.yml
├── .env                      # NICHT committen
├── .env.example              # Vorlage ohne echte Werte
├── .gitignore
├── README.md                 # Setup + Restore
├── CLAUDE.md                 # Arbeitsanweisung fuer Claude Code (Aufbau + Live-Debugging)
├── raspberry-pi-4-spezifikation.md   # diese Datei
├── sites/                    # statische Seiten (je Ordner = eine Seite)
│   ├── main/index.html
│   └── beispiel/index.html
├── apps/                     # dynamische Apps (je Ordner = ein Container)
│   └── app-example/          #   Dockerfile + Quellcode
├── config/
│   └── caddy/
│       └── Caddyfile          # Reverse-Proxy-Routing (Abschnitt 5.2)
├── scripts/
│   ├── setup-env.sh          # interaktiver .env-Assistent
│   ├── 00-bootstrap.sh        # OS-Update, Docker, Pakete
│   ├── 01-harden.sh           # SSH-Härtung + ufw
│   ├── deploy-site.sh         # eine Seite aus ihrem Git-Repo aktualisieren
│   ├── install-backup-cron.sh # idempotente Cron-Installation
│   ├── backup.sh              # Daten-Backup + Rotation
│   ├── verify.sh              # buendelt alle Verifikations-Checks
│   └── install-claude-code.sh # optional: Claude Code CLI fuer Live-Debugging (Abschnitt 5.6)
└── data/                      # Laufzeit-Volumes (gitignored)
    ├── pihole/
    └── uptime-kuma/
```

---

## 5. DIENSTE-SPEZIFIKATION

Format je Dienst: **Image**, **Zweck**, **Exposure**, **Ports**, **Volumes**, **Env**, **Abhängigkeiten**.

### 5.1 `pihole`
- **Image:** `pihole/pihole:<<PIN_TAG>>`
- **Zweck:** Netzweiter DNS-Resolver + Werbe-/Tracker-Blocker.
- **Exposure:** nur LAN.
- **Ports:** `${PI_STATIC_IP}:${PORT_DNS}:53/tcp`, `${PI_STATIC_IP}:${PORT_DNS}:53/udp`, `${PI_STATIC_IP}:${PORT_PIHOLE_UI}:80/tcp`
- **Volumes:** `./data/pihole/etc-pihole:/etc/pihole`
- **Env:** `TZ=${TZ}`, Admin-Passwort = `${PIHOLE_PASSWORD}`
  > Env-Variablennamen sind Pi-hole-v6-spezifisch (z. B. `FTLCONF_webserver_api_password`). Der Agent MUSS den exakten Namen gegen die gepinnte Version prüfen.
- **Upstream-DNS:** verschlüsselt bevorzugt (Quad9 `9.9.9.9` oder Cloudflare `1.1.1.1`); optional DoH-Sidecar.
- **`FTLCONF_dns_listeningMode: "ALL"` ist PFLICHT** (in v2.2 ergänzt, real auf Hardware verifiziert): Pi-hole v6 defaultet sonst auf `dns.listeningMode=LOCAL`. Da `pihole` in einem Docker-Bridge-Netz läuft, hält FTL dabei nur Anfragen aus dem eigenen Bridge-Subnetz für "lokal" und verwirft echte LAN-Clients stillschweigend (Log: `ignoring query from non-local network ...`) — der Dienst läuft, antwortet aber niemandem im LAN. `ALL` ist hier sicher, weil Port 53 laut [M3]/[N4] ohnehin nur an `${PI_STATIC_IP}` gebunden ist, nicht an `0.0.0.0`.

### 5.2 `caddy` (Reverse Proxy & Webserver)
Ab v2.4 ersetzt Caddy den früheren einzelnen `web`/nginx-Dienst. Ein Reverse
Proxy für **beliebig viele** Websites (statisch + dynamisch).
- **Image:** `caddy:<<PIN_TAG>>-alpine`
- **Zweck:** cloudflared schickt jeden Hostnamen an `caddy:80`; Caddy verteilt
  anhand der (Sub-)Domain — statische Seiten aus Ordnern (`file_server`),
  dynamische Apps per `reverse_proxy` an deren Container.
- **Exposure:** **nur internes Docker-Netz `edge`** — kein Host-Port (siehe [M8]).
- **Volumes:** `./config/caddy/Caddyfile:/etc/caddy/Caddyfile:ro`, `./sites:/srv:ro`, `./data/caddy/...`
- **Env:** `DOMAIN=${DOMAIN}` (im Caddyfile als `{$DOMAIN}` eingesetzt).
- **Routing-Konfiguration:** `config/caddy/Caddyfile` (config-as-code).
- **`auto_https off`** — Cloudflare terminiert TLS nach außen, Caddy liefert intern nur HTTP.

### 5.2b Websites (Inhalt, kein eigener Docker-Dienst-Typ)
- **Statische Seite:** Ordner `sites/<name>/` → von Caddy direkt ausgeliefert. Kein eigener Container (ressourcenschonend auf dem Pi).
- **Dynamische App:** Ordner `apps/<name>/` mit eigenem `Dockerfile` → eigener Compose-Dienst auf `edge`, von Caddy per `reverse_proxy` erreichbar. Beispiel: `apps/app-example` (Node).
- **Git-Repo je Seite:** jede Seite kann ein eigenes Git-Repo sein (in `sites/`/`apps/` geklont, Pfad in `.gitignore` des Haupt-Repos). Deploy per `scripts/deploy-site.sh <name>`.
- **Wildcard-Einschränkung:** Cloudflare-Wildcard-Hostnamen mit Proxy sind im kostenlosen Plan nicht verfügbar → pro Subdomain ein Public Hostname im Dashboard (alle → `http://caddy:80`).

### 5.3 `cloudflared`
- **Image:** `cloudflare/cloudflared:<<PIN_TAG>>`
- **Zweck:** Outbound-Tunnel; macht die Websites unter `${DOMAIN}` (und Subdomains) öffentlich erreichbar.
- **Exposure:** keine offenen Ports (nur ausgehend).
- **Command:** `tunnel --no-autoupdate run --token ${CLOUDFLARE_TUNNEL_TOKEN}`
- **Routing:** alle Public Hostnames → `http://caddy:80` (Verteilung übernimmt Caddy).
  > **Default:** Token-Methode; Routing wird im Cloudflare-Zero-Trust-Dashboard gesetzt (aktuelle Bezeichnung dort: "Published Application routes").
  > **Alternative (mehr config-as-code):** lokale `config.yml` + Credentials-Datei (Credentials = Secret, gitignored). Für maximale Reproduzierbarkeit wählbar.
- **Abhängigkeiten:** `depends_on: [caddy]`

### 5.4 `uptime-kuma`
- **Image:** `louislam/uptime-kuma:<<PIN_TAG>>`
- **Zweck:** Verfügbarkeits-Monitoring + Benachrichtigung.
- **Exposure:** nur LAN.
- **Ports:** `${PI_STATIC_IP}:${PORT_UPTIME}:3001`
- **Volumes:** `./data/uptime-kuma:/app/data`
- **Datenbank:** bei Erststart **SQLite** wählen (leicht, im `data/`-Backup enthalten; Embedded MariaDB unnötig schwer auf dem Pi).
- **Checks (nach Erststart einzurichten):** öffentliche Website(s), Pi-hole **über den internen Servicenamen** (`http://pihole/admin/`, nicht die LAN-IP — sonst Docker-NAT-Hairpin-Timeout), Internet-Referenz.

### 5.4b E-Mail — [Cloudflare Email Routing, kein Pi-Dienst]
Ergänzt in v2.4. E-Mail wird **nicht** auf dem Pi gehostet (Port 25 meist gesperrt, eingehende Ports widersprächen [N1], Reputation/Deliverability unlösbar auf Privatanschluss). Stattdessen **Cloudflare Email Routing**: `support@${DOMAIN}` → bestehendes Postfach, reine Dashboard-Konfiguration, keine eingehenden Ports. Nur Empfang/Weiterleitung; Senden-als erfordert zusätzlich einen SMTP-Relay (nicht im Scope).

### 5.5 `wireguard` / `tailscale` — [OPTIONAL, NICHT im Default-Scope]
Nur einbauen, wenn ausdrücklich angefordert. Ohne dieses Modul sind Admin & Dashboards nur im LAN erreichbar (bewusste Entscheidung).
- **Empfehlung:** Tailscale (kein Port-Forwarding, CGNAT-tauglich, kostenloser Personal-Tarif).
- **Alternative:** self-hosted WireGuard (benötigt **eine** UDP-Portfreigabe → widerspricht [N1], daher nur bewusst).

### 5.6 `claude-code` — [OPTIONAL, Debug-Werkzeug, kein Dienst im Docker-Sinne]
Ergänzt in v2.1. Kein eigener Container, kein `restart: unless-stopped`, kein
Eintrag in `docker-compose.yml` — ein CLI-Werkzeug, das **auf Anfrage**
(on-demand) direkt auf dem Host-OS des Pi läuft, um Debugging/Wartung dieses
Stacks per Konversation mit Claude zu unterstützen ("Closed-Loop"-Debugging
direkt am Gerät statt nur über einen entfernten Chat).

- **Installation:** `scripts/install-claude-code.sh` (Node.js LTS + `npm
  install -g @anthropic-ai/claude-code`; bewusst **nicht** der native
  Installer, da dieser auf ARM64/Raspberry Pi zum Zeitpunkt der Erstellung
  dieser Spezifikation bekannte Probleme hat).
- **Betriebsmodus:** [M9] **Kein Hintergrunddienst.** Kein systemd-Unit, kein
  Cronjob, kein Autostart. Aufruf ausschließlich manuell (`claude` im
  Projektverzeichnis), Ressourcenverbrauch nur während einer aktiven Sitzung
  — Begründung: Ressourcenschonung auf der begrenzten Pi-Hardware, siehe
  [N6].
- **Authentifizierung:** headless-tauglich über `ANTHROPIC_API_KEY` (API-Key)
  oder `CLAUDE_CODE_OAUTH_TOKEN` (auf einem Gerät mit Browser per `claude
  setup-token` erzeugt, Wert dann auf dem Pi gesetzt) — kein interaktiver
  Browser-Login auf dem headless Pi.
- **Netzwerk:** ausschließlich ausgehende Verbindungen zur Anthropic-API,
  keine zusätzliche eingehende Portfreigabe — widerspricht damit nicht [N1].
- **Kontext:** liest beim Start automatisch `CLAUDE.md` und diese
  Spezifikation aus dem Projektverzeichnis; dieselbe Instanz aus Abschnitt 0
  begleitet damit sowohl den initialen Aufbau als auch spätere
  Live-Debugging-Sitzungen direkt auf dem Gerät.
- **Hardware-Hinweis:** Anthropics offizielles Minimum für die CLI ist 4 GB
  RAM. Auf einem Pi 4 mit 1–2 GB RAM konkurriert eine aktive Sitzung mit den
  laufenden Containern um Arbeitsspeicher — für dieses Modul wird ein Pi 4
  mit **mindestens 4 GB RAM** empfohlen.

### Zusätzliche Regel durch 5.6 (Ergänzung zu Abschnitt 3)
- [M9] Claude Code CLI läuft ausschließlich on-demand, nie als
  Hintergrunddienst/Autostart.
- [N6] Kein systemd-Unit, kein Cronjob und kein sonstiger Autostart-Mechanismus
  für die Claude Code CLI.

### Netzwerke & Policy (Compose)
- Netzwerk `edge`: `caddy` + `cloudflared` + dynamische Apps (`app-example`, …).
- Netzwerk `lan_net`: `pihole` + `uptime-kuma`.
- `caddy` und die Apps sind ausschließlich über `edge` erreichbar (kein Host-Port).

---

## 6. KONFIGURATIONS-TEMPLATES

Der Agent generiert diese Dateien vollständig; hier die verbindlichen Skelette.

### 6.1 `docker-compose.yml` (Skelett)
```yaml
services:
  pihole:
    image: pihole/pihole:<<PIN_TAG>>
    restart: unless-stopped
    environment:
      TZ: ${TZ}
      # Pi-hole v6: exakten Passwort-Env-Namen gegen Doku verifizieren
      FTLCONF_webserver_api_password: ${PIHOLE_PASSWORD}
      # Pflicht in Docker-Netzwerken, siehe 5.1 - sonst werden LAN-Clients verworfen
      FTLCONF_dns_listeningMode: "ALL"
    ports:
      - "${PI_STATIC_IP}:${PORT_DNS}:53/tcp"
      - "${PI_STATIC_IP}:${PORT_DNS}:53/udp"
      - "${PI_STATIC_IP}:${PORT_PIHOLE_UI}:80/tcp"
    volumes:
      - ./data/pihole/etc-pihole:/etc/pihole
    networks: [lan_net]

  caddy:
    image: caddy:<<PIN_TAG>>-alpine
    restart: unless-stopped
    environment:
      DOMAIN: ${DOMAIN}
    volumes:
      - ./config/caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - ./sites:/srv:ro
      - ./data/caddy/data:/data
      - ./data/caddy/config:/config
    networks: [edge]
    # KEIN ports: (Constraint M8)

  # Dynamische Apps: je App ein Dienst mit build: ./apps/<name>, networks: [edge].
  app-example:
    build: ./apps/app-example
    restart: unless-stopped
    networks: [edge]

  cloudflared:
    image: cloudflare/cloudflared:<<PIN_TAG>>
    restart: unless-stopped
    command: tunnel --no-autoupdate run --token ${CLOUDFLARE_TUNNEL_TOKEN}
    depends_on: [caddy]
    networks: [edge]

  uptime-kuma:
    image: louislam/uptime-kuma:<<PIN_TAG>>
    restart: unless-stopped
    ports:
      - "${PI_STATIC_IP}:${PORT_UPTIME}:3001"
    volumes:
      - ./data/uptime-kuma:/app/data
    networks: [lan_net]

networks:
  edge:
  lan_net:
```

### 6.2 `.env.example`
```dotenv
TZ=Europe/Berlin
LAN_SUBNET=192.168.1.0/24
PI_STATIC_IP=192.168.1.10
PORT_PIHOLE_UI=8080
PORT_DNS=53
PORT_UPTIME=3001
DOMAIN=<<DOMAIN>>
PIHOLE_PASSWORD=<<PIHOLE_PASSWORD>>
CLOUDFLARE_TUNNEL_TOKEN=<<CLOUDFLARE_TUNNEL_TOKEN>>
AGE_RECIPIENT=<<AGE_RECIPIENT_PUBLIC_KEY>>
```

### 6.3 `.gitignore`
```gitignore
.env
/data/
*.tar.gz
*.age
*.gpg
```

### 6.4 `website/index.html`
Minimaler valider HTML5-Platzhalter mit dem Hostnamen/Domain als Titel.

---

## 7. SYSTEM-SETUP (Skripte)

### 7.1 `scripts/00-bootstrap.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y git ufw fail2ban unattended-upgrades rclone age
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"
sudo dpkg-reconfigure -plow unattended-upgrades
echo "Bootstrap fertig. Bitte neu einloggen (Docker-Gruppe)."
```
`git` wurde in v2.1 ergänzt: Raspberry Pi OS Lite hat es nicht vorinstalliert,
wird aber vor diesem Skript zum Klonen des Repos benötigt (siehe README).

### 7.2 `scripts/01-harden.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail
# Werte aus .env laden
set -a; source ../.env; set +a

# SSH-Härtung
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sudo systemctl restart ssh

# Firewall: Default-Deny eingehend, Zugriff nur aus LAN
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from "${LAN_SUBNET}" to any port 22
sudo ufw allow from "${LAN_SUBNET}" to any port "${PORT_DNS}"
sudo ufw allow from "${LAN_SUBNET}" to any port "${PORT_PIHOLE_UI}"
sudo ufw allow from "${LAN_SUBNET}" to any port "${PORT_UPTIME}"
sudo ufw --force enable
```
Muss vor dem Deaktivieren von `PasswordAuthentication` prüfen, ob
`~/.ssh/authorized_keys` befüllt ist, und andernfalls mit Fehlermeldung
abbrechen (Selbstaussperr-Schutz, in v2.0 als Implementierungsdetail ergänzt).

---

## 8. BACKUP & RESTORE

### 8.1 Zwei getrennte Spuren
- **Config/Code → GitHub (privates oder öffentliches Repo):** alles außer `.env` und `data/`.
- **Daten/Secrets → Backup-Remote (verschlüsselt):** `data/`-Volumes + verschlüsselte `.env`.

### 8.2 `scripts/backup.sh` (Spezifikation)
1. `data/` in `backup-YYYY-MM-DD.tar.gz` packen.
2. `.env` mitsichern.
3. Mit `age` (Public-Key, `${AGE_RECIPIENT}`) verschlüsseln → `.age`.
4. Per `rclone copy` nach `${BACKUP_REMOTE}` schieben.
5. Rotation: `${BACKUP_RETENTION_DAILY}` tägliche + `${BACKUP_RETENTION_WEEKLY}` wöchentliche Stände behalten, ältere löschen.
6. Als Cron-Job (nächtlich) einrichten.

**Betriebsanforderungen (v2.3, aus Praxis-Verifikation):**
- Läuft als **root** (Cron-Job in der root-crontab): die Dateien unter
  `data/` gehören den Container-Nutzern; ein tar ohne root scheitert an
  "Permission denied" — beim nächtlichen Lauf unbemerkt.
- `rclone` wird dabei als **Repo-Besitzer** (normaler Nutzer) ausgeführt,
  damit dessen `~/.config/rclone` verwendet wird und Token-Erneuerungen
  die Konfigurationsdatei nicht auf root umkippen.
- tar-Exit-Code 1 ("file changed as we read it") wird akzeptiert — die
  Container schreiben während des Backups weiter in ihre Datenbanken.

### 8.3 Restore-Prozedur
1. OS auf das Boot-Medium flashen, `00-bootstrap.sh` + `01-harden.sh` ausführen.
2. Repo klonen.
3. Neustes `.age`-Backup aus `${BACKUP_REMOTE}` holen, entschlüsseln, `data/` + `.env` wiederherstellen.
4. `docker compose up -d`.

Muss laut [M7] einmal real getestet werden, bevor das Setup als
abgeschlossen gilt.

---

## 9. UMSETZUNGSREIHENFOLGE (mit Definition of Done)

| # | Schritt | Definition of Done |
|---|---|---|
| 1 | Repo-Skelett + `.gitignore` + `.env.example` | `git status` zeigt keine Secrets/`data/`; Struktur = Abschnitt 4 |
| 2 | `00-bootstrap.sh` | Docker, git & Pakete installiert, Skript idempotent |
| 3 | `01-harden.sh` | SSH key-only; `ufw status` = Default-Deny + nur LAN-Regeln |
| 4 | `pihole` | Web-UI nur unter `${PI_STATIC_IP}:${PORT_PIHOLE_UI}`; DNS filtert im LAN |
| 5 | `caddy` + `cloudflared` | `${DOMAIN}` öffentlich per HTTPS erreichbar; `caddy` hat keinen Host-Port (bis v2.3 hieß dieser Dienst `web`/nginx, siehe 5.2) |
| 6 | `uptime-kuma` | UI nur im LAN; Checks für web/pihole/Internet aktiv |
| 7 | `backup.sh` + Cron | Backup landet verschlüsselt im Remote; Rotation greift |
| 8 | **Restore-Test** | Kompletter Restore auf leerem System erfolgreich ([M7]) |
| 9 | `README.md` | Setup vollständig; verwendete Image-Tags notiert |
| 10 | `claude-code` (optional, 5.6) | CLI installiert, Login funktioniert, läuft nachweislich nicht als Hintergrunddienst ([M9]/[N6]) |

---

## 10. VOM NUTZER AUSZUFÜLLENDE PARAMETER

- `<<DOMAIN>>` — registrierte Domain (empf. via Cloudflare Registrar, alternativ: bestehende Domain per Nameserver-Wechsel zu Cloudflare verbinden).
- `<<CLOUDFLARE_TUNNEL_TOKEN>>` — aus dem Cloudflare-Zero-Trust-Dashboard.
- `<<PIHOLE_PASSWORD>>` — Admin-Passwort Pi-hole.
- `<<AGE_RECIPIENT_PUBLIC_KEY>>` — age-Public-Key für Backup-Verschlüsselung (in v2.0 ergänzt, technisch notwendig für 8.2).
- `LAN_SUBNET` / `PI_STATIC_IP` — an das eigene Heimnetz anpassen.
- `<<PIN_TAG>>` je Image — vom Agenten auf aktuelle stabile Version gesetzt.
- Entscheidung: cloudflared **Token-Methode** (Default, gewählt) oder **config.yml**.
- Entscheidung: Backup-Verschlüsselung mit `age` (Default, gewählt) oder `gpg`.
- Optional: Claude Code CLI (5.6) einrichten, inkl. `ANTHROPIC_API_KEY` oder `CLAUDE_CODE_OAUTH_TOKEN`.

---

## Änderungshistorie

- **v2.0:** `AGE_RECIPIENT` ergänzt (technische Notwendigkeit für 8.2, ursprünglich nicht in Abschnitt 1 vorgesehen); `git` in 7.1 ergänzt; Selbstaussperr-Schutz in 7.2 ergänzt.
- **v2.1:** Abschnitt 5.6 (`claude-code`, optionales On-Demand-Debug-Werkzeug) sowie [M9]/[N6] ergänzt; Repo-Struktur (Abschnitt 4) um `CLAUDE.md`, diese Datei und `scripts/install-claude-code.sh` erweitert; Umsetzungstabelle (Abschnitt 9) um Zeile 10 ergänzt.
- **v2.2:** `FTLCONF_dns_listeningMode: "ALL"` als Pflicht-Env für `pihole` ergänzt (5.1, 6.1) — ohne diese Einstellung verwirft Pi-hole v6 im Docker-Bridge-Netz echte LAN-Clients stillschweigend als "non-local"; auf realer Hardware gefunden und verifiziert.
- **v2.3:** Betriebsanforderungen für `backup.sh` präzisiert (8.2): läuft als root (root-crontab), da `data/` den Container-Nutzern gehört; rclone dabei als Repo-Besitzer; tar-Exit-Code 1 bei laufenden Containern akzeptiert. Skripte erhalten Selbstschutz-Guards (mit/ohne sudo, fehlende `.env`/`ufw`).
- **v2.4:** Multi-Website-Hosting: `nginx`/`web` durch `caddy` (Reverse Proxy) ersetzt (5.2); `sites/` (statisch) + `apps/` (dynamisch, eigener Container) + `config/caddy/Caddyfile` + `scripts/deploy-site.sh` ergänzt (Repo-Struktur Abschnitt 4). Cloudflare-Wildcard-Einschränkung (kostenloser Plan) dokumentiert; alle Public Hostnames → `http://caddy:80`. Cloudflare Email Routing für `support@${DOMAIN}` (5.4b). Uptime Kuma: SQLite empfohlen, Pi-hole-Monitor über internen Servicenamen.

*Ende SPEC v2.4 — hardware-frei, agenten-optimiert.*
