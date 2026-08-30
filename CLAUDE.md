# CLAUDE.md - Work Instructions for Claude Code

## Context
Goal: secure multi-service server (Pi-hole, Caddy as reverse proxy,
Cloudflare Tunnel, Uptime Kuma, own app containers) on a Raspberry Pi 4.

The build is **complete** - the server runs in production. This file applies
mainly to **debugging/maintenance sessions** started directly on the Pi
(`claude` in the project folder, see README "Claude Code direkt auf dem Pi").

`raspberry-pi-4-spezifikation.md` is the authoritative source for architecture
and constraints. **Do not read it in full by default** - that is about 6,000
tokens which usually contribute nothing to the task at hand:
- **Debugging/maintenance:** this file plus the matching README section (table
  below) are enough. Consult the SPEC only when a concrete need arises.
- **Architecture change** (new service, network/port/backup restructuring):
  read SPEC section 2 (target architecture), 3 (constraints), 5 (services) and
  8 (backup) first.
- Sections 0, 4, 6, 7, 9 and 10 describe the **build process** and have been
  fully implemented - pure history, useful only for questions about origin.

## Where to find what (README, ~1,100 lines - grep for it rather than reading it whole)
| Topic | README section |
|---|---|
| Troubleshooting, known pitfalls | `## Troubleshooting` |
| Connecting a new website/app | `## Weitere Websites hosten` |
| Initial setup of the Pi | `## Schnellstart (Copy & Paste)` |
| Image versions, `.env` origin | `## Referenz: ...` |
| Claude CLI on the Pi | `## Claude Code direkt auf dem Pi` |

## Environment
- Runs on the Raspberry Pi 4 (Raspberry Pi OS Lite, 64-bit, headless).
- Docker + Docker Compose already present (otherwise run `scripts/00-bootstrap.sh` first).
- Repo root: `~/pi-server`. Always work from here.
- `sudo` is available; use it sparingly and only as the scripts intend.

## Closed-loop workflow (mandatory)
Every change **step by step**, never several unverified changes in a row:
1. Implement (change a file/script or run a command).
2. Verify with a concrete check.
3. Only proceed once the check passes. On failure: read the output, fix the
   cause, check again.

Verification checks (also bundled via `bash scripts/verify.sh`):
- Compose is valid: `docker compose config`
- Services are running: `docker compose ps`
- Firewall: `sudo ufw status verbose` -> default-deny plus LAN rules only
- Website reachable publicly: `curl -I https://<DOMAIN>`
- No secrets in git: `git ls-files | grep -E '(^|/)\.env$|^data/'` must be empty

## Hard rules (SPEC section 3 - NEVER violate)
This list is **complete**; it replaces looking up SPEC section 3.
- [N2] No `:latest`; pin all images to a concrete version (note the tag in the README).
- [N3] Never commit `.env`, `data/`, or backup artifacts (`*.tar.gz`, `*.age`).
- [N1]/[M8] No inbound port forwarding on the router. `caddy` and **all
  app containers** get NO `ports:` entry - they are reachable exclusively
  via `cloudflared` on the internal Docker network. (The former nginx
  service `web` has not existed since v2.4.)
- [N4] Do not bind any service to `0.0.0.0`, except implicitly via the tunnel.
- [M3] Admin UIs (`pihole`, `uptime-kuma`) bind only to `${PI_STATIC_IP}`.
- [M4] `ufw` default-deny inbound; admin ports and SSH only from `${LAN_SUBNET}`.
- [M5] Secrets live exclusively in `.env` (gitignored) plus an encrypted copy
  in the backup remote. App secrets (`SESSION_SECRET`, `ADMIN_*`) live in
  `apps/<name>/.env`, written by `scripts/deploy.sh`, mode 600.
- [M6] SSH key-only; no password login, no root login.
- [M1] Every container: `restart: unless-stopped`.
- [M7] Backup restore must be, and must remain, actually tested.
- If a Claude Code CLI runs on the Pi (SPEC 5.6): never set it up as a
  background service/autostart (no systemd unit, no cron job) - on-demand
  invocation only.

## What to do when unsure
- Verify version-dependent details (e.g. Pi-hole v6 env variable names, image
  tags, Cloudflare dashboard wording) against the official docs - do not guess.
- Announce destructive commands (`rm -rf`, `docker volume rm`, `ufw reset`)
  beforehand and get confirmation.
- **This is a LIVE server** (DNS for the whole LAN plus a public website).
  Act carefully; no broad deletions without asking first.

## Out of scope
- WireGuard/Tailscale only if explicitly requested (SPEC 5.5).
