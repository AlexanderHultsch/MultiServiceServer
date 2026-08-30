# PiMultiServiceServer - Secure Multi-Service Server for Raspberry Pi 4

This repository turns a Raspberry Pi 4 into a small, secure home server. It
implements `raspberry-pi-4-spezifikation.md` (v2.4), which serves as the
authoritative source of truth for all technical decisions.

## What You End Up With

- **As many websites as you like** under your own domain and subdomains
  (`deine-domain.de`, `beispiel.deine-domain.de`, ...), publicly reachable on
  the internet - without opening a single port on the router. Static sites
  and dynamic apps (own container) side by side, each optionally in its own
  Git repo (see "Hosting Additional Websites").
- **Pi-hole**: a network-wide DNS server that blocks ads and trackers for
  every device on your home network (phones, laptops, smart TVs, ...),
  without installing anything on each device individually.
- **Uptime Kuma**: a dashboard that shows you whether the website, Pi-hole,
  and internet connection are up, and notifies you of outages.
- **Automatic, encrypted backups** of all configuration data to the cloud
  (e.g. OneDrive), with rotation of old backups.
- A system hardened according to the usual baseline rules for
  internet-exposed servers: no password login over SSH, firewall in
  default-deny mode, no unnecessarily open ports.

The websites technically run behind a **Cloudflare Tunnel**: the Pi itself
opens an outbound, encrypted connection to Cloudflare, through which the
sites become publicly reachable. As a result, not a single port stays open
on the router as seen from outside - the Pi is invisible on the home
network. Inside the Pi, **Caddy** (a reverse proxy) routes every hostname to
the right site: static sites straight from folders, dynamic apps to their
containers.

```
                     Internet
                        |  (outbound only, encrypted)
                 +------v------+
                 | Cloudflare  |  DNS / TLS / DDoS protection / hides home IP
                 +------+------+
                        |  outbound-only tunnel
 ========================v=========================================
 : Raspberry Pi - ufw default-deny (inbound)                       :
 :                                                                  :
 :  cloudflared --> caddy --> sites/main         (static)          :
 :                    +  +---> sites/beispiel      (static)        :
 :                    +------> app-example        (dynamic app)    :
 :                                                                  :
 :  pihole (DNS+adblock, LAN only)   uptime-kuma (LAN only)        :
 ========================================================================
                        |
                   LAN (${LAN_SUBNET})
          all devices use ${PI_STATIC_IP} as DNS
```

This README explains, for every value you have to enter, **where** it comes
from and **how** you get it. Wherever possible, the manual work has been
packed into scripts (`scripts/setup-env.sh`, `scripts/verify.sh`,
`scripts/install-backup-cron.sh`) - what remains are only the steps that
absolutely require a Cloudflare/router web interface.

> **Note, in case this repository is public:** anyone can read
> `docker-compose.yml`, the scripts, and this README. That is not a problem
> as long as `.env` and `data/` (see `.gitignore`) are never committed - all
> the secrets live there (Pi-hole password, Cloudflare token, age key).
> Before every `git push`: check `git status`; when in doubt run
> `git ls-files | grep -E '(^|/)\.env$|^data/'` (must be empty - this is also
> checked automatically by `scripts/verify.sh`).

---

## Overview: Automated vs. Manual

| Automated (via script) | Manual (web UI / router, cannot be automated) |
|---|---|
| System update, Docker installation | Flashing the SD card |
| SSH hardening, firewall rules | Adding the SSH public key on the Pi |
| Generating `.env` including LAN detection | Adding the domain to Cloudflare |
| Generating the age key pair | Creating the Cloudflare Tunnel + public hostname |
| Backup, encryption, rotation, upload | `rclone config` (OAuth login in the browser) |
| Cron job for the weekly backup | DHCP reservation + Pi-hole as DNS on the router |
| All verification checks (`verify.sh`) | Real restore test on fresh hardware ([M7]) |

---

## Prerequisites

- A computer (Windows/Mac/Linux) to flash the SD card and for SSH.
- Raspberry Pi 4, microSD card or USB SSD, power supply, network cable or WLAN.
- A Cloudflare account (free): <https://dash.cloudflare.com/sign-up>
- A domain managed by Cloudflare as a "zone". If you do not have an existing
  domain, the simplest option is to register one directly in the Cloudflare
  dashboard (it lands on Cloudflare nameservers automatically). With an
  existing domain at another provider: add it in the Cloudflare dashboard,
  then enter the two nameservers it shows you at your current provider - the
  registration itself does not need to move.
- A target for encrypted backups that `rclone` supports (default: OneDrive -
  any service supported by `rclone config` works).

### Generating an SSH Key Pair (If You Don't Have One Yet)

Needed so you can later log in to the Pi without a password - mandatory per
the specification ([M6]: no password login).

```bash
# Mac/Linux (on your own computer, NOT on the Pi):
ls ~/.ssh/id_ed25519.pub 2>/dev/null || ssh-keygen -t ed25519 -C "pi-server"
```

Windows: open PowerShell and run the same command (the OpenSSH client has
been preinstalled since Windows 10), or use PuTTYgen.

---

## Quick Start (Copy & Paste)

**All 16 steps at a glance** - details follow below:

| # | Step | Where |
|---|---|---|
| 1 | Flash SD card, prepare SSH | Your own computer |
| 2 | Connect via SSH | Your own computer |
| 3 | Clone the repo | Pi |
| 4 | Generate `.env` via the assistant | Pi |
| 5 | Bootstrap (Docker, packages) | Pi |
| 6 | Reserve a static IP | Router |
| 7 | Hardening (SSH, firewall) | Pi |
| 8 | Create the Cloudflare Tunnel | Cloudflare dashboard |
| 9 | Start the services | Pi |
| 10 | Pi-hole as the network DNS | Router |
| 11 | Check the public website | Pi |
| 12 | Set up Uptime Kuma | Browser (LAN) |
| 13 | Connect the backup target (rclone) | Pi |
| 14 | Test the backup + set up cron | Pi |
| 15 | Full verification | Pi |
| 16 | Restore test | Fresh system |

> **Sudo convention:** start all scripts **without** `sudo` - they request
> root privileges themselves where needed, and abort with a clear message if
> something is missing. The one exception is `scripts/backup.sh`, which
> needs `sudo bash scripts/backup.sh` (reasoning in step 14).

### 1. Flash the SD Card and Prepare SSH

