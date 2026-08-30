# SPEC: Raspberry Pi 4 - Secure Multi-Service Server

**Version:** 2.4 (hardware-agnostic)
**Target audience of this document:** AI coding agent (Claude Code)
**Format:** Declarative specification. All values in section 1 are the *single
source of truth* and are referenced throughout.

---

## 0. MANDATE TO THE CODING AGENT

You are a coding agent. Produce from this specification:

1. A complete, runnable repository following the structure in **section 4**.
2. A `docker-compose.yml` that starts all services from **section 5**.
3. All configuration files from **section 6** (fully filled in except for
   `<<PLACEHOLDER>>` values).
4. Setup and hardening scripts per **section 7**.
5. A backup/restore script per **section 8**.
6. A `README.md` with setup instructions **and** a tested restore procedure.

**Rules:**
- Follow **every** MUST/MUST-NOT rule in **section 3**.
- Use only the parameters from **section 1**; do not invent values.
- `<<PLACEHOLDER>>` = to be filled in by the user -> leave it as such and list
  it in **section 10**.
- Where an image version or an environment variable name is version-dependent,
  **verify** it against the official docs of the pinned version and document
  the version used.
- No step counts as done without its matching *Definition of Done* from
  **section 9**.

---

## 1. GLOBAL PARAMETERS (Single Source of Truth)

Convention:
- `${VAR}` -> value lives in `.env` (do not commit).
- `<<PLACEHOLDER>>` -> the user must set this before deployment.

| Parameter | Default | User-adjustable | Description |
|---|---|---|---|
| `TZ` | `Europe/Berlin` | yes | Timezone for all containers |
| `LAN_SUBNET` | `192.168.1.0/24` | **yes** | Home network CIDR for firewall rules |
| `PI_STATIC_IP` | `192.168.1.10` | **yes** | Fixed IP of the Pi (DHCP reservation) |
| `PORT_PIHOLE_UI` | `8080` | no | Host port for Pi-hole web admin (LAN only) |
| `PORT_DNS` | `53` | no | DNS (TCP+UDP, LAN only) |
| `PORT_UPTIME` | `3001` | no | Host port for Uptime Kuma (LAN only) |
| `DOMAIN` | `<<DOMAIN>>` | **yes** | Public domain of the website |
| `CLOUDFLARE_TUNNEL_TOKEN` | `<<CLOUDFLARE_TUNNEL_TOKEN>>` | **yes** | Tunnel token (secret) |
| `PIHOLE_PASSWORD` | `<<PIHOLE_PASSWORD>>` | **yes** | Pi-hole admin password (secret) |
| `REPO_ROOT` | `~/pi-server` | yes | Root directory of the repo on the Pi |
| `BACKUP_REMOTE` | `onedrive:PiBackups` | yes | rclone remote target for data backups |
| `BACKUP_RETENTION_COUNT` | `12` | yes | Number of newest weekly backup archives to keep |
| `BACKUP_HEARTBEAT_URL` | (empty) | yes | Uptime Kuma push monitor URL for backup notifications (optional) |
| `AGE_RECIPIENT` | `<<AGE_RECIPIENT_PUBLIC_KEY>>` | **yes** | age public key for backup encryption (technically required for section 8.2, added in v2.0) |

**Image tag policy:** All images MUST be pinned to a **concrete published
version** (see section 5). `:latest` is forbidden. The agent enters the
current stable version at implementation time and notes it in `README.md`.

---

## 2. TARGET ARCHITECTURE

```
                     Internet
                        |  (OUTBOUND only, encrypted)
                 +------v------+
                 | Cloudflare  |  DNS . TLS . DDoS protection . hides home IP
                 +------+------+
                        |  outbound-only tunnel
================================v========================================
| Raspberry Pi . ufw default-deny (inbound)                             |
|                                                                        |
|  cloudflared --> caddy --> static sites (sites/)                      |
|                     `----> dynamic apps (apps/)                       |
|                                                                        |
|  pihole (DNS+adblock, LAN only)   uptime-kuma (LAN only)              |
==========================================================================
                        |
                   LAN (${LAN_SUBNET})
          all devices use ${PI_STATIC_IP} as DNS
