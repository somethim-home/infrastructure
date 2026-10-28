#!/usr/bin/env python3
"""Checks that the templates, the secrets and the compose files agree with the Deploy workflow.

    python3 ci/check_templates.py [--self-test]

Rules (each problem is printed as a ::error:: line):
  1. Every Jinja variable in stack/**/*.j2 and roles/*/templates/*.j2 has a source: production.yml,
     release.yml's vars, a role default, or a key the workflow's "Build extra-vars file from secrets"
     step writes. Every key that step writes is used by some template (no dead secrets).
  2. Each extra-vars key renders only into the bundle files SECRET_FILES allows; a <stack>/.env
     (interpolation only) and the role templates render none.
  3. Each compose file's ${VAR} interpolations are all set by its stack's env.j2 (role compose
     files take none; HOST_VARIABLES, which infra-apply exports from /etc/infra/host.env, are the
     exception), and every env_file a stack names is rendered by release.yml.
  4. Literal image: lines are <repo>:<tag>@sha256:<digest>; app images are only ${<NAME>_IMAGE},
     only in stack/ files, and their env.j2 points them at the production.yml repositories.
  5. ansible.cfg has host_key_checking = True; no deploy file turns host key checking off; every ssh
     call in deploy.yml uses $SSH_OPTIONS, which holds StrictHostKeyChecking=yes.
  6. docker.sock is mounted only by the three *-socket-proxy services, and only read-only.
  7. release.yml's asserts and the workflow agree: every extra var the "Require deploy secrets"
     assert reads is an extra-vars key; env_file_values (the env-file safety loop) lists exactly the
     extra-vars keys; the step's env block sets exactly the variables its jq object reads.
  8. ci/sample-extra-vars.json sets exactly the extra-vars keys, with obviously fake values (never a
     real token prefix such as ghp_ or github_pat_).
  9. No compose file publishes a host port (ports:, network_mode: host) but the hetzner host's
     Traefik, exactly "80:80" and "443:443" (PUBLIC_PORTS: the firewalls admit Cloudflare alone).
     The other exceptions are TAILNET_PORTS, each exactly "${TAILSCALE_IP}:<port>:<port>" (the host's Tailscale
     address), and HOST_NETWORK_SERVICES: the Snowflake proxy, which publishes nothing but needs the
     host network for WebRTC NAT traversal and is fenced by uid in roles/snowflake. The origin
     certificate and key reach only edge/tls.yml (rule 2).
 10. home-tls, the Traefik in front of Home, passes Home through untouched: its entrypoint has no read
     or write deadline (Home's live updates are one long Server-Sent Events response, uploads are big),
     no middleware exists anywhere in its configuration (no buffering, which would hold the event
     stream; no compression; no header or prefix rewriting), Home's name is routed whole to
     home-server:8080, and no other router on Home's name takes /app or /api (the web app, the API
     and the event stream are Home's).

--self-test first seeds at least one violation per rule into a temp copy of the tree and requires
each to be caught, then checks the real tree.
"""
from __future__ import annotations

import configparser
import json
import pathlib
import re
import shutil
import sys
import tempfile

import jinja2
import jinja2.meta
import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOW = ".github/workflows/deploy.yml"
SAMPLE = "ci/sample-extra-vars.json"
EXTRA_VARS_STEP = "Build extra-vars file from secrets"
SECRETS_ASSERT = "Require deploy secrets"