> **No more default "pi" user:** since Raspberry Pi OS "Bookworm" there is no
> longer a preinstalled `pi` user. In the Imager, under "Advanced options",
> you set your **own username**. Throughout this README, `<username>` is a
> placeholder for that - in every command, replace it with the actual name
> you chose.

1. Install and open the [Raspberry Pi Imager](https://www.raspberrypi.com/software/).
2. Device: **Raspberry Pi 4**. Operating system: **Raspberry Pi OS Lite (64-bit)**.
3. Click the gear icon (the "Advanced options"), and there:
   - Set a hostname (e.g. `pi-server`)
   - **Set a username and password** - set a password even if you want
     public-key login only (as a fallback in case the key import does not
     take effect, see the box below - this happens occasionally).
   - Enable SSH -> "Allow public-key authentication only" -> paste the
     **public key** (the content of `~/.ssh/id_ed25519.pub`, NOT the private
     key!). Some Imager versions do not reliably apply the pasted key when
     writing the card - always verify with the command in the box below
     after the first login.
   - If using WLAN: enter the SSID/password
4. Write the image, insert the SD card into the Pi, power on the Pi.

#### Checking What the Imager Actually Set Up

After the first login, **always** check whether a **public key** was
actually added (not just that password login works) - this is a prerequisite
for step 7 (`01-harden.sh` otherwise aborts with an error message, so you
don't lock yourself out):

```bash
cat ~/.ssh/authorized_keys 2>/dev/null && echo "OK: key present" || echo "MISSING: see below"
```

**If that is empty** (the Imager's key import did not work, login currently
works only via password - a known, occasional Imager issue): add the key
now from your own computer, using the existing password login:

```bash
# Mac/Linux, on your own computer, you will be prompted for the password once:
ssh-copy-id <username>@pi-server.local
```

```powershell
# Windows (PowerShell), on your own computer, if ssh-copy-id is not available:
Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub | ssh <username>@pi-server.local "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
```

Then check again on the Pi (command above) - only once "OK: key present"
appears, continue with step 2 or step 7.

### 2. Connect

```bash
# Find the Pi on the network (default hostname, or the one you set):
ping pi-server.local

# Connect (<username> = the username set in the Imager):
ssh <username>@pi-server.local
```

If `*.local` does not resolve: find the IP via the router's device list (the
router's admin interface, usually reachable at `192.168.0.1` or
`192.168.1.1` - printed on the back of the router or in its app).

### 3. Clone the Repo

Raspberry Pi OS Lite does not have `git` preinstalled - at this point
`scripts/00-bootstrap.sh` (which installs `git` among other things) has not
run yet, so install it manually first, briefly:

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/AlexanderHultsch/PiMultiServiceServer.git ~/pi-server
cd ~/pi-server
```

### 4. Generate `.env` Interactively

```bash
bash scripts/setup-env.sh
```

The script asks for each value individually, explains where it comes from,
suggests sensible defaults (including an automatically detected LAN),
generates a secure Pi-hole password if needed as well as the age key pair
for backups automatically, and finally writes `.env` (with `chmod 600`).

If the Cloudflare tunnel token (step 8) is not available yet: just press
Enter at that prompt and add it to `.env` manually later - the script points
this out again at the end.

### 5. System Bootstrap (Docker, Packages, Updates)

```bash
bash scripts/00-bootstrap.sh
```

Afterwards, log out and back in once (the new `docker` group membership only
becomes active after a fresh login):

```bash
exit
ssh <username>@pi-server.local
cd ~/pi-server
```

### 6. Reserve a Static IP for the Pi (Router, Manual)

**Important to understand:** this reservation links a **MAC address** to an
IP. WLAN and Ethernet (LAN cable) are **two different network interfaces on
the Pi, each with its own MAC address** (`wlan0` and `eth0` respectively).
The router needs to know **which of the two MAC addresses is actually
connected right now** - the IP is reserved for exactly that interface. If
you later switch interfaces (e.g. WLAN -> LAN cable), the reservation in the
router has to be switched over to the other MAC address once (see the box
below) - `PI_STATIC_IP` itself stays the same.

Second key point: **the IP entered in the router's reservation must exactly
match `PI_STATIC_IP` in `.env`** - that does not happen automatically just
because a toggle is enabled.

1. Find out which interface is currently actively connected, and note its
   MAC address:
   ```bash
   ip -4 addr show
   ```
   The interface with a line `inet 192.168.x.x/24 ...` is the active one.
   MAC address of that interface:
   ```bash
   ip link show wlan0 | awk '/ether/ {print $2}'   # for Ethernet: eth0 instead of wlan0
   ```
2. Look up the current `PI_STATIC_IP` value from `.env`, so you know which
   IP has to be entered in the router:
   ```bash
   grep -E 'PI_STATIC_IP|LAN_SUBNET' ~/pi-server/.env
   ```

#### FRITZ!Box (Very Common, e.g. AVM Routers)

1. Open <http://fritz.box> (or <http://192.168.178.1>) in a browser and log
   in with the FRITZ!Box password.
2. **Home Network -> Network -> Network Connections**.
3. Find the Pi in the device list (name `pi-server`, or the MAC address of
   the **active** interface from above) and click the pencil/edit icon.
4. There you will find the switch **"Always assign this device the same
   IPv4 address"**. Right next to/above it is an **IPv4 address field**:
   this exact **value** is the IP that gets reserved.
   - If it already shows the same address as `PI_STATIC_IP` from `.env` ->
     nothing else to do, confirm/save with **Apply**.
   - If it shows a **different** address (typical if the Pi previously got a
     different IP automatically via DHCP): either change the field to the
     value of `PI_STATIC_IP` (must be within the range managed by the
     FRITZ!Box, usually `192.168.178.x` by default), **or**, more simply:
     copy the value shown in the router 1:1 into `.env` as `PI_STATIC_IP`
     (`nano ~/pi-server/.env`).
5. **The FRITZ!Box default LAN is `192.168.178.0/24`**, not `192.168.1.0/24`.
   If `LAN_SUBNET` in `.env` is still `192.168.1.0/24` (e.g. because
   `setup-env.sh` did not detect it correctly), correct it now to
   `192.168.178.0/24` - otherwise the `ufw` rules from step 7 will not work
   for the actual LAN.
6. Click Save/**Apply**.

#### Other Router Brands

The menu item there is usually called **"DHCP reservation"** / **"static
lease"** / **"address reservation"** (the wording varies by manufacturer);
same principle: link the MAC address of the **active** interface to the
`PI_STATIC_IP` value from `.env` - when in doubt, it is easier to copy the
address shown/assigned by the router into `.env` than the other way around.

#### Switching From WLAN to a LAN Cable Later

If you set things up over WLAN and later switch to a LAN cable: this changes
**nothing** in `.env`, `docker-compose.yml`, or the `ufw` rules - the IP
stays identical, only the network hardware changes. All that is left to do
is:

1. Plug in the LAN cable.
2. In the router (FRITZ!Box: see above), switch the **same reservation**
   (same `PI_STATIC_IP`) to the MAC address of `eth0` (instead of `wlan0`):
   ```bash
   ip link show eth0 | awk '/ether/ {print $2}'
   ```
   Enter this value in the router in place of the previous `wlan0` MAC address.
3. `sudo reboot`, then check with the verification command below.

**Leave WLAN enabled while doing this, do not disable it.** When Ethernet
and WLAN are active at the same time, Linux automatically prefers the wired
connection (better routing metric) - no extra step is needed for that. An
enabled but unused WLAN serves as a fallback: if the cable is accidentally
unplugged or comes loose, the Pi stays reachable over WLAN instead of being
completely cut off from the network. **`sudo rfkill block wifi` is therefore
no longer recommended** - this state survives reboots (see the
troubleshooting entry "No connection after a reboot, WLAN dead") and can
cause exactly the situation it was meant to avoid: a complete loss of
connectivity after a reboot as soon as no Ethernet link is present for any
reason. If WLAN is currently blocked: `sudo rfkill unblock wifi`.

#### After Saving

```bash
sudo reboot
```

After the reboot, connect again and check that the Pi actually has the
reserved address (this works regardless of whether WLAN or Ethernet is
active):

```bash
ssh <username>@pi-server.local
ip -4 addr show | grep inet
```

The result must contain the `PI_STATIC_IP` entered in `.env` - if not,
adjust `.env` accordingly before continuing with step 7.

### 7. Hardening: SSH Key-Only + Firewall Default-Deny

```bash
bash scripts/01-harden.sh
```

The script **aborts with an error message** if there is no public key yet
under `~/.ssh/authorized_keys` - this protects you from accidentally locking
yourself out.

Verify:

```bash
sudo ufw status verbose
```

Expected: `Default: deny (incoming), allow (outgoing)` and rules only for
`${LAN_SUBNET}`.

### 8. Set Up the Cloudflare Tunnel (One-Time, in the Dashboard)

This is the only step that cannot be automated on the command line (an
OAuth-protected web interface).

1. Open <https://one.dash.cloudflare.com> (activate Zero Trust for free if needed).
2. In the left menu, **Networks -> Tunnels -> Create a tunnel**.
3. Choose the connector type **Cloudflared**, give it a name (e.g. `pi-server`).
4. Under "Choose your environment" click **Docker**. A command like this appears:
   ```
   docker run cloudflare/cloudflared:... tunnel --no-autoupdate run --token eyJhIjoi...
   ```
   Copy only the part after `--token` (the long string) - that is
   `CLOUDFLARE_TUNNEL_TOKEN`.
5. Enter it in `.env`:
   ```bash
   nano .env
   # CLOUDFLARE_TUNNEL_TOKEN=<pasted value>
   ```
6. In the same tunnel setup (or afterwards under the tunnel -> **Published
   Application routes** -> **Add published application**, current
   Cloudflare wording as of 2026):
   - **Subdomain**: leave empty, unless you want a subdomain like `www.`
   - **Domain**: the `DOMAIN` value from `.env`
   - **Path**: leave empty (matches everything)
   - **Service URL**: `http://caddy:80` - **not** `localhost`! `caddy` is
     the internal Docker service name of the reverse proxy from
     `docker-compose.yml`, reachable only for `cloudflared` on the `edge`
     network; port `80`, because that is where Caddy listens (no host port,
     see [M8]).
   - Click **Add route**.

   > **All** public hostnames (the main domain and, later, every subdomain)
   > point to the **same** service `http://caddy:80` - Caddy internally
   > routes to the right site based on the hostname. Every additional
   > subdomain gets its own additional public hostname created here later
   > (see "Hosting Additional Websites"). A wildcard (`*.deine-domain.de`) is
   > not available on the free Cloudflare plan, hence one entry per subdomain.

### 9. Start the Services

```bash
docker compose config   # syntax/value check
docker compose up -d     # builds the example app (app-example) the first time
docker compose ps
```

All services should be `running` (`pihole`, `caddy`, `app-example`,
`cloudflared`, `uptime-kuma`). On the first start, Docker builds the example
app's image - that takes one to two minutes, once.

### 10. Set Pi-hole as the Network DNS (Router, Manual)

- **Open the web UI:** `http://<PI_STATIC_IP>:<PORT_PIHOLE_UI>/admin/` -
  using the actual values from `.env`, e.g. `http://192.168.178.53:8080/admin/`.
  The **trailing `/admin/` is mandatory** (Pi-hole v6 does not automatically
  redirect there from the plain IP/port address). Log in with
  `PIHOLE_PASSWORD`. Reachable only from the LAN.
- **The "Consider upgrading to HTTPS" notice:** Pi-hole shows this message
  by default because the interface runs over HTTP. Not a problem for this
  setup, since the UI is reachable only from the LAN anyway (secured by a
  `ufw` rule, see step 7) - it can simply be ignored. If you want, you can
  enable HTTPS with a self-signed certificate in the Pi-hole UI under
  **Settings -> Web Interface / API**; the browser will then show a
  certificate warning, though, since the certificate was not issued by a
  public authority.
- **Set Pi-hole as the DNS server for the whole home network** - on a
  FRITZ!Box:
  1. **Home Network -> Network -> Network Settings**.
  2. If needed, click **"Show more settings"** so all fields are visible.
  3. In the **IPv4 configuration** section, find the field **"Local DNS
     server"** and enter `PI_STATIC_IP` there (e.g. `192.168.178.53`).
  4. Click **Apply**. From now on, every device that receives an address via
     DHCP from the FRITZ!Box is automatically assigned Pi-hole as its DNS
     server.

  **Do not confuse this with:** this is a different field than
  **"MyFRITZ!/DynDNS"** (used to make the FRITZ!Box itself reachable under a
  fixed name from the *internet* - the opposite of what is needed here) and
  also different from the DNS server under **Internet -> Access Type ->
  DNS Server** (that only affects which DNS server the FRITZ!Box itself
  queries externally, not what is handed to devices in the LAN via DHCP).
  On other routers, the field you want is usually just called **"DNS
  server"** in the general network/LAN settings.

#### Checking That It Works

Right after making the change, the Pi-hole dashboard usually shows
**`0 q/min`** - that is normal and not an error: devices only pick up the new
DNS server at their next DHCP renewal, not immediately.

**Quick test, independent of DHCP** (works immediately, from any device on
the LAN or on the Pi itself):

```bash
nslookup doubleclick.net 192.168.178.53   # substitute PI_STATIC_IP for the example IP
```

If you get a result back (even `0.0.0.0` counts - that is a block), Pi-hole
is working correctly. Right after that, check the Pi-hole dashboard /
**Query Log** - that one request should show up there.

**For real devices to actually use Pi-hole**, their DHCP lease has to be
renewed:
- Easiest: restart the FRITZ!Box once - this forces a new request from every
  device.
- Per device: toggle WLAN off/on briefly (phone), or run `ipconfig /release
  && ipconfig /renew` (Windows), or reconnect (Mac/Linux).

**Checking which DNS server a device is actually using right now:**
Windows `ipconfig /all` (the "DNS Servers" field), Mac System Settings ->
Network -> WLAN -> Details -> DNS, Linux `resolvectl status`, on a
smartphone under the WLAN network details.

### 11. Check the Public Website

```bash
curl -I https://deine-domain.de   # <- substitute your own domain from .env
```

Expected: `HTTP/2 200`. `caddy` itself has **no** host port - the only route
to it goes through `cloudflared`.

### 12. Set Up Uptime Kuma

- Web UI: `http://<PI_STATIC_IP>:3001` (LAN only), e.g.
  `http://192.168.178.53:3001`.
- On the first visit, Uptime Kuma asks **"Which database do you want to
  use?"** (embedded MariaDB / MariaDB-MySQL / SQLite) -> choose **SQLite**.
  Reasoning: embedded MariaDB starts a whole database server inside the
  container (permanently higher RAM usage on the already-shared Pi, and
  there are reports of restart loops); its performance advantage only
  matters once you have a lot of monitors. SQLite is a single file in
  `data/uptime-kuma/`, which the weekly backup covers cleanly. "external
  MariaDB/MySQL" is not an option - this setup has no separate database
  server.
- Then create the admin account.
- Create monitors for:
  - The public website: `https://deine-domain.de`
  - **Pi-hole: `http://pihole/admin/`** (not the LAN IP!) - Uptime Kuma and
    Pi-hole run on the same Docker network `lan_net` and reach each other
    directly via the service name `pihole` (port 80 internally). Over the
    LAN IP (`http://<PI_STATIC_IP>:8080/admin/`), the monitor can incorrectly
    run into a timeout - a container that addresses its own host-published
    port over the bridge can fall foul of Docker's NAT "hairpin" limitation,
    even though the site loads normally in a browser from any real LAN
    device.
  - An internet reference check, e.g. `1.1.1.1`.

### 13. Connect the Backup Target (rclone, Interactive)

The remote name must match the prefix of `BACKUP_REMOTE` in `.env` (default:
`onedrive`).

```bash
rclone config
```

In the interactive menu (example for OneDrive):

1. `n` (New remote) -> enter a name, e.g. `onedrive` (must match `BACKUP_REMOTE`)
2. Choose the storage type from the list: **Microsoft OneDrive**
3. `client_id` / `client_secret`: leave empty (Enter)
4. "Edit advanced config?" -> `n`
5. "Use web browser to automatically authenticate?" -> `y`, if the Pi allows
   a graphical interface/browser redirect. On a headless Pi (the standard
   case): choose `n` and instead run `rclone authorize "onedrive"` on a
   device with a browser, then paste the resulting code back into the
   terminal on the Pi (the setup will prompt for it).
6. Confirm the drive from the list (usually `0`), then `y`.
7. `q` to quit.

Test it (with the remote name you just set):

```bash
rclone lsd onedrive:
```

### 14. Run the Backup and Automate It

Test it manually - **an exception where `sudo` is used here**, because the
files under `data/` belong to the container users and only root can read all
of them (the upload via rclone still runs automatically as your normal user,
so that your rclone login is used):

```bash
sudo bash scripts/backup.sh
```

Set it up as a weekly cron job, Mondays at 03:30 (it lands in root's crontab
for the same reason; idempotent - running it multiple times does not create
duplicate entries). If the Pi still has an older, more frequent cron entry
from before this change, re-running this script replaces it with the new
weekly schedule rather than leaving both or silently keeping the old one:

```bash
bash scripts/install-backup-cron.sh
```

**Important, one time only:** the private age key
(`~/.config/age/pi-server.txt`) is **not** included in the backup itself -
without it, all backups are worthless. Copy it now to a safe place outside
the Pi (password manager, USB drive), if you have not done so already.

#### Optional: Backup Failure Notification (Uptime Kuma Push)

The backup works fine without this - it is purely a notification layer.

1. In Uptime Kuma (Quick Start step 12), create a monitor with **Monitor
   Type = Push** and set the **Heartbeat Interval** to about 8 days (a
   weekly backup plus some slack for a late run).
2. Uptime Kuma shows a **Push URL** for that monitor. Put it into `.env` as
   `BACKUP_HEARTBEAT_URL`.
3. From then on, three things can happen:
   - The backup runs and succeeds -> it pings the monitor with an up status.
   - The backup runs and fails (reachability check, tar, age, or upload) ->
     it pings the monitor with a down status naming the failing stage.
   - The backup does not run at all (broken cron, Pi switched off) -> no
     ping arrives, and the monitor's own 8-day heartbeat interval expires,
     which is what raises the alarm in this case.

Leaving `BACKUP_HEARTBEAT_URL` empty simply disables the notification; the
backup itself is unaffected.

### 15. Verify Everything at Once

```bash
bash scripts/verify.sh
```

Checks: `docker compose config`, all services running, no secrets in git,
`ufw` default-deny active, public domain reachable, `PI_STATIC_IP` actually
bound to an active interface, WLAN not blocked while no Ethernet is active -
with PASS/FAIL output per check.

### 16. Do a Real Restore Test Once (Mandatory, [M7])

Before considering the setup complete, **do one real restore on an empty/
fresh system**: flash a new boot medium, clone the repo, run
`00-bootstrap.sh` + `01-harden.sh`, set up the private age key and the
`rclone` connection on the new system, fetch the latest backup from
`BACKUP_REMOTE` and decrypt it with `age -d`, restore `data/` and `.env`,
then run `docker compose up -d` and `scripts/verify.sh`. The exact procedure
is documented in the comments of `scripts/backup.sh`.

---

## Troubleshooting

| Symptom | Likely cause | Check / fix |
|---|---|---|
| `docker compose ps` shows `cloudflared` as not `running` | Token wrong/empty | `docker compose logs cloudflared`; copy the token fresh from the dashboard into `.env` |
| `curl -I https://${DOMAIN}` returns an error/timeout | Published-application routing missing, or DNS not propagated yet | Check the route in the Zero Trust dashboard; wait a few minutes |
| Pi-hole UI not reachable at `PI_STATIC_IP` | `PI_STATIC_IP` does not match the Pi's actual IP, or a `ufw` rule is missing | Compare `ip -4 addr show` on the Pi against `.env`; `sudo ufw status verbose` |
| Devices on the LAN are not using Pi-hole as DNS | Router DNS setting not set yet, or device cache | Check the router DNS setting (Quick Start step 10); reconnect the affected device |
| `scripts/01-harden.sh` aborts with an error | No public key in `~/.ssh/authorized_keys` | Add the key as in Quick Start step 1, then run it again |
| `scripts/backup.sh` fails at `rclone` | Remote not configured, or its name does not match `BACKUP_REMOTE`. Important: run `rclone config` as a normal user (not with sudo) - the backup automatically uses that user's configuration | `rclone listremotes` (without sudo); repeat Quick Start step 13 |
| `scripts/backup.sh` aborts immediately with "remote not reachable" (before any tar/age output) | The upfront reachability check failed - usually an expired OneDrive OAuth token | `rclone config reconnect <remote>:` (as the normal user, not with sudo), then run the backup again |
| `-bash: git: command not found` while cloning | Raspberry Pi OS Lite does not have `git` preinstalled, and `00-bootstrap.sh` (which installs it) only runs after cloning | `sudo apt update && sudo apt install -y git`, then clone again (Quick Start step 3) |
| `git pull` in `sites/<name>` reports `Already up to date`, but the site still shows old content | `sites/<name>` is not its own Git repo but still lives inside the main repo (common with `sites/main` when the bundled example site was replaced directly with the real homepage) - `git pull` then resolves against the main repo, not the actual website | Check `git remote -v` in `sites/<name>`: does it show the main repo instead of the website? -> `bash scripts/adopt-site-repo.sh sites/<name> <real-repo-url>` (see "Each Site as Its Own Git Repo") |
| No longer reachable at the reserved IP after a reboot | The router reservation is tied to the MAC address of the **wrong** interface (e.g. `eth0` reserved, but the Pi is connected via `wlan0`, or vice versa) | `ip -4 addr show` on the Pi, determine the active interface, match its MAC in the router (Quick Start step 6) |
| `ufw` rules do not match the actual LAN | `LAN_SUBNET` in `.env` contains a host address instead of the network address (e.g. `192.168.178.53/24` instead of `192.168.178.0/24`) | Check `grep LAN_SUBNET .env`, correct if needed, run `scripts/01-harden.sh` again |
| The Cloudflare dashboard shows no "Public Hostname" menu item | Cloudflare renamed it to "Published Application routes" / "Add published application" (as of 2026) | Look for **Published Application routes** in the tunnel detail view, fill in the fields as in Quick Start step 8 |
| The Pi-hole dashboard permanently shows `0 q/min` after changing the router DNS | Devices have not renewed their DHCP lease yet, so they are still using the old DNS server | Quick test via `nslookup <domain> ${PI_STATIC_IP}`; for real devices, restart the router or renew the lease individually (Quick Start step 10) |
| No connection after a reboot, WLAN dead (also shows as "not connected" via the local console) | Most common cause: WLAN was disabled via `rfkill block wifi` (e.g. when switching to a LAN cable) - this state survives reboots. If an active Ethernet link is also missing, the Pi has no network connection at all | Log in locally via keyboard/monitor, check `rfkill list`; if it shows "Soft blocked: yes" for WLAN -> `sudo rfkill unblock wifi`. Do not block WLAN again afterwards (see the note in Quick Start step 6) |
| Pi completely unreachable at `PI_STATIC_IP`, DNS fails for the whole LAN | The physical Ethernet connection is disconnected (cable unplugged/loose) - `eth0` then has no IP at all, and the Pi can fall back to DHCP on `wlan0` in parallel, ending up on a completely different address | `ip link` on the Pi: does `eth0` show "NO-CARRIER"/"state DOWN"? -> check the cable/port. Before suspecting DNS/software: always check the physical connection first (`ip link`, `dmesg`), otherwise this looks exactly like a pure DNS problem |
| Pi-hole is running (`healthy`), port 53 is reachable, but real devices on the LAN still get no answer | Pi-hole v6 defaults to `dns.listeningMode=LOCAL`. In a Docker bridge network, FTL then only considers queries from its own bridge subnet "local" and silently drops real LAN clients | Check the Pi-hole log for "ignoring query from non-local network ..."; `FTLCONF_dns_listeningMode: "ALL"` is already set in `docker-compose.yml` (see the comment there) - on older checkouts of this repo, add it if missing and run `docker compose up -d` again |
| `docker compose ps` showed "running" a while ago, but the problem persists | The status can be stale - containers may have crashed/restarted in the meantime | **Re-run `docker compose ps` live**, do not rely on an older glance, before continuing to look for the cause |
| A DNS test from a test container on the same Docker bridge network fails, even though everything works fine from real LAN devices | Docker NAT "hairpin" limitation: a container that addresses its own host-published port over the bridge can fail here - looks like a bug but is a known Docker quirk | Always test from a real LAN client or directly from the host (`nslookup <domain> ${PI_STATIC_IP}`), not from another container on the same bridge |
| The Uptime Kuma monitor for Pi-hole shows "timeout of Nms exceeded", even though `http://<PI_STATIC_IP>:8080/admin/` loads fine in a browser | Same Docker NAT hairpin limitation: Uptime Kuma is itself a container and fails to reach Pi-hole's own host-published port over the LAN IP | Change the monitor URL to `http://pihole/admin/` (internal service name instead of LAN IP, see Quick Start step 12) |
| Logging into an app seems to succeed, but the user immediately lands back on `/login` | `cloudflared` speaks plain HTTP to `caddy:80`, so Caddy sets `X-Forwarded-Proto: http`. Frameworks with secure cookies (e.g. `express-session` with `cookie.secure=true` behind `trust proxy`) then **silently** drop the session cookie - no error in the log, just a `debug()` call | Add `header_up X-Forwarded-Proto https` to the app's `reverse_proxy` block (template in the comment above the `@app` block in `config/caddy/Caddyfile`), then `docker compose restart caddy` |
| Only the **first** `admin: yes` site from `sites.conf` gets seeded, all others are missing | Known, fixed bug in older versions of `scripts/deploy.sh`: `docker compose exec` always attaches stdin to the container (`-T` only disables the TTY), and inside the loop body it read the still-open `sites.conf` down to EOF, leaving it empty | `git pull` - the fix (`< /dev/null` on the exec, plus reading the manifest via FD 3) is included. Seed missing admins once manually: `docker compose exec -T <service> npm run seed:admin < /dev/null` |

**Caution when live-debugging DNS issues:** do not start a second,
unconfigured Pi-hole test container via `docker run --network host
pihole/...` while the real service already holds port 53 - that needlessly
competes for the same port. Instead, test directly from the host with
`nslookup`/`dig` against `${PI_STATIC_IP}`.

---

## What Can I Actually Do With Pi-hole?

A quick overview of the most common tasks in the Pi-hole web interface
(`http://${PI_STATIC_IP}:${PORT_PIHOLE_UI}/admin/`):

- **Query Log** (left menu): shows every DNS request from the network in
  real time and whether it was blocked or let through - the fastest way to
  find out which domain is currently blocking something.
- **Blocking ads/trackers:** mostly runs automatically via the bundled
  blocklists (adlists). Add more lists under **Settings -> Adlists**, then
  run **Tools -> Update Gravity** to make them active.
- **Blocking a specific domain deliberately:** enter the domain under
  **Domains** in the **Blacklist (Exact/Wildcard)** tab - or directly from
  the Query Log by clicking the domain and "Blacklist".
- **Unblocking a site broken by Pi-hole:** happens occasionally when a
  website loads content/scripts from the same domain as a tracking/ad
  domain. Enter the affected domain under **Domains -> Whitelist** (the
  Query Log usually reveals which domain is currently being blocked) - the
  site then loads normally again.
- **Disabling Pi-hole briefly, completely** (to test whether Pi-hole is the
  cause of a problem): use the "Disable" switch at the top of the dashboard,
  with a time limit (e.g. 5 minutes) or permanently, then "Enable" again.
  Handy for quickly ruling out Pi-hole as the culprit for a problem.
- **Treating groups/devices differently:** under **Group Management** you
  can, for example, set up stricter rules for children's devices or looser
  ones for guest WLAN, and assign them to individual clients.
- **Statistics:** the dashboard shows, among other things, the
  most-frequently-blocked domains and the share of blocked requests in total
  traffic.

---

## Hosting Additional Websites

The reverse proxy **Caddy** serves all websites. `cloudflared` sends every
hostname to `caddy:80`, and Caddy decides based on the (sub)domain what gets
served - routing lives in `config/caddy/Caddyfile`.

There are two kinds of sites:

| | **Static site** | **Dynamic app** |
|---|---|---|
| What | HTML/CSS/JS, finished files | A running program (Node, Python, ...) |
| Where | Folder under `sites/<name>/` | Folder under `apps/<name>/` (with a `Dockerfile`) |
| How it is served | Caddy serves the files directly | Its own container, Caddy forwards via `reverse_proxy` |
| Resources | Very light (no own container) | One container per app |
| Bundled example | `sites/main/`, `sites/beispiel/` | `apps/app-example/` |

### Adding a Static Site (e.g. `blog.deine-domain.de`)

1. Create a folder with content:
   ```bash
   mkdir -p ~/pi-server/sites/blog
   echo '<h1>Mein Blog</h1>' > ~/pi-server/sites/blog/index.html
   ```
2. Add a block in `config/caddy/Caddyfile` (following the pattern of
   `beispiel`):
   ```
   @blog host blog.{$DOMAIN}
   handle @blog {
       root * /srv/blog
       file_server
   }
   ```
3. Reload Caddy: `docker compose restart caddy`
4. In the Cloudflare dashboard, create a public hostname
   `blog.deine-domain.de` -> `http://caddy:80` (as in Quick Start step 8,
   just with a subdomain).
5. Optional: a monitor on `https://blog.deine-domain.de` in Uptime Kuma.

> Pure content changes to existing sites (editing files in `sites/<name>/`)
> need **no** restart - Caddy serves them immediately. Only changes to the
> `Caddyfile` itself need `docker compose restart caddy`.

### Adding a Dynamic App (e.g. `shop.deine-domain.de`)

1. Create the app under `apps/shop/` (its own `Dockerfile`, must listen on a
   port). `apps/app-example/` serves as a template.
2. Add a service in `docker-compose.yml` (following the pattern of
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
       reverse_proxy shop:3000    # adjust the port to match the app
   }
   ```
4. Build/start it and reload Caddy:
   ```bash
   docker compose up -d --build shop
   docker compose restart caddy
   ```
5. Public hostname in the Cloudflare dashboard + Uptime Kuma monitor as above.

### Each Site as Its Own Git Repo (Recommended for Independent Versioning)

By default, the example sites live **inside** the main repo. For a real site
with its own Git history, clone a separate repo into the folder instead, and
add that path to the main repo's `.gitignore`, so the two do not interfere
with each other:

```bash
# Example: your own blog site from a separate repo
git clone https://github.com/<you>/my-blog.git ~/pi-server/sites/blog
echo '/sites/blog/' >> ~/pi-server/.gitignore
```

Updating is then conveniently done via a helper script (runs `git pull`, and
for dynamic apps also the rebuild):

```bash
bash scripts/deploy-site.sh blog     # static site
bash scripts/deploy-site.sh shop     # dynamic app (rebuilds the container)
```

#### Converting a Bundled Example Site Later (e.g. `sites/main`)

`sites/main` and `sites/beispiel` live **inside the main repo** from the
start (see the table above). If you simply replace their content with your
own, real homepage without also doing the two steps above (detaching the
folder from the main repo + the `.gitignore` entry), the folder remains part
of the main repo. The tricky part: `git pull` in this state appears to work
completely normally - it just reports `Already up to date`, because it is
actually resolving against the **main repo**, not the repo of the real
website. The site then never updates, without any error pointing to why.

Quick check for whether a site folder is affected:

```bash
cd ~/pi-server/sites/main
git remote -v   # shows the MAIN repo's remote instead of the actual website? -> affected
```

A bundled script automates the conversion (detaching from the main repo +
`.gitignore` entry + fresh clone from the real repo; the old content is not
deleted, just to be safe, but moved aside as `sites/main.bak-<timestamp>`):

```bash
bash scripts/adopt-site-repo.sh sites/main https://github.com/<you>/my-homepage.git
git push   # do not forget the commit that now makes sites/main ignored
```

### Managing Multiple Sites Centrally (`sites.conf` + `deploy.sh`)

`deploy-site.sh` updates **one** already-existing site. Once several of your
own websites are running under the "one repo = one container" pattern (see
above), `scripts/deploy.sh` is worth using instead: a manifest-driven script
that clones/pulls, builds, and starts **all** the sites listed in
`sites.conf` in one go.

`sites.conf` at the repo root (one line per site):

```
# name    repo_url                                  host    admin
shop      https://github.com/<you>/my-shop-app.git shop    yes
blog      https://github.com/<you>/my-blog.git      blog    no
```

- `name` = the folder name under `apps/` **and** the service name in
  `docker-compose.yml` (it must also be entered there as a service, see
  "Adding a Dynamic App" above - `sites.conf` alone is not enough).
- `host` = the subdomain label, or `apex` for the main domain itself.
- `admin` = `yes` if the app needs a login. `deploy.sh` then asks once for a
  **shared** admin username/password (stored in `admin.env`, gitignored,
  reused for all `admin: yes` sites), writes it together with a random
  `SESSION_SECRET` into `apps/<name>/.env`, and then runs `npm run
  seed:admin` inside the container. The app itself has to consume these
  three variables (`ADMIN_USER`, `ADMIN_PASSWORD`, `SESSION_SECRET`) (e.g.
  via `express-session` plus its own `seed:admin` script).

Usage on the Pi:

```bash
bash scripts/deploy.sh                # normal update of all sites
bash scripts/deploy.sh --fresh        # also resets all app databases
bash scripts/deploy.sh --set-password # sets a new shared admin password
```

**Which script, when?**

| Situation | Script |
|---|---|
| Quickly update a single site (no admin handling, no Caddy restart) | `deploy-site.sh <name>` |
| Update all sites from `sites.conf` at once, including the shared admin account and a Caddy restart | `deploy.sh` |
| A site has not been cloned yet at all | `deploy.sh` (clones it automatically from `sites.conf`) - or clone it manually, then `deploy-site.sh` |

### Setting Up Email: `support@deine-domain.de` (Cloudflare Email Routing)

Email is **not** hosted on the Pi (a mail server on a residential connection
behind the tunnel practically does not work: port 25 is usually blocked, it
would need inbound ports contrary to [N1], and without a static IP and
reputation, mail ends up in spam). Instead, **Cloudflare Email Routing**
forwards it for free to your existing mailbox - purely a dashboard matter,
nothing on the Pi:

1. <https://dash.cloudflare.com> -> your domain -> **Email -> Email Routing**.
2. The first time, Cloudflare automatically adds the required MX/TXT records
   (confirm this).
3. Under **Routing rules**, create an address: `support@deine-domain.de` ->
   destination = your real address (e.g. Gmail). Cloudflare sends a
   confirmation email there, confirm it once.
4. Done - mail to `support@deine-domain.de` now lands in your mailbox.

> Only **receiving** (forwarding). To also **send as** `support@...`, you
> additionally need an SMTP relay service - not part of this setup.

---

## Claude Code Directly on the Pi (On-Demand Debugging)

For debugging and maintenance, the Claude Code CLI can be installed directly
on the Pi and invoked in the project folder as needed - without any service
running permanently in the background consuming resources.

### Installation

```bash
bash scripts/install-claude-code.sh
```

Installs Node.js (LTS) if needed, and then the Claude Code CLI via `npm`.
Deliberately **not** the native installer (`curl -fsSL
https://claude.ai/install.sh | bash`): it has known issues on ARM64/
Raspberry Pi (reports success but does not reliably install the binary).

During installation, a warning like `npm warn allow-scripts ... not yet
covered by allowScripts` may appear (newer npm versions ask before running
packages' install scripts). In practice, the CLI has still worked afterward
- check with `claude --version` (should show a version number like
`2.1.210 (Claude Code)`). If not: run `npm approve-scripts
--allow-scripts-pending` and check again.

### Logging In (One-Time, Headless-Friendly)

A Raspberry Pi in Lite mode has no browser. **Important:** if
`ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` is already set as an
environment variable **before** `claude` is started for the first time, the
CLI automatically skips the interactive login menu. On a headless device
this is the simplest approach - so set it permanently first, then start
`claude`.

**Option A - API key (Anthropic Console):**

```bash
echo 'export ANTHROPIC_API_KEY=<your-api-key>' >> ~/.bashrc
source ~/.bashrc
```

The `echo ... >> ~/.bashrc` command appends the line to the shell
configuration permanently, so the variable is set automatically on every new
login - not just for the current session. `source ~/.bashrc` applies the
change to the already-open session immediately, without having to log in
again.

**Option B - Claude Pro/Max subscription:**

On a device **with** a browser (your own computer, not the Pi), once:

```bash
claude setup-token
```

Walks you through a browser login and prints a token at the end. Then store
this token on the Pi permanently, the same way:

```bash
echo 'export CLAUDE_CODE_OAUTH_TOKEN=<the-printed-token>' >> ~/.bashrc
source ~/.bashrc
```

**If the "Select login method" menu appears anyway** (happens when `claude`
is started before either variable is set) - the three options mean:

| Menu item | Meaning | For the headless Pi |
|---|---|---|
| "Account with subscription" | Claude.ai Pro/Max login via browser OAuth | **Cancel** on the Pi (no browser available) - prepare option B instead, from a device with a browser |
| "Anthropic Console account" | API-key-based login | Corresponds to option A - simpler to set `ANTHROPIC_API_KEY` beforehand directly, then the menu never appears in the first place |
| "3rd party platform" | Access via AWS Bedrock / Google Vertex AI etc. | Only relevant if Claude is already being obtained through one of these platforms - not needed for this project |

The simplest approach remains: set up option A or B **beforehand**, then the
menu never comes up at all.

### Usage

```bash
cd ~/pi-server
claude
```

Starts an interactive session that automatically reads `CLAUDE.md` and
`raspberry-pi-4-spezifikation.md` from this repo as context - the same rules
this project was built with then also apply to the debugging session. After
the session ends, nothing keeps running in the background; there is
deliberately no systemd service and no autostart for it.

### Resuming After an Interrupted SSH Connection

If the SSH connection drops during an active `claude` session (WLAN gone,
laptop closed, ...): **nothing is lost.** Claude Code continuously writes
the session history to disk, independent of the SSH connection. After
logging back in, in the same folder:

```bash
cd ~/pi-server
claude --continue   # automatically loads the most recently active session for this folder
```

If there are several interrupted/parallel sessions and the most recent one
is not the right one:

```bash
claude --resume   # shows a selection list of all saved sessions for this folder
```

Both only work if you are **in the same directory** where the session was
originally started (`~/pi-server`) - sessions are stored per working
directory.

### Hardware Note

Anthropic's official minimum for the CLI is 4 GB RAM. On a Pi 4 with 1-2 GB
RAM, an active session competes with the running containers for memory - for
this optional feature, a Pi 4 with at least 4 GB RAM is recommended.

---

## Reference: Image Versions Used

Verified against the current stable version of each and verified on real
Raspberry Pi 4 hardware; the public site is reachable via the Cloudflare
tunnel with `HTTP/2 200`. Per the specification, `:latest` is not used
anywhere.

| Service | Image | Tag |
|---|---|---|
| Pi-hole | `pihole/pihole` | `2026.07.2` |
| Reverse proxy / web | `caddy` | `2.11.4-alpine` |
| Cloudflare Tunnel | `cloudflare/cloudflared` | `2026.7.0` |
| Uptime Kuma | `louislam/uptime-kuma` | `2.4.0` |
| Dynamic example app | `node` (build) | `24-alpine` |

To use a new version: change the tag in `docker-compose.yml`,
`docker compose pull && docker compose up -d`, update this table.

---

## Reference: Where Each `.env` Value Comes From

All values are asked for interactively by `scripts/setup-env.sh`, or (in the
case of `AGE_RECIPIENT`) generated automatically - this table is the quick
reference in case you want to edit `.env` by hand.

| Variable | Meaning | Where do you get the value? |
|---|---|---|
| `TZ` | Time zone for all containers | E.g. `Europe/Berlin`. List: [Wikipedia tz database](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones) |
| `LAN_SUBNET` | Home network CIDR for firewall rules | Detected automatically; check manually with `ip -4 addr show` on the Pi |
| `PI_STATIC_IP` | Fixed IP of the Pi on the LAN | Freely chosen, must be entered as a DHCP reservation in the router (instructions in Quick Start step 6) |
| `PORT_PIHOLE_UI` / `PORT_DNS` / `PORT_UPTIME` | Fixed ports for the Pi-hole UI/DNS/Uptime Kuma | Preset defaults, usually leave unchanged |
| `DOMAIN` | Public domain of the website | Your own domain, managed as a "zone" in your Cloudflare account (see Prerequisites) |
| `PIHOLE_PASSWORD` | Pi-hole admin password | Freely chosen - `setup-env.sh` can also generate a secure password automatically |
| `CLOUDFLARE_TUNNEL_TOKEN` | Tunnel token (secret) | From the Cloudflare Zero Trust dashboard when creating the tunnel (Quick Start step 8) |
| `BACKUP_REMOTE` | rclone remote target for backups | Name of the rclone remote you set up with `rclone config` (Quick Start step 13) |
| `BACKUP_RETENTION_COUNT` | Number of retained weekly backup archives | Freely chosen, default `12` (about three months) |
| `BACKUP_HEARTBEAT_URL` | Push URL of an Uptime Kuma monitor for backup failure notification | Optional; from the Push monitor in Uptime Kuma (see "Optional: Backup Failure Notification" in Quick Start step 14) |
| `AGE_RECIPIENT` | age public key for backup encryption | Generated automatically by `setup-env.sh` (age key pair); technically required, added in the SPEC |

---

## Repository Structure

```
pi-server/
 |-- docker-compose.yml
 |-- .env                        # DO NOT commit (gitignored)
 |-- .env.example
 |-- .gitignore
 |-- README.md
 |-- CLAUDE.md                    # Work instructions for Claude Code (build + live debugging)
 |-- raspberry-pi-4-spezifikation.md
 |-- sites/                       # STATIC sites (one folder = one site)
 |    |-- main/                    #   Main domain
 |    |    `-- index.html
 |    `-- beispiel/                #   Example subpage (template)
 |         `-- index.html
 |-- apps/                        # DYNAMIC apps (one folder = one container)
 |    `-- app-example/             #   Example app (Node)
 |         |-- Dockerfile
 |         |-- server.js
 |         `-- package.json
 |-- config/
 |    `-- caddy/
 |         `-- Caddyfile            # Reverse proxy routing for all sites
 |-- sites.conf                    # Manifest of all sites for scripts/deploy.sh
 |-- scripts/
 |    |-- setup-env.sh             # interactive .env assistant
 |    |-- 00-bootstrap.sh
 |    |-- 01-harden.sh
 |    |-- deploy-site.sh           # update one site from its Git repo
 |    |-- deploy.sh                # clone/build/start all sites from sites.conf + seed admin accounts
 |    |-- adopt-site-repo.sh       # convert a bundled site folder into its own Git repo
 |    |-- install-backup-cron.sh   # idempotent cron installation
 |    |-- backup.sh
 |    |-- verify.sh                # bundles all verification checks
 |    `-- install-claude-code.sh   # optional: Claude Code CLI for live debugging
 `-- data/                        # runtime volumes (gitignored)
      |-- pihole/
      |-- caddy/
      `-- uptime-kuma/
```

---

## Upgrading From an Older Version (nginx `web` -> Caddy)

Earlier versions of this repo had a single nginx service `web` for a single
site. Anyone upgrading from there (`git pull`) with services already running
should do the following once, afterward:

1. Carry over any custom content of the old `website/` site (if modified) to
   `sites/main/` - the `website/` folder and the nginx configuration are
   removed.
2. In the Cloudflare dashboard, change the existing public hostname's
   **service URL from `http://web:80` to `http://caddy:80`**.
3. Restart (builds the example app, replaces `web` with `caddy`):
   ```bash
   docker compose up -d --build --remove-orphans
   docker compose ps
   ```
   `--remove-orphans` removes the old `web` container.
4. Check: `curl -I https://deine-domain.de` -> `HTTP/2 200`.