```

**Invariant:** No port is open from the outside. The only external path to
the websites runs through the Cloudflare tunnel established by the Pi;
internally, `caddy` distributes traffic by hostname.

---

## 3. HARD CONSTRAINTS

### MUST
- [M1] Every container: `restart: unless-stopped`.
- [M2] All images pinned to a concrete version.
- [M3] Admin UIs (`pihole`, `uptime-kuma`) are bound **only** to `${PI_STATIC_IP}`.
- [M4] `ufw` default-deny inbound; access to admin ports/SSH only from `${LAN_SUBNET}`.
- [M5] Secrets exclusively in `.env` (gitignored) plus an encrypted copy in the backup remote.
- [M6] SSH only via public key; `PasswordAuthentication no`; `PermitRootLogin no`.
- [M7] Backup restore must be **actually tested once** before completion.
- [M8] The web/proxy service (`caddy`) and all app containers have **no**
  `ports:` entry (internal Docker network only, reachable exclusively via cloudflared).

### MUST NOT
- [N1] No inbound port forwarding on the router.
- [N2] No `:latest` tag.
- [N3] Never commit `.env`, `data/`, or backup artifacts.
- [N4] No service bound to `0.0.0.0`, except implicitly via the tunnel.
- [N5] No password-based SSH login.

---

## 4. REPO STRUCTURE (target state)

```
pi-server/
+-- docker-compose.yml
+-- .env                      # DO NOT commit
+-- .env.example              # template without real values
+-- .gitignore
+-- README.md                 # setup + restore
+-- CLAUDE.md                 # work instructions for Claude Code (build + live debugging)
+-- raspberry-pi-4-spezifikation.md   # this file
+-- sites/                    # static sites (one folder = one site)
|   +-- main/index.html
|   +-- beispiel/index.html
+-- apps/                     # dynamic apps (one folder = one container)
|   +-- app-example/          #   Dockerfile + source code
+-- config/
|   +-- caddy/
|       +-- Caddyfile          # reverse proxy routing (section 5.2)
+-- scripts/
|   +-- setup-env.sh          # interactive .env assistant
|   +-- 00-bootstrap.sh        # OS update, Docker, packages
|   +-- 01-harden.sh           # SSH hardening + ufw
|   +-- deploy-site.sh         # update one site from its git repo
|   +-- install-backup-cron.sh # idempotent cron installation
|   +-- backup.sh              # data backup + rotation
|   +-- verify.sh              # bundles all verification checks
|   +-- install-claude-code.sh # optional: Claude Code CLI for live debugging (section 5.6)
+-- data/                      # runtime volumes (gitignored)
    +-- pihole/
    +-- uptime-kuma/
```

---

## 5. SERVICE SPECIFICATION

Format per service: **Image**, **Purpose**, **Exposure**, **Ports**,
**Volumes**, **Env**, **Dependencies**.

### 5.1 `pihole`
- **Image:** `pihole/pihole:<<PIN_TAG>>`
- **Purpose:** network-wide DNS resolver + ad/tracker blocker.
- **Exposure:** LAN only.
- **Ports:** `${PI_STATIC_IP}:${PORT_DNS}:53/tcp`, `${PI_STATIC_IP}:${PORT_DNS}:53/udp`, `${PI_STATIC_IP}:${PORT_PIHOLE_UI}:80/tcp`
- **Volumes:** `./data/pihole/etc-pihole:/etc/pihole`
- **Env:** `TZ=${TZ}`, admin password = `${PIHOLE_PASSWORD}`
  > Env variable names are Pi-hole v6 specific (e.g. `FTLCONF_webserver_api_password`).
  > The agent MUST check the exact name against the pinned version.
- **Upstream DNS:** encrypted preferred (Quad9 `9.9.9.9` or Cloudflare `1.1.1.1`); optional DoH sidecar.
- **`FTLCONF_dns_listeningMode: "ALL"` is MANDATORY** (added in v2.2, verified
  for real on hardware): Pi-hole v6 otherwise defaults to
  `dns.listeningMode=LOCAL`. Since `pihole` runs on a Docker bridge network,
  FTL then only considers requests from its own bridge subnet "local" and
  silently drops real LAN clients (log: `ignoring query from non-local
  network ...`) - the service runs but answers nobody on the LAN. `ALL` is
  safe here because port 53 is bound only to `${PI_STATIC_IP}` per
  [M3]/[N4] anyway, not to `0.0.0.0`.

### 5.2 `caddy` (reverse proxy & web server)
As of v2.4, Caddy replaces the former single `web`/nginx service. A reverse
proxy for **any number** of websites (static + dynamic).
- **Image:** `caddy:<<PIN_TAG>>-alpine`
- **Purpose:** cloudflared sends every hostname to `caddy:80`; Caddy
  distributes it by (sub)domain - static sites from folders (`file_server`),
  dynamic apps via `reverse_proxy` to their container.
- **Exposure:** **internal Docker network `edge` only** - no host port (see [M8]).
- **Volumes:** `./config/caddy/Caddyfile:/etc/caddy/Caddyfile:ro`, `./sites:/srv:ro`, `./data/caddy/...`
- **Env:** `DOMAIN=${DOMAIN}` (used in the Caddyfile as `{$DOMAIN}`).
- **Routing configuration:** `config/caddy/Caddyfile` (config-as-code).
- **`auto_https off`** - Cloudflare terminates TLS outward, Caddy serves plain HTTP internally.

### 5.2b Websites (content, not its own Docker service type)
- **Static site:** folder `sites/<name>/` -> served directly by Caddy. No
  own container (resource-friendly on the Pi).
- **Dynamic app:** folder `apps/<name>/` with its own `Dockerfile` -> its own
  compose service on `edge`, reachable from Caddy via `reverse_proxy`.
  Example: `apps/app-example` (Node).
- **Git repo per site:** each site can be its own git repo (cloned into
  `sites/`/`apps/`, path in the main repo's `.gitignore`). Deploy via
  `scripts/deploy-site.sh <name>`.
- **Wildcard limitation:** Cloudflare proxied wildcard hostnames are not
  available on the free plan -> one Public Hostname per subdomain in the
  dashboard (all -> `http://caddy:80`).