# Extra-vars key -> the bundle files it may be rendered into.
SECRET_FILES = {
    "postgres_superuser_password": {"database/postgres.env", "database/provision.sql"},
    "portfolio_db_password": {"database/provision.sql", "portfolio/portfolio.env"},
    # The R2 endpoint: the portfolio's media and the database dump's.
    "r2_account_id": {"portfolio/portfolio.env", "database/backup.env"},
}
SECRET_PREFIX_FILES = {
    "portfolio_": {"portfolio/portfolio.env"},
    "r2_backup_": {"database/backup.env"},
    "r2_": {"portfolio/portfolio.env"},
    "media_public_base": {"portfolio/portfolio.env"},
    "ghcr_": {"ghcr.env"},
    "cf_origin_": {"edge/tls.yml"},
    "home_tls_": {"media/home-tls.env"},
    "beszel_password": {"media/beszel.env", "media/beszel-pair.env"},
    "beszel_agent_": {"media/beszel-pair.env", "media/beszel-agent.env"},
    "garage_rpc_": {"media/garage.env"},
    "garage_admin_": {"media/garage.env", "media/garage-setup.env"},
    "garage_owner_": {"media/garage-setup.env", "media/sftpgo.env"},
    "files_password": {"media/sftpgo.env"},
    "home_owner_email": {"home/home-server.env"},
    "home_secret_": {"home/home-keys.env"},
    "home_data_": {"home/home-keys.env"},
    "home_resend_": {"home/home-keys.env"},
    "home_power_": {"home/home-keys.env"},
    "home_tmdb_": {"home/home-keys.env"},
    "home_beszel_": {"home/home-keys.env"},
}
# Set at apply time from /etc/infra/host.env (infra-apply exports them), never by a bundle file.
HOST_VARIABLES = {"TAILSCALE_IP"}
# Role compose variables, each from the .env its role writes beside the compose file.
ROLE_VARIABLES = {("roles/edge/files/docker-compose.yml", "CLOUDFLARE_IPS")}
# Extra vars that are PEM files rendered into a YAML file, never env values.
PEM_VALUES = {"cf_origin_cert", "cf_origin_key"}
# The only public ports: the hetzner host's Traefik, which the firewalls admit from Cloudflare alone.
PUBLIC_PORTS = {("roles/edge/files/docker-compose.yml", "traefik"): ["80:80", "443:443"]}
# The only published ports (the compose guard holds the same list): (stack, service) -> port.
TAILNET_PORTS = {
    ("media", "home"): 80,
    ("media", "home-tls"): 443,
    ("media", "beszel"): 8090,
    ("media", "garage"): 3900,
    ("media", "sftpgo"): 8091,
}
ANSIBLE_MAGIC = {"playbook_dir", "role_path", "inventory_hostname", "ansible_managed", "item", "lookup"}
SOCKET_PROXIES = {"edge-socket-proxy", "watchtower-socket-proxy", "autoheal-socket-proxy", "beszel-socket-proxy"}
PINNED_IMAGE = re.compile(r"^[a-z0-9./_-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$")
APP_IMAGE = re.compile(r"^\$\{([A-Z][A-Z0-9_]*_IMAGE)\}$")
INTERPOLATION = re.compile(r"(?<!\$)\$(?:\{([A-Za-z_][A-Za-z0-9_]*)([^}]*)\}|([A-Za-z_][A-Za-z0-9_]*))")
REAL_TOKEN_PREFIXES = ("ghp_", "gho_", "ghs_", "ghu_", "github_pat_", "re_", "sk_live_", "xox")
HOST_KEY_OFF = [
    re.compile(r"host_key_checking\s*[=:]\s*[\"']?(false|no|0|off)\b", re.I),
    re.compile(r"ANSIBLE_(SSH_)?HOST_KEY_CHECKING\s*[=:]\s*[\"']?(false|no|0|off)\b", re.I),
    re.compile(r"StrictHostKeyChecking[\s=]+[\"']?(no|off|accept-new)\b", re.I),
    re.compile(r"UserKnownHostsFile[\s=]+/dev/null"),
]
# Deploy files only: docs, plans and these checkers describe the rules rather than configure hosts.
HOST_KEY_SCAN_SKIP_DIRS = {".git", ".claude", "docs", "plans", "audit", "__pycache__"}
HOST_KEY_SCAN_SKIP_FILES = {"ci/check_templates.py", "ci/check_access.py"}


class CheckError(Exception):
    pass


def load_yaml(path: pathlib.Path):
    return yaml.safe_load(path.read_text())


def steps_of(workflow: dict) -> list[dict]:
    return [s for job in (workflow.get("jobs") or {}).values() for s in job.get("steps") or []]


def extra_vars_step(workflow_text: str) -> dict:
    matches = [s for s in steps_of(yaml.safe_load(workflow_text)) if s.get("name") == EXTRA_VARS_STEP]
    if len(matches) != 1:
        raise CheckError(f"{WORKFLOW}: expected exactly one step named {EXTRA_VARS_STEP!r}")
    return matches[0]


def extra_var_sources(workflow_text: str) -> dict[str, str]:
    """Extra-vars key -> the step env variable its jq line reads."""
    step = extra_vars_step(workflow_text)
    body = re.search(r"jq -n '\{(.*?)\}'", step.get("run") or "", re.S)
    if not body:
        raise CheckError(f"{WORKFLOW}: the jq object of {EXTRA_VARS_STEP!r} was not found")
    keys: dict[str, str] = {}
    for line in body.group(1).splitlines():
        line = line.strip().rstrip(",")
        if not line:
            continue
        m = re.fullmatch(r"([a-z0-9_]+):\s*env\.([A-Z0-9_]+)", line)
        if not m:
            raise CheckError(f"{WORKFLOW}: unrecognised jq line {line!r}")
        keys[m.group(1)] = m.group(2)
    return keys


def ansible_vars(root: pathlib.Path) -> dict:
    merged: dict = {}
    for path in sorted(root.glob("roles/*/defaults/main.yml")):
        merged.update(load_yaml(path) or {})
    merged.update(load_yaml(root / "production.yml") or {})
    for playbook in ("provision.yml", "release.yml"):
        for play in load_yaml(root / playbook) or []:
            merged.update(play.get("vars") or {})
    return merged


def templates(root: pathlib.Path) -> list[str]:
    found = [*root.glob("stack/**/*.j2"), *root.glob("roles/*/templates/*.j2")]
    return sorted(str(p.relative_to(root)) for p in found)


# Ansible's Jinja tests, by name only: the checks parse assert expressions, they never evaluate them.
ANSIBLE_TESTS = ("match", "search", "regex", "exists", "file", "directory", "link", "abs", "success", "failed", "changed", "skipped")


def jinja_env() -> jinja2.Environment:
    # An undefined variable renders empty here; rule 1 reports it by name.
    env = jinja2.Environment(keep_trailing_newline=True)
    env.tests.update({name: (lambda *_a, **_k: True) for name in ANSIBLE_TESTS})
    env.filters["bool"] = lambda value: str(value).strip().lower() in ("true", "yes", "1", "on")
    env.globals["lookup"] = lambda *_a, **_k: ""
    return env


def template_variables(root: pathlib.Path, rel: str) -> set[str]:
    try:
        return jinja2.meta.find_undeclared_variables(jinja_env().parse((root / rel).read_text()))
    except jinja2.TemplateError as e:
        raise CheckError(f"{rel}: does not parse: {type(e).__name__}: {e}")


