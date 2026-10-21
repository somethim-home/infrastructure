# The edge: Cloudflare Tunnel and Traefik

The server publishes no port to the internet or the LAN. The public reaches the sites through
a **Cloudflare Tunnel**: a `cloudflared` container on the host dials out to Cloudflare's edge
and keeps those connections open, Cloudflare sends each request for a public hostname down
one of them, and `cloudflared` hands it to Traefik on the Docker network. Traefik routes it
by `Host` header to whichever stack claims that domain.

```
visitor ──HTTPS──▶ Cloudflare edge ◀══ outbound tunnel ══ cloudflared ──HTTP──▶ edge-traefik:80 ──▶ portfolio / prizm-web / prizm-provider
                   (TLS, HTTP→HTTPS,                       (stack/tunnel,       (roles/edge,
                    CF-Connecting-IP)                       edge network)        edge network)
```

Two pieces, owned by different paths:

| Piece | What | Owned by | Changes with |
| --- | --- | --- | --- |
| `cloudflared` | `cloudflare/cloudflared` (pinned by digest), `tunnel --no-autoupdate --metrics 0.0.0.0:2000 run`, token from `TUNNEL_TOKEN` | the release bundle (`stack/tunnel`, project `tunnel`) | a `release` |
| `edge-traefik` | `traefik:v3.7.13` (pinned by digest) and its socket proxy | provisioning (`roles/edge`, project `edge` in `/opt/edge`) | `provision.yml --tags edge` |

## Why the tunnel is a release stack

