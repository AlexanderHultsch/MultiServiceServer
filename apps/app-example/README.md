# app-example - dynamic example app

Tiny Node app (standard library only) that shows how a **dynamic**
website runs in this setup: its own container, its own directory, reachable
from Caddy via `reverse_proxy` at `app.<DOMAIN>`.

## Files
- `server.js` - the HTTP server (placeholder, prints the server time).
- `package.json` - metadata; add real dependencies here later.
- `Dockerfile` - builds the container image (Node 24 Alpine).

## Replace with your real app
1. Replace the contents of this folder with your app (must listen on port
   `3000`, or adjust `PORT` in the container and match the
   `reverse_proxy` port in the Caddyfile).
2. If you have dependencies: uncomment the line `RUN npm install --omit=dev`
   in the `Dockerfile`.
3. Rebuild and start: `docker compose up -d --build app-example`.

## Running it as its own git repo
This folder is an example in the main repo. For a real app with its own
versioning: clone your own git repo here and add the path to the main
repo's `.gitignore` (see README, "Hosting more websites" section). Then
deploy via `git pull` + `docker compose up -d --build`.
