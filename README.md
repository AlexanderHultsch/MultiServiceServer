# PiMultiServiceServer — Sicherer Multi-Service-Server für Raspberry Pi 4

Dieses Repository baut aus einem Raspberry Pi 4 einen kleinen, sicheren
Heimserver auf. Setzt `raspberry-pi-4-spezifikation.md` (v2.4) um, die als
maßgebliche Quelle der Wahrheit für alle technischen Entscheidungen dient.

## Was am Ende dabei herauskommt

- **Beliebig viele Websites** unter deiner eigenen Domain und Subdomains
  (`deine-domain.de`, `beispiel.deine-domain.de`, …), öffentlich im Internet
  erreichbar — ohne einen einzigen Port am Router freizugeben. Statische
  Seiten und dynamische Apps (eigener Container) parallel, jede optional in
  ihrem eigenen Git-Repo (siehe „Weitere Websites hosten").
- **Pi-hole**: ein netzwerkweiter DNS-Server, der Werbung und Tracker für
  alle Geräte in deinem Heimnetz blockiert (Handys, Laptops, Smart-TVs, …),
  ohne dass auf jedem Gerät einzeln etwas installiert werden muss.
- **Uptime Kuma**: ein Dashboard, das dir anzeigt, ob Webseite, Pi-hole und
  Internetverbindung laufen, und dich bei Ausfällen benachrichtigt.
- **Automatische, verschlüsselte Backups** aller Konfigurationsdaten in die
  Cloud (z. B. OneDrive), mit Rotation alter Stände.
- Ein System, das nach den üblichen Grundregeln für Internet-exponierte
  Server gehärtet ist: kein Passwort-Login per SSH, Firewall im
  Default-Deny-Modus, keine unnötig offenen Ports.

Die Websites laufen technisch hinter einem **Cloudflare Tunnel**: der Pi baut
selbst eine ausgehende, verschlüsselte Verbindung zu Cloudflare auf, worüber
die Seiten öffentlich erreichbar werden. Von außen bleibt am Router dadurch
kein einziger Port offen — der Pi ist im Heimnetz unsichtbar. Innerhalb des
Pi verteilt **Caddy** (ein Reverse Proxy) jeden Hostnamen an die richtige
Seite: statische Seiten direkt aus Ordnern, dynamische Apps an deren Container.

```
                     Internet
                        │  (nur AUSGEHEND, verschlüsselt)
                 ┌──────▼──────┐
                 │ Cloudflare  │  DNS · TLS · DDoS-Schutz · versteckt Heim-IP
                 └──────┬──────┘
                        │  outbound-only Tunnel
╔═══════════════════════▼═══════════════════════════════════════╗
║ Raspberry Pi · ufw Default-Deny (eingehend)                   ║
║                                                               ║
║  cloudflared ──▶ caddy ──▶ sites/main        (statisch)       ║
║                    │  └───▶ sites/beispiel     (statisch)       ║
║                    └──────▶ app-example       (dynam. App)    ║
║                                                               ║
║  pihole (DNS+Adblock, nur LAN)   uptime-kuma (nur LAN)        ║
╚═══════════════════════════════════════════════════════════════╝
                        │
                   LAN (${LAN_SUBNET})
          alle Geräte nutzen ${PI_STATIC_IP} als DNS
```

Dieses README erklärt zu jedem Wert, den du eintragen musst, **woher** er
kommt und **wie** du ihn bekommst. Wo es ging, wurde die manuelle Arbeit in
Skripte gepackt (`scripts/setup-env.sh`, `scripts/verify.sh`,
`scripts/install-backup-cron.sh`) — übrig bleiben nur die Schritte, die
zwingend eine Cloudflare-/Router-Weboberfläche brauchen.

> **Hinweis, falls das Repository öffentlich ist:** Jeder kann
> `docker-compose.yml`, die Skripte und dieses README lesen. Das ist
> unproblematisch, solange `.env` und `data/` (siehe `.gitignore`) niemals
> committet werden — dort leben alle Geheimnisse (Pi-hole-Passwort,
> Cloudflare-Token, age-Key). Vor jedem `git push`: `git status` prüfen,
> im Zweifel `git ls-files | grep -E '(^|/)\.env$|^data/'` ausführen (muss
> leer sein — wird auch von `scripts/verify.sh` automatisch geprüft).

---

## Übersicht: automatisiert vs. manuell

| Automatisiert (per Skript) | Manuell (Web-UI / Router, nicht automatisierbar) |
|---|---|
| System-Update, Docker-Installation | SD-Karte flashen |
| SSH-Härtung, Firewall-Regeln | SSH-Public-Key auf dem Pi hinterlegen |
| `.env` erzeugen inkl. LAN-Erkennung | Domain zu Cloudflare hinzufügen |
| age-Schlüsselpaar erzeugen | Cloudflare Tunnel + Public Hostname anlegen |
| Backup, Verschlüsselung, Rotation, Upload | `rclone config` (OAuth-Login im Browser) |
| Cron-Job für nächtliches Backup | DHCP-Reservierung + Pi-hole als DNS im Router |
| Alle Verifikations-Checks (`verify.sh`) | Realer Restore-Test auf frischer Hardware ([M7]) |

---

## Voraussetzungen

- Ein Computer (Windows/Mac/Linux) zum Flashen der SD-Karte und für SSH.
- Raspberry Pi 4, microSD-Karte oder USB-SSD, Netzteil, Netzwerkkabel oder WLAN.
- Ein Cloudflare-Account (kostenlos): <https://dash.cloudflare.com/sign-up>
- Eine Domain, die bei Cloudflare als "Zone" verwaltet wird. Ohne bestehende
  Domain am einfachsten: direkt im Cloudflare Dashboard eine registrieren
  (landet automatisch auf Cloudflare-Nameservern). Mit bestehender Domain
  bei einem anderen Anbieter: im Cloudflare Dashboard hinzufügen, die zwei
  angezeigten Nameserver beim bisherigen Anbieter eintragen — die
  Registrierung selbst muss dafür nicht umziehen.
- Ein Ziel für verschlüsselte Backups, das `rclone` unterstützt (Default:
  OneDrive — jeder von `rclone config` unterstützte Dienst funktioniert).

### SSH-Schlüsselpaar erzeugen (falls noch nicht vorhanden)

Wird gebraucht, um sich später passwortlos auf dem Pi anzumelden — Pflicht
laut Spezifikation ([M6]: kein Passwort-Login).

```bash
# Mac/Linux (auf dem eigenen Computer, NICHT auf dem Pi):
ls ~/.ssh/id_ed25519.pub 2>/dev/null || ssh-keygen -t ed25519 -C "pi-server"
```

Windows: PowerShell öffnen und denselben Befehl ausführen (OpenSSH-Client ist
seit Windows 10 vorinstalliert), oder PuTTYgen verwenden.

---

## Schnellstart (Copy & Paste)

**Alle 16 Schritte im Überblick** — Details folgen darunter:

| # | Schritt | Wo |
|---|---|---|
| 1 | SD-Karte flashen, SSH vorbereiten | Eigener Computer |
| 2 | Per SSH verbinden | Eigener Computer |
| 3 | Repo klonen | Pi |
| 4 | `.env` per Assistent erzeugen | Pi |
| 5 | Bootstrap (Docker, Pakete) | Pi |
| 6 | Feste IP reservieren | Router |
| 7 | Härtung (SSH, Firewall) | Pi |
| 8 | Cloudflare Tunnel anlegen | Cloudflare-Dashboard |
| 9 | Dienste starten | Pi |
| 10 | Pi-hole als Netzwerk-DNS | Router |
| 11 | Öffentliche Webseite prüfen | Pi |
| 12 | Uptime Kuma einrichten | Browser (LAN) |
| 13 | Backup-Ziel verbinden (rclone) | Pi |
| 14 | Backup testen + Cron einrichten | Pi |
| 15 | Gesamt-Verifikation | Pi |
| 16 | Restore-Test | Frisches System |

> **Sudo-Konvention:** Alle Skripte **ohne** `sudo` starten — sie fordern
> root-Rechte selbst an, wo nötig, und brechen mit klarer Meldung ab, wenn
> etwas fehlt. Einzige Ausnahme: `scripts/backup.sh` braucht
> `sudo bash scripts/backup.sh` (Begründung in Schritt 14).

### 1. SD-Karte flashen und SSH vorbereiten

> **Kein Standard-Benutzer "pi" mehr:** Seit Raspberry Pi OS "Bookworm" gibt
> es keinen vorinstallierten `pi`-Nutzer. Im Imager wird unter "Advanced
> options" ein **eigener Benutzername** festgelegt. In diesem README steht
> überall `<benutzer>` als Platzhalter dafür — in jedem Befehl durch den
> tatsächlich vergebenen Namen ersetzen.

1. [Raspberry Pi Imager](https://www.raspberrypi.com/software/) installieren und öffnen.
2. Gerät: **Raspberry Pi 4**. Betriebssystem: **Raspberry Pi OS Lite (64-bit)**.
3. Auf das Zahnrad-Symbol (⚙, "Advanced options") klicken, dort:
   - Hostname vergeben (z. B. `pi-server`)
   - **Benutzername und Passwort festlegen** — ein Passwort auch dann
     setzen, wenn Public-Key-Login gewünscht ist (Fallback, falls der
     Key-Import nicht greift, siehe Kasten unten — das kommt gelegentlich vor).
   - SSH aktivieren → "Allow public-key authentication only" → den
     **Public Key** einfügen (Inhalt von `~/.ssh/id_ed25519.pub`, NICHT den
     privaten Schlüssel!). Manche Imager-Versionen übernehmen den
     eingefügten Key beim Schreiben nicht zuverlässig — nach dem ersten
     Login immer mit dem Befehl im Kasten unten verifizieren.
   - Falls per WLAN: SSID/Passwort hinterlegen
4. Schreiben, SD-Karte in den Pi, Pi einschalten.

#### Prüfen, was der Imager tatsächlich eingerichtet hat

Nach dem ersten Login **immer** prüfen, ob wirklich ein **Public Key**
hinterlegt wurde (nicht nur Passwort-Login funktioniert) — Voraussetzung für
Schritt 7 (`01-harden.sh` bricht sonst mit einer Fehlermeldung ab, damit man
sich nicht aussperrt):

```bash
cat ~/.ssh/authorized_keys 2>/dev/null && echo "OK: Key vorhanden" || echo "FEHLT: siehe unten"
```

**Falls das leer ist** (Imager-Key-Import hat nicht funktioniert, Login
gerade nur per Passwort — ein bekanntes, gelegentliches Imager-Problem):
Key jetzt vom eigenen Computer aus nachtragen, über die bestehende
Passwort-Anmeldung:

```bash
# Mac/Linux, auf dem eigenen Computer, Passwort wird einmal abgefragt:
ssh-copy-id <benutzer>@pi-server.local
```

```powershell
# Windows (PowerShell), auf dem eigenen Computer, falls ssh-copy-id fehlt:
Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub | ssh <benutzer>@pi-server.local "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
```

Danach auf dem Pi erneut prüfen (Befehl oben) — erst wenn "OK: Key
vorhanden" erscheint, weiter mit Schritt 2 bzw. Schritt 7.

### 2. Verbinden

```bash
# Pi im Netzwerk finden (Standard-Hostname bzw. der vergebene):
ping pi-server.local

# Verbinden (<benutzer> = der im Imager gesetzte Benutzername):
ssh <benutzer>@pi-server.local
```

Falls `*.local` nicht auflöst: IP über die Geräteliste des Routers ermitteln
(Admin-Oberfläche des Routers, meist erreichbar unter `192.168.0.1` oder
`192.168.1.1` — steht auf der Rückseite des Routers oder in dessen App).

### 3. Repo klonen

Raspberry Pi OS Lite hat `git` nicht vorinstalliert — an dieser Stelle ist
`scripts/00-bootstrap.sh` (das `git` mitinstalliert) noch nicht ausgeführt,
also erst kurz manuell nachinstallieren:

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/AlexanderHultsch/PiMultiServiceServer.git ~/pi-server
cd ~/pi-server
```

### 4. `.env` interaktiv erzeugen

```bash
bash scripts/setup-env.sh
```

Das Skript fragt jeden Wert einzeln ab, erklärt dabei woher er kommt,
schlägt sinnvolle Defaults vor (u. a. automatisch erkanntes LAN), generiert
bei Bedarf ein sicheres Pi-hole-Passwort sowie automatisch das
age-Schlüsselpaar fürs Backup, und schreibt am Ende `.env` (mit `chmod 600`).

Falls der Cloudflare-Tunnel-Token (Schritt 8) noch nicht vorliegt: bei der
Frage einfach Enter drücken und später manuell in `.env` nachtragen — das
Skript weist am Ende noch einmal darauf hin.

### 5. System-Bootstrap (Docker, Pakete, Updates)

```bash
bash scripts/00-bootstrap.sh
```

Danach einmal ab- und wieder anmelden (die neue `docker`-Gruppenmitgliedschaft
wird erst nach einem neuen Login aktiv):

```bash
exit
ssh <benutzer>@pi-server.local
cd ~/pi-server
```

### 6. Feste IP für den Pi reservieren (Router, manuell)

**Wichtig zu verstehen:** Diese Reservierung verknüpft eine **MAC-Adresse**
mit einer IP. WLAN und Ethernet (LAN-Kabel) sind auf dem Pi **zwei
unterschiedliche Netzwerk-Interfaces mit je einer eigenen MAC-Adresse**
(`wlan0` bzw. `eth0`). Der Router muss wissen, **welche der beiden
MAC-Adressen gerade tatsächlich verbunden ist** — die IP wird für genau
dieses Interface reserviert. Bei einem späteren Wechsel des Interfaces (z. B.
WLAN → LAN-Kabel) muss die Reservierung im Router einmalig auf die andere
MAC-Adresse umgestellt werden (siehe Kasten unten) — `PI_STATIC_IP` selbst
bleibt dabei gleich.

Zweiter entscheidender Punkt: **die IP, die im Router bei der Reservierung
steht, muss exakt mit `PI_STATIC_IP` in `.env` übereinstimmen** — das
passiert nicht automatisch, nur weil ein Schalter aktiv ist.

1. Herausfinden, welches Interface gerade aktiv verbunden ist, und dessen
   MAC-Adresse notieren:
   ```bash
   ip -4 addr show
   ```
   Das Interface mit einer Zeile `inet 192.168.x.x/24 ...` ist das aktive.
   MAC-Adresse dieses Interfaces:
   ```bash
   ip link show wlan0 | awk '/ether/ {print $2}'   # bei Ethernet: eth0 statt wlan0
   ```
2. Aktuellen `PI_STATIC_IP`-Wert aus `.env` nachsehen, damit klar ist,
   welche IP im Router eingetragen sein muss:
   ```bash
   grep -E 'PI_STATIC_IP|LAN_SUBNET' ~/pi-server/.env
   ```

#### FRITZ!Box (sehr verbreitet, z. B. AVM-Router)

1. Im Browser <http://fritz.box> (oder <http://192.168.178.1>) öffnen, mit
   dem Kennwort der FRITZ!Box anmelden.
2. **Heimnetz → Netzwerk → Netzwerkverbindungen**.
3. Den Pi in der Geräteliste suchen (Name `pi-server` bzw. die MAC-Adresse
   des **aktiven** Interfaces von oben) und auf das Stift-/Bearbeiten-Symbol
   klicken.
4. Dort findet sich der Schalter **"IPv4-Adresse dauerhaft zuweisen"**.
   Direkt daneben/darüber steht ein **IPv4-Adressfeld**: genau **dieser
   Wert** ist die IP, die reserviert wird.
   - Steht dort bereits dieselbe Adresse wie `PI_STATIC_IP` aus `.env` →
     nichts weiter zu tun, mit **Übernehmen** bestätigen/speichern.
   - Steht dort eine **andere** Adresse (typisch, wenn der Pi vorher
     automatisch per DHCP eine andere IP bekommen hat): entweder das Feld
     auf den Wert von `PI_STATIC_IP` ändern (muss innerhalb des von der
     FRITZ!Box verwalteten Bereichs liegen, Standard meist `192.168.178.x`),
     **oder** einfacher: den im Router angezeigten Wert 1:1 in `.env` als
     `PI_STATIC_IP` übernehmen (`nano ~/pi-server/.env`).
5. **FRITZ!Box-Standard-LAN ist `192.168.178.0/24`**, nicht `192.168.1.0/24`.
   Falls `LAN_SUBNET` in `.env` noch `192.168.1.0/24` ist (z. B. weil
   `setup-env.sh` es nicht korrekt erkannt hat), jetzt auf `192.168.178.0/24`
   korrigieren — sonst funktionieren die `ufw`-Regeln aus Schritt 7 nicht
   für das tatsächliche LAN.
6. Speichern/**Übernehmen** klicken.

#### Andere Router-Hersteller

Menüpunkt heißt dort meist **"DHCP-Reservierung"** / **"Static Lease"** /
**"Address Reservation"** (Bezeichnung variiert je nach Hersteller); gleiches
Prinzip: MAC-Adresse des **aktiven** Interfaces mit dem `PI_STATIC_IP`-Wert
aus `.env` verknüpfen — im Zweifel lieber die im Router angezeigte/vergebene
Adresse in `.env` übernehmen als umgekehrt.

#### Später von WLAN auf LAN-Kabel wechseln

Bei Einrichtung über WLAN mit späterem Wechsel auf ein LAN-Kabel: das ändert
**nichts** an `.env`, `docker-compose.yml` oder den `ufw`-Regeln — die IP
bleibt identisch, nur die Netzwerk-Hardware wechselt. Zu erledigen ist dann
nur:

1. LAN-Kabel einstecken.
2. Im Router (FRITZ!Box: siehe oben) die **gleiche Reservierung** (gleiche
   `PI_STATIC_IP`) auf die MAC-Adresse von `eth0` umstellen (statt `wlan0`):
   ```bash
   ip link show eth0 | awk '/ether/ {print $2}'
   ```
   Diesen Wert im Router anstelle der bisherigen `wlan0`-MAC-Adresse eintragen.
3. `sudo reboot`, danach mit dem Verifikationsbefehl unten prüfen.

**WLAN dabei aktiviert lassen, nicht deaktivieren.** Linux bevorzugt bei
gleichzeitig aktivem Ethernet und WLAN automatisch die Kabelverbindung
(bessere Routing-Metrik) — ein zusätzlicher Schritt ist dafür nicht nötig.
Ein aktiviertes, aber ungenutztes WLAN dient als Rückfalloption: Wird das
Kabel versehentlich abgezogen oder gelöst, bleibt der Pi trotzdem über WLAN
erreichbar, statt komplett vom Netz getrennt zu sein. **`sudo rfkill block
wifi` wird deshalb nicht mehr empfohlen** — dieser Zustand übersteht Reboots
(siehe Troubleshooting-Eintrag "Nach einem Neustart keine Verbindung mehr,
WLAN tot") und kann genau die Situation verursachen, die er vermeiden sollte:
kompletter Verbindungsverlust nach einem Neustart, sobald aus irgendeinem
Grund kein Ethernet-Link mehr vorhanden ist. Falls WLAN aktuell blockiert
ist: `sudo rfkill unblock wifi`.

#### Nach dem Speichern

```bash
sudo reboot
```

Nach dem Neustart erneut verbinden und prüfen, dass der Pi tatsächlich die
reservierte Adresse hat (funktioniert unabhängig davon, ob WLAN oder
Ethernet aktiv ist):

```bash
ssh <benutzer>@pi-server.local
ip -4 addr show | grep inet
```

Das Ergebnis muss die in `.env` eingetragene `PI_STATIC_IP` enthalten —
falls nicht, `.env` entsprechend anpassen, bevor es mit Schritt 7 weitergeht.

### 7. Härtung: SSH key-only + Firewall Default-Deny

```bash
bash scripts/01-harden.sh
```

Das Skript bricht **mit Fehlermeldung ab**, falls unter
`~/.ssh/authorized_keys` noch kein Public Key hinterlegt ist — das schützt
davor, sich versehentlich selbst auszusperren.

Verifizieren:

```bash
sudo ufw status verbose
```

Erwartet: `Default: deny (incoming), allow (outgoing)` und Regeln nur für
`${LAN_SUBNET}`.

### 8. Cloudflare Tunnel einrichten (einmalig, im Dashboard)

Das ist der einzige Schritt, der sich nicht per Kommandozeile automatisieren
lässt (OAuth-geschützte Weboberfläche).

1. <https://one.dash.cloudflare.com> öffnen (ggf. Zero Trust kostenlos aktivieren).
2. Links im Menü **Networks → Tunnels → Create a tunnel**.
3. Connector-Typ **Cloudflared** wählen, Namen vergeben (z. B. `pi-server`).
4. Bei "Choose your environment" auf **Docker** klicken. Es erscheint ein
   Befehl wie:
   ```
   docker run cloudflare/cloudflared:... tunnel --no-autoupdate run --token eyJhIjoi...
   ```
   Nur den Teil nach `--token` kopieren (die lange Zeichenkette) — das ist
   `CLOUDFLARE_TUNNEL_TOKEN`.
5. In `.env` eintragen:
   ```bash
   nano .env
   # CLOUDFLARE_TUNNEL_TOKEN=<eingefügter Wert>
   ```
6. Im selben Tunnel-Setup (oder danach unter dem Tunnel → **Published
   Application routes** → **Add published application**, aktuelle
   Cloudflare-Bezeichnung, Stand 2026):
   - **Subdomain**: leer lassen, außer eine Subdomain wie `www.` ist gewünscht
   - **Domain**: der `DOMAIN`-Wert aus `.env`
   - **Path**: leer lassen (matcht alles)
   - **Service URL**: `http://caddy:80` — **nicht** `localhost`! `caddy` ist
     der interne Docker-Servicename des Reverse Proxys aus
     `docker-compose.yml`, nur für `cloudflared` im `edge`-Netzwerk
     erreichbar; Port `80`, weil Caddy dort lauscht (kein Host-Port, siehe [M8]).
   - **Add route** klicken.

   > **Alle** öffentlichen Hostnamen (Hauptdomain und später jede Subdomain)
   > zeigen auf **denselben** Service `http://caddy:80` — Caddy verteilt intern
   > anhand des Hostnamens an die richtige Seite. Für jede weitere Subdomain
   > wird hier später ein weiterer Public Hostname angelegt (siehe „Weitere
   > Websites hosten"). Wildcard (`*.deine-domain.de`) geht auf dem kostenlosen
   > Cloudflare-Plan nicht, daher pro Subdomain ein Eintrag.

### 9. Dienste starten

```bash
docker compose config   # Syntax-/Wertecheck
docker compose up -d     # baut beim ersten Mal die Beispiel-App (app-example)
docker compose ps
```

Alle Dienste sollten `running` sein (`pihole`, `caddy`, `app-example`,
`cloudflared`, `uptime-kuma`). Beim ersten Start baut Docker das Image der
Beispiel-App — das dauert einmalig ein bis zwei Minuten.

### 10. Pi-hole als Netzwerk-DNS eintragen (Router, manuell)

- **Web-UI aufrufen:** `http://<PI_STATIC_IP>:<PORT_PIHOLE_UI>/admin/` — mit
  den tatsächlichen Werten aus `.env`, z. B. `http://192.168.178.53:8080/admin/`.
  Der Pfad **`/admin/` am Ende ist Pflicht** (Pi-hole v6 leitet von der
  reinen IP/Port-Adresse nicht automatisch dorthin um). Login mit
  `PIHOLE_PASSWORD`. Nur aus dem LAN erreichbar.
- **Hinweis "Consider upgrading to HTTPS":** Diese Meldung zeigt Pi-hole
  standardmäßig an, weil die Oberfläche per HTTP läuft. Unproblematisch für
  dieses Setup, da die UI ohnehin nur aus dem LAN erreichbar ist (per
  `ufw`-Regel abgesichert, siehe Schritt 7) — kann einfach ignoriert werden.
  Wer möchte, kann in der Pi-hole-UI unter **Settings → Web Interface / API**
  HTTPS mit einem selbstsignierten Zertifikat aktivieren; der Browser zeigt
  dann allerdings eine Zertifikatswarnung, da das Zertifikat nicht von einer
  öffentlichen Stelle ausgestellt ist.
- **Pi-hole als DNS-Server für das gesamte Heimnetz eintragen** — bei einer
  FRITZ!Box:
  1. **Heimnetz → Netzwerk → Netzwerkeinstellungen**.
  2. Ggf. auf **"Weitere Einstellungen anzeigen"** klicken, damit alle
     Felder sichtbar sind.
  3. Im Abschnitt zur **IPv4-Konfiguration** das Feld **"Lokaler
     DNS-Server"** suchen und dort `PI_STATIC_IP` eintragen (z. B.
     `192.168.178.53`).
  4. **Übernehmen** klicken. Ab jetzt bekommt jedes Gerät, das per DHCP eine
     Adresse von der FRITZ!Box erhält, automatisch Pi-hole als DNS-Server
     zugewiesen.

  **Nicht verwechseln:** Das ist ein anderes Feld als **"MyFRITZ!/DynDNS"**
  (dient dazu, die FRITZ!Box selbst über einen festen Namen aus dem
  *Internet* erreichbar zu machen — das Gegenteil von dem, was hier gebraucht
  wird) und auch ein anderes als der DNS-Server unter **Internet →
  Zugangsart → DNS-Server** (das betrifft nur, welchen DNS-Server die
  FRITZ!Box selbst nach außen hin befragt, nicht was den Geräten im LAN per
  DHCP mitgeteilt wird). Bei anderen Routern heißt das gesuchte Feld meist
  einfach **"DNS-Server"** in den generellen Netzwerk-/LAN-Einstellungen.

#### Prüfen, ob es funktioniert

Direkt nach dem Ändern zeigt das Pi-hole-Dashboard meist **`0 q/min`** an —
das ist normal und kein Fehler: Geräte übernehmen den neuen DNS-Server erst
bei der nächsten DHCP-Erneuerung, nicht sofort.

**Schnelltest, unabhängig von DHCP** (funktioniert sofort, von jedem Gerät im LAN oder auf dem Pi selbst):

```bash
nslookup doubleclick.net 192.168.178.53   # PI_STATIC_IP statt Beispiel-IP einsetzen
```

Kommt ein Ergebnis zurück (auch `0.0.0.0` zählt — das ist ein Block), läuft
Pi-hole korrekt. Direkt danach im Pi-hole-Dashboard bzw. **Query Log**
nachsehen — die eine Anfrage sollte dort auftauchen.

**Damit reale Geräte Pi-hole tatsächlich nutzen**, muss deren DHCP-Lease
erneuert werden:
- Am einfachsten: FRITZ!Box einmal neu starten — erzwingt bei allen Geräten
  eine neue Anfrage.
- Pro Gerät: WLAN kurz aus-/einschalten (Handy) bzw. `ipconfig /release &&
  ipconfig /renew` (Windows) oder neu verbinden (Mac/Linux).

**Prüfen, welchen DNS-Server ein Gerät gerade tatsächlich verwendet:**
Windows `ipconfig /all` (Feld "DNS-Server"), Mac Systemeinstellungen →
Netzwerk → WLAN → Details → DNS, Linux `resolvectl status`, Smartphone in
den WLAN-Netzwerkdetails.

### 11. Öffentliche Webseite prüfen

```bash
curl -I https://deine-domain.de   # <- eigene Domain aus .env einsetzen
```

Erwartet: `HTTP/2 200`. `caddy` selbst hat **keinen** Host-Port — die einzige
Route dorthin führt über `cloudflared`.

### 12. Uptime Kuma einrichten

- Web-UI: `http://<PI_STATIC_IP>:3001` (nur LAN), z. B.
  `http://192.168.178.53:3001`.
- Beim ersten Aufruf fragt Uptime Kuma **"Welche Datenbank möchtest du
  verwenden?"** (Embedded MariaDB / MariaDB-MySQL / SQLite) →
  **SQLite** wählen. Begründung: Embedded MariaDB startet einen kompletten
  Datenbankserver im Container mit (dauerhaft mehr RAM-Verbrauch auf dem
  ohnehin geteilten Pi, und es gibt Berichte über Start-Schleifen); der
  Performance-Vorteil zählt erst bei sehr vielen Monitoren. SQLite ist eine
  einzelne Datei in `data/uptime-kuma/`, die das nächtliche Backup sauber
  mitsichert. "MariaDB/MySQL" (extern) scheidet aus — es gibt in diesem
  Setup keinen separaten Datenbankserver.
- Danach Admin-Account anlegen.
- Monitore anlegen für:
  - Die öffentliche Webseite: `https://deine-domain.de`
  - **Pi-hole: `http://pihole/admin/`** (nicht die LAN-IP!) — Uptime Kuma
    und Pi-hole laufen im selben Docker-Netz `lan_net` und erreichen sich
    dort direkt über den Servicenamen `pihole` (Port 80 intern). Über die
    LAN-IP (`http://<PI_STATIC_IP>:8080/admin/`) kann der Monitor
    fälschlicherweise in einen Timeout laufen — ein Container, der den
    eigenen host-published Port über die Bridge anspricht, kann an Dockers
    NAT-"Hairpin"-Limitation scheitern, obwohl die Seite im Browser von
    jedem echten LAN-Gerät aus normal erreichbar ist.
  - Ein Internet-Referenz-Check, z. B. `1.1.1.1`.

### 13. Backup-Ziel verbinden (rclone, interaktiv)

Der Remote-Name muss zum Präfix von `BACKUP_REMOTE` in `.env` passen
(Default: `onedrive`).

```bash
rclone config
```

Im interaktiven Menü (Beispiel für OneDrive):

1. `n` (New remote) → Name eingeben, z. B. `onedrive` (muss zu `BACKUP_REMOTE` passen)
2. Storage-Typ aus der Liste wählen: **Microsoft OneDrive**
3. `client_id` / `client_secret`: leer lassen (Enter)
4. "Edit advanced config?" → `n`
5. "Use web browser to automatically authenticate?" → `y`, falls der Pi
   eine grafische Oberfläche/Browser-Weiterleitung erlaubt. Bei einem
   headless Pi (Standardfall): `n` wählen und stattdessen auf einem Gerät
   mit Browser `rclone authorize "onedrive"` ausführen, den Code zurück ins
   Terminal auf dem Pi einfügen (das Setup fragt danach).
6. Laufwerk aus der Liste bestätigen (meist `0`), dann `y`.
7. `q` zum Beenden.

Testen (mit dem eben vergebenen Remote-Namen):

```bash
rclone lsd onedrive:
```

### 14. Backup ausführen und automatisieren

Manuell testen — **hier ausnahmsweise mit `sudo`**, weil die Dateien unter
`data/` den Container-Nutzern gehören und nur root sie vollständig lesen
kann (der Upload per rclone läuft trotzdem automatisch unter deinem
normalen Nutzer, damit deine rclone-Anmeldung verwendet wird):

```bash
sudo bash scripts/backup.sh
```

Als nächtlichen Cron-Job einrichten (landet aus demselben Grund in der
root-crontab; idempotent — mehrfaches Ausführen legt den Eintrag nicht
doppelt an):

```bash
bash scripts/install-backup-cron.sh
```

**Wichtig, einmalig:** Der private age-Schlüssel
(`~/.config/age/pi-server.txt`) wird **nicht** mitgesichert — ohne ihn sind
alle Backups wertlos. Jetzt an einen sicheren Ort außerhalb des Pi kopieren
(Passwort-Manager, USB-Stick), falls noch nicht geschehen.

### 15. Alles auf einmal verifizieren

```bash
bash scripts/verify.sh
```

Prüft: `docker compose config`, alle Dienste laufen, keine Secrets im Git,
`ufw` Default-Deny aktiv, öffentliche Domain erreichbar, `PI_STATIC_IP`
tatsächlich an einem aktiven Interface gebunden, WLAN nicht blockiert
während kein Ethernet aktiv ist — mit PASS/FAIL-Ausgabe pro Check.

### 16. Restore einmal real testen (Pflicht, [M7])

Vor Abschluss des Setups **einmal auf einem leeren/frischen System einen
echten Restore durchführen**: neues Boot-Medium flashen, Repo klonen,
`00-bootstrap.sh` + `01-harden.sh` ausführen, den privaten age-Schlüssel und
die `rclone`-Verbindung auf dem neuen System einrichten, neuestes Backup aus
`BACKUP_REMOTE` holen und mit `age -d` entschlüsseln, `data/` und `.env`
wiederherstellen, dann `docker compose up -d` und `scripts/verify.sh`. Details
zum genauen Ablauf stehen in den Kommentaren von `scripts/backup.sh`.

---

## Troubleshooting

| Symptom | Wahrscheinliche Ursache | Prüfen / Fix |
|---|---|---|
| `docker compose ps` zeigt `cloudflared` nicht `running` | Token falsch/leer | `docker compose logs cloudflared`; Token in `.env` neu aus dem Dashboard kopieren |
| `curl -I https://${DOMAIN}` liefert Fehler/Timeout | Published-Application-Routing fehlt oder DNS noch nicht propagiert | Im Zero-Trust-Dashboard die Route prüfen; einige Minuten warten |
| Pi-hole-UI unter `PI_STATIC_IP` nicht erreichbar | `PI_STATIC_IP` stimmt nicht mit tatsächlicher Pi-IP überein, oder `ufw`-Regel fehlt | `ip -4 addr show` auf dem Pi vs. `.env` vergleichen; `sudo ufw status verbose` |
| Geräte im LAN nutzen Pi-hole nicht als DNS | Router-DNS-Einstellung noch nicht gesetzt oder Geräte-Cache | Router-DNS-Setting prüfen (Schnellstart Schritt 10); betroffenes Gerät neu verbinden |
| `scripts/01-harden.sh` bricht mit Fehler ab | Kein Public Key in `~/.ssh/authorized_keys` | Key wie in Schnellstart Schritt 1 hinterlegen, dann erneut ausführen |
| `scripts/backup.sh` schlägt bei `rclone` fehl | Remote nicht konfiguriert oder Name stimmt nicht mit `BACKUP_REMOTE` überein. Wichtig: `rclone config` als normaler Nutzer ausführen (nicht mit sudo) — das Backup nutzt automatisch dessen Konfiguration | `rclone listremotes` (ohne sudo); Schnellstart Schritt 13 wiederholen |
| `-bash: git: command not found` beim Klonen | Raspberry Pi OS Lite hat `git` nicht vorinstalliert, `00-bootstrap.sh` (installiert es) läuft erst nach dem Klonen | `sudo apt update && sudo apt install -y git`, dann erneut klonen (Schnellstart Schritt 3) |
| `git pull` in `sites/<name>` meldet `Already up to date`, aber die Seite zeigt weiter alte Inhalte | `sites/<name>` ist kein eigenes Git-Repo, sondern liegt noch im Haupt-Repo (häufig bei `sites/main`, wenn die mitgelieferte Beispielseite direkt durch die echte Homepage ersetzt wurde) — `git pull` löst sich dann gegen das Haupt-Repo auf, nicht gegen die eigentliche Website | `git remote -v` in `sites/<name>` prüfen: zeigt es das Haupt-Repo statt der Website? → `bash scripts/adopt-site-repo.sh sites/<name> <echte-repo-url>` (siehe „Jede Seite als eigenes Git-Repo") |
| Nach Reboot nicht mehr unter der reservierten IP erreichbar | Router-Reservierung hängt an der MAC-Adresse des **falschen** Interfaces (z. B. `eth0` reserviert, Pi hängt aber an `wlan0`, oder umgekehrt) | `ip -4 addr show` auf dem Pi, aktives Interface ermitteln, MAC damit im Router abgleichen (Schnellstart Schritt 6) |
| `ufw`-Regeln passen nicht zum tatsächlichen LAN | `LAN_SUBNET` in `.env` enthält eine Host-Adresse statt der Netz-Adresse (z. B. `192.168.178.53/24` statt `192.168.178.0/24`) | `grep LAN_SUBNET .env` prüfen, bei Bedarf korrigieren, `scripts/01-harden.sh` erneut ausführen |
| Cloudflare-Dashboard zeigt keinen Menüpunkt "Public Hostname" | Cloudflare hat die Bezeichnung zu "Published Application routes" / "Add published application" geändert (Stand 2026) | Im Tunnel-Detail nach **Published Application routes** suchen, Felder wie in Schnellstart Schritt 8 ausfüllen |
| Pi-hole-Dashboard zeigt dauerhaft `0 q/min` nach Umstellung des Router-DNS | Geräte haben ihre DHCP-Lease noch nicht erneuert, nutzen also noch den alten DNS-Server | Schnelltest per `nslookup <domain> ${PI_STATIC_IP}`; für echte Geräte Router neu starten oder Lease einzeln erneuern (Schnellstart Schritt 10) |
| Nach einem Neustart keine Verbindung mehr, WLAN tot (auch über lokale Konsole als "nicht verbunden" sichtbar) | Häufigste Ursache: WLAN wurde per `rfkill block wifi` deaktiviert (z. B. beim Umstieg auf ein LAN-Kabel) — dieser Zustand übersteht Neustarts. Fehlt dann zusätzlich ein aktiver Ethernet-Link, hat der Pi gar keine Netzwerkverbindung mehr | Per Tastatur/Monitor lokal einloggen, `rfkill list` prüfen; steht dort "Soft blocked: yes" bei WLAN → `sudo rfkill unblock wifi`. WLAN danach nicht erneut blockieren (siehe Hinweis in Schnellstart Schritt 6) |
| Pi unter `PI_STATIC_IP` komplett unerreichbar, DNS für das ganze LAN fällt aus | Physische Ethernet-Verbindung getrennt (Kabel raus/lose) — `eth0` hat dann gar keine IP mehr, der Pi kann parallel per DHCP auf `wlan0` ausweichen und landet auf einer völlig anderen Adresse | `ip link` auf dem Pi: Zeigt `eth0` "NO-CARRIER"/"state DOWN"? → Kabel/Port prüfen. Bevor man DNS/Software verdächtigt: immer zuerst die physische Verbindung prüfen (`ip link`, `dmesg`), das sieht sonst wie ein reines DNS-Problem aus |
| Pi-hole läuft (`healthy`), Port 53 ist erreichbar, aber echte Geräte im LAN bekommen trotzdem keine Antwort | Pi-hole v6 verwendet standardmäßig `dns.listeningMode=LOCAL`. In einem Docker-Bridge-Netz hält FTL dabei nur Anfragen aus dem eigenen Bridge-Subnetz für "lokal" und verwirft echte LAN-Clients stillschweigend | Pi-hole-Log auf "ignoring query from non-local network ..." prüfen; `FTLCONF_dns_listeningMode: "ALL"` ist bereits in `docker-compose.yml` gesetzt (siehe Kommentar dort) — bei älteren Ständen dieses Repos ggf. nachtragen und `docker compose up -d` erneut ausführen |
| `docker compose ps` zeigte vor einer Weile "running", Problem besteht aber weiter | Status kann veraltet sein — Container können zwischenzeitlich abgestürzt/neu gestartet sein | `docker compose ps` **live neu ausführen**, nicht auf einen älteren Blick verlassen, bevor man weiter nach der Ursache sucht |
| DNS-Test von einem Test-Container auf demselben Docker-Bridge-Netz schlägt fehl, obwohl von echten LAN-Geräten aus alles funktioniert | Docker-NAT-"Hairpin"-Limitation: ein Container, der den eigenen host-published Port über die Bridge anspricht, kann daran scheitern — sieht wie ein Bug aus, ist aber eine bekannte Docker-Eigenheit | Zum Testen immer von einem echten LAN-Client oder direkt vom Host aus prüfen (`nslookup <domain> ${PI_STATIC_IP}`), nicht von einem anderen Container auf derselben Bridge |
| Uptime-Kuma-Monitor für Pi-hole zeigt "timeout of Nms exceeded", obwohl `http://<PI_STATIC_IP>:8080/admin/` im Browser normal lädt | Dieselbe Docker-NAT-Hairpin-Limitation: Uptime Kuma ist selbst ein Container und scheitert daran, den eigenen host-published Port von Pi-hole über die LAN-IP anzusprechen | Monitor-URL auf `http://pihole/admin/` ändern (interner Servicename statt LAN-IP, siehe Schnellstart Schritt 12) |
| Login einer App gelingt scheinbar, der Nutzer landet aber sofort wieder auf `/login` | `cloudflared` spricht Klartext-HTTP mit `caddy:80`, Caddy setzt daher `X-Forwarded-Proto: http`. Frameworks mit Secure-Cookies (z. B. `express-session` mit `cookie.secure=true` hinter `trust proxy`) verwerfen das Session-Cookie dann **stillschweigend** — kein Fehler im Log, nur ein `debug()`-Aufruf | Im `reverse_proxy`-Block der App `header_up X-Forwarded-Proto https` ergänzen (Vorlage im Kommentar über dem `@app`-Block in `config/caddy/Caddyfile`), dann `docker compose restart caddy` |
| Nur die **erste** `admin: yes`-Seite aus `sites.conf` wird geseedet, alle weiteren fehlen | Bekannter, behobener Fehler in älteren Ständen von `scripts/deploy.sh`: `docker compose exec` hängt stdin immer an den Container (`-T` schaltet nur das TTY ab) und las im Schleifenkörper die offene `sites.conf` bis EOF leer | `git pull` — der Fix (`< /dev/null` am exec plus Manifest-Lesen über FD 3) ist enthalten. Fehlende Admins einmalig nachziehen: `docker compose exec -T <dienst> npm run seed:admin < /dev/null` |

**Vorsicht beim Live-Debugging von DNS-Problemen:** keinen zweiten,
unkonfigurierten Pi-hole-Testcontainer per `docker run --network host
pihole/...` starten, während der eigentliche Dienst bereits Port 53 belegt —
das konkurriert unnötig um denselben Port. Stattdessen direkt vom Host aus
mit `nslookup`/`dig` gegen `${PI_STATIC_IP}` testen.

---

## Was kann ich mit Pi-hole eigentlich machen?

Ein kurzer Überblick über die gängigsten Aufgaben in der Pi-hole-Weboberfläche
(`http://${PI_STATIC_IP}:${PORT_PIHOLE_UI}/admin/`):

- **Query Log** (Menü links): zeigt in Echtzeit jede DNS-Anfrage aus dem
  Netzwerk und ob sie geblockt oder durchgelassen wurde — der schnellste Weg
  herauszufinden, welche Domain gerade etwas blockiert.
- **Werbung/Tracker blockieren:** läuft größtenteils automatisch über die
  mitgelieferten Blocklisten (Adlists). Weitere Listen unter
  **Settings → Adlists** hinzufügen, danach **Tools → Update Gravity**
  ausführen, damit sie aktiv werden.
- **Eine bestimmte Domain gezielt blockieren:** unter **Domains** die Domain
  im Reiter **Blacklist (Exact/Wildcard)** eintragen — oder direkt aus dem
  Query Log per Klick auf die Domain und "Blacklist".
- **Eine Seite freigeben, die durch Pi-hole kaputtgeht:** passiert gelegentlich,
  wenn eine Webseite Inhalte/Skripte über dieselbe Domain wie eine
  Tracking-/Werbe-Domain lädt. Unter **Domains → Whitelist** die betroffene
  Domain eintragen (Query Log verrät meist, welche Domain gerade blockiert
  wurde) — danach lädt die Seite wieder normal.
- **Pi-hole kurz komplett deaktivieren** (zum Testen, ob Pi-hole die Ursache
  eines Problems ist): auf dem Dashboard oben der Schalter "Disable" mit
  Zeitlimit (z. B. 5 Minuten) oder dauerhaft, danach wieder "Enable".
  Praktisch, um schnell auszuschließen, dass Pi-hole für ein Problem
  verantwortlich ist.
- **Gruppen/Geräte unterschiedlich behandeln:** unter **Group Management**
  lassen sich z. B. strengere Regeln für Kinder-Geräte oder lockerere für
  Gäste-WLAN einrichten und einzelnen Clients zuweisen.
- **Statistiken:** das Dashboard zeigt u. a. die am häufigsten geblockten
  Domains und den Anteil geblockter Anfragen am Gesamtverkehr.

---

## Weitere Websites hosten

Der Reverse Proxy **Caddy** liefert alle Websites aus. `cloudflared` schickt
jeden Hostnamen an `caddy:80`, und Caddy entscheidet anhand der (Sub-)Domain,
was ausgeliefert wird — Routing steht in `config/caddy/Caddyfile`.

Es gibt zwei Arten von Seiten:

| | **Statische Seite** | **Dynamische App** |
|---|---|---|
| Was | HTML/CSS/JS, fertige Dateien | Laufendes Programm (Node, Python, …) |
| Wo | Ordner unter `sites/<name>/` | Ordner unter `apps/<name>/` (mit `Dockerfile`) |
| Wie ausgeliefert | Caddy liefert die Dateien direkt | Eigener Container, Caddy leitet per `reverse_proxy` weiter |
| Ressourcen | Sehr leicht (kein eigener Container) | Ein Container pro App |
| Mitgeliefertes Beispiel | `sites/main/`, `sites/beispiel/` | `apps/app-example/` |

### Eine statische Seite hinzufügen (z. B. `blog.deine-domain.de`)

1. Ordner mit Inhalt anlegen:
   ```bash
   mkdir -p ~/pi-server/sites/blog
   echo '<h1>Mein Blog</h1>' > ~/pi-server/sites/blog/index.html
   ```
2. In `config/caddy/Caddyfile` einen Block ergänzen (nach dem Muster von
   `beispiel`):
   ```
   @blog host blog.{$DOMAIN}
   handle @blog {
       root * /srv/blog
       file_server
   }
   ```
3. Caddy neu laden: `docker compose restart caddy`
4. Im Cloudflare-Dashboard einen Public Hostname `blog.deine-domain.de` →
   `http://caddy:80` anlegen (wie Schnellstart Schritt 8, nur mit Subdomain).
5. Optional: in Uptime Kuma einen Monitor auf `https://blog.deine-domain.de`.

> Reine Inhalts-Änderungen an bestehenden Seiten (Dateien in `sites/<name>/`
> ändern) brauchen **keinen** Neustart — Caddy liefert sie sofort aus. Nur
> Änderungen am `Caddyfile` selbst brauchen `docker compose restart caddy`.

### Eine dynamische App hinzufügen (z. B. `shop.deine-domain.de`)

1. App unter `apps/shop/` anlegen (eigenes `Dockerfile`, muss auf einem Port
   lauschen). `apps/app-example/` dient als Vorlage.
2. In `docker-compose.yml` einen Dienst ergänzen (nach dem Muster von
   `app-example`):
   ```yaml
   shop:
     build: ./apps/shop
     restart: unless-stopped
     networks: [edge]
   ```
3. In `config/caddy/Caddyfile`:
   ```
   @shop host shop.{$DOMAIN}
   handle @shop {
       reverse_proxy shop:3000    # Port an die App anpassen
   }
   ```
4. Bauen/starten und Caddy neu laden:
   ```bash
   docker compose up -d --build shop
   docker compose restart caddy
   ```
5. Public Hostname im Cloudflare-Dashboard + Uptime-Kuma-Monitor wie oben.

### Bring2Bring! (bereits verdrahtet): `dishlist.deine-domain.de`

**Bring2Bring!** ist ein privates digitales Kochbuch (eigenes Repo, Node +
SQLite) und läuft als vierte dynamische App neben winecashing, ginperium und
tipsy-trails. Die Verdrahtung (Dienst in `docker-compose.yml`, Block in
`config/caddy/Caddyfile`, Eintrag in `sites.conf`) ist bereits erledigt —
hier nur die Punkte, die vor dem **ersten** Deploy zusätzlich zu beachten sind:

- **Einmalig vor dem ersten Deploy:** Datenverzeichnis anlegen und dem
  Container-Nutzer übergeben:
  ```bash
  mkdir -p ~/pi-server/data/bring2bring && sudo chown -R 1000:1000 ~/pi-server/data/bring2bring
  ```
  Grund: der Bind-Mount `./data/bring2bring:/data` überdeckt, was das Image beim
  Bau vorbereitet hat; legt Docker das Verzeichnis selbst an (weil es vorher
  nicht existiert), gehört es `root`. Bring2Bring! läuft aber unprivilegiert als
  `node`-Nutzer (UID 1000) und könnte dann seine SQLite-Datenbank nicht
  anlegen. Bei den anderen Apps besteht dieses Problem nicht in derselben
  Form, siehe deren jeweilige Dockerfiles.
- **`PUBLIC_BASE_URL` steht in `docker-compose.yml`**, nicht in
  `apps/bring2bring/.env` — `prepare_site()` in `scripts/deploy.sh` schreibt
  diese `.env`-Datei bei **jedem** Deploy komplett neu (nur
  `SESSION_SECRET`/`ADMIN_USER`/`ADMIN_PASSWORD`); ein von Hand ergänztes
  `PUBLIC_BASE_URL` dort würde beim nächsten Deploy stillschweigend wieder
  verschwinden und der Container würde danach nicht mehr starten (Bring2Bring!
  bricht ohne diese Variable beim Start hart ab).
- **Cloudflare-Vorsicht bei `/r/*`:** Diese Route ist die bewusst öffentliche
  Rezept-Freigabeseite — Bring! ruft sie von eigenen Servern mit einem
  Nicht-Browser-User-Agent ab. Landet `dishlist.deine-domain.de` jemals hinter
  Cloudflare-Bot-Fighting oder einer Access-Regel, bricht jeder Bring!-Import
  lautlos, während die Seite im Browser weiterhin ganz normal aussieht.
- **Uptime Kuma:** einen Monitor auf `https://dishlist.deine-domain.de/healthz`
  anlegen (wie in „Weitere Websites hosten" oben beschrieben).
- **Backup:** `data/bring2bring/` wird vom nächtlichen Backup bereits
  mitgesichert — `scripts/backup.sh` packt pauschal das gesamte `data/`-
  Verzeichnis (`tar ... data .env`), ohne einzelne Unterordner aufzuzählen.
- **Ausrollen:** `bash scripts/deploy.sh` klont/pullt Bring2Bring!, schreibt die
  Admin-`.env`, baut den Container, führt `npm run seed:admin` aus und lädt
  Caddy neu — wie bei den anderen Admin-Apps.

### Jede Seite als eigenes Git-Repo (empfohlen für unabhängige Versionierung)

Standardmäßig liegen die Beispielseiten **im** Haupt-Repo. Für eine echte
Seite mit eigener Git-Historie stattdessen ein separates Repo in den Ordner
klonen und diesen Pfad in der `.gitignore` des Haupt-Repos eintragen, damit
beide sich nicht in die Quere kommen:

```bash
# Beispiel: eigene Blog-Seite aus separatem Repo
git clone https://github.com/<du>/mein-blog.git ~/pi-server/sites/blog
echo '/sites/blog/' >> ~/pi-server/.gitignore
```

Aktualisieren geht dann bequem per Helfer-Skript (macht `git pull`, und bei
dynamischen Apps zusätzlich den Rebuild):

```bash
bash scripts/deploy-site.sh blog     # statische Seite
bash scripts/deploy-site.sh shop     # dynamische App (baut Container neu)
```

#### Eine mitgelieferte Beispielseite nachträglich umstellen (z. B. `sites/main`)

`sites/main` und `sites/beispiel` liegen von Anfang an **im Haupt-Repo** (siehe
Tabelle oben). Ersetzt man ihren Inhalt einfach durch die eigene, echte
Homepage, ohne die beiden Schritte oben (Ordner aus dem Haupt-Repo lösen +
`.gitignore`-Eintrag) nachzuholen, bleibt der Ordner weiterhin Teil des
Haupt-Repos. Das Tückische daran: `git pull` funktioniert in diesem Zustand
scheinbar völlig normal — er meldet nur `Already up to date`, weil er sich
in Wirklichkeit gegen das **Haupt-Repo** auflöst, nicht gegen das Repo der
eigentlichen Website. Die Seite aktualisiert sich dann nie, ohne dass eine
Fehlermeldung darauf hinweist.

Kurzer Check, ob ein Seitenordner betroffen ist:

```bash
cd ~/pi-server/sites/main
git remote -v   # zeigt das Remote des HAUPT-Repos statt der eigentlichen Website? -> betroffen
```

Ein mitgeliefertes Skript erledigt die Umstellung automatisch (Haupt-Repo
entkoppeln + `.gitignore`-Eintrag + Neuklon vom echten Repo; der alte Inhalt
wird vorsichtshalber nicht gelöscht, sondern als `sites/main.bak-<Zeitstempel>`
danebengelegt):

```bash
bash scripts/adopt-site-repo.sh sites/main https://github.com/<du>/meine-homepage.git
git push   # den Commit, der sites/main jetzt ignoriert, nicht vergessen
```

### Mehrere Seiten zentral verwalten (`sites.conf` + `deploy.sh`)

`deploy-site.sh` aktualisiert **eine** bereits vorhandene Seite. Sobald mehrere
eigene Websites nach dem Muster „ein Repo = ein Container" laufen (siehe oben),
lohnt sich stattdessen `scripts/deploy.sh`: ein Manifest-getriebenes Skript,
das **alle** in `sites.conf` eingetragenen Seiten in einem Rutsch klont/pullt,
baut und startet.

`sites.conf` im Repo-Wurzelverzeichnis (eine Zeile pro Seite):

```
# name    repo_url                                  host    admin
shop      https://github.com/<du>/meine-shop-app.git shop    yes
blog      https://github.com/<du>/mein-blog.git      blog    no
```

- `name` = Ordnername unter `apps/` **und** Service-Name in `docker-compose.yml`
  (muss dort ebenfalls als Dienst eingetragen sein, siehe „Eine dynamische App
  hinzufügen" oben — `sites.conf` allein reicht nicht).
- `host` = Subdomain-Label, oder `apex` für die Hauptdomain selbst.
- `admin` = `yes`, wenn die App einen Login braucht. `deploy.sh` fragt dann
  einmalig nach einem **gemeinsamen** Admin-Benutzernamen/-Passwort (in
  `admin.env`, gitignored, wird für alle `admin: yes`-Seiten wiederverwendet),
  schreibt es zusammen mit einem zufälligen `SESSION_SECRET` in `apps/<name>/.env`
  und führt anschließend `npm run seed:admin` im Container aus. Die jeweilige
  App muss diese drei Variablen (`ADMIN_USER`, `ADMIN_PASSWORD`,
  `SESSION_SECRET`) selbst konsumieren (z. B. per `express-session` +
  eigenem `seed:admin`-Skript).

Nutzung auf dem Pi:

```bash
bash scripts/deploy.sh                # normales Update aller Seiten
bash scripts/deploy.sh --fresh        # zusaetzlich alle App-Datenbanken zuruecksetzen
bash scripts/deploy.sh --set-password # gemeinsames Admin-Passwort neu setzen
```

**Wann welches Skript?**

| Situation | Skript |
|---|---|
| Eine einzelne Seite schnell aktualisieren (kein Admin-Handling, kein Caddy-Neustart) | `deploy-site.sh <name>` |
| Alle Seiten aus `sites.conf` auf einmal aktualisieren, inkl. gemeinsamem Admin-Account und Caddy-Neustart | `deploy.sh` |
| Eine Seite ist noch gar nicht geklont | `deploy.sh` (klont automatisch aus `sites.conf`) — oder manuell klonen, dann `deploy-site.sh` |

### E-Mail: `support@deine-domain.de` einrichten (Cloudflare Email Routing)

E-Mail wird **nicht** auf dem Pi gehostet (ein Mailserver auf einem
Privatanschluss hinter dem Tunnel funktioniert praktisch nicht: Port 25 ist
meist gesperrt, es bräuchte eingehende Ports entgegen [N1], und ohne feste
IP + Reputation landen Mails im Spam). Stattdessen leitet **Cloudflare Email
Routing** kostenlos an dein bestehendes Postfach weiter — reine
Dashboard-Sache, nichts auf dem Pi:

1. <https://dash.cloudflare.com> → deine Domain → **Email → Email Routing**.
2. Beim ersten Mal fügt Cloudflare automatisch die nötigen MX-/TXT-Einträge
   hinzu (bestätigen).
3. Unter **Routing rules** eine Adresse anlegen: `support@deine-domain.de`
   → Ziel = deine echte Adresse (z. B. Gmail). Cloudflare schickt dorthin
   eine Bestätigungsmail, einmal bestätigen.
4. Fertig — Mails an `support@deine-domain.de` landen in deinem Postfach.

> Nur **Empfang** (Weiterleitung). Um auch **als** `support@…` zu senden,
> braucht es zusätzlich einen SMTP-Relay-Dienst — nicht Teil dieses Setups.

---

## Claude Code direkt auf dem Pi (On-Demand-Debugging)

Für Debugging und Wartung lässt sich die Claude Code CLI direkt auf dem Pi
installieren und bei Bedarf im Projektordner aufrufen — ohne dass dafür ein
Dienst dauerhaft im Hintergrund läuft und Ressourcen verbraucht.

### Installation

```bash
bash scripts/install-claude-code.sh
```

Installiert bei Bedarf Node.js (LTS) und danach die Claude Code CLI per
`npm`. Bewusst **kein** nativer Installer (`curl -fsSL
https://claude.ai/install.sh | bash`): dieser hat auf ARM64/Raspberry Pi
bekannte Probleme (meldet Erfolg, installiert die Binary aber nicht
zuverlässig mit).

Während der Installation kann eine Warnung wie `npm warn allow-scripts ...
not yet covered by allowScripts` erscheinen (neuere npm-Versionen fragen vor
Install-Scripts von Paketen nach). In der Praxis hat die CLI danach trotzdem
funktioniert — mit `claude --version` prüfen (sollte eine Versionsnummer wie
`2.1.210 (Claude Code)` zeigen). Falls nicht: `npm approve-scripts
--allow-scripts-pending` ausführen und erneut prüfen.

### Anmelden (einmalig, headless-tauglich)

Ein Raspberry Pi im Lite-Modus hat keinen Browser. **Wichtig:** Ist
`ANTHROPIC_API_KEY` oder `CLAUDE_CODE_OAUTH_TOKEN` bereits als
Umgebungsvariable gesetzt, **bevor** `claude` das erste Mal gestartet wird,
überspringt die CLI das interaktive Anmelde-Menü automatisch. Das ist auf
einem headless-Gerät der einfachste Weg — deshalb zuerst dauerhaft setzen,
dann `claude` starten.

**Variante A — API-Key (Anthropic Console):**

```bash
echo 'export ANTHROPIC_API_KEY=<dein-api-key>' >> ~/.bashrc
source ~/.bashrc
```

Der `echo ... >> ~/.bashrc`-Befehl hängt die Zeile dauerhaft an die
Shell-Konfiguration an, damit die Variable bei jeder neuen Anmeldung
automatisch gesetzt ist — nicht nur für die aktuelle Sitzung. `source
~/.bashrc` wendet die Änderung sofort auf die schon offene Sitzung an, ohne
dass man sich neu einloggen muss.

**Variante B — Claude Pro/Max-Abo:**

Auf einem Gerät **mit** Browser (eigener Computer, nicht der Pi) einmalig:

```bash
claude setup-token
```

Führt durch einen Browser-Login und gibt am Ende ein Token aus. Dieses Token
dann genauso dauerhaft auf dem Pi hinterlegen:

```bash
echo 'export CLAUDE_CODE_OAUTH_TOKEN=<das-ausgegebene-token>' >> ~/.bashrc
source ~/.bashrc
```

**Falls trotzdem das Menü "Select login method" erscheint** (passiert, wenn
`claude` gestartet wird, bevor eine der beiden Variablen gesetzt ist) — die
drei Optionen bedeuten:

| Menüpunkt | Bedeutung | Für den headless Pi |
|---|---|---|
| "Account with subscription" | Claude.ai Pro/Max-Login per Browser-OAuth | Auf dem Pi **abbrechen** (kein Browser vorhanden) — stattdessen Variante B von einem Gerät mit Browser aus vorbereiten |
| "Anthropic Console account" | API-Key-basierte Anmeldung | Entspricht Variante A — einfacher direkt vorab per `ANTHROPIC_API_KEY` setzen, dann erscheint das Menü gar nicht erst |
| "3rd party platform" | Zugriff über AWS Bedrock / Google Vertex AI o. ä. | Nur relevant, falls Claude bereits über eine dieser Plattformen bezogen wird — für dieses Projekt nicht nötig |

Am einfachsten bleibt: Variante A oder B **vorher** einrichten, dann taucht
das Menü erst gar nicht auf.

### Verwendung

```bash
cd ~/pi-server
claude
```

Startet eine interaktive Sitzung, die automatisch `CLAUDE.md` und
`raspberry-pi-4-spezifikation.md` aus diesem Repo als Kontext liest — dieselben
Regeln, nach denen dieses Projekt aufgebaut wurde, gelten dann auch für die
Debugging-Sitzung. Nach Ende der Sitzung läuft nichts mehr im Hintergrund;
es gibt bewusst keinen systemd-Dienst und keinen Autostart dafür.

### Nach einer unterbrochenen SSH-Verbindung wieder einsteigen

Bricht die SSH-Verbindung während einer laufenden `claude`-Sitzung ab (WLAN
weg, Laptop zugeklappt, …): **nichts geht verloren.** Claude Code schreibt
den Sitzungsverlauf fortlaufend auf die Platte, unabhängig von der
SSH-Verbindung. Nach dem erneuten Einloggen im selben Ordner:

```bash
cd ~/pi-server
claude --continue   # laedt automatisch die zuletzt aktive Sitzung dieses Ordners
```

Gibt es mehrere unterbrochene/parallele Sitzungen und die letzte ist nicht
die richtige:

```bash
claude --resume   # zeigt eine Auswahlliste aller gespeicherten Sitzungen dieses Ordners
```

Beides funktioniert nur, wenn man sich **im selben Verzeichnis** befindet, in
dem die Sitzung ursprünglich gestartet wurde (`~/pi-server`) — Sitzungen sind
pro Arbeitsverzeichnis gespeichert.

### Hardware-Hinweis

Anthropics offizielles Minimum für die CLI liegt bei 4 GB RAM. Auf einem Pi 4
mit 1–2 GB RAM konkurriert eine aktive Sitzung mit den laufenden Containern
um Arbeitsspeicher — für dieses optionale Feature empfiehlt sich ein Pi 4 mit
mindestens 4 GB RAM.

---

## Referenz: verwendete Image-Versionen

Gegen die jeweils aktuelle stabile Version verifiziert und auf echter
Raspberry-Pi-4-Hardware verifiziert; öffentliche Seite über den
Cloudflare-Tunnel mit `HTTP/2 200` erreichbar. `:latest` wird laut
Spezifikation nirgends verwendet.

| Dienst | Image | Tag |
|---|---|---|
| Pi-hole | `pihole/pihole` | `2026.07.2` |
| Reverse Proxy / Web | `caddy` | `2.11.4-alpine` |
| Cloudflare Tunnel | `cloudflare/cloudflared` | `2026.7.0` |
| Uptime Kuma | `louislam/uptime-kuma` | `2.4.0` |
| Dynamische Beispiel-App | `node` (Build) | `24-alpine` |

Neue Version einsetzen: Tag in `docker-compose.yml` ändern,
`docker compose pull && docker compose up -d`, diese Tabelle aktualisieren.

---

## Referenz: welcher `.env`-Wert kommt woher

Alle Werte werden von `scripts/setup-env.sh` interaktiv abgefragt bzw. (bei
`AGE_RECIPIENT`) automatisch erzeugt — diese Tabelle ist die Kurzreferenz,
falls du `.env` von Hand anpassen willst.

| Variable | Bedeutung | Woher bekommst du den Wert? |
|---|---|---|
| `TZ` | Zeitzone aller Container | Z. B. `Europe/Berlin`. Liste: [Wikipedia tz-database](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones) |
| `LAN_SUBNET` | Heimnetz-CIDR für Firewall-Regeln | Wird automatisch erkannt; manuell prüfen mit `ip -4 addr show` auf dem Pi |
| `PI_STATIC_IP` | Feste IP des Pi im LAN | Frei wählbar, muss als DHCP-Reservierung im Router eingetragen werden (Anleitung in Schnellstart Schritt 6) |
| `PORT_PIHOLE_UI` / `PORT_DNS` / `PORT_UPTIME` | Feste Ports für Pi-hole-UI/DNS/Uptime Kuma | Vorgegebene Defaults, i. d. R. unverändert lassen |
| `DOMAIN` | Öffentliche Domain der Webseite | Eigene Domain, verwaltet als "Zone" in deinem Cloudflare-Account (siehe Voraussetzungen) |
| `PIHOLE_PASSWORD` | Admin-Passwort Pi-hole | Frei wählbar — `setup-env.sh` kann auch automatisch ein sicheres Passwort generieren |
| `CLOUDFLARE_TUNNEL_TOKEN` | Tunnel-Token (Secret) | Aus dem Cloudflare Zero-Trust-Dashboard beim Anlegen des Tunnels (Schnellstart Schritt 8) |
| `BACKUP_REMOTE` | rclone-Remote-Ziel für Backups | Name des rclone-Remotes, das du mit `rclone config` einrichtest (Schnellstart Schritt 13) |
| `BACKUP_RETENTION_DAILY` / `_WEEKLY` | Anzahl aufbewahrter Backup-Stände | Frei wählbare Zahlen, Default 7 / 4 |
| `AGE_RECIPIENT` | age-Public-Key zur Backup-Verschlüsselung | Wird von `setup-env.sh` automatisch erzeugt (age-Schlüsselpaar); technisch notwendig, in der SPEC ergänzt |

---

## Repo-Struktur

```
pi-server/
├── docker-compose.yml
├── .env                        # NICHT committen (gitignored)
├── .env.example
├── .gitignore
├── README.md
├── CLAUDE.md                    # Arbeitsanweisung fuer Claude Code (Aufbau + Live-Debugging)
├── raspberry-pi-4-spezifikation.md
├── sites/                       # STATISCHE Seiten (je Ordner = eine Seite)
│   ├── main/                    #   Hauptdomain
│   │   └── index.html
│   └── beispiel/                #   Beispiel-Unterseite (Vorlage)
│       └── index.html
├── apps/                        # DYNAMISCHE Apps (je Ordner = ein Container)
│   └── app-example/             #   Beispiel-App (Node)
│       ├── Dockerfile
│       ├── server.js
│       └── package.json
├── config/
│   └── caddy/
│       └── Caddyfile            # Reverse-Proxy-Routing aller Seiten
├── sites.conf                    # Manifest aller Seiten fuer scripts/deploy.sh
├── scripts/
│   ├── setup-env.sh             # interaktiver .env-Assistent
│   ├── 00-bootstrap.sh
│   ├── 01-harden.sh
│   ├── deploy-site.sh           # eine Seite aus ihrem Git-Repo aktualisieren
│   ├── deploy.sh                # alle Seiten aus sites.conf klonen/bauen/starten + Admin-Accounts seeden
│   ├── adopt-site-repo.sh       # mitgelieferten Seitenordner zu eigenem Git-Repo umbauen
│   ├── install-backup-cron.sh   # idempotente Cron-Installation
│   ├── backup.sh
│   ├── verify.sh                # buendelt alle Verifikations-Checks
│   └── install-claude-code.sh   # optional: Claude Code CLI fuer Live-Debugging
└── data/                        # Laufzeit-Volumes (gitignored)
    ├── pihole/
    ├── caddy/
    └── uptime-kuma/
```

---

## Upgrade von einem älteren Stand (nginx `web` → Caddy)

Frühere Versionen dieses Repos hatten einen einzelnen nginx-Dienst `web` für
eine einzige Seite. Wer von dort aktualisiert (`git pull`) und die Dienste
schon laufen hatte, macht danach einmalig:

1. Eigenen Inhalt der alten `website/`-Seite (falls angepasst) nach
   `sites/main/` übernehmen — der Ordner `website/` und die
   nginx-Konfiguration entfallen.
2. Im Cloudflare-Dashboard beim bestehenden Public Hostname die **Service
   URL von `http://web:80` auf `http://caddy:80`** ändern.
3. Neu starten (baut die Beispiel-App, ersetzt `web` durch `caddy`):
   ```bash
   docker compose up -d --build --remove-orphans
   docker compose ps
   ```
   `--remove-orphans` entfernt den alten `web`-Container.
4. Prüfen: `curl -I https://deine-domain.de` → `HTTP/2 200`.
