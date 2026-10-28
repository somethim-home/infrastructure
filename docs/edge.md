# The edge: Cloudflare in front of Traefik on the hetzner host

The public site runs on the **hetzner host** (a small Hetzner Cloud server, CAX class, Arm64). The
home server has no public site any more and no edge at all: Home and its services are on the
tailnet only, behind their own Traefik, `home-tls` ([stacks.md](stacks.md#media)).

On the hetzner host, Traefik is the only public entry: it publishes `80` and `443`, and only
Cloudflare may reach them. Cloudflare proxies every public name (orange cloud), terminates the
visitor's TLS and connects to the origin over TLS again, SSL/TLS mode **Full (strict)**. Traefik
serves a **Cloudflare Origin CA certificate** and requires **Cloudflare's client certificate**
(Authenticated Origin Pulls) on every TLS connection, then routes by `Host` to the portfolio.

```
visitor ──HTTPS──▶ Cloudflare edge ──HTTPS + client cert──▶ :443 edge-traefik ──HTTP──▶ portfolio:3000 ──▶ postgresql
                   (TLS, CF-Connecting-IP)  (Full (strict),      (roles/edge;        (edge network)      (data network,
                                             AOP)                 Cloudflare's ranges                      never published)
                                                                  only: Hetzner Cloud
                                                                  Firewall, ufw, DOCKER-USER)
```

Until plan 023 (2026-10-28) the sites ran on the home server behind a Cloudflare Tunnel. There is
no tunnel any more: Cloudflare reaches the hetzner host's public address directly.

| Piece | What | Owned by | Changes with |
| --- | --- | --- | --- |
| `edge-traefik` | `traefik:v3.7.13` (multi-arch, pinned by digest) and its socket proxy, ports 80 and 443 | provisioning (`roles/edge`, project `edge` in `/opt/edge`) | `provision.yml -e infra_host=hetzner --tags edge` |
| `/opt/edge/.env` | `CLOUDFLARE_IPS`, Cloudflare's ranges, the only forwarders Traefik trusts | provisioning (`tasks/cloudflare-ips.yml`) | any hetzner provisioning run |
| `/opt/edge/dynamic/tls.yml` | the Origin CA certificate and key, and the client-certificate rule | every hetzner release (`edge/tls.yml` in the bundle, written by `infra-apply`) | a `release` |

## Only Cloudflare reaches Traefik

Three layers, each enough on its own:

- **The Hetzner Cloud Firewall** (set by the owner in the Hetzner console, RUNBOOK.md, "Hetzner
  host"): ICMP from anywhere, TCP 80 and 443 from Cloudflare's ranges only, nothing else inbound.
  SSH arrives over Tailscale, which dials out.
- **The host itself**, which does not count on the cloud firewall. Docker publishes Traefik's
  ports past ufw, so `infra-firewall` (roles/host) filters them in the `DOCKER-USER` chain: on the
  public interface a new connection reaches only the ports in `PUBLIC_PORTS` (`80,443`), and
  only from the IPv4 ranges in `PUBLIC_SOURCES`, both in `/etc/infra/host.env`. IPv6 reaches
  Traefik through `docker-proxy` on the host (the Docker networks are IPv4-only), which ufw does
  see: provisioning adds one `ufw allow proto tcp from <range> to any port 80,443` per Cloudflare
  range, v4 and v6, and ufw denies the rest.
- **Authenticated Origin Pulls.** Even from a Cloudflare address, a TLS client must present the
  certificate Cloudflare signs with its origin-pull CA (`stack/edge/origin-pull-ca.pem`, public,
  valid until 2029-11-01). Another Cloudflare customer pointing a record at this address gets no
  further than the handshake. Port 80 only ever redirects to https.

**Cloudflare's ranges** come from <https://www.cloudflare.com/ips-v4> and
<https://www.cloudflare.com/ips-v6>, fetched by every hetzner provisioning run
(`tasks/cloudflare-ips.yml`). When the fetch fails or returns something that is not a list of
ranges, the run uses `production.yml`'s `cloudflare_ips_pinned` and says so; when the fetched
lists differ from the pinned ones it says to re-pin them. The ranges feed ufw, `PUBLIC_SOURCES`
and Traefik's `CLOUDFLARE_IPS`. A range Cloudflare drops keeps its ufw rule until deleted by hand.

### Client addresses and forwarded headers

Cloudflare sets `CF-Connecting-IP` to the visitor's address and overwrites any value a client
sent. Traefik keeps the `X-Forwarded-*` headers only from `CLOUDFLARE_IPS`
(`forwardedHeaders.trustedIPs` on both entrypoints), and since nothing but Cloudflare can
connect, the portfolio may trust `CF-Connecting-IP` (`CLIENT_IP_SOURCE=Cloudflare`,
[stacks.md](stacks.md#portfolio)) for its rate limiter.

## TLS

- **Cloudflare ↔ visitor:** Cloudflare's own edge certificates.
- **Cloudflare ↔ origin:** SSL/TLS **Full (strict)**. Traefik's default certificate is a
  Cloudflare Origin CA certificate for `arbikullakshi.com` and `*.arbikullakshi.com` (15 years),
  which only Cloudflare trusts, so no browser ever sees it. Never *Flexible*: Cloudflare would
  talk plain http to the origin, Traefik would redirect to https, and every request would loop.
- **The certificate and key** are the `CF_ORIGIN_CERT` and `CF_ORIGIN_KEY` secrets. A hetzner
  release renders them, with the vendored origin-pull CA, into `edge/tls.yml`
  (`stack/edge/tls.yml.j2`, inline PEM; 0600); `infra-apply` checks it holds a certificate and
  the client-certificate rule and installs it atomically as `/opt/edge/dynamic/tls.yml`, and
  Traefik's file provider picks it up without a restart. Rotating them is a normal release.
- **The rule:** `tls.options.default` sets `clientAuthType: RequireAndVerifyClientCert` and TLS
  1.2 or later; every router on `websecure` uses the default options.
- Before the first hetzner release Traefik serves its own self-signed certificate and asks for no
  client certificate; nothing routes there yet.

**Redirects.** The `web` entrypoint (:80) redirects everything to `websecure` (:443). The `www.` →
apex redirect is a `redirectregex` middleware on the portfolio's labels.

## Verifying it

Every hetzner release ends with checks run on the host itself, after every container is healthy
([deploying.md](deploying.md#what-infra-apply-checks-in-order)):

- **http redirects**: `curl -H 'Host: <name>' http://<edge-traefik's edge address>:80<path>` must
  answer `301`, `307` or `308` for `arbikullakshi.com/api/health` and `www.arbikullakshi.com/`.
- **https refuses a client without Cloudflare's certificate**: the same names over https, pinned
  to Traefik's edge address, must fail in the TLS handshake (no HTTP status at all; curl exits 35,
  55 or 56). An HTTP answer here means `tls.yml` is missing or not loaded and the origin would
  serve anyone.
- **Through Cloudflare** (the public check): `https://arbikullakshi.com/api/health` `2xx`,
  `https://www.arbikullakshi.com/` and `http://arbikullakshi.com/api/health` a redirect, asked
  from the host by name. This is the only check that proves the route to the portfolio, since
  only Cloudflare can complete the handshake. A failure here leaves the release current and
  verified and names the Cloudflare side (521/522 firewall or address, 525 Authenticated Origin
  Pulls off, 526 not Full (strict) with the Origin CA certificate).

Provisioning (`roles/edge/tasks/verify.yml`) reads back that `edge-traefik` publishes exactly 80
and 443, and `roles/host/tasks/verify.yml` that no other container publishes anything
(`public_bindings`).

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

Traefik reads its routes from Docker labels on the containers themselves (`--providers.docker`,
through the socket proxy), scoped to the `edge` network, and its TLS settings from
`/opt/edge/dynamic` (`--providers.file`). `exposedbydefault=false`: a container is invisible to
Traefik until it opts in with `traefik.enable=true`. `traefik.docker.network=edge` is set on the
portfolio because it is on two networks (`edge` and `data`).

Conventions for a routed stack: router names unique across the host (prefixed with the stack:
`portfolio-www`); `entrypoints=websecure` and no `tls` or `certresolver` labels (the entrypoint
and the default TLS store do it); an explicit `loadbalancer.server.port`; the container on `edge`
with no published port; the name proxied in Cloudflare (proxied `A` and `AAAA` records to the
server) and added to `route_targets` in `infra-apply`.

`production.yml`'s `preview_domain` adds a second name to the portfolio's router, for checking
the hetzner host through Cloudflare before the real names move to it (RUNBOOK.md, "Hetzner
host"); empty, the router names the apex twice.

## Timeouts

`--entrypoints.websecure.transport.respondingTimeouts.readTimeout=1800s`

Traefik v3 gives a request body 60 seconds by default. A large video upload to the portfolio
admin exceeds that, and Traefik cuts the connection with nothing on the origin to explain
it. Cloudflare limits a request body to 100 MB on the Free plan regardless, and waits at most
100 seconds for the origin's answer (HTTP 524).

It is bounded at 30 minutes rather than disabled with `0`, because `0` means a held-open
request costs nothing to keep and a slow-loris becomes free.

## Logs

`--log.level=ERROR`. Traefik at `INFO` narrates every router change, which on a host where
Watchtower recreates containers regularly buries anything worth reading.

## The down page

When the hetzner host is off or Traefik does not answer, Cloudflare itself answers with its own
521/522 error page. Instead, a **Cloudflare Worker** on the public hostnames answers with a page
of our own: `cloudflare/down-page/`, Rust with [workers-rs](https://github.com/cloudflare/workers-rs)
(`worker` 0.8.7, built by `worker-build` 0.8.7, both pinned), deployed by the owner with
wrangler ([RUNBOOK.md](../RUNBOOK.md#the-down-page)). It is not part of a release or of
provisioning, holds no secret and has no binding.

```
visitor ──▶ Cloudflare edge ──▶ down-page Worker ──fetch(request)──▶ Traefik ──▶ portfolio
                                   │ the origin's response, untouched (streamed)
                                   └ or, when the origin cannot be reached: 503 + the down page
```

| Route (zone `arbikullakshi.com`) | |
| --- | --- |
| `arbikullakshi.com/*`, `www.arbikullakshi.com/*` | every request goes through the Worker |

**What it decides** (`src/decision.rs`, unit-tested with `cargo test`). The Worker forwards the
request as it came (method, headers, cookies, body; redirects are not followed) and looks only
at the response's status:

| Origin's answer | Worker returns |
| --- | --- |
| the fetch itself failed | the down page |
| `520`–`527` (Cloudflare's own origin errors: 521/522 while the server is off), `530` | the down page |
| `502` / `504` whose body is a gateway's: empty, `error code: <n>`, Cloudflare's HTML error page, or Traefik's exact `Bad Gateway` / `Gateway Timeout` (the portfolio's container is not up) | the down page |
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

**Free plan limits.** 100,000 Worker requests a day per account (every page view and asset
counts, cached or not), 10 ms of CPU per request (waiting on the origin is not CPU; the Worker
uses well under 1 ms), 3 MB compressed per Worker. Past the daily limit the routes follow the
Worker's *request limit failure mode*: set it to **fail open** so requests then go straight to
the origin, without the down page, instead of failing (RUNBOOK.md).

**Checked in CI** (`.github/workflows/checks.yml`, job *Down page Worker*): `cargo fmt`,
`cargo test`, clippy for the host and `wasm32-unknown-unknown`, `cargo build --release --target
wasm32-unknown-unknown`, and `worker-build --release`, which produces what wrangler uploads.