### 5.3 `cloudflared`
- **Image:** `cloudflare/cloudflared:<<PIN_TAG>>`
- **Purpose:** outbound tunnel; makes the websites publicly reachable under
  `${DOMAIN}` (and subdomains).
- **Exposure:** no open ports (outbound only).
- **Command:** `tunnel --no-autoupdate run --token ${CLOUDFLARE_TUNNEL_TOKEN}`
- **Routing:** all Public Hostnames -> `http://caddy:80` (distribution is
  handled by Caddy).
  > **Default:** token method; routing is set in the Cloudflare Zero Trust
  > dashboard (current label there: "Published Application routes").
  > **Alternative (more config-as-code):** local `config.yml` + credentials
  > file (credentials = secret, gitignored). Selectable for maximum
  > reproducibility.
- **Dependencies:** `depends_on: [caddy]`

### 5.4 `uptime-kuma`
- **Image:** `louislam/uptime-kuma:<<PIN_TAG>>`
- **Purpose:** availability monitoring + notifications.
- **Exposure:** LAN only.
- **Ports:** `${PI_STATIC_IP}:${PORT_UPTIME}:3001`
- **Volumes:** `./data/uptime-kuma:/app/data`
- **Database:** choose **SQLite** on first start (lightweight, included in
  the `data/` backup; embedded MariaDB is needlessly heavy on the Pi).
- **Checks (to set up after first start):** public website(s), Pi-hole
  **via the internal service name** (`http://pihole/admin/`, not the LAN
  IP - otherwise a Docker NAT hairpin timeout), an internet reference check.

### 5.4b Email - [Cloudflare Email Routing, not a Pi service]
Added in v2.4. Email is **not** hosted on the Pi (port 25 is usually blocked,
inbound ports would contradict [N1], reputation/deliverability is unsolvable
on a residential connection). Instead, **Cloudflare Email Routing**:
`support@${DOMAIN}` -> existing mailbox, pure dashboard configuration, no
inbound ports. Receiving/forwarding only; sending-as additionally requires an
SMTP relay (out of scope).

### 5.5 `wireguard` / `tailscale` - [OPTIONAL, NOT in the default scope]
Only add this if explicitly requested. Without this module, admin UIs and
dashboards are reachable only within the LAN (a deliberate decision).
- **Recommendation:** Tailscale (no port forwarding, CGNAT-capable, free personal tier).
- **Alternative:** self-hosted WireGuard (needs **one** UDP port forwarded ->
  contradicts [N1], so only with deliberate intent).

