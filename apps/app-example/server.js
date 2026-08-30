// Tiny dynamic example app - Node standard library only, no dependencies.
// Purpose: shows that a dynamic app (own container, behind Caddy) works.
// Replace the content with your real app (Express, Fastify, etc.).
const http = require("http");

const PORT = process.env.PORT || 3000;

const server = http.createServer((req, res) => {
  res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
  res.end(`<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Dynamic Example App</title>
<style>
  :root { color-scheme: light dark; }
  body { margin:0; min-height:100vh; display:flex; align-items:center; justify-content:center;
         font-family:system-ui,-apple-system,"Segoe UI",sans-serif; background:#0b1020; color:#e8ecf7; text-align:center; }
  main { padding:2rem; max-width:40rem; }
  h1 { font-size:1.75rem; margin-bottom:0.5rem; }
  p { color:#9aa4c0; line-height:1.5; }
  code { background:#1a2138; padding:0.1rem 0.3rem; border-radius:4px; }
</style></head>
<body><main>
  <h1>Dynamic app is running</h1>
  <p>Server time at this request: <code>${new Date().toISOString()}</code></p>
  <p>This page is regenerated on <em>every</em> request - unlike the
     static pages. Code lives in <code>apps/app-example/</code>.</p>
</main></body></html>`);
});

server.listen(PORT, () => console.log(`app-example running on port ${PORT}`));