`cloudflared` needs one secret, the tunnel token, and nothing else from the host: no port, no
mount, no socket, no privilege. That fits the release model exactly, so it lives in the bundle
like an app: the token is the `CF_TUNNEL_TOKEN` secret of the `production` Environment,
`release.yml` renders it into `tunnel/tunnel.env`, the only file `cloudflared` reads and that
no other container reads, and **rotating the token is a normal release**
([RUNBOOK.md](../RUNBOOK.md#rotating-a-secret)). Provisioning never sees it (provisioning
holds no secrets; `ci/check_access.py` rule 6). The compose guard holds the `tunnel` stack to
the edge network, the `cloudflared` container name, `tunnel.env`, a digest-pinned image, no
volume and only the `autoheal` label; `infra-apply` refuses a `tunnel.env` that sets anything
but `TUNNEL_TOKEN`.

Traefik stays in provisioning: it needs the Docker API (through its socket proxy), which a
release may never mount.

The tunnel is **remotely managed**: its routes, the Public Hostnames, are stored in
Cloudflare, not in a file on the host. They must be exactly:

| Public hostname | Service |
| --- | --- |
| `arbikullakshi.com` | `http://edge-traefik:80` |
| `www.arbikullakshi.com` | `http://edge-traefik:80` |
| `hypernova.arbikullakshi.com` | `http://edge-traefik:80` |

with the default `http_status:404` for anything else, and no origin option changed:
cloudflared keeps the request's own `Host`, which is what Traefik routes on. Each hostname's
DNS record is a proxied `CNAME` to `<tunnel id>.cfargotunnel.com`. A new public domain is a
new Public Hostname and a new router label; nothing on the host changes
([RUNBOOK.md](../RUNBOOK.md#6-cloudflare-tunnel)).

The server's own public IP is irrelevant: it can change at any time, and nothing points at
it.

## Only the tunnel reaches Traefik

Traefik has **one entrypoint, `web`, on :80 inside the container, and publishes no host
port.** It is reachable only at its address on the `edge` network, from containers on that
network and from the host itself. That is the whole lock, and it holds in layers:

- No compose file publishes a port (`ci/check_templates.py` rule 9; the compose guard refuses
  `ports:` in every release stack), and provisioning reads back that `edge-traefik` has no
  port bindings (`roles/edge/tasks/verify.yml`).
- ufw admits nothing inbound but 22 on `tailscale0`, and `INFRA-PUBLIC` drops every new
  connection forwarded from the LAN-facing interface to any container
  ([host.md](host.md#firewall)), so even a mistakenly published port would be unreachable.
- The router forwards no port to the server.

The only thing on the `edge` network that carries outside requests is `cloudflared`, and it
only accepts them from Cloudflare's edge, authenticated by the tunnel token. That replaces
the old Cloudflare-IP allowlist: there is no origin address left to bypass Cloudflare with.

### Client addresses and forwarded headers

Cloudflare sets `CF-Connecting-IP` to the visitor's address and overwrites any value a client
sent; `cloudflared` passes it, `X-Forwarded-For` and `X-Forwarded-Proto: https` through to
Traefik. Traefik leaves `CF-Connecting-IP` alone, and keeps the `X-Forwarded-*` headers
because `--entrypoints.web.forwardedHeaders.trustedIPs` lists the private ranges Docker draws
its bridge networks from (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`): only containers on
this host can reach the entrypoint at all. So the apps see the real visitor
(`CLIENT_IP_SOURCE=Cloudflare` in the portfolio, [stacks.md](stacks.md#portfolio)) and know the
request was HTTPS.

That trust is what the no-published-port rule protects: publish :80 on the host and anyone
on the LAN could send a forged `CF-Connecting-IP` and defeat the portfolio's rate limiter.

## TLS and redirects

Cloudflare terminates TLS with its own edge certificates; Traefik serves plain HTTP inside the
host and holds no certificate, no ACME account and no volume. The HTTP → HTTPS redirect is
Cloudflare's **Always Use HTTPS** zone setting (the release's public check asks for it);
Traefik has no redirecting entrypoint. The `www.` → apex redirect stays in Traefik (below),
because it is part of the portfolio's routing.

## Verifying it

Every release ends with checks run on the host itself, after every container is healthy
([deploying.md](deploying.md#what-infra-apply-checks-in-order)):

- **Routes**: `curl -H 'Host: <domain>' -H 'X-Forwarded-Proto: https' http://<edge-traefik's
  edge address>:80<path>`, the request the tunnel makes, must answer `2xx` for
  `arbikullakshi.com/api/health`, `hypernova.arbikullakshi.com/` and `/api/health`, and
  `301`/`308` for `www.arbikullakshi.com/`. A `404` means no router serves that host; `502`,
  `503` or `504` that the app behind it is unreachable.
- **Tunnel**: `cloudflared`'s `/ready` on its metrics port (`:2000`, on the edge network,
  never published) must answer `200`, which it does only while it holds at least one
  connection to Cloudflare. A wrong or revoked token, or no outbound internet, fails here.
  The container's healthcheck (`cloudflared tunnel ready`) asks the same question, so autoheal
  restarts a tunnel that loses its connections for good.

Every release then asks the public hostnames through Cloudflare, from the host (`infra-apply`'s
public check).

## The socket proxy

Traefik never sees the Docker socket. It reads container labels through `edge-socket-proxy`
(`wollomatic/socket-proxy`, pinned), on an internal network of their own (`edge-socket`).
The proxy mounts the socket read-only, accepts connections only from `traefik`, and allows
only `GET` of `_ping`, `version`, the container list, a container's JSON and `events` (plus
`HEAD _ping`). Everything else is refused and logged as `blocked request`.

Provisioning and every release check that the proxy is running and has refused none of
Traefik's calls since it started. A Traefik upgrade that needs another endpoint shows up
there first; widen the `-allowGET` rule in `roles/edge/files/docker-compose.yml` to exactly
what the log names.

## Routing by label

Traefik reads its configuration from Docker labels on the containers themselves
(`--providers.docker`, through the socket proxy), scoped to the `edge` network. An application
declares its own routing in its own compose file, and **adding a project requires no change
to the edge role**.

`--providers.docker.exposedbydefault=false` means a container is invisible to Traefik until it
opts in with `traefik.enable=true`. That is why a container can sit on the `edge` network
without being publicly reachable, and why `cloudflared`, which is on that network too, is never
routed (the guard refuses Traefik labels on the tunnel stack).

`traefik.docker.network=edge` is set on every routed container because several of them are
attached to more than one network. Without it Traefik may pick the wrong address.

### Conventions an app stack must follow

- Router names must be **unique across the whole host**, not just within the stack. They
  share one namespace. Prefixing with the stack name (`portfolio-www`, `hypernova-web`) is
  enough.
- `traefik.http.routers.<name>.entrypoints=web`: the only entrypoint. No `tls` or
  `certresolver` labels: Cloudflare terminates TLS.
- Set `traefik.http.services.<name>.loadbalancer.server.port` explicitly. Traefik guesses
  otherwise, and guesses wrong on images that expose several ports.
- Attach the container to `edge`, and publish no port.
- Add the hostname to the tunnel's Public Hostnames and its proxied `CNAME`
  ([RUNBOOK.md](../RUNBOOK.md#6-cloudflare-tunnel)), and to `route_targets` in `infra-apply`
  so every release proves the route.

### Priorities

Traefik matches the most specific rule first, but ties are resolved by rule length, which is
not something to rely on. Where two routers can match the same request, set `priority`
explicitly.

hypernova does this: `hypernova-provider` matches `Host(...) && PathPrefix(/api)` at priority
100, and `hypernova-web` matches the same host at priority 1. The provider serves its API at
the root, so a `stripprefix` middleware removes `/api` before forwarding.

The portfolio uses a `redirectregex` middleware to send `www.` to the apex permanently, with
`service=portfolio` so both routers share one backend. Its regex accepts `http` or `https`
(`^https?://www\.…`): behind the tunnel the request reaches Traefik as plain HTTP, and the
replacement always names `https://`.

## Timeouts

`--entrypoints.web.transport.respondingTimeouts.readTimeout=1800s`

Traefik v3 gives a request body 60 seconds by default. A large video upload to the portfolio
admin exceeds that, and Traefik cuts the connection with nothing on the origin to explain
it — the application sees a truncated request and logs nothing useful. Cloudflare limits a
request body to 100 MB on the Free plan regardless.

It is bounded at 30 minutes rather than disabled with `0`, because `0` means a held-open
request costs nothing to keep and a slow-loris becomes free.

## Logs

`--log.level=ERROR`. Traefik at `INFO` narrates every router change, which on a host where
Watchtower recreates containers regularly buries anything worth reading. `cloudflared` logs
at `info`: connection registrations and errors, never request bodies
(`sudo docker logs cloudflared`).

## The down page

When the server is off (a poweroff from Home, a power cut, a reboot) or `cloudflared` is not
connected, Cloudflare itself answers the public sites with its own error 1033 page. Instead,
a **Cloudflare Worker** on the three public hostnames answers with a page of our own:
`cloudflare/down-page/`, Rust with [workers-rs](https://github.com/cloudflare/workers-rs)
(`worker` 0.8.7, built by `worker-build` 0.8.7, both pinned), deployed by the owner with
wrangler ([RUNBOOK.md](../RUNBOOK.md#the-down-page)). It is not part of a release or of
provisioning, holds no secret and has no binding.

```
visitor ──▶ Cloudflare edge ──▶ down-page Worker ──fetch(request)──▶ tunnel ──▶ Traefik ──▶ app
                                   │ the origin's response, untouched (streamed)
                                   └ or, when the origin cannot be reached: 503 + the down page
```

| Route (zone `arbikullakshi.com`) | |
| --- | --- |
| `arbikullakshi.com/*`, `www.arbikullakshi.com/*`, `hypernova.arbikullakshi.com/*` | every request goes through the Worker |

**What it decides** (`src/decision.rs`, unit-tested with `cargo test`). The Worker forwards the
request as it came (method, headers, cookies, body; redirects are not followed) and looks only
at the response's status:

| Origin's answer | Worker returns |
| --- | --- |
| the fetch itself failed | the down page |
| `530` (the tunnel has no connector: error 1033), `520`–`527` (Cloudflare's own origin errors) | the down page |
| `502` / `504` whose body is a gateway's: empty (cloudflared), `error code: <n>`, Cloudflare's HTML error page, or Traefik's exact `Bad Gateway` / `Gateway Timeout` (the app's container is not up) | the down page |
| `502` / `504` from the app (JSON, an event stream, any other text, or longer than 16 KiB) | the origin's response |
| anything else (`2xx`, redirects, `4xx`, other `5xx`, `101` WebSocket upgrades) | the origin's response |

Only a `502`/`504` that is `text/html`, `text/plain` or untyped and at most 16 KiB is read, from a
copy (`Response.clone()`); reading stops at 16 KiB and the original body still streams to the
visitor. Every other response is returned as the very object `fetch` gave back, so the body
streams and the status, headers (`Set-Cookie`, `Cache-Control`, `Location`) and caching are the
origin's. Should the Worker itself throw, `passThroughOnException` sends the request to the
origin as if the Worker were not there.

**The page** (`src/page.html`, `src/page.rs`): the portfolio's dark pixel style, one HTML file
with inline CSS and an inline SVG; no script, font, image or other request (a unit test fails on
any `http`, `url(`, `<script`, `<link` or `src=`). It names the site from a fixed list (never
echoes the `Host`), reloads itself every minute and is sent with `503`, `Retry-After: 120`,
`Cache-Control: no-store`, `X-Robots-Tag: noindex` and a `default-src 'none'` CSP, so neither
Cloudflare nor a browser nor a crawler keeps it.

**Privacy.** The Worker logs nothing (no `console` call) and `wrangler.toml` turns Workers Logs
off (`[observability] enabled = false`); there is no `workers.dev` address and no preview URL.
It never caches anything itself and never changes a private response.

**Free plan limits.** 100,000 Worker requests a day per account (every page view and asset of
the three hosts counts, cached or not), 10 ms of CPU per request (waiting on the origin is not
CPU; the Worker uses well under 1 ms), 3 MB compressed per Worker. Past the daily limit the
routes follow the Worker's *request limit failure mode*: set it to **fail open** so requests
then go straight to the origin, without the down page, instead of failing (RUNBOOK.md).

**Checked in CI** (`.github/workflows/checks.yml`, job *Down page Worker*): `cargo fmt`,
`cargo test`, clippy for the host and `wasm32-unknown-unknown`, `cargo build --release --target
wasm32-unknown-unknown`, and `worker-build --release`, which produces what wrangler uploads.
