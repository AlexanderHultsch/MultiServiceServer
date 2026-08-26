# CLAUDE.md — Arbeitsanweisung für Claude Code

## Kontext
Ziel: sicherer Multi-Service-Server (Pi-hole, Caddy als Reverse Proxy,
Cloudflare Tunnel, Uptime Kuma, eigene App-Container) auf einem Raspberry Pi 4.

Der Aufbau ist **abgeschlossen** — der Server läuft produktiv. Diese Datei gilt
vor allem für **Debugging-/Wartungs-Sitzungen**, die direkt auf dem Pi gestartet
werden (`claude` im Projektordner, siehe README "Claude Code direkt auf dem Pi").

`raspberry-pi-4-spezifikation.md` ist die maßgebliche Quelle für Architektur und
Constraints. **Lies sie nicht pauschal komplett** — das sind ~6.000 Token, die
meist nichts zur Aufgabe beitragen:
- **Debugging/Wartung:** diese Datei + der passende README-Abschnitt (Tabelle
  unten) genügen. SPEC nur bei konkretem Bedarf.
- **Architekturänderung** (neuer Dienst, Netz-/Port-/Backup-Umbau): vorher SPEC
  Abschnitt 2 (Zielarchitektur), 3 (Constraints), 5 (Dienste) und 8 (Backup) lesen.
- Abschnitte 0, 4, 6, 7, 9 und 10 beschreiben den **Bauvorgang** und sind
  vollständig umgesetzt — reine Historie, nur für Rückfragen zur Herkunft.

## Wo steht was (README, ~1.100 Zeilen — gezielt greppen statt komplett lesen)
| Thema | README-Abschnitt |
|---|---|
| Fehlersuche, bekannte Fallen | `## Troubleshooting` |
| Neue Website/App anbinden | `## Weitere Websites hosten` |
| Erstinstallation des Pi | `## Schnellstart (Copy & Paste)` |
| Image-Versionen, `.env`-Herkunft | `## Referenz: ...` |
| Claude-CLI auf dem Pi | `## Claude Code direkt auf dem Pi` |

## Umgebung
- Läuft auf dem Raspberry Pi 4 (Raspberry Pi OS Lite, 64-bit, headless).
- Docker + Docker Compose vorhanden (sonst zuerst `scripts/00-bootstrap.sh`).
- Repo-Wurzel: `~/pi-server`. Arbeite immer von hier.
- `sudo` verfügbar; sparsam und nur wie in den Skripten vorgesehen einsetzen.

## Closed-Loop-Arbeitsweise (verbindlich)
Jede Änderung **Schritt für Schritt**, nie mehrere ungeprüft hintereinander:
1. Umsetzen (Datei/Skript ändern oder Befehl ausführen).
2. Mit einem konkreten Check verifizieren.
3. Erst weitergehen, wenn der Check bestanden ist. Bei Fehler: Ausgabe lesen, Ursache beheben, erneut prüfen.

Verifikations-Checks (auch gebündelt über `bash scripts/verify.sh`):
- Compose gültig: `docker compose config`
- Dienste laufen: `docker compose ps`
- Firewall: `sudo ufw status verbose` → Default-Deny + nur LAN-Regeln
- Web öffentlich erreichbar: `curl -I https://<DOMAIN>`
- Keine Secrets im Git: `git ls-files | grep -E '(^|/)\.env$|^data/'` muss leer sein

## Harte Regeln (SPEC Abschnitt 3 — NIEMALS verletzen)
Diese Liste ist **vollständig**; sie ersetzt das Nachschlagen von SPEC Abschnitt 3.
- [N2] Kein `:latest`; alle Images auf konkrete Version pinnen (Tag in README notieren).
- [N3] `.env`, `data/`, Backup-Artefakte (`*.tar.gz`, `*.age`) NIE committen.
- [N1]/[M8] Keine eingehende Portfreigabe am Router. `caddy` und **alle
  App-Container** bekommen KEINEN `ports:`-Eintrag — sie sind ausschließlich
  über `cloudflared` im internen Docker-Netz erreichbar. (Der frühere
  nginx-Dienst `web` existiert seit v2.4 nicht mehr.)
- [N4] Keinen Dienst an `0.0.0.0` binden, außer implizit über den Tunnel.
- [M3] Admin-UIs (`pihole`, `uptime-kuma`) nur an `${PI_STATIC_IP}` binden.
- [M4] `ufw` Default-Deny eingehend; Admin-Ports und SSH nur aus `${LAN_SUBNET}`.
- [M5] Secrets ausschließlich in `.env` (gitignored) plus verschlüsselte Kopie
  im Backup-Remote. App-Secrets (`SESSION_SECRET`, `ADMIN_*`) liegen in
  `apps/<name>/.env`, geschrieben von `scripts/deploy.sh`, Modus 600.
- [M6] SSH key-only; kein Passwort-Login, kein Root-Login.
- [M1] Jeder Container: `restart: unless-stopped`.
- [M7] Backup-Restore muss real getestet sein/bleiben.
- Läuft eine Claude Code CLI auf dem Pi (SPEC 5.6): niemals als
  Hintergrunddienst/Autostart einrichten (kein systemd-Unit, kein Cronjob) —
  nur On-Demand-Aufruf.

## Vorgehen bei Unsicherheit
- Versionsabhängige Details (z. B. Pi-hole-v6-Env-Variablennamen, Image-Tags, Cloudflare-Dashboard-Wortlaut) gegen die offizielle Doku verifizieren — nicht raten.
- Zerstörerische Befehle (`rm -rf`, `docker volume rm`, `ufw reset`) vorher ankündigen und bestätigen lassen.
- **Dies ist ein LIVE-Server** (DNS fürs ganze LAN + öffentliche Webseite). Handle vorsichtig; keine breiten Löschaktionen ohne Rückfrage.

## Nicht im Scope
- WireGuard/Tailscale nur, wenn ausdrücklich angefordert (SPEC 5.5).