### 5.6 `claude-code` - [OPTIONAL, debug tool, not a service in the Docker sense]
Added in v2.1. Not its own container, no `restart: unless-stopped`, no entry
in `docker-compose.yml` - a CLI tool that runs **on request** (on-demand)
directly on the Pi's host OS to support debugging/maintenance of this stack
via a conversation with Claude ("closed-loop" debugging directly on the
device instead of only via a remote chat).

- **Installation:** `scripts/install-claude-code.sh` (Node.js LTS + `npm
  install -g @anthropic-ai/claude-code`; deliberately **not** the native
  installer, since it has known issues on ARM64/Raspberry Pi at the time
  this specification was written).
- **Operating mode:** [M9] **No background service.** No systemd unit, no
  cron job, no autostart. Invocation is manual only (`claude` in the project
  directory), resource usage only during an active session - rationale:
  conserving resources on the limited Pi hardware, see [N6].
- **Authentication:** headless-capable via `ANTHROPIC_API_KEY` (API key) or
  `CLAUDE_CODE_OAUTH_TOKEN` (generated on a device with a browser via `claude
  setup-token`, the value then set on the Pi) - no interactive browser login
  on the headless Pi.
- **Network:** outbound connections to the Anthropic API only, no additional
  inbound port forwarding - therefore does not contradict [N1].
- **Context:** automatically reads `CLAUDE.md` and this specification from
  the project directory at startup; the same instance from section 0 thus
  accompanies both the initial build and later live debugging sessions
  directly on the device.
- **Hardware note:** Anthropic's official minimum for the CLI is 4 GB RAM.
  On a Pi 4 with 1-2 GB RAM, an active session competes with the running
  containers for memory - for this module, a Pi 4 with **at least 4 GB RAM**
  is recommended.

### Additional rule from 5.6 (supplement to section 3)
- [M9] The Claude Code CLI runs exclusively on-demand, never as a background
  service/autostart.
- [N6] No systemd unit, no cron job, and no other autostart mechanism for the
  Claude Code CLI.

### Networks & policy (Compose)
- Network `edge`: `caddy` + `cloudflared` + dynamic apps (`app-example`, ...).
- Network `lan_net`: `pihole` + `uptime-kuma`.
- `caddy` and the apps are reachable exclusively via `edge` (no host port).

---

## 6. CONFIGURATION TEMPLATES

The agent generates these files in full; below are the binding skeletons.

### 6.1 `docker-compose.yml` (skeleton)
```yaml
services:
  pihole:
    image: pihole/pihole:<<PIN_TAG>>
    restart: unless-stopped
    environment:
      TZ: ${TZ}
      # Pi-hole v6: verify the exact password env name against the docs
      FTLCONF_webserver_api_password: ${PIHOLE_PASSWORD}
      # Mandatory in Docker networks, see 5.1 - otherwise LAN clients get dropped
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
    # NO ports: (constraint M8)

  # Dynamic apps: one service per app with build: ./apps/<name>, networks: [edge].
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
Minimal valid HTML5 placeholder with the hostname/domain as the title.

---

## 7. SYSTEM SETUP (scripts)

### 7.1 `scripts/00-bootstrap.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y git ufw fail2ban unattended-upgrades rclone age
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"
sudo dpkg-reconfigure -plow unattended-upgrades
echo "Bootstrap done. Please log in again (docker group)."
```
`git` was added in v2.1: Raspberry Pi OS Lite does not have it preinstalled,
but it is needed before this script to clone the repo (see README).

### 7.2 `scripts/01-harden.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail
# load values from .env
set -a; source ../.env; set +a

# SSH hardening
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sudo systemctl restart ssh