def release_renders(root: pathlib.Path) -> dict[str, str]:
    """stack/<src> -> bundle path, from release.yml's render loop."""
    play = (load_yaml(root / "release.yml") or [{}])[0]
    for task in play.get("tasks") or []:
        if "ansible.builtin.template" in task:
            return {f"stack/{item['src']}": item["dest"] for item in task.get("loop") or []}
    raise CheckError("release.yml: the task that renders the env files was not found")


def sentinel(key: str) -> str:
    # Letters and digits only, so urlencode keeps it whole.
    return "Sentinel" + key.replace("_", "") + "X"


def render_all(root: pathlib.Path, extra: dict[str, str]) -> dict[str, str]:
    context = {**ansible_vars(root), "playbook_dir": str(root), **{k: sentinel(k) for k in extra}}
    rendered = {}
    for rel in templates(root):
        try:
            rendered[rel] = jinja_env().from_string((root / rel).read_text()).render(**context)
        except jinja2.TemplateError as e:
            raise CheckError(f"{rel}: does not render with the deploy vars: {type(e).__name__}: {e}")
    return rendered


def env_values(text: str) -> dict[str, str]:
    return dict(re.findall(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", text, re.M))


def allowed_files(key: str) -> set[str] | None:
    if key in SECRET_FILES:
        return SECRET_FILES[key]
    for prefix, files in SECRET_PREFIX_FILES.items():
        if key.startswith(prefix):
            return files
    return None


def compose_files(root: pathlib.Path) -> list[str]:
    found = [*root.glob("stack/*/docker-compose.yml"), *root.glob("roles/*/files/docker-compose.yml")]
    return sorted(str(p.relative_to(root)) for p in found)


def interpolation_source(rel: str) -> str | None:
    parts = rel.split("/")
    if parts[0] == "stack":
        return f"stack/{parts[1]}/env.j2"
    return None


# Rule 1
def check_sources(root: pathlib.Path, extra: dict[str, str]) -> list[str]:
    problems = []
    sources = set(extra) | set(ansible_vars(root)) | ANSIBLE_MAGIC
    used: set[str] = set()
    for rel in templates(root):
        names = template_variables(root, rel)
        used |= names
        for name in sorted(names - sources):
            problems.append(f"rule 1: {rel}: '{name}' has no source; add it to production.yml, a role default, "
                            f"release.yml's vars or {WORKFLOW}'s extra-vars step (env + jq)")
    for key in sorted(set(extra) - used):
        problems.append(f"rule 1: {WORKFLOW}: the extra-vars step writes '{key}', which no template uses (a dead secret); remove it")
    return problems


# Rule 2
def check_secret_files(root: pathlib.Path, extra: dict[str, str], rendered: dict[str, str]) -> list[str]:
    problems = []
    dests = release_renders(root)
    for key in sorted(extra):
        allowed = allowed_files(key)
        if allowed is None:
            problems.append(f"rule 2: '{key}' has no allowed bundle file; add it to SECRET_FILES in ci/check_templates.py")
            continue
        found = {dests.get(rel, rel) for rel, text in rendered.items() if sentinel(key) in text}
        if key in SECRET_FILES and found & allowed != allowed:
            problems.append(f"rule 2: '{key}' must reach {', '.join(sorted(allowed))}; it reaches only {', '.join(sorted(found & allowed)) or 'none of them'}")
        for rel, text in sorted(rendered.items()):
            if sentinel(key) not in text:
                continue
            dest = dests.get(rel, rel)
            if dest.endswith("/.env") or rel.endswith("/env.j2"):
                problems.append(f"rule 2: {rel}: renders the secret '{key}' into {dest}, which only feeds compose interpolation")
            elif dest not in allowed:
                problems.append(f"rule 2: {rel}: renders '{key}' into {dest}; it may only reach {', '.join(sorted(allowed))}")
    return problems


# Rule 3
def check_compose_env(root: pathlib.Path, rendered: dict[str, str]) -> list[str]:
    problems = []
    dests = set(release_renders(root).values())
    for rel in compose_files(root):
        source = interpolation_source(rel)
        defined = set(env_values(rendered[source])) if source in rendered else set()
        text = (root / rel).read_text()
        body = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
        for braced, modifier, bare in INTERPOLATION.findall(body):
            name = braced or bare
            if (name in HOST_VARIABLES and rel.startswith("stack/")) or (rel, name) in ROLE_VARIABLES:
                continue
            if name not in defined and not modifier.lstrip(":").startswith("-"):
                problems.append(f"rule 3: {rel}: ${{{name}}} is not set by {source if source in rendered else 'any env template'} "
                                "(Compose would interpolate an empty string)")
        services = (yaml.safe_load(text) or {}).get("services") or {}
        stack = rel.split("/")[1]
        for name, service in services.items():
            env_files = service.get("env_file") or []
            for env_file in [env_files] if isinstance(env_files, (str, dict)) else env_files:
                path = env_file.get("path") if isinstance(env_file, dict) else env_file
                if not rel.startswith("stack/"):
                    problems.append(f"rule 3: {rel}: service {name} reads env_file {path}; role compose files take no env files")
                elif f"{stack}/{path}" not in dests:
                    problems.append(f"rule 3: {rel}: service {name} reads env_file {path}, which release.yml does not render into {stack}/")
    return sorted(set(problems))


# Rule 4
def check_images(root: pathlib.Path, rendered: dict[str, str]) -> list[str]:
    problems = []
    variables = ansible_vars(root)
    app_repos = {str(v) for k, v in variables.items() if k.endswith("_image_repo")}
    for rel in compose_files(root):
        services = (load_yaml(root / rel) or {}).get("services") or {}
        defined = env_values(rendered.get(interpolation_source(rel) or "", ""))
        for name, service in services.items():
            image = str(service.get("image", ""))
            app = APP_IMAGE.match(image)
            if image.startswith("$"):
                if not app:
                    problems.append(f"rule 4: {rel}: service {name} image {image!r} must be exactly ${{<NAME>_IMAGE}}")
                elif not rel.startswith("stack/"):
                    problems.append(f"rule 4: {rel}: service {name} takes an app image ({image}) outside stack/")
                elif defined.get(app.group(1), "").rsplit(":", 1)[0] not in app_repos:
                    problems.append(f"rule 4: {rel}: {app.group(1)} does not point at an app repository of production.yml")
            elif not PINNED_IMAGE.match(image):
                problems.append(f"rule 4: {rel}: service {name} runs {image!r}, which is not pinned to <tag>@sha256:<digest>")
            elif image.split("@")[0].rsplit(":", 1)[0] in app_repos:
                problems.append(f"rule 4: {rel}: service {name} names the app image {image!r} literally; use ${{<NAME>_IMAGE}}")
    return problems


def ssh_lines(run: str) -> list[str]:
    return [line for line in run.splitlines() if re.search(r"(^|[\s;(|&])ssh\s", line) and not line.lstrip().startswith("#")]


# Rule 5
def check_host_keys(root: pathlib.Path, workflow_text: str) -> list[str]:
    problems = []
    cfg = configparser.ConfigParser()
    cfg.read_string((root / "ansible.cfg").read_text())
    if not cfg.getboolean("defaults", "host_key_checking", fallback=False):
        problems.append("rule 5: ansible.cfg: host_key_checking must be True")
    for path in sorted(root.rglob("*")):
        rel = path.relative_to(root)
        if not path.is_file() or HOST_KEY_SCAN_SKIP_DIRS & set(rel.parts) or path.suffix == ".md" or str(rel) in HOST_KEY_SCAN_SKIP_FILES:
            continue
        try:
            text = path.read_text()
        except UnicodeDecodeError:
            continue
        for pattern in HOST_KEY_OFF:
            for m in pattern.finditer(text):
                problems.append(f"rule 5: {rel}: turns host key checking off ({m.group(0)!r})")
    steps = steps_of(yaml.safe_load(workflow_text))
    options = [s for s in steps if "SSH_OPTIONS=" in (s.get("run") or "")]
    if len(options) != 1:
        problems.append(f"rule 5: {WORKFLOW}: exactly one step must define SSH_OPTIONS")
    for step in options:
        line = next(l for l in (step.get("run") or "").splitlines() if "SSH_OPTIONS=" in l)
        if "StrictHostKeyChecking=yes" not in line or not re.search(r"UserKnownHostsFile=\S", line):
            problems.append(f"rule 5: {WORKFLOW}: SSH_OPTIONS must hold -o StrictHostKeyChecking=yes and a pinned UserKnownHostsFile")
    calls = [(s.get("name"), line) for s in steps for line in ssh_lines(s.get("run") or "")]
    if not calls:
        problems.append(f"rule 5: {WORKFLOW}: no step connects to the server with ssh")
    for name, line in calls:
        if "$SSH_OPTIONS" not in line and "StrictHostKeyChecking=yes" not in line:
            problems.append(f"rule 5: {WORKFLOW}: step {name!r} runs ssh without $SSH_OPTIONS (StrictHostKeyChecking=yes)")
    return problems


# Rule 6
def check_docker_socket(root: pathlib.Path) -> list[str]:
    problems = []
    for rel in compose_files(root):
        model = load_yaml(root / rel) or {}
        services = model.get("services") or {}
        outside = {k: v for k, v in model.items() if k != "services"}
        if "docker.sock" in yaml.safe_dump(outside):
            problems.append(f"rule 6: {rel}: mentions docker.sock outside a service")
        for name, service in services.items():
            if "docker.sock" not in yaml.safe_dump(service):
                continue
            if name not in SOCKET_PROXIES:
                problems.append(f"rule 6: {rel}: service {name} mounts docker.sock; only {', '.join(sorted(SOCKET_PROXIES))} may")
                continue
            mounts = [str(v) for v in service.get("volumes") or [] if "docker.sock" in str(v)]
            if not mounts or any(not m.endswith(":ro") for m in mounts) or "docker.sock" in yaml.safe_dump({k: v for k, v in service.items() if k != "volumes"}):
                problems.append(f"rule 6: {rel}: service {name} must mount docker.sock read-only (:ro) and nowhere else")
    return problems


def assert_variables(expressions: list[str]) -> set[str]:
    env = jinja_env()
    names: set[str] = set()
    for expr in expressions:
        names |= jinja2.meta.find_undeclared_variables(env.parse("{{ " + str(expr) + " }}"))
    return names


# Rule 7
def check_asserts(root: pathlib.Path, workflow_text: str, extra: dict[str, str]) -> list[str]:
    problems = []
    play = (load_yaml(root / "release.yml") or [{}])[0]
    asserts = [t for t in play.get("pre_tasks") or [] if t.get("name") == SECRETS_ASSERT]
    if len(asserts) != 1:
        return [f"rule 7: release.yml: expected exactly one pre_task named {SECRETS_ASSERT!r}"]
    asserted = assert_variables((asserts[0].get("ansible.builtin.assert") or {}).get("that") or [])
    # infra_host is the host the run renders for (build-bundle.sh --host), not a secret.
    for name in sorted(asserted - set(extra) - {"infra_host"}):
        problems.append(f"rule 7: release.yml: the {SECRETS_ASSERT!r} assert reads '{name}', which {WORKFLOW}'s extra-vars step never sets")
    listed = set((play.get("vars") or {}).get("env_file_values") or [])
    for name in sorted(listed & PEM_VALUES):
        problems.append(f"rule 7: release.yml: env_file_values names '{name}', a PEM file whose line breaks it would refuse")
    for name in sorted(set(extra) - listed - PEM_VALUES):
        problems.append(f"rule 7: release.yml: env_file_values lacks '{name}', so a $, quote or # in it would reach Compose unchecked")
    for name in sorted(listed - set(extra)):
        problems.append(f"rule 7: release.yml: env_file_values names '{name}', which {WORKFLOW}'s extra-vars step never sets")
    env = set((extra_vars_step(workflow_text).get("env") or {}))
    for name in sorted(set(extra.values()) - env):
        problems.append(f"rule 7: {WORKFLOW}: the jq object reads env.{name}, which the step's env block never sets (it would reach Ansible as null)")
    for name in sorted(env - set(extra.values())):
        problems.append(f"rule 7: {WORKFLOW}: the extra-vars step's env block sets {name}, which its jq object never reads")
    return problems


# Rule 8
def check_sample(root: pathlib.Path, extra: dict[str, str]) -> list[str]:
    problems = []
    sample = json.loads((root / SAMPLE).read_text())
    if set(sample) != set(extra):
        problems.append(f"rule 8: {SAMPLE}: keys differ from the extra-vars step: "
                        f"missing {sorted(set(extra) - set(sample))}, extra {sorted(set(sample) - set(extra))}")
    for key, value in sorted(sample.items()):
        if str(value).lower().startswith(REAL_TOKEN_PREFIXES):
            problems.append(f"rule 8: {SAMPLE}: '{key}' looks like a real token (prefix of {', '.join(REAL_TOKEN_PREFIXES)}); use an obviously fake value")
    return problems


# Rule 9
# The one service allowed on the host network: Tor's Snowflake proxy. Behind a
# Docker bridge its NAT measures "strict" instead of "restricted"; it publishes
# no port and roles/snowflake's nftables fence keeps its uid off every local and
# private address (docs/host.md "Snowflake").
HOST_NETWORK_SERVICES = {("roles/snowflake/files/docker-compose.yml", "snowflake-proxy")}


def check_no_published_ports(root: pathlib.Path) -> list[str]:
    problems = []
    for rel in compose_files(root):
        services = (load_yaml(root / rel) or {}).get("services") or {}
        stack = rel.split("/")[1] if rel.startswith("stack/") else None
        for name, service in services.items():
            port = TAILNET_PORTS.get((stack, name))
            want = [f"${{TAILSCALE_IP}}:{port}:{port}"]
            public = PUBLIC_PORTS.get((rel, name))
            if public is not None:
                if service.get("ports") != public:
                    problems.append(f"rule 9: {rel}: service {name} publishes {service.get('ports')}; it may publish exactly {public}")
            elif port is not None and service.get("ports") != want:
                problems.append(f"rule 9: {rel}: service {name} publishes {service.get('ports')}; it may publish exactly {want}, "
                                "on the host's Tailscale address only (docs/architecture.md)")
            elif port is None and service.get("ports"):
                problems.append(f"rule 9: {rel}: service {name} publishes host ports {service['ports']}; nothing may be reachable "
                                "but Traefik's 80 and 443 on the hetzner host (PUBLIC_PORTS), or TAILNET_PORTS on the tailnet (docs/edge.md)")
            if str(service.get("network_mode", "")) == "host" and (rel, name) not in HOST_NETWORK_SERVICES:
                problems.append(f"rule 9: {rel}: service {name} uses network_mode: host, which listens on the host's interfaces")
    return problems


# Rule 10
HOME_TLS_COMPOSE = "stack/media/docker-compose.yml"


def check_home_tls_streaming(root: pathlib.Path) -> list[str]:
    problems = []
    service = ((load_yaml(root / HOME_TLS_COMPOSE) or {}).get("services") or {}).get("home-tls") or {}
    env = service.get("environment") or {}
    static = yaml.safe_load(str(env.get("HOME_TLS_STATIC", ""))) or {}
    dynamic = yaml.safe_load(str(env.get("HOME_TLS_DYNAMIC", ""))) or {}
    entry = ((static.get("entryPoints") or {}).get("websecure") or {})
    timeouts = ((entry.get("transport") or {}).get("respondingTimeouts") or {})
    for name in ("readTimeout", "writeTimeout"):
        if str(timeouts.get(name)) not in ("0", "0s"):
            problems.append(f"rule 10: {HOME_TLS_COMPOSE}: home-tls's websecure {name} is {timeouts.get(name)!r}; it must be 0s, or Home's "
                            "event stream (/api/events) and long uploads are cut")
    if (entry.get("http") or {}).get("middlewares"):
        problems.append(f"rule 10: {HOME_TLS_COMPOSE}: home-tls's websecure entrypoint applies middlewares; Home must pass untouched")
    http = dynamic.get("http") or {}
    if http.get("middlewares"):
        problems.append(f"rule 10: {HOME_TLS_COMPOSE}: home-tls defines middlewares ({', '.join(sorted(http['middlewares']))}); none may exist "
                        "(buffering holds Home's event stream, compression and rewrites change what Home sends)")
    routers = http.get("routers") or {}
    for name, router in sorted(routers.items()):
        if (router or {}).get("middlewares"):
            problems.append(f"rule 10: {HOME_TLS_COMPOSE}: home-tls router {name} uses middlewares; none may")
    home = routers.get("home") or {}
    if home.get("rule") != "Host(`${HOME_DOMAIN}`)" or home.get("service") != "home-server":
        problems.append(f"rule 10: {HOME_TLS_COMPOSE}: home-tls router home must route Host(`${{HOME_DOMAIN}}`) whole to home-server")
    servers = ((((http.get("services") or {}).get("home-server") or {}).get("loadBalancer") or {}).get("servers") or [])
    if [s.get("url") for s in servers] != ["http://home-server:8080"]:
        problems.append(f"rule 10: {HOME_TLS_COMPOSE}: home-tls service home-server must be exactly http://home-server:8080")
    for name, router in sorted(routers.items()):
        rule = str((router or {}).get("rule", ""))
        if name != "home" and "${HOME_DOMAIN}" in rule and re.search(r"Path(Prefix)?\(`/(app|api)", rule):
            problems.append(f"rule 10: {HOME_TLS_COMPOSE}: home-tls router {name} takes {rule}; /app and /api on Home's name are home-server's")
    return problems


def run_checks(root: pathlib.Path) -> list[str]:
    try:
        workflow_text = (root / WORKFLOW).read_text()
        extra = extra_var_sources(workflow_text)
        rendered = render_all(root, extra)
        problems = check_sources(root, extra)
        problems += check_secret_files(root, extra, rendered)
        problems += check_compose_env(root, rendered)
        problems += check_images(root, rendered)
        problems += check_host_keys(root, workflow_text)
        problems += check_docker_socket(root)
        problems += check_asserts(root, workflow_text, extra)
        problems += check_sample(root, extra)
        problems += check_no_published_ports(root)
        problems += check_home_tls_streaming(root)
        return problems
    except CheckError as e:
        return [str(e)]
    except (KeyError, TypeError, AttributeError, ValueError, OSError, yaml.YAMLError, jinja2.TemplateError) as e:
        return [f"the checks could not read their inputs: {type(e).__name__}: {e}"]


def self_test() -> None:
    def edit(rel: str, old: str, new: str):
        def mutate(tmp: pathlib.Path) -> None:
            path = tmp / rel
            text = path.read_text()
            if old not in text:
                raise SystemExit(f"self-test setup failed: {old!r} not in {rel}")
            path.write_text(text.replace(old, new, 1))
        return mutate

    def append(rel: str, extra: str):
        def mutate(tmp: pathlib.Path) -> None:
            path = tmp / rel
            path.write_text(path.read_text() + extra)
        return mutate

    def both(*mutations):
        def mutate(tmp: pathlib.Path) -> None:
            for m in mutations:
                m(tmp)
        return mutate

    jq_last = "            home_beszel_password: env.HOME_BESZEL_PASSWORD\n"
    env_last = "          HOME_BESZEL_PASSWORD: ${{ secrets.HOME_BESZEL_PASSWORD }}\n"
    dead_secret = both(
        edit(WORKFLOW, jq_last, jq_last.rstrip("\n") + ",\n            crm_db_password: env.CRM_DB_PASSWORD\n"),
        edit(WORKFLOW, env_last, env_last + "          CRM_DB_PASSWORD: ${{ secrets.CRM_DB_PASSWORD }}\n"),
        edit(SAMPLE, '"portfolio_admin_password"', '"crm_db_password": "FakeCrm0000", "portfolio_admin_password"'),
        edit("release.yml", "      - portfolio_admin_password\n", "      - portfolio_admin_password\n      - crm_db_password\n"),
    )
    cases = [
        ("1", "a template variable with no source", append("stack/portfolio/portfolio.env.j2", "CRM_URL={{ crm_url }}\n"), "'crm_url' has no source"),
        ("1", "a dead secret in the extra-vars step", dead_secret, "writes 'crm_db_password', which no template uses"),
        ("2", "the backup key rendered into portfolio.env", append("stack/portfolio/portfolio.env.j2", "BACKUP={{ r2_backup_secret_access_key }}\n"),
         "renders 'r2_backup_secret_access_key' into portfolio/portfolio.env"),
        ("2", "a secret in an interpolation-only .env", append("stack/portfolio/env.j2", "TOKEN={{ ghcr_token }}\n"), "renders the secret 'ghcr_token' into portfolio/.env"),
        ("2", "a database password in the wrong env file", append("stack/database/backup.env.j2", "OTHER={{ portfolio_db_password }}\n"),
         "renders 'portfolio_db_password' into database/backup.env"),
        ("2", "a role password no longer set by provision.sql", edit("stack/database/provision.sql.j2", "PASSWORD '{{ consumer.password }}'", "PASSWORD NULL"),
         "'portfolio_db_password' must reach database/provision.sql, portfolio/portfolio.env"),
        ("2", "the origin key rendered into portfolio.env", append("stack/portfolio/portfolio.env.j2", "KEY={{ cf_origin_key }}\n"),
         "renders 'cf_origin_key' into portfolio/portfolio.env"),
        ("3", "a compose variable no env.j2 sets", edit("stack/portfolio/docker-compose.yml", "Host(`${WWW_DOMAIN}`)", "Host(`${OLD_DOMAIN}`)"),
         "${OLD_DOMAIN} is not set by stack/portfolio/env.j2"),
        ("3", "a role compose file that interpolates a variable", edit("roles/edge/files/docker-compose.yml", "      - --log.level=ERROR\n", "      - --log.level=${EDGE_LOG_LEVEL}\n"),
         "${EDGE_LOG_LEVEL} is not set by any env template"),
        ("3", "an env_file release.yml does not render", edit("stack/portfolio/docker-compose.yml", "env_file: portfolio.env", "env_file: crm.env"),
         "reads env_file crm.env, which release.yml does not render"),
        ("4", "an unpinned third-party image", edit("roles/edge/files/docker-compose.yml", "image: traefik:v3.7.13@sha256:", "image: traefik:v3.7.13 # @sha256:"),
         "runs 'traefik:v3.7.13', which is not pinned"),
        ("4", "an app image named literally", edit("stack/portfolio/docker-compose.yml", "image: ${PORTFOLIO_IMAGE}",
                                                    "image: ghcr.io/somethim/portfolio:latest@sha256:" + "0" * 64), "names the app image"),
        ("4", "an app image variable in a role compose file", edit("roles/autoheal/files/docker-compose.yml", "image: willfarrell/autoheal:latest@sha256:",
                                                                   "image: ${AUTOHEAL_IMAGE}\n    x-was: willfarrell/autoheal:latest@sha256:"), "takes an app image"),
        ("5", "ansible.cfg without host key checking", edit("ansible.cfg", "host_key_checking = True", "host_key_checking = False"), "host_key_checking must be True"),
        ("5", "the workflow turns host key checking off", edit(WORKFLOW, "    steps:\n", "    env:\n      ANSIBLE_HOST_KEY_CHECKING: \"False\"\n    steps:\n"),
         "turns host key checking off"),
        ("5", "SSH_OPTIONS accepts new host keys", edit(WORKFLOW, "StrictHostKeyChecking=yes", "StrictHostKeyChecking=accept-new"), "SSH_OPTIONS must hold"),
        ("5", "an ssh call without SSH_OPTIONS", edit(WORKFLOW, 'ssh $SSH_OPTIONS "${DEPLOY_USER}@${SERVER_SSH_HOST}" release', 'ssh "${DEPLOY_USER}@${SERVER_SSH_HOST}" release'),
         "runs ssh without $SSH_OPTIONS"),
        ("6", "Traefik mounts docker.sock", edit("roles/edge/files/docker-compose.yml", "      - ./dynamic:/dynamic:ro\n", "      - ./dynamic:/dynamic:ro\n      - /var/run/docker.sock:/var/run/docker.sock:ro\n"),
         "service traefik mounts docker.sock"),
        ("6", "a socket proxy mounts docker.sock read-write", edit("roles/watchtower/files/docker-compose.yml", "/var/run/docker.sock:/var/run/docker.sock:ro", "/var/run/docker.sock:/var/run/docker.sock"),
         "must mount docker.sock read-only"),
        ("7", "an assert on a secret the workflow never sets", edit("release.yml", "          - infra_host != 'hetzner' or portfolio_admin_password | default('') | length > 0\n",
                                                                     "          - infra_host != 'hetzner' or portfolio_admin_password | default('') | length > 0\n          - crm_token | default('') | length > 0\n"),
         "assert reads 'crm_token'"),
        ("7", "a secret left out of env_file_values", edit("release.yml", "      - portfolio_resend_api_key\n", ""), "env_file_values lacks 'portfolio_resend_api_key'"),
        ("7", "a jq key whose env var is not set", edit(WORKFLOW, "          R2_BACKUP_SECRET_ACCESS_KEY: ${{ secrets.R2_BACKUP_SECRET_ACCESS_KEY }}\n", ""),
         "reads env.R2_BACKUP_SECRET_ACCESS_KEY, which the step's env block never sets"),
        ("7", "a PEM value run through the env-file check", edit("release.yml", "      - portfolio_resend_api_key\n", "      - portfolio_resend_api_key\n      - cf_origin_cert\n"),
         "env_file_values names 'cf_origin_cert', a PEM file"),
        ("7", "an env var the jq object never reads", edit(WORKFLOW, env_last, env_last + "          CRM_TOKEN: ${{ secrets.CRM_TOKEN }}\n"),
         "sets CRM_TOKEN, which its jq object never reads"),
        ("8", "a sample value with a real token prefix", edit(SAMPLE, '"fake_ghcr_token_', '"ghp_ghcr_token_'), "'ghcr_token' looks like a real token"),
        ("8", "a sample missing a key", edit(SAMPLE, '"portfolio_resend_api_key": "fake-resend-key-0000",', ""), "keys differ from the extra-vars step"),
        ("9", "Traefik publishes another port", edit("roles/edge/files/docker-compose.yml", '      - "443:443"\n', '      - "443:443"\n      - "8080:8080"\n'),
         "service traefik publishes ['80:80', '443:443', '8080:8080']; it may publish exactly ['80:80', '443:443']"),
        ("9", "the database on the host network", edit("stack/database/docker-compose.yml", "    container_name: postgresql\n", "    container_name: postgresql\n    network_mode: host\n"),
         "service postgres uses network_mode: host"),
        ("9", "another role service on the host network", edit("roles/autoheal/files/docker-compose.yml", "    container_name: autoheal\n", "    container_name: autoheal\n    network_mode: host\n"),
         "service autoheal uses network_mode: host"),
        ("9", "the Snowflake proxy publishes a port", edit("roles/snowflake/files/docker-compose.yml", "    container_name: snowflake-proxy\n", "    container_name: snowflake-proxy\n    ports: [\"8080:8080\"]\n"),
         "service snowflake-proxy publishes host ports"),
        ("9", "a stack publishes a port", edit("stack/portfolio/docker-compose.yml", "    container_name: portfolio\n", "    container_name: portfolio\n    ports: [\"3000:3000\"]\n"),
         "service portfolio publishes host ports"),
        ("9", "the file manager published on every interface", edit("stack/media/docker-compose.yml", '      - "${TAILSCALE_IP}:8091:8091"\n', '      - "8091:8091"\n'),
         "service sftpgo publishes ['8091:8091']; it may publish exactly ['${TAILSCALE_IP}:8091:8091']"),
        ("9", "llama-server published on the tailnet", edit("stack/ai/docker-compose.yml", "    container_name: llama\n", "    container_name: llama\n    ports:\n      - \"${TAILSCALE_IP}:8080:8080\"\n"),
         "service llama publishes host ports"),
        ("9", "the status dashboard published on the LAN address", edit("stack/media/docker-compose.yml", '"${TAILSCALE_IP}:8090:8090"', '"192.168.1.50:8090:8090"'),
         "service beszel publishes ['192.168.1.50:8090:8090']; it may publish exactly ['${TAILSCALE_IP}:8090:8090']"),
        ("2", "the dashboard password rendered into the media .env", append("stack/media/env.j2", "BESZEL={{ beszel_password }}\n"),
         "renders the secret 'beszel_password' into media/.env"),
        ("2", "the files password rendered into the portfolio's env", append("stack/portfolio/portfolio.env.j2", "FILES={{ files_password }}\n"),
         "renders 'files_password' into portfolio/portfolio.env"),
        ("3", "an ai variable no env.j2 sets", edit("stack/ai/docker-compose.yml", '      LLAMA_MODELS: "${LLAMA_MODELS}"', '      LLAMA_MODELS: "${LLAMA_MODEL_FILES}"'),
         "${LLAMA_MODEL_FILES} is not set by stack/ai/env.j2"),
        ("2", "Home's data key rendered into home-server's settings", append("stack/home/home-server.env.j2", "KEY={{ home_data_key }}\n"),
         "renders 'home_data_key' into home/home-server.env"),
        ("2", "Home's mail key rendered into the file manager's env", append("stack/media/sftpgo.env.j2", "MAIL={{ home_resend_api_key }}\n"),
         "renders 'home_resend_api_key' into media/sftpgo.env"),
        ("2", "Garage's RPC secret rendered into the file manager's env", append("stack/media/sftpgo.env.j2", "RPC={{ garage_rpc_secret }}\n"),
         "renders 'garage_rpc_secret' into media/sftpgo.env"),
        ("2", "TMDB's token rendered into home-server's settings", append("stack/home/home-server.env.j2", "TMDB={{ home_tmdb_read_token }}\n"),
         "renders 'home_tmdb_read_token' into home/home-server.env"),
        ("10", "Traefik's 60-second read deadline back on home-tls", edit(HOME_TLS_COMPOSE, "                readTimeout: 0s\n", "                readTimeout: 60s\n"),
         "websecure readTimeout is '60s'"),
        ("10", "a compression middleware on home-tls", edit(HOME_TLS_COMPOSE, "        http:\n          routers:\n",
                                                            "        http:\n          middlewares:\n            gzip:\n              compress: {}\n          routers:\n"),
         "home-tls defines middlewares (gzip)"),
        ("10", "a buffering middleware on Home's router", edit(HOME_TLS_COMPOSE, "              service: home-server\n",
                                                             "              service: home-server\n              middlewares: [buffer]\n"),
         "home-tls router home uses middlewares"),
        ("10", "/app sent to the file manager's WebDAV", edit(HOME_TLS_COMPOSE, "PathPrefix(`/dav`)", "PathPrefix(`/app`)"),
         "/app and /api on Home's name are home-server's"),
    ]
    caught_rules = set()
    for rule, name, mutate, expected in cases:
        with tempfile.TemporaryDirectory() as d:
            tmp = pathlib.Path(d) / "root"
            shutil.copytree(ROOT, tmp, ignore=shutil.ignore_patterns(".git", ".claude", "plans", "audit", "__pycache__", "target"))
            mutate(tmp)
            problems = run_checks(tmp)
            if not any(expected in p and p.startswith(f"rule {rule}:") for p in problems):
                raise SystemExit(f"self-test FAILED: rule {rule}: {name}: expected a problem containing {expected!r}, got {problems}")
            caught_rules.add(rule)
            print(f"ok   rule {rule} caught: {name}")
    missing = {str(n) for n in range(1, 11)} - caught_rules
    if missing:
        raise SystemExit(f"self-test FAILED: no seeded violation for rules {sorted(missing)}")
    print("self-test: every seeded violation was caught")


def main() -> int:
    if "--self-test" in sys.argv[1:]:
        self_test()
    problems = run_checks(ROOT)
    for p in problems:
        print(f"::error::{p}")
    if problems:
        return 1
    print("deploy templates: every variable has a source and every extra var a use, secrets reach only their own env files, "
          "compose interpolations and env files are rendered, images pinned, host keys checked, docker.sock only in the "
          "socket proxies (read-only), release.yml's asserts match the workflow, the sample vars are fake, no host port is published but the tailnet-only ones on the Tailscale address, "
          "home-tls passes Home (its web app and event stream) through with no deadline, buffering or compression")
    return 0


if __name__ == "__main__":
    sys.exit(main())