# Firewall: default-deny inbound, access only from LAN
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from "${LAN_SUBNET}" to any port 22
sudo ufw allow from "${LAN_SUBNET}" to any port "${PORT_DNS}"
sudo ufw allow from "${LAN_SUBNET}" to any port "${PORT_PIHOLE_UI}"
sudo ufw allow from "${LAN_SUBNET}" to any port "${PORT_UPTIME}"
sudo ufw --force enable
```
Must check, before disabling `PasswordAuthentication`, whether
`~/.ssh/authorized_keys` is populated, and abort with an error otherwise
(self-lockout protection, added in v2.0 as an implementation detail).

---

## 8. BACKUP & RESTORE

### 8.1 Two separate tracks
- **Config/code -> GitHub (private or public repo):** everything except
  `.env` and `data/`.
- **Data/secrets -> backup remote (encrypted):** `data/` volumes + encrypted `.env`.

### 8.2 `scripts/backup.sh` (specification)
1. Check that `${BACKUP_REMOTE}` is reachable and its token is still valid;
   abort early with a clear message if not. An expired OneDrive OAuth token
   is the expected failure mode of an unattended weekly job, and failing
   before an hour of tar and age work makes the log unambiguous.
2. Pack the whole of `data/` into `backup-YYYY-MM-DD.tar.gz`. `data/` also
   holds Pi-hole, Caddy and Uptime Kuma state, it is all small, and a
   restore needs `.env` anyway - there is no per-site selection.
3. Include `.env`.
4. Encrypt with `age` (public key, `${AGE_RECIPIENT}`) -> `.age`.
5. Push via `rclone copy` to `${BACKUP_REMOTE}`.
6. Rotation: keep the newest `${BACKUP_RETENTION_COUNT}` archives (default
   `12`, i.e. about three months of weekly backups); delete everything
   older than the newest `${BACKUP_RETENTION_COUNT}`. This replaces the
   former daily/weekly retention pair (see change history). A count is
   used instead of an age cutoff ("delete anything older than 12 weeks")
   deliberately: an age cutoff would, if the job stopped running for
   longer than that, delete every backup that exists while no new one is
   arriving. Keeping the newest N can never empty the remote.
7. On success, if `${BACKUP_HEARTBEAT_URL}` is set, ping it with an up
   status; on failure, ping it with a down status and a short reason.
   `${BACKUP_HEARTBEAT_URL}` is optional: if it is empty or unset, the
   backup still runs and only the notification is skipped - it must never
   be a hard requirement.
8. Set up as a **weekly** cron job in the root crontab: Mondays at 03:30.
   The data that matters (accounts, recipes, game progress) changes
   slowly, and a night-time slot reduces how much the containers are
   writing while the archive is taken.

**Operational requirements (v2.3, from real-world verification):**
- Runs as **root** (cron job in the root crontab): the files under `data/`
  are owned by the container users; a tar run without root fails with
  "Permission denied" - unnoticed during the nightly run.
- `rclone` is run as the **repo owner** (a normal user) so that its
  `~/.config/rclone` is used and token renewals do not flip the config file
  over to root.

**Accepted risk (v2.5): hot tar of a running system.**
The archive is taken from a running system: the containers keep writing to
their SQLite databases while tar reads them, and tar exit code 1 ("file
changed as we read it") is tolerated. This means a backup can in principle
contain a torn, unrestorable database, and that would only be discovered at
restore time. Two alternatives were considered - per-database
`sqlite3 .backup` snapshots, or briefly stopping the containers during the
backup window - and deliberately not chosen; the owner chose to keep the
hot tar. This is recorded as an accepted risk so that a future restore
failure is not a surprise and the decision can be revisited without
re-deriving it.

**Failure detection (v2.5): Uptime Kuma push heartbeat.**
`${BACKUP_HEARTBEAT_URL}` points at an Uptime Kuma PUSH monitor and covers
three failure cases:
1. The script runs and succeeds -> it pings the monitor with an up status.
2. The script runs and fails (reachability check, tar, age, or rclone
   step) -> it pings the monitor with a down status and a short reason.
3. The script does not run at all - broken cron, Pi switched off, SD card
   dead - no ping arrives, and the monitor's own heartbeat interval
   expires, so Uptime Kuma raises the alarm on its own.
This third case is the reason a push monitor is used rather than the
script sending mail: a script that never runs cannot send its own mail
either. Recommended monitor heartbeat interval: 8 days, so that one missed
weekly run alerts without a late run causing a false alarm.

### 8.3 Restore procedure
1. Flash the OS onto the boot medium, run `00-bootstrap.sh` + `01-harden.sh`.
2. Clone the repo.
3. Fetch the latest `.age` backup from `${BACKUP_REMOTE}`, decrypt it,
   restore `data/` + `.env`.
4. `docker compose up -d`.

Per [M7], this must be actually tested once before the setup counts as complete.

---

## 9. IMPLEMENTATION ORDER (with Definition of Done)

| # | Step | Definition of Done |
|---|---|---|
| 1 | Repo skeleton + `.gitignore` + `.env.example` | `git status` shows no secrets/`data/`; structure = section 4 |
| 2 | `00-bootstrap.sh` | Docker, git & packages installed, script idempotent |
| 3 | `01-harden.sh` | SSH key-only; `ufw status` = default-deny + LAN rules only |
| 4 | `pihole` | Web UI only under `${PI_STATIC_IP}:${PORT_PIHOLE_UI}`; DNS filters on the LAN |
| 5 | `caddy` + `cloudflared` | `${DOMAIN}` publicly reachable via HTTPS; `caddy` has no host port (until v2.3 this service was called `web`/nginx, see 5.2) |
| 6 | `uptime-kuma` | UI LAN-only; checks for web/pihole/internet active |
| 7 | `backup.sh` + cron | Backup lands encrypted in the remote; rotation works |
| 8 | **Restore test** | Full restore on an empty system succeeds ([M7]) |
| 9 | `README.md` | Setup complete; image tags used are noted |
| 10 | `claude-code` (optional, 5.6) | CLI installed, login works, verifiably not running as a background service ([M9]/[N6]) |

---

## 10. PARAMETERS TO BE FILLED IN BY THE USER

- `<<DOMAIN>>` - registered domain (recommended via Cloudflare Registrar,
  alternatively: connect an existing domain to Cloudflare via a nameserver change).
- `<<CLOUDFLARE_TUNNEL_TOKEN>>` - from the Cloudflare Zero Trust dashboard.
- `<<PIHOLE_PASSWORD>>` - Pi-hole admin password.
- `<<AGE_RECIPIENT_PUBLIC_KEY>>` - age public key for backup encryption
  (added in v2.0, technically required for 8.2).
- `LAN_SUBNET` / `PI_STATIC_IP` - adapt to your own home network.
- `<<PIN_TAG>>` per image - set by the agent to the current stable version.
- Decision: cloudflared **token method** (default, chosen) or **config.yml**.
- Decision: backup encryption with `age` (default, chosen) or `gpg`.
- Optional: set up the Claude Code CLI (5.6), including `ANTHROPIC_API_KEY`
  or `CLAUDE_CODE_OAUTH_TOKEN`.

---

## Change history

- **v2.0:** Added `AGE_RECIPIENT` (technical necessity for 8.2, not
  originally planned in section 1); added `git` in 7.1; added self-lockout
  protection in 7.2.
- **v2.1:** Added section 5.6 (`claude-code`, optional on-demand debug tool)
  as well as [M9]/[N6]; extended the repo structure (section 4) with
  `CLAUDE.md`, this file, and `scripts/install-claude-code.sh`; added row 10
  to the implementation table (section 9).
- **v2.2:** Added `FTLCONF_dns_listeningMode: "ALL"` as a mandatory env var
  for `pihole` (5.1, 6.1) - without this setting, Pi-hole v6 on a Docker
  bridge network silently drops real LAN clients as "non-local"; found and
  verified on real hardware.
- **v2.3:** Clarified operational requirements for `backup.sh` (8.2): runs
  as root (root crontab) since `data/` is owned by the container users;
  rclone runs as the repo owner; tar exit code 1 accepted while containers
  are running. Scripts get self-protection guards (with/without sudo,
  missing `.env`/`ufw`).
- **v2.4:** Multi-website hosting: replaced `nginx`/`web` with `caddy`
  (reverse proxy) (5.2); added `sites/` (static) + `apps/` (dynamic, own
  container) + `config/caddy/Caddyfile` + `scripts/deploy-site.sh` (repo
  structure, section 4). Documented the Cloudflare wildcard limitation (free
  plan); all Public Hostnames -> `http://caddy:80`. Cloudflare Email Routing
  for `support@${DOMAIN}` (5.4b). Uptime Kuma: SQLite recommended, Pi-hole
  monitor via internal service name.
- **v2.5:** Redesigned the backup schedule and monitoring (8.2): backup.sh
  now runs weekly (Mondays 03:30) instead of nightly; retention switched
  from `BACKUP_RETENTION_DAILY`/`BACKUP_RETENTION_WEEKLY` to a single
  `BACKUP_RETENTION_COUNT` (default 12, keep-newest-N instead of
  age-based, so a stalled job cannot empty the remote); added an optional
  `BACKUP_HEARTBEAT_URL` Uptime Kuma push monitor for failure detection,
  including the no-run-at-all case; added a reachability/token precheck
  before packing or encrypting; documented the hot-tar approach as a
  deliberately accepted risk with its rejected alternatives.

*End of SPEC v2.5 - hardware-free, agent-optimized.*
