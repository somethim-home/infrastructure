#!/usr/bin/env bash
# Tests the release path against fakes: build-bundle.sh, infra-deploy-gate,
# infra-apply and infra-compose-guard. Fake docker, curl and sudo go first on
# PATH; `docker compose config` is delegated to the real Docker CLI (it needs
# no daemon), flock is real, and every host path is a temp dir through the
# INFRA_APPLY_* overrides. Nothing here contacts a server or a registry.
#
#   bash ci/release-scripts.sh
#
# Prints "ok   ..." per case and stops with "FAIL ..." on the first failure.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
apply="$root/roles/common/files/infra-apply"
gate="$root/roles/common/files/infra-deploy-gate"
guard="$root/roles/common/files/infra-compose-guard"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
# shellcheck source=ci/release-fakes.sh
. "$here/release-fakes.sh"
host_power_key=SGFybmVzc0hvbWVQb3dlcktleTAxMjM0NTY3ODlhYmM=

current_release() {
  readlink "$state/stack/current" | sed 's,^releases/,,'
}

# The bundle a fresh release of fake_host's kind installs: good.tgz (home) or
# hgood.tgz (hetzner).
base_bundle() {
  if [ "${fake_host:-home}" = hetzner ]; then echo "$work/hgood.tgz"; else echo "$work/good.tgz"; fi
}

# A state with one verified release installed; refusals must leave it as it is.
# The first call per host kind installs it; later calls copy that state.
declare -A installed_template=() template_id=()
installed_state() {
  local host="${fake_host:-home}"
  if [ -z "${installed_template[$host]-}" ]; then
    new_state
    run_apply "$(base_bundle)" release || { cat "$work/out"; echo "FAIL the base release did not install"; exit 1; }
    installed_template[$host]="$state"
    template_id[$host]="$(current_release)"
  fi
  count=$((count + 1))
  state="$work/state$count"
  cp -a "${installed_template[$host]}" "$state"
  base_id="${template_id[$host]}"
  : >"$state/calls"
}

expect_untouched() {
  local name="$1"
  if grep -qE '^compose .* (pull|up)( |$)' "$state/calls" || grep -q '^login' "$state/calls"; then
    echo "FAIL the stacks were touched after a refusal: $name"; exit 1
  fi
  if grep -qE '^(stop|start) ' "$state/calls"; then
    echo "FAIL Watchtower was stopped or started after a refusal: $name"; exit 1
  fi
  [ "$(current_release)" = "$base_id" ] || { echo "FAIL current moved after a refusal: $name"; exit 1; }
  [ "$(find "$state/stack/releases" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ] || { echo "FAIL a release was left on disk after a refusal: $name"; exit 1; }
  [ -z "$(find "$state/stack" -maxdepth 1 -name '.incoming.*')" ] || { echo "FAIL the incoming bundle was left behind: $name"; exit 1; }
}

refused_bundle() {
  local name="$1" want="$2" bundle="$3"
  installed_state
  expect_refused "$name" "$want" "$bundle" release
  grep -q 'infra-apply: FAILED: ' "$work/out" || { cat "$work/out"; echo "FAIL no FAILED line: $name"; exit 1; }
  expect_untouched "$name"
}

unpack() {
  rm -rf "$2"
  mkdir -p "$2"
  tar -xzf "$1" -C "$2"
}

manifest() {
  local dir="$1"
  local -a files
  mapfile -t files < <(cd "$dir" && find . -type f ! -name manifest.sha256 -printf '%P\n' | LC_ALL=C sort)
  (cd "$dir" && sha256sum -- "${files[@]}") >"$dir/manifest.sha256"
}

# pack <dir> <out> [tar options]: file entries only, like build-bundle.sh.
pack() {
  local dir="$1" out="$2"
  shift 2
  local -a files
  mapfile -t files < <(cd "$dir" && find . -mindepth 1 ! -type d -printf '%P\n' | LC_ALL=C sort)
  tar --create --gzip --no-recursion --file "$out" --owner=0 --group=0 "$@" -C "$dir" -- "${files[@]}"
}

# variant <name>: unpack the good bundle into $work/<name> for editing; then
# repack <name> rewrites the manifest and packs it to $work/<name>.tgz.
variant() {
  unpack "$(base_bundle)" "$work/$1"
}
repack() {
  manifest "$work/$1"
  pack "$work/$1" "$work/$1.tgz"
}

### Bundles from the real templates

cat >"$work/deploy_key.pub" <<'KEY'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHarnessHarnessHarnessHarnessHarnessHarness01 infra-deploy-test
KEY
cat >"$work/vars.json" <<JSON
{
  "ghcr_username": "infra-bot",
  "ghcr_token": "ghp_HarnessToken0123456789",
  "postgres_superuser_password": "HarnessPgSuperuser0123456789abcdefA",
  "portfolio_db_password": "HarnessPortfolioDb0123456789abcdefAB",
  "portfolio_totp_encryption_key": "SGFybmVzc1RvdHBLZXkwMTIzNDU2Nzg5YWJjZGVmQUI=",
  "portfolio_admin_password": "harness-portfolio-admin",
  "portfolio_resend_api_key": "re_HarnessResendKey",
  "portfolio_google_client_id": "harness.apps.googleusercontent.com",
  "portfolio_google_client_secret": "HarnessGoogleSecret",
  "r2_account_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaa0001",
  "r2_access_key_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaa0002",
  "r2_secret_access_key": "cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc0003",
  "r2_public_bucket": "harness-public",
  "r2_private_bucket": "harness-private",
  "media_public_base": "https://media.example.com",
  "r2_backup_access_key_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaa0004",
  "r2_backup_secret_access_key": "cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc0005",
  "cf_origin_cert": "-----BEGIN CERTIFICATE-----\nSGFybmVzc09yaWdpbkNlcnRCb2R5MDEyMw==\n-----END CERTIFICATE-----",
  "cf_origin_key": "-----BEGIN PRIVATE KEY-----\nSGFybmVzc09yaWdpbktleUJvZHkwMTIzNA==\n-----END PRIVATE KEY-----",
  "home_tls_cf_dns_token": "HarnessHomeTlsDnsToken0123456789abcdefABCDEF",
  "beszel_password": "HarnessBeszelPassword0123",
  "beszel_agent_token": "harness-beszel-agent-token-0123456789",
  "garage_rpc_secret": "aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111",
  "garage_admin_token": "HarnessGarageAdmin0123456789abcdefAB",
  "garage_owner_access_key_id": "GKcccc3333cccc3333cccc3333",
  "garage_owner_secret_key": "bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222",
  "files_password": "HarnessFilesPassword0123",
  "home_owner_email": "owner@example.com",
  "home_secret_key": "SGFybmVzc0hvbWVTZWNyZXRLZXkwMTIzNDU2Nzg5YWI=",
  "home_data_key": "SGFybmVzc0hvbWVEYXRhS2V5MDEyMzQ1Njc4OWFiY2Q=",
  "home_resend_api_key": "HarnessHomeResendKey0123",
  "home_power_key": "$host_power_key",
  "home_tmdb_read_token": "eyJIb21lVG1kYg.eyJIYXJuZXNzVG1kYiI6MX0.SGFybmVzc1RtZGJTaWduYXR1cmU",
  "home_beszel_password": "",
  "deploy_key_file": "$work/deploy_key.pub"
}
JSON
secrets=(ghp_HarnessToken0123456789 HarnessPgSuperuser0123456789abcdefA
  HarnessPortfolioDb0123456789abcdefAB SGFybmVzc1RvdHBLZXkwMTIzNDU2Nzg5YWJjZGVmQUI= harness-portfolio-admin
  re_HarnessResendKey HarnessGoogleSecret aaaaaaaaaaaaaaaaaaaaaaaaaaaa0001 aaaaaaaaaaaaaaaaaaaaaaaaaaaa0002
  cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc0003 aaaaaaaaaaaaaaaaaaaaaaaaaaaa0004
  cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc0005 SGFybmVzc09yaWdpbkNlcnRCb2R5MDEyMw==
  SGFybmVzc09yaWdpbktleUJvZHkwMTIzNA== HarnessHomeTlsDnsToken0123456789abcdefABCDEF
  HarnessBeszelPassword0123 harness-beszel-agent-token-0123456789 aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111
  HarnessGarageAdmin0123456789abcdefAB GKcccc3333cccc3333cccc3333 bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222
  HarnessFilesPassword0123 SGFybmVzc0hvbWVTZWNyZXRLZXkwMTIzNDU2Nzg5YWI= SGFybmVzc0hvbWVEYXRhS2V5MDEyMzQ1Njc4OWFiY2Q=
  HarnessHomeResendKey0123 "$host_power_key" eyJIb21lVG1kYg.eyJIYXJuZXNzVG1kYiI6MX0.SGFybmVzc1RtZGJTaWduYXR1cmU)

# build [build-bundle.sh arguments]: renders the bundle of fake_host's kind (default home).
build() {
  "$root/build-bundle.sh" --host "${fake_host:-home}" "$@" >"$work/build.log" 2>&1
}

build "$work/vars.json" "$work/good.tgz" || { cat "$work/build.log"; echo "FAIL build-bundle.sh"; exit 1; }
no_secret_in "$work/build.log" "build-bundle.sh"
build "$work/vars.json" "$work/good-again.tgz" || { cat "$work/build.log"; echo "FAIL build-bundle.sh (second build)"; exit 1; }
cmp -s "$work/good.tgz" "$work/good-again.tgz" || { echo "FAIL build-bundle.sh is not deterministic"; exit 1; }
fake_host=hetzner build "$work/vars.json" "$work/hgood.tgz" || { cat "$work/build.log"; echo "FAIL build-bundle.sh --host hetzner"; exit 1; }
no_secret_in "$work/build.log" "build-bundle.sh --host hetzner"
echo "ok   bundle: two builds from the same vars are byte-identical"
for bundle in good hgood; do
  if tar -tvzf "$work/$bundle.tgz" | grep -qv '^-'; then tar -tvzf "$work/$bundle.tgz"; echo "FAIL the bundle holds entries other than regular files"; exit 1; fi
done
[ "$(tar -tzf "$work/good.tgz" | wc -l)" -eq 18 ] || { tar -tzf "$work/good.tgz"; echo "FAIL the home bundle does not hold exactly 18 files"; exit 1; }
[ "$(tar -tzf "$work/hgood.tgz" | wc -l)" -eq 11 ] || { tar -tzf "$work/hgood.tgz"; echo "FAIL the hetzner bundle does not hold exactly 11 files"; exit 1; }
tar -tzf "$work/good.tgz" | grep -qE '^(database|portfolio|edge)/' && { echo "FAIL the home bundle holds a hetzner stack"; exit 1; }
tar -tzf "$work/hgood.tgz" | grep -qE '^(ai|media|home)/' && { echo "FAIL the hetzner bundle holds a home stack"; exit 1; }
echo "ok   bundle: 18 file entries for home, 11 for hetzner, each only its own stacks, no directories"
unpack "$work/good.tgz" "$work/good"
unpack "$work/hgood.tgz" "$work/hgood"
grep -qxF "RELEASE_COMMIT=$(git -C "$root" rev-parse HEAD)" "$work/good/release.env" || { echo "FAIL release.env does not name the checked-out commit"; exit 1; }
grep -qx 'RELEASE_MODE=latest' "$work/good/release.env" || { echo "FAIL a plain build is not a latest release"; exit 1; }

# Each secret lands only in the env file of the container that reads it.
owner_of() {
  case "$1" in
    ghp_*) echo ghcr.env ;;
    HarnessPgSuperuser*) echo "database/postgres.env database/provision.sql" ;;
    HarnessPortfolioDb*) echo "database/provision.sql portfolio/portfolio.env" ;;
    *0001) echo "database/backup.env portfolio/portfolio.env" ;;
    *0004 | *0005) echo database/backup.env ;;
    SGFybmVzc09yaWdpbk*) echo edge/tls.yml ;;
    HarnessHomeTlsDns*) echo media/home-tls.env ;;
    HarnessBeszelPassword*) echo "media/beszel.env media/beszel-pair.env" ;;
    harness-beszel-agent-token*) echo "media/beszel-pair.env media/beszel-agent.env" ;;
    aaaa1111*) echo media/garage.env ;;
    HarnessGarageAdmin*) echo "media/garage.env media/garage-setup.env" ;;
    GKcccc3333* | bbbb2222*) echo "media/garage-setup.env media/sftpgo.env" ;;
    HarnessFilesPassword*) echo media/sftpgo.env ;;
    SGFybmVzc0hvbWV* | HarnessHomeResend* | eyJIb21lVG1kYg*) echo home/home-keys.env ;;
    *) echo portfolio/portfolio.env ;;
  esac
}
for secret in "${secrets[@]}"; do
  found="$({ (cd "$work/good" && grep -rlF -- "$secret" .) || true; (cd "$work/hgood" && grep -rlF -- "$secret" .) || true; } | sed 's,^\./,,' | LC_ALL=C sort -u | tr '\n' ' ')"
  want="$(owner_of "$secret" | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ')"
  [ "$found" = "$want" ] || { echo "FAIL a secret is in '$found', expected only '$want'"; exit 1; }
done
for file in hgood/portfolio/.env good/ai/.env good/media/.env good/home/.env; do
  if grep -vqE '^(PORTFOLIO_IMAGE|HOME_IMAGE|HOME_UID|HOME_GID|APEX_DOMAIN|WWW_DOMAIN|PREVIEW_DOMAIN|AI_UID|AI_GID|LLAMA_MODELS|MEDIA_UID|MEDIA_GID|HOME_DOMAIN|SERVER_NAME|ACME_EMAIL|STATUS_OWNER_EMAIL)=' "$work/$file"; then
    cat "$work/$file"; echo "FAIL $file holds more than image references, domains, the service accounts, the models and the contact addresses"; exit 1
  fi
done
grep -qx 'PREVIEW_DOMAIN=arbikullakshi.com' "$work/hgood/portfolio/.env" || { cat "$work/hgood/portfolio/.env"; echo "FAIL an empty preview_domain does not fall back to the apex"; exit 1; }
grep -qx 'RCLONE_S3_ENDPOINT=https://aaaaaaaaaaaaaaaaaaaaaaaaaaaa0001.r2.cloudflarestorage.com' "$work/hgood/database/backup.env" || { echo "FAIL backup.env does not name the account's R2 endpoint"; exit 1; }
if ! grep -q 'clientAuthType: RequireAndVerifyClientCert$' "$work/hgood/edge/tls.yml" || ! grep -q 'BEGIN CERTIFICATE' "$work/hgood/edge/tls.yml"; then
  echo "FAIL edge/tls.yml does not require Cloudflare's client certificate"; exit 1
fi
grep -qx 'LLAMA_MODELS=qwen3-8b:Qwen3-8B-Q5_K_M.gguf gemma-3-12b:gemma-3-12b-it-q4_0.gguf qwen3-14b:Qwen3-14B-Q4_K_M.gguf' "$work/good/ai/.env" ||
  { cat "$work/good/ai/.env"; echo "FAIL ai/.env does not list production.yml's home_ai_models for llama-server"; exit 1; }
grep -qx 'MEDIA_GID=2000' "$work/good/home/.env" || { cat "$work/good/home/.env"; echo "FAIL home/.env does not name the media group home-server joins"; exit 1; }
grep -q '^HOST_' "$work/good/media/.env" && { cat "$work/good/media/.env"; echo "FAIL media/.env names an https name besides Home's"; exit 1; }
grep -qx 'SERVER_NAME=infra-host' "$work/good/media/.env" || { cat "$work/good/media/.env"; echo "FAIL media/.env does not name the server for the tailnet addresses"; exit 1; }
for want in HOME_OWNER_EMAIL=owner@example.com HOME_PUBLIC_ORIGIN=https://home.arbikullakshi.com HOME_SECRET_KEY_FILE=/run/keys/secret_key \
  HOME_DATA_KEY_FILE=/run/keys/data_key HOME_SMTP_PASSWORD_FILE=/run/keys/smtp_password HOME_FILES_ROOT=/files HOME_FILES_CAPACITY=600G HOME_BESZEL_URL= \
  HOME_POWER_DIR=/run/power HOME_POWER_KEY_FILE=/run/keys/power_key HOME_MEDIA_FILMS=/data/media/films HOME_MEDIA_SERIES=/data/media/series \
  HOME_MEDIA_CACHE=/data/media-cache HOME_MEDIA_QUIET_HOURS=23:00-08:00 HOME_MEDIA_TIMEZONE=Europe/Berlin HOME_MEDIA_TRANSCODES=2 HOME_MEDIA_TRANSCODES_QUIET=1 \
  HOME_TMDB_READ_TOKEN_FILE=/run/keys/tmdb_read_token HOME_BOOKS_LIBRARY=/data/books HOME_AI_URL=http://llama:8080 \
  "HOME_AI_MODELS=qwen3-8b=Qwen3 8B|Fast everyday answers, any hour;gemma-3-12b=Gemma 3 12B|Writing and explaining, careful with kids;qwen3-14b=Qwen3 14B|Code and reasoning, by day only" \
  HOME_AI_DAY_ONLY_MODELS=qwen3-14b HOME_AI_DATABASE_PATH=/data/ai.db HOME_AI_QUIET_HOURS=23:00-08:00 HOME_AI_TIMEZONE=Europe/Berlin; do
  grep -qxF "$want" "$work/good/home/home-server.env" || { cat "$work/good/home/home-server.env"; echo "FAIL home/home-server.env lacks $want"; exit 1; }
done
grep -qx 'HOME_BESZEL_PASSWORD=' "$work/good/home/home-keys.env" || { echo "FAIL home-keys.env holds a Beszel password while production.yml names no Beszel user"; exit 1; }
grep -q 'HOME_WEB_APP_DIR' "$work/good/home/home-server.env" && { echo "FAIL home-server.env sets HOME_WEB_APP_DIR, which Home's image sets to its own /app"; exit 1; }
echo "ok   bundle: each secret is only in the env file of the container that reads it"

jq '.files_password = "HarnessFilesPasswordTwo0"' "$work/vars.json" >"$work/vars-second.json"
secrets+=(HarnessFilesPasswordTwo0)
build "$work/vars-second.json" "$work/second.tgz" || { cat "$work/build.log"; echo "FAIL build-bundle.sh (second release)"; exit 1; }
jq '.portfolio_admin_password = "second-admin-password"' "$work/vars.json" >"$work/vars-hsecond.json"
secrets+=(second-admin-password)
fake_host=hetzner build "$work/vars-hsecond.json" "$work/hsecond.tgz" || { cat "$work/build.log"; echo "FAIL build-bundle.sh (second hetzner release)"; exit 1; }

printf 'RELEASE_MODE=pinned\nPORTFOLIO_IMAGE=%s:%s@%s\n' "$portfolio_repo" "$(printf '1%.0s' $(seq 40))" "$(d 10)" >"$work/pins.env"
fake_host=hetzner build --pin "$work/pins.env" "$work/vars.json" "$work/pinned.tgz" || { cat "$work/build.log"; echo "FAIL build-bundle.sh --pin"; exit 1; }
unpack "$work/pinned.tgz" "$work/pinned"
grep -qx 'RELEASE_MODE=pinned' "$work/pinned/release.env" || { echo "FAIL a --pin build is not a pinned release"; exit 1; }
grep -qxF "PORTFOLIO_IMAGE=$portfolio_repo:$(printf '1%.0s' $(seq 40))@$(d 10)" "$work/pinned/portfolio/.env" || { echo "FAIL the portfolio pin is not in portfolio/.env"; exit 1; }
printf 'RELEASE_MODE=pinned\nHOME_IMAGE=%s:latest@%s\n' "$home_repo" "$(d 50)" >"$work/home-pins.env"
build --pin "$work/home-pins.env" "$work/vars.json" "$work/home-pinned.tgz" || { cat "$work/build.log"; echo "FAIL build-bundle.sh --pin of Home"; exit 1; }
unpack "$work/home-pinned.tgz" "$work/home-pinned"
grep -qxF "HOME_IMAGE=$home_repo:latest@$(d 50)" "$work/home-pinned/home/.env" || { echo "FAIL the Home pin is not in home/.env"; exit 1; }
echo "ok   bundle: --pin writes the pin into portfolio/.env (hetzner) and home/.env (home)"

pin_refused() {
  local name="$1" want="$2" body="$3"
  printf '%b' "$body" >"$work/bad-pins.env"
  rm -f "$work/refused.tgz"
  if build --pin "$work/bad-pins.env" "$work/vars.json" "$work/refused.tgz"; then echo "FAIL build-bundle.sh accepted $name"; exit 1; fi
  grep -qE -- "$want" "$work/build.log" || { cat "$work/build.log"; echo "FAIL build-bundle.sh refused $name for the wrong reason"; exit 1; }
  [ ! -e "$work/refused.tgz" ] || { echo "FAIL build-bundle.sh left a bundle behind: $name"; exit 1; }
  echo "ok   bundle refuses: $name"
}
pin_refused "a pins file without RELEASE_MODE" "must hold exactly" "HOME_IMAGE=$home_repo:latest@$(d 1)\n"
pin_refused "a pins file with an unpinned tag" "HOME_IMAGE is neither" "RELEASE_MODE=pinned\nHOME_IMAGE=$home_repo:v2\n"
pin_refused "a pins file that pins nothing" "pins no image to a digest" "RELEASE_MODE=pinned\nHOME_IMAGE=$home_repo:latest\n"
pin_refused "a pins file naming another repository" "names ghcr.io/evil/home-server" "RELEASE_MODE=pinned\nHOME_IMAGE=ghcr.io/evil/home-server:latest@$(d 1)\n"
pin_refused "a pins file that sets a key twice" "must hold exactly|exactly once" "RELEASE_MODE=pinned\nHOME_IMAGE=$home_repo:latest@$(d 1)\nHOME_IMAGE=$home_repo:latest@$(d 1)\n"
pin_refused "the other host's pins" "must set HOME_IMAGE exactly once" "RELEASE_MODE=pinned\nPORTFOLIO_IMAGE=$portfolio_repo:latest@$(d 1)\n"
rm -f "$work/refused.tgz"
if "$root/build-bundle.sh" --host crm "$work/vars.json" "$work/refused.tgz" >"$work/build.log" 2>&1; then echo "FAIL build-bundle.sh built for an unknown host"; exit 1; fi
grep -q 'usage: build-bundle.sh --host <home|hetzner>' "$work/build.log" || { cat "$work/build.log"; echo "FAIL build-bundle.sh refused an unknown host for the wrong reason"; exit 1; }
echo "ok   bundle refuses: an unknown host"

render_refused() {
  local name="$1" filter="$2"
  jq "$filter" "$work/vars.json" >"$work/bad-vars.json"
  rm -f "$work/refused.tgz"
  if build "$work/bad-vars.json" "$work/refused.tgz"; then echo "FAIL build-bundle.sh rendered $name"; exit 1; fi
  grep -q 'release.yml refused to render the bundle' "$work/build.log" || { cat "$work/build.log"; echo "FAIL build-bundle.sh refused $name for the wrong reason"; exit 1; }
  no_secret_in "$work/build.log" "build-bundle.sh refusing $name"
  [ ! -e "$work/refused.tgz" ] || { echo "FAIL build-bundle.sh left a bundle behind: $name"; exit 1; }
  echo "ok   bundle refuses: $name"
}
fake_host=hetzner
render_refused "a short database password" '.portfolio_db_password = "short"'
render_refused "two equal database passwords" '.portfolio_db_password = .postgres_superuser_password'
# shellcheck disable=SC2016 # a jq filter; the $$ is literal
render_refused "a value holding \$" '.portfolio_admin_password = "pa$$word"'
render_refused "a TOTP key that is not base64 of 32 bytes" '.portfolio_totp_encryption_key = "short"'
render_refused "no origin certificate" 'del(.cf_origin_cert)'
render_refused "an origin key that is not PEM" '.cf_origin_key = "not-a-key"'
render_refused "no R2 secret" 'del(.r2_secret_access_key)'
render_refused "one R2 key for the portfolio and its backups" '.r2_backup_access_key_id = .r2_access_key_id'
render_refused "one bucket for public and private media" '.r2_private_bucket = .r2_public_bucket'
render_refused "a media base that is not https" '.media_public_base = "http://media.example.com"'
jq 'with_entries(select(.key | test("^(home_|beszel_|garage_|files_)") | not))' "$work/vars.json" >"$work/vars-hetzner-only.json"
build "$work/vars-hetzner-only.json" "$work/hetzner-only.tgz" || { cat "$work/build.log"; echo "FAIL the hetzner bundle needs Home's secrets"; exit 1; }
unset fake_host
jq 'with_entries(select(.key | test("^(portfolio_|postgres_|r2_|media_public|cf_origin)") | not))' "$work/vars.json" >"$work/vars-home-only.json"
build "$work/vars-home-only.json" "$work/home-only.tgz" || { cat "$work/build.log"; echo "FAIL the home bundle needs the portfolio's secrets"; exit 1; }
echo "ok   bundle: each host needs only its own secrets"
render_refused "no Cloudflare DNS token for home-tls" 'del(.home_tls_cf_dns_token)'
render_refused "Home's name that is not a DNS name" '.home_domain = "home arbikullakshi"'
grep -q "home_domain must be a DNS name" "$work/build.log" || { cat "$work/build.log"; echo "FAIL a bad home_domain was refused for another reason"; exit 1; }
render_refused "a Cloudflare DNS token that is too short" '.home_tls_cf_dns_token = "short"'
render_refused "no Beszel password" 'del(.beszel_password)'
render_refused "a short Beszel password" '.beszel_password = "short"'
render_refused "a short Beszel agent token" '.beszel_agent_token = "short"'
render_refused "a Garage RPC secret that is not 64 hex digits" '.garage_rpc_secret = "HarnessNotHex0123456789abcdefABCDEF0123456789abcdefABCDEF01234567"'
render_refused "no Garage admin token" 'del(.garage_admin_token)'
render_refused "a Garage key ID that is not GK and 24 hex digits" '.garage_owner_access_key_id = "AKIAHARNESS0123456789"'
render_refused "a Garage secret key that is not 64 hex digits" '.garage_owner_secret_key = "short"'
render_refused "a files password shorter than 16 letters and digits" '.files_password = "short"'
render_refused "a files password with a symbol" '.files_password = "HarnessFilesPassword-0123"'
render_refused "no owner for Home (the HOME_OWNER_EMAIL variable unset)" '.home_owner_email = ""'
grep -q "HOME_OWNER_EMAIL repository variable" "$work/build.log" || { cat "$work/build.log"; echo "FAIL a missing Home owner was refused for another reason"; exit 1; }
render_refused "no Home secret key" 'del(.home_secret_key)'
render_refused "a Home data key that is not base64 of 32 bytes" '.home_data_key = "short"'
render_refused "the same key twice for Home" '.home_data_key = .home_secret_key'
render_refused "no Resend key for Home's mail" '.home_resend_api_key = ""'
render_refused "a Beszel user for Home without its password" '.home_beszel_user = "status@example.com"'
render_refused "a Home Files pool that is not a size" '.home_files_capacity = "lots"'
render_refused "TMDB's short API key instead of its Read Access Token" '.home_tmdb_read_token = "0123456789abcdef0123456789abcdef"'
grep -q "HOME_TMDB_READ_TOKEN, when" "$work/build.log" || { cat "$work/build.log"; echo "FAIL a short TMDB key was refused for another reason"; exit 1; }
# production.yml's home_ai_models as a jq literal, so a case changes one field of the real list.
ai_models="$(python3 -I -c 'import json, sys, yaml; print(json.dumps(yaml.safe_load(open(sys.argv[1]))["home_ai_models"]))' "$root/production.yml")"
render_refused "a day-only default AI model" ".home_ai_models = $ai_models | .home_ai_models[0].day_only = true"
grep -q "home_ai_models must be" "$work/build.log" || { cat "$work/build.log"; echo "FAIL a day-only default model was refused for another reason"; exit 1; }
render_refused "an AI model label that would split HOME_AI_MODELS" ".home_ai_models = $ai_models | .home_ai_models[1].label = \"Gemma; 12B\""
render_refused "an AI model whose file is not a GGUF" ".home_ai_models = $ai_models | .home_ai_models[2].file = \"../etc/passwd\""
render_refused "two AI models with one id" ".home_ai_models = $ai_models | .home_ai_models[1].id = \"qwen3-8b\""
render_refused "no HLS transcode allowed" '.home_media_transcodes = 0'
jq 'del(.home_tmdb_read_token)' "$work/vars.json" >"$work/vars-notmdb.json"
build "$work/vars-notmdb.json" "$work/notmdb.tgz" || { cat "$work/build.log"; echo "FAIL build-bundle.sh without a TMDB token"; exit 1; }
unpack "$work/notmdb.tgz" "$work/notmdb"
if ! grep -qx 'HOME_TMDB_READ_TOKEN=' "$work/notmdb/home/home-keys.env" || ! grep -qx 'HOME_TMDB_READ_TOKEN_FILE=' "$work/notmdb/home/home-server.env"; then
  echo "FAIL without a TMDB token Home is still pointed at a token file"; exit 1
fi
jq '.quiet_hours_enabled = false' "$work/vars.json" >"$work/vars-noquiet.json"
build "$work/vars-noquiet.json" "$work/noquiet.tgz" || { cat "$work/build.log"; echo "FAIL build-bundle.sh without quiet hours"; exit 1; }
unpack "$work/noquiet.tgz" "$work/noquiet"
if ! grep -qx 'HOME_AI_QUIET_HOURS=off' "$work/noquiet/home/home-server.env" || ! grep -qx 'HOME_MEDIA_QUIET_HOURS=' "$work/noquiet/home/home-server.env"; then
  cat "$work/noquiet/home/home-server.env"; echo "FAIL Home keeps quiet hours that production.yml turned off"; exit 1
fi
echo "ok   bundle: Home's TMDB token file only with a token; its quiet hours follow production.yml's"
jq '.home_beszel_user = "status@example.com" | .home_beszel_password = "HarnessHomeBeszel0123"' "$work/vars.json" >"$work/vars-beszel.json"
build "$work/vars-beszel.json" "$work/beszel.tgz" || { cat "$work/build.log"; echo "FAIL build-bundle.sh with a Beszel user for Home"; exit 1; }
no_secret_in "$work/build.log" "build-bundle.sh with a Beszel user for Home"
unpack "$work/beszel.tgz" "$work/beszel"
if ! grep -qx 'HOME_BESZEL_URL=http://beszel:8090' "$work/beszel/home/home-server.env" ||
  ! grep -qx 'HOME_BESZEL_USER=status@example.com' "$work/beszel/home/home-server.env" ||
  ! grep -qx 'HOME_BESZEL_PASSWORD=HarnessHomeBeszel0123' "$work/beszel/home/home-keys.env" ||
  grep -q HarnessHomeBeszel0123 "$work/beszel/home/home-server.env"; then
  echo "FAIL a Beszel user for Home does not turn on its Status card"; exit 1
fi
echo "ok   bundle: a Beszel user in production.yml turns on Home's Status card, its password only in home-keys.env"
printf 'REPLACE_ME_BEFORE_DEPLOYING\n' >"$work/placeholder.pub"
render_refused "the placeholder deploy key" ".deploy_key_file = \"$work/placeholder.pub\""

scratch="$work/scratch-repo"
mkdir "$scratch"
tar --exclude=.git --exclude=./cloudflare/down-page/target -C "$root" -cf - . | tar -xf - -C "$scratch"
sed -i 's,image: traefik:v3[^[:space:]]*,image: traefik:v3,' "$scratch/roles/edge/files/docker-compose.yml"
(
  cd "$scratch"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
  git init -q . && git add -A && git commit -qm "test(release): unpinned image"
)
if "$scratch/build-bundle.sh" --host home "$work/vars.json" "$work/refused.tgz" >"$work/build.log" 2>&1; then echo "FAIL build-bundle.sh accepted an unpinned third-party image"; exit 1; fi
grep -q 'roles/edge/files/docker-compose.yml runs traefik:v3, which is not pinned' "$work/build.log" || { cat "$work/build.log"; echo "FAIL wrong refusal for an unpinned image"; exit 1; }
echo "ok   bundle refuses: an unpinned third-party image"

### Accepted releases

new_state
expect_ok "the bundle build-bundle.sh renders from the real templates" "RELEASE OK: [0-9]{8}T[0-9]{6}Z-[0-9a-f]{12} is current, following :latest, auto-updates on$" "$work/good.tgz" release
first_id="$(current_release)"
for stack in ai media home; do
  grep -q "compose model accepted: .* in the $stack stack, no privileged settings" "$work/out" || { cat "$work/out"; echo "FAIL the checked-in $stack stack did not pass the compose guard"; exit 1; }
done
grep -qF "compose model accepted: 1 service(s) in the ai stack, no privileged settings, no host port but none on the tailnet, no bind mount but none, the GPU only for llama, no Docker socket" "$work/out" ||
  { cat "$work/out"; echo "FAIL the ai stack summary does not say it publishes nothing and gives the GPU to llama-server alone"; exit 1; }
grep -qF "compose model accepted: 9 service(s) in the media stack, no privileged settings, no host port but beszel $tailscale_ip:8090, garage $tailscale_ip:3900, home $tailscale_ip:80, home-tls $tailscale_ip:443, sftpgo $tailscale_ip:8091 on the tailnet, no bind mount but beszel-agent /srv/media/.beszel (ro), beszel-agent /srv/backup (ro), garage /srv/media/s3, the GPU only for beszel-agent, no Docker socket" "$work/out" ||
  { cat "$work/out"; echo "FAIL the media stack summary does not name its tailnet ports, its bind mounts and the GPU"; exit 1; }
grep -qF "compose model accepted: 2 service(s) in the home stack, no privileged settings, no host port but none on the tailnet, no bind mount but home-server /srv/media/home-files, home-server /run/home-power, home-server /srv/media/movies, home-server /srv/media/shows, the GPU only for home-server, no Docker socket, no extra group but home-server +media" "$work/out" ||
  { cat "$work/out"; echo "FAIL the home stack summary does not name its four bind mounts (Files, the power requests, the films and series), the GPU and the media group"; exit 1; }
echo "ok   the three checked-in home stacks pass the compose guard"
[ -f "$state/stack/releases/$first_id/.verified" ] || { echo "FAIL the release was not marked verified"; exit 1; }
for file in ghcr.env ai/.env media/.env media/home-tls.env media/beszel.env media/beszel-pair.env media/beszel-agent.env media/garage.env media/garage-setup.env media/sftpgo.env home/.env home/home-server.env home/home-keys.env manifest.sha256; do
  [ "$(stat -c %a "$state/stack/current/$file")" = 600 ] || { echo "FAIL $file is not 0600 in the release"; exit 1; }
done
[ "$(stat -c %a "$state/stack/current/home/docker-compose.yml")" = 644 ] || { echo "FAIL docker-compose.yml is not 0644"; exit 1; }
[ "$(cat "$state/login.stdin")" = ghp_HarnessToken0123456789 ] || { echo "FAIL docker login did not receive the token on stdin"; exit 1; }
grep -q '^login ghcr.io --username infra-bot --password-stdin$' "$state/calls" || { echo "FAIL docker login did not use the GHCR username"; exit 1; }
grep -q '^exec ' "$state/calls" && { echo "FAIL the home server ran psql"; exit 1; }
order="$(grep -nE '^compose .*/(ai|media|home) (pull --quiet|up -d.*)$' "$state/calls" | sed -E 's,^[0-9]+:,,; s,^compose .*/(ai|media|home) ,\1 ,')"
want_order="$(printf '%s\n' 'ai pull --quiet' 'media pull --quiet' 'home pull --quiet' 'ai up -d --remove-orphans' 'media up -d --remove-orphans' 'home up -d --remove-orphans')"
[ "$order" = "$want_order" ] || { printf '%s\n' "$order"; echo "FAIL the stacks did not start in the order ai, media, home"; exit 1; }
grep -qE '^compose --file [^ ]*/stack/current/home/docker-compose.yml' "$state/calls" || { echo "FAIL home did not start from the current link"; exit 1; }
grep -qE '^curl (route|mtls|public) ' "$state/calls" && { grep '^curl' "$state/calls"; echo "FAIL the home server checked a public route"; exit 1; }
[ ! -e "$state/edge/dynamic/tls.yml" ] || { echo "FAIL the home server wrote Traefik's TLS settings"; exit 1; }
grep -qF "infra-apply: the tailnet-only ports home:80 home-tls:443 beszel:8090 garage:3900 sftpgo:8091 are bound to $tailscale_ip alone" "$work/out" || { cat "$work/out"; echo "FAIL verify did not read back the tailnet-only port"; exit 1; }
grep -qxF "curl tls home.arbikullakshi.com:443:$tailscale_ip https://home.arbikullakshi.com/healthz" "$state/calls" || { grep '^curl' "$state/calls"; echo "FAIL verify did not ask home-tls for Home's /healthz on the tailnet address"; exit 1; }
grep -q '^curl tls [a-z0-9]*\.home\.' "$state/calls" && { grep '^curl' "$state/calls"; echo "FAIL verify asked home-tls for a name under Home's"; exit 1; }
grep -qF "infra-apply: home-tls serves https with a trusted certificate on $tailscale_ip for home.arbikullakshi.com, and Home's web app at https://home.arbikullakshi.com/app/" "$work/out" || { cat "$work/out"; echo "FAIL verify did not report home-tls's certificate for every name and Home's web app"; exit 1; }
grep -qxF "curl tls home.arbikullakshi.com:443:$tailscale_ip https://home.arbikullakshi.com/app/" "$state/calls" || { grep '^curl' "$state/calls"; echo "FAIL verify did not ask home-tls for Home's web app on the tailnet address"; exit 1; }
[ ! -e "$state/stack/previous" ] || { echo "FAIL a first release has no previous release"; exit 1; }
printf '%s\n' "home-server=$home_repo@$(d 51)" |
  cmp -s - "$state/stack/current/running-images.env" || { cat "$state/stack/current/running-images.env"; echo "FAIL running-images.env does not record the running digests"; exit 1; }
echo "ok   a first home release pulls, starts ai, media, home in order, checks the tailnet ports and home-tls, and records the running digest"

# watchtower_order <name> [steps]: Watchtower was stopped before the first pull,
# started after the last app `up` and before verify read its logs, and runs again.
watchtower_order() {
  local name="$1" want="${2:-stop pull up start logs}" got
  got="$(grep -nE '^stop --time [0-9]+ watchtower$|^start watchtower$|^compose .* pull --quiet$|^compose .*/(home|portfolio) up |^logs --since .* watchtower$' "$state/calls" |
    sed -E 's,^[0-9]+:,,; s,^stop .*,stop,; s,^start .*,start,; s,^compose .* pull .*,pull,; s,^compose .* up .*,up,; s,^logs .*,logs,' | uniq)"
  [ "$got" = "$(tr ' ' '\n' <<<"$want")" ] || { printf '%s\n' "$got"; echo "FAIL Watchtower was not stopped from the pull to the app up: $name"; exit 1; }
  [ "$(cat "$state/running/watchtower")" = "true false" ] || { echo "FAIL Watchtower does not run after: $name"; exit 1; }
}
watchtower_order "a first release"
echo "ok   Watchtower is stopped from the first pull until the app stacks are up, then started before verify"

running_image home-server "$home_repo:latest" 52
sleep 1
expect_ok "a second release keeps the first as the previous release" "following :latest, auto-updates on; $first_id is kept as the previous release" "$work/second.tgz" release
second_id="$(current_release)"
[ "$second_id" != "$first_id" ] || { echo "FAIL the second release reused the first id"; exit 1; }
[ "$(readlink "$state/stack/previous")" = "releases/$first_id" ] || { echo "FAIL previous does not point at the first release"; exit 1; }
grep -q '^FILES_PASSWORD=HarnessFilesPasswordTwo0$' "$state/stack/current/media/sftpgo.env" || { echo "FAIL current is not the second release"; exit 1; }

running_image home-server "$home_repo:latest@$(d 50)" 50
sleep 1
expect_ok "a pinned release" "RELEASE OK: .* is current, pinned \\(HOME_IMAGE\\), auto-updates paused for them; $second_id is kept as the previous release" "$work/home-pinned.tgz" release
pinned_id="$(current_release)"
[ "$(find "$state/stack/releases" -mindepth 1 -maxdepth 1 | wc -l)" -eq 2 ] || { echo "FAIL old releases were not pruned"; exit 1; }
[ ! -e "$state/stack/releases/$first_id" ] || { echo "FAIL the oldest release was kept"; exit 1; }

printf '%s\n' "$(d 50) 2026-10-12 10:00:00 +0000 UTC" "$(d 52) 2026-10-01 10:00:00 +0000 UTC" "<none> 2026-09-01 10:00:00 +0000 UTC" "$(d 52) 2026-10-01 10:00:00 +0000 UTC" >"$state/known/$(printf '%s' "$home_repo" | tr / _)"
expect_ok "status after a pinned release" "current release: $pinned_id \\(verified\\), pinned \\(HOME_IMAGE\\), auto-updates paused for them" /dev/null status
for want in \
  "infra-apply: previous release: $second_id (verified), following :latest, auto-updates on" \
  "infra-apply: image home-server ref=$home_repo:latest@$(d 50) digest=$(d 50) created=" \
  "infra-apply: known $home_repo digest=$(d 50) created=2026-10-12 10:00:00 +0000 UTC" \
  "infra-apply: known $home_repo digest=$(d 52) created=2026-10-01 10:00:00 +0000 UTC" \
  "infra-apply: recorded $pinned_id home-server=$home_repo@$(d 50)" \
  "infra-apply: recorded $second_id home-server=$home_repo@$(d 52)" \
  "NAME IMAGE STATUS (home)"; do
  grep -qF -- "$want" "$work/out" || { cat "$work/out"; echo "FAIL status does not print: $want"; exit 1; }
done
[ "$(grep -c "known $home_repo " "$work/out")" -eq 2 ] || { cat "$work/out"; echo "FAIL status lists a known digest twice or lists <none>"; exit 1; }
[ "$(grep -n "known $home_repo digest=$(d 50)" "$work/out" | cut -d: -f1)" -lt "$(grep -n "known $home_repo digest=$(d 52)" "$work/out" | cut -d: -f1)" ] || { echo "FAIL known digests are not newest first"; exit 1; }
echo "ok   status prints both releases, image, known and recorded lines"

### The hetzner host: database, provision.sql, portfolio, Traefik's TLS settings, the public routes

fake_host=hetzner
new_state
expect_ok "the hetzner bundle build-bundle.sh renders from the real templates" "RELEASE OK: [0-9]{8}T[0-9]{6}Z-[0-9a-f]{12} is current, following :latest, auto-updates on$" "$work/hgood.tgz" release
hfirst_id="$(current_release)"
for stack in database portfolio; do
  grep -q "compose model accepted: .* in the $stack stack, no privileged settings" "$work/out" || { cat "$work/out"; echo "FAIL the checked-in $stack stack did not pass the compose guard"; exit 1; }
done
for file in ghcr.env edge/tls.yml database/postgres.env database/provision.sql database/backup.env portfolio/.env portfolio/portfolio.env manifest.sha256; do
  [ "$(stat -c %a "$state/stack/current/$file")" = 600 ] || { echo "FAIL $file is not 0600 in the release"; exit 1; }
done
cmp -s "$state/psql.stdin" "$work/hgood/database/provision.sql" || { echo "FAIL provision.sql was not fed to psql"; exit 1; }
cmp -s "$state/edge/dynamic/tls.yml" "$work/hgood/edge/tls.yml" || { echo "FAIL edge/tls.yml was not installed for Traefik"; exit 1; }
[ "$(stat -c %a "$state/edge/dynamic/tls.yml")" = 600 ] || { echo "FAIL Traefik's tls.yml is not 0600"; exit 1; }
order="$(grep -nE '^compose .*/(database|portfolio) (pull --quiet|up -d.*)$|^exec -i postgresql psql -v ON_ERROR_STOP=1 -U postgres -d postgres$' "$state/calls" | sed -E 's,^[0-9]+:,,; s,^compose .*/(database|portfolio) ,\1 ,; s,^exec .*,psql,')"
want_order="$(printf '%s\n' 'database pull --quiet' 'portfolio pull --quiet' 'database up -d --wait --remove-orphans' psql 'portfolio up -d --remove-orphans')"
[ "$order" = "$want_order" ] || { printf '%s\n' "$order"; echo "FAIL the stacks did not start in the order database, provision.sql, portfolio"; exit 1; }
for want in "curl route arbikullakshi.com http://172.18.0.2:80/api/health" "curl route www.arbikullakshi.com http://172.18.0.2:80/" \
  "curl mtls arbikullakshi.com:443:172.18.0.2 https://arbikullakshi.com/api/health" "curl mtls www.arbikullakshi.com:443:172.18.0.2 https://www.arbikullakshi.com/"; do
  grep -qxF "$want" "$state/calls" || { grep '^curl' "$state/calls"; echo "FAIL verify did not check: $want"; exit 1; }
done
[ "$(grep -c '^curl \(route\|mtls\) ' "$state/calls")" -eq 4 ] || { grep '^curl' "$state/calls"; echo "FAIL verify checked more than the two names"; exit 1; }
[ "$(grep -c '^curl public ' "$state/calls")" -eq 3 ] || { grep '^curl' "$state/calls"; echo "FAIL the public check asked other than the two routes and the http redirect"; exit 1; }
grep -qE '^curl tls ' "$state/calls" && { echo "FAIL the hetzner host asked for home-tls"; exit 1; }
printf '%s\n' "portfolio=$portfolio_repo@$(d 11)" | cmp -s - "$state/stack/current/running-images.env" ||
  { cat "$state/stack/current/running-images.env"; echo "FAIL running-images.env does not record the running digest"; exit 1; }
watchtower_order "a first hetzner release"
echo "ok   a first hetzner release starts database, provision.sql, portfolio in order, installs Traefik's TLS settings, checks the redirect and the refused handshake, and asks Cloudflare"

running_image portfolio "$portfolio_repo:latest" 12
sleep 1
expect_ok "a second hetzner release" "$hfirst_id is kept as the previous release" "$work/hsecond.tgz" release
grep -q '^ADMIN_PASSWORD=second-admin-password$' "$state/stack/current/portfolio/portfolio.env" || { echo "FAIL current is not the second release"; exit 1; }
running_image portfolio "$portfolio_repo:$(printf '1%.0s' $(seq 40))@$(d 10)" 10
sleep 1
expect_ok "a pinned hetzner release" "RELEASE OK: .* is current, pinned \\(PORTFOLIO_IMAGE\\), auto-updates paused for them" "$work/pinned.tgz" release

new_state
printf '000' >"$state/curl.arbikullakshi.com"
echo 7 >"$state/curl.arbikullakshi.com.rc"
expect_refused "Traefik refuses the connection" "Traefik answered 000 on http for arbikullakshi\\.com/api/health, expected a redirect to https" "$work/hgood.tgz" release
[ ! -e "$state/stack/current/.verified" ] || { echo "FAIL a release Traefik did not answer for was marked verified"; exit 1; }

new_state
printf '200' >"$state/curl.www.arbikullakshi.com"
expect_refused "plain http served instead of redirected" "Traefik answered 200 on http for www\\.arbikullakshi\\.com/, expected a redirect to https" "$work/hgood.tgz" release

new_state
printf '200' >"$state/curl.mtls.arbikullakshi.com"
echo 0 >"$state/curl.mtls.arbikullakshi.com.rc"
expect_refused "https served without Cloudflare's client certificate" "Traefik answered 200 \\(curl exit 0\\) on https for arbikullakshi\\.com/api/health without a client certificate; it must refuse the TLS handshake" "$work/hgood.tgz" release
[ ! -e "$state/stack/current/.verified" ] || { echo "FAIL a release without Authenticated Origin Pulls was marked verified"; exit 1; }

new_state
echo 7 >"$state/curl.mtls.www.arbikullakshi.com.rc"
expect_refused "https not answering at all" "Traefik answered 000 \\(curl exit 7\\) on https for www\\.arbikullakshi\\.com/" "$work/hgood.tgz" release

for rc in 35 55; do
  new_state
  echo "$rc" >"$state/curl.mtls.arbikullakshi.com.rc"
  expect_ok "the handshake refused with curl exit $rc" "Traefik redirects http to https and refuses https without Cloudflare's client certificate" "$work/hgood.tgz" release
done

new_state
rm "$state/ip/edge-traefik"
expect_refused "a Traefik with no edge address" "edge-traefik has no address on the edge network" "$work/hgood.tgz" release

new_state
rmdir "$state/edge/dynamic"
expect_refused "a Traefik whose TLS settings directory was never provisioned" "edge/dynamic does not exist; run provisioning with --tags edge" "$work/hgood.tgz" release
echo "ok   verify requires the redirect to https and the refused handshake from Traefik"

new_state
expect_ok "the public check asks every route by name through Cloudflare" "Cloudflare serves https://arbikullakshi\\.com/api/health https://www\\.arbikullakshi\\.com/ http://arbikullakshi\\.com/api/health$" "$work/hgood.tgz" release

new_state
printf '403' >"$state/curl.public.https.arbikullakshi.com"
expect_refused "Cloudflare blocks a public route" "https://arbikullakshi\.com/api/health answered 403 through Cloudflare, expected .*the release itself is current and verified on the host" "$work/hgood.tgz" release
[ -e "$state/stack/current/.verified" ] || { echo "FAIL a release that passed on the host was not marked verified when only Cloudflare failed"; exit 1; }
if grep -q "A rollback cannot fix\|Run the Deploy workflow with action rollback" "$work/out"; then cat "$work/out"; echo "FAIL a Cloudflare-side failure suggested a rollback"; exit 1; fi

new_state
printf '200' >"$state/curl.public.http.arbikullakshi.com"
expect_refused "plain http served instead of redirected to https" "http://arbikullakshi\.com/api/health answered 200 through Cloudflare, expected \^30\[18\]\\\$; the release" "$work/hgood.tgz" release
echo "ok   the public check requires each route's status through Cloudflare, after the host verified the release"
unset fake_host

new_state
expect_ok "status with no release installed" "no release is installed" /dev/null status

new_state
printf '000' >"$state/curl.tls.home.arbikullakshi.com"
echo 60 >"$state/curl.tls.home.arbikullakshi.com.rc"
expect_refused "home-tls without a trusted certificate" "https://home\\.arbikullakshi\\.com/healthz on $tailscale_ip answered 000, expected 200 with a trusted certificate \\(000: no certificate for it yet: HOME_TLS_CF_DNS_TOKEN" "$work/good.tgz" release
[ ! -e "$state/stack/current/.verified" ] || { echo "FAIL a release whose links page has no certificate was marked verified"; exit 1; }
grep -q '^curl public ' "$state/calls" && { echo "FAIL the public hosts were asked before home-tls had its certificate"; exit 1; }

new_state
printf '502' >"$state/curl.tls.home.arbikullakshi.com"
expect_refused "home-tls that cannot reach home-server" "https://home\\.arbikullakshi\\.com/healthz on $tailscale_ip answered 502" "$work/good.tgz" release

new_state
printf '404' >"$state/curl.tls.home.arbikullakshi.com"
expect_refused "Home's name answering 404" "https://home\\.arbikullakshi\\.com/healthz on $tailscale_ip answered 404" "$work/good.tgz" release

new_state
printf '404' >"$state/curl.tls-app.home.arbikullakshi.com"
expect_refused "a Home image without its web app" "https://home\\.arbikullakshi\\.com/app/ on $tailscale_ip answered 404, expected 200: Home's web app" "$work/good.tgz" release
[ ! -e "$state/stack/current/.verified" ] || { echo "FAIL a release without Home's web app was marked verified"; exit 1; }
echo "ok   verify requires https://home.arbikullakshi.com/healthz from home-server with a trusted certificate on the Tailscale address"

new_state
tailnet_binding sftpgo 8091 0.0.0.0
expect_refused "the file manager bound to every interface" "sftpgo publishes .*0\\.0\\.0\\.0.*, expected only $tailscale_ip:8091" "$work/good.tgz" release
[ ! -e "$state/stack/current/.verified" ] || { echo "FAIL a release with a port off the tailnet was marked verified"; exit 1; }
new_state
printf '{"8091/tcp":[{"HostIp":"%s","HostPort":"8091"}],"9090/tcp":[{"HostIp":"%s","HostPort":"9090"}]}\n' "$tailscale_ip" "$tailscale_ip" >"$state/ports/sftpgo"
expect_refused "the file manager with a second binding" "sftpgo publishes .*9090.*, expected only" "$work/good.tgz" release
new_state
tailnet_binding beszel 8090 192.168.1.50
expect_refused "the status dashboard on the LAN address" "beszel publishes .*192\\.168\\.1\\.50.*, expected only $tailscale_ip:8090" "$work/good.tgz" release
new_state
rm "$state/ports/garage"
expect_refused "S3 not published at all" "garage publishes \\{\\}, expected only $tailscale_ip:3900" "$work/good.tgz" release
echo "ok   verify requires each tailnet-only port bound to the Tailscale address alone"

### Refused before anything changes

: >"$work/empty"
refused_bundle "an empty stdin" "no bundle arrived" "$work/empty"
head -c 1048577 /dev/urandom >"$work/big"
refused_bundle "a bundle over 1 MiB" "larger than 1048576 bytes" "$work/big"
printf 'not a tarball\n' >"$work/garbage"
refused_bundle "a bundle that is not gzip" "not a gzip-compressed tar archive" "$work/garbage"

variant extra
printf 'set -eu\n' >"$work/extra/home/extra.sh"
repack extra
refused_bundle "an unexpected entry" "unexpected entry: home/extra\\.sh" "$work/extra.tgz"
fake_host=hetzner
refused_bundle "a home bundle sent to the hetzner host" "unexpected entry: (ai|home|media)/" "$work/good.tgz"
unset fake_host
refused_bundle "a hetzner bundle sent to the home server" "unexpected entry: (database|edge|portfolio)/" "$work/hgood.tgz"

variant traversal
manifest "$work/traversal"
pack "$work/traversal" "$work/traversal.tgz" -P --transform 's,^ghcr.env$,../ghcr.env,'
refused_bundle "a path traversal entry" "unexpected entry: \\.\\./ghcr\\.env" "$work/traversal.tgz"

variant absolute
manifest "$work/absolute"
pack "$work/absolute" "$work/absolute.tgz" -P --transform 's,^ghcr.env$,/etc/cron.d/ghcr,'
refused_bundle "an absolute path entry" "unexpected entry: /etc/cron\\.d/ghcr" "$work/absolute.tgz"

variant symlink
rm "$work/symlink/home/home-server.env"
ln -s /etc/passwd "$work/symlink/home/home-server.env"
manifest "$work/symlink" 2>/dev/null || true
pack "$work/symlink" "$work/symlink.tgz"
refused_bundle "a symlink entry" "home/home-server\\.env is not a regular file" "$work/symlink.tgz"

variant hardlink
rm "$work/hardlink/media/sftpgo.env"
ln "$work/hardlink/home/home-server.env" "$work/hardlink/media/sftpgo.env"
repack hardlink
refused_bundle "a hard link entry" "is not a regular file" "$work/hardlink.tgz"

variant withdir
manifest "$work/withdir"
(cd "$work/withdir" && tar --create --gzip --file "$work/withdir.tgz" --owner=0 --group=0 manifest.sha256 release.env ghcr.env ai media home)
refused_bundle "a directory entry" "unexpected entry: ai/" "$work/withdir.tgz"

variant duplicate
manifest "$work/duplicate"
mapfile -t files < <(cd "$work/duplicate" && find . -type f -printf '%P\n' | LC_ALL=C sort)
(cd "$work/duplicate" && tar --create --file "$work/duplicate.tar" --no-recursion -- "${files[@]}" && tar --append --file "$work/duplicate.tar" ghcr.env)
gzip -c "$work/duplicate.tar" >"$work/duplicate.tgz"
refused_bundle "an entry named twice" "more than once" "$work/duplicate.tgz"

variant missing
rm "$work/missing/home/home-keys.env"
repack missing
refused_bundle "a missing file" "missing home/home-keys\\.env" "$work/missing.tgz"

variant large
head -c 300000 /dev/zero | tr '\0' 'a' >"$work/large/media/sftpgo.env"
repack large
refused_bundle "a file over 256 KiB" "did not extract cleanly|larger than 262144 bytes" "$work/large.tgz"

variant tampered
manifest "$work/tampered"
printf 'EXTRA=1\n' >>"$work/tampered/home/home-server.env"
pack "$work/tampered" "$work/tampered.tgz"
refused_bundle "a checksum mismatch" "does not match its manifest\\.sha256 checksum" "$work/tampered.tgz"

variant short
manifest "$work/short"
grep -v ' media/sftpgo.env$' "$work/short/manifest.sha256" >"$work/short/manifest.new"
mv "$work/short/manifest.new" "$work/short/manifest.sha256"
pack "$work/short" "$work/short.tgz"
refused_bundle "a manifest that leaves a file out" "does not list exactly the files" "$work/short.tgz"

variant outside
manifest "$work/outside"
printf '%064d  ../../etc/passwd\n' 0 >>"$work/outside/manifest.sha256"
pack "$work/outside" "$work/outside.tgz"
refused_bundle "a manifest that names an extra file" "names an unexpected file" "$work/outside.tgz"

variant badenv
printf 'export EVIL=1\n' >>"$work/badenv/media/sftpgo.env"
repack badenv
refused_bundle "an env line that is not KEY=value" "media/sftpgo\\.env line $(wc -l <"$work/badenv/media/sftpgo.env") is not KEY=value" "$work/badenv.tgz"

variant comment
sed -i '1i # a comment' "$work/comment/home/.env"
repack comment
refused_bundle "an env comment line" "home/\\.env line 1 is not KEY=value" "$work/comment.tgz"

variant badghcr
printf 'GHCR_USERNAME=infra-bot\nGHCR_TOKEN=x\nGHCR_EXTRA=1\n' >"$work/badghcr/ghcr.env"
repack badghcr
refused_bundle "ghcr.env with an extra key" "must set exactly GHCR_USERNAME and GHCR_TOKEN" "$work/badghcr.tgz"

fake_host=hetzner
variant badbackup
printf 'RCLONE_CONFIG=/etc/passwd\n' >>"$work/badbackup/database/backup.env"
repack badbackup
refused_bundle "backup.env with an extra key" "database/backup\\.env must set exactly RCLONE_S3_PROVIDER RCLONE_S3_ENDPOINT RCLONE_S3_ACCESS_KEY_ID RCLONE_S3_SECRET_ACCESS_KEY" "$work/badbackup.tgz"
variant badendpoint
sed -i 's,^RCLONE_S3_ENDPOINT=.*,RCLONE_S3_ENDPOINT=https://evil.example.com,' "$work/badendpoint/database/backup.env"
repack badendpoint
refused_bundle "backup.env pointing the dump elsewhere" "database/backup\\.env must set exactly" "$work/badendpoint.tgz"
variant badtls
sed -i '/clientAuthType/d' "$work/badtls/edge/tls.yml"
repack badtls
refused_bundle "tls.yml without the client-certificate rule" "edge/tls\\.yml does not hold the origin certificate and the client-certificate rule" "$work/badtls.tgz"
variant notls
rm "$work/notls/edge/tls.yml"
repack notls
refused_bundle "a hetzner bundle without tls.yml" "missing edge/tls\\.yml" "$work/notls.tgz"
unset fake_host

variant badhometls
printf 'CF_DNS_API_TOKEN=HarnessHomeTlsDnsToken0123456789abcdefABCDEF\nCF_API_EMAIL=x\n' >"$work/badhometls/media/home-tls.env"
repack badhometls
refused_bundle "home-tls.env with an extra key" "media/home-tls\\.env must set exactly CF_DNS_API_TOKEN" "$work/badhometls.tgz"

variant badgarage
printf 'GARAGE_RPC_SECRET=aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111\nGARAGE_ADMIN_TOKEN=HarnessGarageAdmin0123456789abcdefAB\nGARAGE_CONFIG_FILE=/etc/passwd\n' >"$work/badgarage/media/garage.env"
repack badgarage
refused_bundle "garage.env with an extra key" "media/garage\\.env must set exactly GARAGE_RPC_SECRET GARAGE_ADMIN_TOKEN" "$work/badgarage.tgz"

variant badbeszel
printf 'TOKEN=harness-beszel-agent-token-0123456789\nDOCKER_HOST=unix:///var/run/docker.sock\n' >"$work/badbeszel/media/beszel-agent.env"
repack badbeszel
refused_bundle "beszel-agent.env with an extra key" "media/beszel-agent\\.env must set exactly TOKEN" "$work/badbeszel.tgz"

variant badgaragekey
printf 'GARAGE_ADMIN_TOKEN=HarnessGarageAdmin0123456789abcdefAB\nOWNER_ACCESS_KEY_ID=AKIAHARNESS\nOWNER_SECRET_ACCESS_KEY=bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222\n' >"$work/badgaragekey/media/garage-setup.env"
repack badgaragekey
refused_bundle "garage-setup.env with a malformed key ID" "media/garage-setup\\.env must set exactly GARAGE_ADMIN_TOKEN OWNER_ACCESS_KEY_ID OWNER_SECRET_ACCESS_KEY" "$work/badgaragekey.tgz"

variant badhomekeys
printf 'HOME_SECRET_KEY=SGFybmVzc0hvbWVTZWNyZXRLZXkwMTIzNDU2Nzg5YWI=\nHOME_DATA_KEY=SGFybmVzc0hvbWVEYXRhS2V5MDEyMzQ1Njc4OWFiY2Q=\nHOME_SMTP_PASSWORD=HarnessHomeResendKey0123\nHOME_BESZEL_PASSWORD=\nHOME_POWER_KEY=\nHOME_DATABASE_PATH=/etc/passwd\n' >"$work/badhomekeys/home/home-keys.env"
repack badhomekeys
refused_bundle "home-keys.env with an extra key" "home/home-keys\\.env must set exactly HOME_SECRET_KEY HOME_DATA_KEY HOME_SMTP_PASSWORD HOME_BESZEL_PASSWORD HOME_POWER_KEY HOME_TMDB_READ_TOKEN" "$work/badhomekeys.tgz"
variant badtmdb
sed -i 's,^HOME_TMDB_READ_TOKEN=.*,HOME_TMDB_READ_TOKEN=0123456789abcdef0123456789abcdef,' "$work/badtmdb/home/home-keys.env"
repack badtmdb
refused_bundle "a TMDB API key where the Read Access Token belongs" "home/home-keys\\.env must set exactly .* HOME_TMDB_READ_TOKEN" "$work/badtmdb.tgz"

# The power key: the bundle's must be the one provisioning made on the host, or none.
variant powerkey
sed -i 's,^HOME_POWER_KEY=.*,HOME_POWER_KEY=SGFybmVzc090aGVyUG93ZXJLZXkwMTIzNDU2Nzg5YWI=,' "$work/powerkey/home/home-keys.env"
repack powerkey
refused_bundle "a power key that is not the host's" "HOME_POWER_KEY is not this host's power key \\(.*/home-power\\.key\\); set the secret to it" "$work/powerkey.tgz"
installed_state
rm "$state/home-power.key"
expect_refused "a power key on a host provisioning has not made one on" "HOME_POWER_KEY is set, but this host has no .*/home-power\\.key yet; provision with --tags host first" "$work/good.tgz" release
expect_untouched "a power key on a host without one"
variant nopowerkey
sed -i 's,^HOME_POWER_KEY=.*,HOME_POWER_KEY=,' "$work/nopowerkey/home/home-keys.env"
repack nopowerkey
installed_state
rm "$state/home-power.key"
expect_ok "no power key, and none on the host: Home's power control off" "RELEASE OK" "$work/nopowerkey.tgz" release
variant badpowerkey
sed -i 's,^HOME_POWER_KEY=.*,HOME_POWER_KEY=not-a-key,' "$work/badpowerkey/home/home-keys.env"
repack badpowerkey
refused_bundle "a malformed power key" "home/home-keys\\.env must set exactly .* HOME_POWER_KEY" "$work/badpowerkey.tgz"

release_env_case() {
  local name="$1" want="$2" body="$3"
  variant relenv
  printf '%b' "$body" >"$work/relenv/release.env"
  repack relenv
  refused_bundle "$name" "$want" "$work/relenv.tgz"
}
commit_one=1111111111111111111111111111111111111111
release_env_case "release.env with an unknown mode" "RELEASE_MODE must be latest or pinned" "RELEASE_MODE=paused\nRELEASE_COMMIT=$commit_one\n"
release_env_case "release.env with a short commit" "RELEASE_COMMIT is not a full commit sha" "RELEASE_MODE=latest\nRELEASE_COMMIT=1111111\n"
release_env_case "release.env with an extra key" "must set exactly RELEASE_MODE and RELEASE_COMMIT" "RELEASE_MODE=latest\nRELEASE_COMMIT=$commit_one\nAUTO=1\n"
release_env_case "release.env naming a key twice" "must set exactly RELEASE_MODE and RELEASE_COMMIT" "RELEASE_MODE=latest\nRELEASE_MODE=latest\n"
release_env_case "a pinned release without a digest" "a pinned release must pin at least one image" "RELEASE_MODE=pinned\nRELEASE_COMMIT=$commit_one\n"

variant latestdigest
sed -i "s,^HOME_IMAGE=.*,HOME_IMAGE=$home_repo:latest@$(d 1)," "$work/latestdigest/home/.env"
repack latestdigest
refused_bundle "a latest release with a digest" "HOME_IMAGE must be $home_repo:latest in a latest release" "$work/latestdigest.tgz"

unpack "$work/home-pinned.tgz" "$work/pinnedtag"
sed -i "s,^HOME_IMAGE=.*,HOME_IMAGE=$home_repo:v2," "$work/pinnedtag/home/.env"
repack pinnedtag
refused_bundle "a pinned release with a moving tag" "HOME_IMAGE must be $home_repo:latest or" "$work/pinnedtag.tgz"

variant otherrepo
sed -i "s,^HOME_IMAGE=.*,HOME_IMAGE=ghcr.io/evil/home-server:latest," "$work/otherrepo/home/.env"
repack otherrepo
refused_bundle "an app image from another repository" "HOME_IMAGE runs ghcr\\.io/evil/home-server:latest, not an image of $home_repo" "$work/otherrepo.tgz"

fake_host=hetzner
variant twice
printf 'PORTFOLIO_IMAGE=%s:latest\n' "$portfolio_repo" >>"$work/twice/portfolio/.env"
repack twice
refused_bundle "an image key set twice" "must set PORTFOLIO_IMAGE exactly once" "$work/twice.tgz"
unset fake_host

installed_state
echo 1 >"$state/config.rc"
expect_refused "a compose file docker compose rejects" "docker compose rejects ai/docker-compose\\.yml" "$work/good.tgz" release
expect_untouched "a compose file docker compose rejects"

installed_state
exec 8>"$state/stack/.lock"
flock -n 8
expect_refused "a release while the lock is held" "another release or status is running" "$work/good.tgz" release
expect_untouched "a release while the lock is held"
exec 8>&-

installed_state
echo 1 >"$state/login.rc"
expect_refused "a refused registry login" "docker login to ghcr.io was refused" "$work/good.tgz" release
[ "$(current_release)" = "$base_id" ] || { echo "FAIL a refused login moved current"; exit 1; }
grep -qE '^compose .* (pull|up)( |$)' "$state/calls" && { echo "FAIL the stacks were touched after a refused login"; exit 1; }

installed_state
echo 1 >"$state/pull.rc"
expect_refused "an image pull that fails" "pulling the ai images failed; the running release is untouched" "$work/good.tgz" release
grep -qE '^compose .* up( |$)' "$state/calls" && { echo "FAIL a stack started after a failed pull"; exit 1; }
[ "$(current_release)" = "$base_id" ] || { echo "FAIL a failed pull moved current"; exit 1; }
[ "$(find "$state/stack/releases" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ] || { echo "FAIL a failed pull left its release on disk"; exit 1; }
grep -q '^stop --time [0-9]* watchtower$' "$state/calls" || { echo "FAIL Watchtower was not stopped before the pull"; exit 1; }
grep -q '^start watchtower$' "$state/calls" || { echo "FAIL Watchtower was not started again after a failed pull"; exit 1; }
[ "$(cat "$state/running/watchtower")" = "true false" ] || { echo "FAIL Watchtower does not run after a failed pull"; exit 1; }
echo "ok   a failed pull starts Watchtower again"

installed_state
echo 1 >"$state/stop.rc"
expect_refused "Watchtower cannot be stopped" "Watchtower could not be stopped, so it could race the release; the running release is untouched" "$work/good.tgz" release
grep -qE '^compose .* (pull|up)( |$)' "$state/calls" && { echo "FAIL the stacks were touched when Watchtower could not be stopped"; exit 1; }
grep -q '^start watchtower$' "$state/calls" || { echo "FAIL Watchtower was not started after a failed stop"; exit 1; }
[ "$(current_release)" = "$base_id" ] || { echo "FAIL a failed Watchtower stop moved current"; exit 1; }
[ "$(find "$state/stack/releases" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ] || { echo "FAIL a failed Watchtower stop left its release on disk"; exit 1; }

installed_state
rm "$state/running/watchtower"
expect_refused "a release on a host without Watchtower" "watchtower is not running; run provisioning" "$work/second.tgz" release
grep -qE '^(stop|start) ' "$state/calls" && { echo "FAIL infra-apply stopped or started a Watchtower that was not running"; exit 1; }
echo "ok   a Watchtower that is not running is neither stopped nor started"

fake_host=hetzner
new_state
rm "$state/edge/docker-compose.yml"
expect_refused "a hetzner host whose edge was never provisioned" "edge/docker-compose\\.yml does not exist, so no Traefik routes the stacks" "$work/hgood.tgz" release
new_state
sed -i "s,^PORTFOLIO_IMAGE_REPO=.*,PORTFOLIO_IMAGE_REPO=not a repo," "$state/host.env"
expect_refused "a host.env with a malformed repository" "PORTFOLIO_IMAGE_REPO is not an image repository" "$work/hgood.tgz" release
unset fake_host
new_state
expect_ok "a home server without the edge Traefik" "RELEASE OK" "$work/good.tgz" release
new_state
sed -i '/^INFRA_HOST=/d' "$state/host.env"
expect_refused "a host.env without the host's kind" "INFRA_HOST is neither home nor hetzner; run provisioning" "$work/good.tgz" release
new_state
sed -i '/^TAILSCALE_IP=/d' "$state/host.env"
expect_refused "a host.env without the Tailscale address" "TAILSCALE_IP is not this host's Tailscale IPv4" "$work/good.tgz" release
new_state
sed -i 's,^TAILSCALE_IP=.*,TAILSCALE_IP=192.168.1.50,' "$state/host.env"
expect_refused "a host.env naming a LAN address as the Tailscale address" "TAILSCALE_IP is not this host's Tailscale IPv4" "$work/good.tgz" release
new_state
sed -i 's,^AI_USER=.*,AI_USER=0:0,' "$state/host.env"
expect_refused "a host.env naming root as the ai account" "AI_USER is not the <uid>:<gid> of the ai account" "$work/good.tgz" release
new_state
sed -i '/^MEDIA_USER=/d' "$state/host.env"
expect_refused "a host.env without the media account" "MEDIA_USER is not the <uid>:<gid> of the media account" "$work/good.tgz" release
new_state
sed -i '/^HOME_USER=/d' "$state/host.env"
expect_refused "a host.env without the home-server account" "HOME_USER is not the <uid>:<gid> of the home-server account" "$work/good.tgz" release
new_state
sed -i '/^HOME_IMAGE_REPO=/d' "$state/host.env"
expect_refused "a host.env without Home's repository" "HOME_IMAGE_REPO is not an image repository" "$work/good.tgz" release
rm "$state/host.env"
expect_refused "a host that was never provisioned" "host\\.env does not exist; run provisioning" "$work/good.tgz" release

### The compose guard

# compose_case <name> <stack> <want> <python edit of the compose text>
compose_case() {
  local name="$1" stack="$2" want="$3" edit="$4"
  variant compose
  python3 -I -c "
import sys
path = sys.argv[1]
text = open(path).read()
$edit
open(path, 'w').write(text)
" "$work/compose/$stack/docker-compose.yml"
  repack compose
  refused_bundle "the guard: $name" "$stack/docker-compose\\.yml: $want" "$work/compose.tgz"
}
fake_host=hetzner
db_service='    restart: always\n'
compose_case "privileged" database "service postgres sets privileged, which gives it root" "text = text.replace('$db_service', '$db_service    privileged: true\n')"
compose_case "cap_add" database "service postgres sets cap_add, which adds kernel capabilities" "text = text.replace('$db_service', '$db_service    cap_add: [NET_ADMIN]\n')"
compose_case "ports" portfolio "service portfolio sets ports, which publishes a host port" "text = text.replace('    restart: always\n', '    restart: always\n    ports: [\"3000:3000\"]\n')"
compose_case "a bind mount" portfolio 'service portfolio has a "bind" mount of "/etc"' "text = text.replace('    env_file: portfolio.env\n', '    env_file: portfolio.env\n    volumes:\n      - /etc:/host-etc:ro\n')"
compose_case "the Docker socket" portfolio 'service portfolio mounts the Docker socket "/var/run/docker.sock"' "text = text.replace('    env_file: portfolio.env\n', '    env_file: portfolio.env\n    volumes:\n      - /var/run/docker.sock:/var/run/docker.sock:ro\n')"
compose_case "network_mode host" portfolio "service portfolio sets network_mode, which a release may not set" "text = text.replace('    networks:\n      - data\n      - edge\n    healthcheck:', '    network_mode: host\n    healthcheck:')"
compose_case "pid host" database "service postgres sets pid, which a release may not set" "text = text.replace('$db_service', '$db_service    pid: host\n')"
compose_case "a foreign env_file" portfolio 'service portfolio reads env_file "../ghcr.env"' "text = text.replace('    env_file: portfolio.env\n', '    env_file: [portfolio.env, ../ghcr.env]\n')"
compose_case "another stack's env_file" database 'service postgres reads env_file "../portfolio/portfolio.env"' "text = text.replace('    env_file: postgres.env\n', '    env_file: [postgres.env, ../portfolio/portfolio.env]\n')"
compose_case "the backup key in postgres" database 'service postgres reads env_file "backup.env"' "text = text.replace('    env_file: postgres.env\n', '    env_file: [postgres.env, backup.env]\n')"
compose_case "pgdata without external or name" database 'volume pgdata is "database_pgdata"; the database stack keeps its data in "pgdata-v18" \(external\)' "text = text.replace('    name: pgdata-v18\n    external: true\n', '')"
compose_case "the media volume back in the portfolio" portfolio 'the volumes are \["portfolio-media"\]; the portfolio stack uses exactly \[\]' "text = text.replace('    env_file: portfolio.env\n', '    env_file: portfolio.env\n    volumes:\n      - portfolio-media:/app/media\n') + 'volumes:\n  portfolio-media:\n    name: portfolio-media\n'"
compose_case "an extra volume" database 'the volumes are \["extra", "pgdata"\]' "text = text.replace('      - pgdata:/var/lib/postgresql\n', '      - pgdata:/var/lib/postgresql\n      - extra:/extra\n').replace('\nvolumes:\n  pgdata:\n', '\nvolumes:\n  extra:\n  pgdata:\n')"
compose_case "an external network other than edge and data" portfolio 'network edge is "bridge"; the portfolio stack may only join' "text = text.replace('    name: edge\n', '    name: bridge\n')"
compose_case "edge on the database" database 'network data is "edge"; the database stack may only join the existing network\(s\) data' "text = text.replace('    name: data\n', '    name: edge\n')"
compose_case "a wrong container_name" portfolio 'service portfolio sets container_name "portfolio-web"' "text = text.replace('container_name: portfolio', 'container_name: portfolio-web')"
compose_case "a Watchtower label on postgres" database "service postgres sets the label com.centurylinklabs.watchtower.enable" "text = text.replace('$db_service', '$db_service    labels: [com.centurylinklabs.watchtower.enable=true]\n')"
compose_case "a traefik label on postgres" database "service postgres sets the label traefik.enable" "text = text.replace('$db_service', '$db_service    labels:\n      traefik.enable: \"true\"\n')"
compose_case "extends" database "service postgres extends another service" "text = text.replace('  postgres:\n', '  base:\n    image: postgres:18.6-alpine@sha256:77f585114c32fbca283dc835b0596f4e52b51b4c6662d7810b2f4084f60a1873\n    container_name: postgresql-base\n    networks: [data]\n  postgres:\n    extends: base\n')"
compose_case "include" portfolio "includes another compose file" "text = text.replace('name: portfolio\n', 'name: portfolio\ninclude:\n  - ../database/docker-compose.yml\n', 1)"
compose_case "a YAML merge key" portfolio "uses a YAML merge key" "text = text.replace('name: portfolio\n', 'name: portfolio\nx-base: &base\n  restart: always\n', 1).replace('    restart: always\n    security_opt', '    <<: *base\n    security_opt')"
compose_case "profiles" portfolio "service debug sets profiles" "text = text.replace('\nnetworks:\n  edge:', '\n  debug:\n    image: alpine:3.22@sha256:$(printf '0%.0s' $(seq 64))\n    container_name: portfolio\n    profiles: [debug]\n\nnetworks:\n  edge:', 1)"
compose_case "an unpinned third-party image" database 'service postgres runs "postgres:18-alpine"' "import re; text = re.sub(r'image: postgres:\S+', 'image: postgres:18-alpine', text)"
compose_case "a root user" portfolio 'service portfolio sets user "0:0"' "text = text.replace('    restart: always\n', '    restart: always\n    user: \"0:0\"\n')"
compose_case "another security_opt" portfolio 'service portfolio sets security_opt "seccomp=unconfined"' "text = text.replace('      - no-new-privileges:true\n', '      - no-new-privileges:true\n      - seccomp=unconfined\n')"
compose_case "a privileged flag hidden behind a default" database "service postgres sets privileged" "text = text.replace('$db_service', '$db_service    privileged: \${X_FLAG:-false}\n')"
compose_case "a wrong project name" portfolio 'the project name is "other", not portfolio' "text = text.replace('name: portfolio\n', 'name: other\n', 1)"
compose_case "the portfolio on llm" portfolio 'network llm is "llm"; the portfolio stack may only join the existing network\(s\) data and edge' "text = text.replace('      - edge\n    healthcheck:', '      - edge\n      - llm\n    healthcheck:', 1).replace('networks:\n  edge:\n', 'networks:\n  llm:\n    name: llm\n    external: true\n  edge:\n', 1)"
unset fake_host
# The ai stack: llama-server alone, hardened as the ai account, on home-llm alone, published nowhere.
llama_networks='    networks:\n      - home-llm\n    healthcheck:'
compose_case "Ollama back in the ai stack" ai 'service ollama sets container_name "ollama"; the ai stack names its containers llama' "text = text.replace('services:\n', 'services:\n  ollama:\n    image: ollama/ollama:0.40.4@sha256:926d40fd6eeeebd346b5c358a63de2a10ec995371cd93dd22f1843200694b1a6\n    container_name: ollama\n    user: \"\${AI_UID}:\${AI_GID}\"\n    mem_limit: 8g\n    read_only: true\n    cap_drop: [ALL]\n    security_opt:\n      - no-new-privileges:true\n    networks:\n      - home-llm\n\n', 1)"
compose_case "Ollama's old models volume in llama-server" ai 'the volumes are \["llama-models", "ollama-models"\]; the ai stack uses exactly \["llama-models"\]' "text = text.replace('          nocopy: true\n    deploy:', '          nocopy: true\n      - type: volume\n        source: ollama-models\n        target: /ollama\n    deploy:', 1) + '  ollama-models:\n    name: ollama-models\n    external: true\n'"
compose_case "llama-server with deploy labels" ai "service llama sets deploy .*; it may only reserve all NVIDIA GPUs" "text = text.replace('    deploy:\n      resources:', '    deploy:\n      labels:\n        x-extra: \"1\"\n      resources:', 1)"
compose_case "llama-server reserving more than the GPU" ai "service llama sets deploy .*; it may only reserve all NVIDIA GPUs" "text = text.replace('capabilities: [gpu]', 'capabilities: [gpu, utility]', 1)"
compose_case "llama-server without a memory limit" ai "service llama sets no mem_limit" "text = text.replace('    mem_limit: 6g\n', '')"
compose_case "llama-server keeping its capabilities" ai "service llama does not drop every capability" "text = text.replace('    cap_drop: [ALL]\n', '')"
compose_case "llama-server on the data network" ai 'network data is "data"; the ai stack may only join the existing network\(s\) home-llm' "text = text.replace('$llama_networks', '    networks:\n      - home-llm\n      - data\n    healthcheck:').replace('networks:\n  # Created', 'networks:\n  data:\n    name: data\n    external: true\n  # Created')"
compose_case "llama-server on llm, Ollama's old line" ai 'network llm is "llm"; the ai stack may only join the existing network\(s\) home-llm' "text = text.replace('$llama_networks', '    networks:\n      - home-llm\n      - llm\n    healthcheck:').replace('networks:\n  # Created', 'networks:\n  llm:\n    name: llm\n    external: true\n  # Created')"
compose_case "llama-server reading another stack's secret" ai 'service llama reads env_file ".*home-tls.env"' "text = text.replace('    environment:\n      HOME: /tmp\n', '    env_file: ../media/home-tls.env\n    environment:\n      HOME: /tmp\n')"
compose_case "a Watchtower label on llama-server" ai "service llama sets the label com.centurylinklabs.watchtower.enable" "text = text.replace('      - autoheal=true\n', '      - autoheal=true\n      - com.centurylinklabs.watchtower.enable=true\n', 1)"
compose_case "a service named apart from its container" ai 'service server names its container "llama"' "text = text.replace('  llama:\n    image:', '  server:\n    image:')"
compose_case "the models volume created by the release" ai 'volume llama-models is "llama-models"; the ai stack keeps its data in "llama-models" \(external\)' "text = text.replace('  llama-models:\n    name: llama-models\n    external: true\n', '  llama-models:\n    name: llama-models\n')"
compose_case "llama-server published on the tailnet" ai "service llama sets ports, which publishes a host port" "text = text.replace('    container_name: llama\n', '    container_name: llama\n    ports:\n      - \"\${TAILSCALE_IP}:8080:8080\"\n')"
compose_case "llama-server as root" ai 'service llama runs as "0:0"; it must run as 2001:2001' "text = text.replace('    container_name: llama\n    user: \"\${AI_UID}:\${AI_GID}\"\n', '    container_name: llama\n    user: \"0:0\"\n')"
compose_case "llama-server unpinned" ai 'service llama runs "ghcr.io/ggml-org/llama.cpp:server-cuda"' "import re; text = re.sub(r'image: ghcr.io/ggml-org/llama.cpp:\S+', 'image: ghcr.io/ggml-org/llama.cpp:server-cuda', text)"
compose_case "llama-server reading the film library" ai 'service llama has a "bind" mount of "/srv/media/movies"' "text = text.replace('      - type: volume\n        source: llama-models\n', '      - type: bind\n        source: /srv/media/movies\n        target: /films\n        bind:\n          create_host_path: false\n      - type: volume\n        source: llama-models\n', 1)"

# The media stack: tailnet-only, hardened, only Garage's objects and Beszel's two size folders bound.
# shellcheck disable=SC2016 # the compose text, ${TAILSCALE_IP} literal
files_port='      - "${TAILSCALE_IP}:8091:8091"\n'
backup_mount='        source: /srv/backup\n        target: /extra-filesystems/backup\n        read_only: true\n'
home_networks='    networks:\n      - media\n    healthcheck:'
compose_case "the file manager on every interface" media 'service sftpgo publishes \["0.0.0.0:8091:8091"\]' "text = text.replace('\${TAILSCALE_IP}:8091:8091', '0.0.0.0:8091:8091')"
compose_case "the file manager on a literal address" media 'service sftpgo publishes \["100.101.102.103:8091:8091"\]' "text = text.replace('$files_port', '      - \"100.101.102.103:8091:8091\"\n')"
compose_case "the file manager on a LAN address by default" media 'service sftpgo publishes \["\$\{FILES_IP:-192.168.1.50\}:8091:8091"\]' "text = text.replace('\${TAILSCALE_IP}:8091:8091', '\${FILES_IP:-192.168.1.50}:8091:8091')"
compose_case "a second file manager port" media 'service sftpgo publishes \[".*8091:8091", ".*:8092:8091"\]' "text = text.replace('$files_port', '$files_port      - \"\${TAILSCALE_IP}:8092:8091\"\n')"
compose_case "ports in flow style" media "service sftpgo writes ports in a form other than a list" "text = text.replace('    ports:\n$files_port', '    ports: [\"\${TAILSCALE_IP}:8091:8091\"]\n')"
compose_case "the status dashboard published on a second port" media 'service beszel publishes \[".*:8090:8090", ".*:8095:8095"\]' "text = text.replace('      - \"\${TAILSCALE_IP}:8090:8090\"\n', '      - \"\${TAILSCALE_IP}:8090:8090\"\n      - \"\${TAILSCALE_IP}:8095:8095\"\n')"
compose_case "the tailnet port moved to another service name" media "service files sets ports, which publishes a host port" "text = text.replace('  sftpgo:\n    image:', '  files:\n    image:')"
compose_case "the whole disk in Garage" media 'service garage has a "bind" mount of "/srv/media"; a release may only use its named volumes and tmpfs, and /srv/media/s3' "text = text.replace('        source: /srv/media/s3\n', '        source: /srv/media\n')"
compose_case "the backup disk in Garage" media 'service garage has a "bind" mount of "/srv/backup"' "text = text.replace('        source: /srv/media/s3\n', '        source: /srv/backup\n')"
compose_case "Beszel's agent writing the backup disk" media 'service beszel-agent mounts /srv/backup as .*; it may only mount it at /extra-filesystems/backup read-only' "text = text.replace('$backup_mount', '$backup_mount'.replace('        read_only: true\n', ''))"
compose_case "a bind mount in the short syntax" media 'service garage mounts /srv/media/s3 as .*"bind": \{(\}|"create_host_path": true\})' "text = text.replace('      - type: bind\n        source: /srv/media/s3\n        target: /data\n        bind:\n          create_host_path: false\n', '      - /srv/media/s3:/data\n')"
compose_case "a shared mount propagation" media 'service garage mounts /srv/media/s3 as' "text = text.replace('        target: /data\n        bind:\n          create_host_path: false\n', '        target: /data\n        bind:\n          create_host_path: false\n          propagation: rshared\n')"
compose_case "the host's /etc in Beszel's agent" media 'service beszel-agent has a "bind" mount of "/etc"' "text = text.replace('        source: /srv/media/.beszel\n', '        source: /etc\n')"
compose_case "the file manager as root" media 'service sftpgo runs as "0:0"; it must run as 2000:2000' "text = text.replace('    container_name: sftpgo\n    user: \"\${MEDIA_UID}:\${MEDIA_GID}\"\n', '    container_name: sftpgo\n    user: \"0:0\"\n')"
compose_case "the GPU for the file manager" media "service sftpgo sets deploy, which can reserve host devices; only beszel-agent, home-server, llama may reserve the GPU" "text = text.replace('    container_name: sftpgo\n', '    container_name: sftpgo\n    deploy:\n      resources:\n        reservations:\n          devices:\n            - driver: nvidia\n              count: all\n              capabilities: [gpu]\n')"
compose_case "the links page on the edge network" media 'network edge is "edge"; the media stack may only join the existing network\(s\) beszel-socket and media' "text = text.replace('$home_networks', '    networks:\n      - media\n      - edge\n    healthcheck:', 1).replace('networks:\n  media:\n', 'networks:\n  edge:\n    name: edge\n    external: true\n  media:\n')"
compose_case "a Traefik route to the links page" media "service home sets the label traefik.enable" "text = text.replace('      - autoheal=true\n', '      - autoheal=true\n      - traefik.enable=true\n', 1)"
compose_case "the links page on the agent's socket network" media 'service home joins beszel-socket; home may only join media' "text = text.replace('$home_networks', '    networks:\n      - media\n      - beszel-socket\n    healthcheck:', 1)"
compose_case "an env file from another stack in the media stack" media 'service home reads env_file ".*"; the media stack may only read' "text = text.replace('    container_name: home\n', '    container_name: home\n    env_file: ../ai/.env\n')"
compose_case "the links page reading home-tls's secret" media 'service home reads env_file ".*home-tls.env"; in the media stack beszel, beszel-agent, beszel-pair, garage, garage-setup, home-tls, sftpgo may read an env file' "text = text.replace('    container_name: home\n', '    container_name: home\n    env_file: home-tls.env\n')"
# The home stack: tailnet-only behind home-tls, hardened as 65532, only its Files folder bound.
compose_case "home-server on the edge network" home 'network edge is "edge"; the home stack may only join the existing network\(s\) home-llm and media' "text = text.replace('    networks:\n      - media\n      - home-llm\n    healthcheck:', '    networks:\n      - media\n      - home-llm\n      - edge\n    healthcheck:', 1).replace('networks:\n  media:\n', 'networks:\n  edge:\n    name: edge\n    external: true\n  media:\n')"
compose_case "home-server as root" home 'service home-server runs as "0:0"; it must run as 65532:65532' "text = text.replace('    container_name: home-server\n    user: \"\${HOME_UID}:\${HOME_GID}\"\n', '    container_name: home-server\n    user: \"0:0\"\n')"
compose_case "home-server reading its keys' env file" home 'service home-server reads env_file ".*home-keys.env"; in the home stack home-keys, home-server may read an env file, each its own' "text = text.replace('    env_file: home-server.env\n', '    env_file: [home-server.env, home-keys.env]\n')"
compose_case "the whole media disk in home-server" home 'service home-server has a "bind" mount of "/srv/media"; a release may only use its named volumes and tmpfs, and /run/home-power, /srv/media/home-files, /srv/media/movies, /srv/media/shows' "text = text.replace('        source: /srv/media/home-files\n', '        source: /srv/media\n')"
compose_case "an edge route to home-server" home "service home-server sets the label traefik.enable; the home stack is never routed by the edge Traefik" "text = text.replace('      - autoheal=true\n', '      - autoheal=true\n      - traefik.enable=true\n', 1)"
compose_case "the power directory read-only" home 'service home-server mounts /run/home-power as .*; it may only mount it at /run/power, with' "text = text.replace('        target: /run/power\n', '        target: /run/power\n        read_only: true\n')"
compose_case "the power directory at another path" home 'service home-server mounts /run/home-power as .*; it may only mount it at /run/power' "text = text.replace('        target: /run/power\n', '        target: /run/keys/power\n')"
compose_case "all of /run in home-server" home 'service home-server has a "bind" mount of "/run"; a release may only use its named volumes and tmpfs, and /run/home-power, /srv/media/home-files, /srv/media/movies, /srv/media/shows' "text = text.replace('        source: /run/home-power\n', '        source: /run\n')"
compose_case "the power directory in home-keys" home 'service home-keys has a "bind" mount of "/run/home-power"; a release may only use its named volumes and tmpfs' "text = text.replace('        target: /keys\n', '        target: /keys\n      - type: bind\n        source: /run/home-power\n        target: /run/power\n        bind:\n          create_host_path: false\n', 1)"
compose_case "a published Home port" home "service home-server sets ports, which publishes a host port" "text = text.replace('    container_name: home-server\n', '    container_name: home-server\n    ports:\n      - \"\${TAILSCALE_IP}:8080:8080\"\n')"
# Home's media library, its GPU and the media group: home-server's alone, at fixed paths, nothing more.
films_mount='        source: /srv/media/movies\n        target: /data/media/films\n'
gpu_reservation='    deploy:\n      resources:\n        reservations:\n          devices:\n            - driver: nvidia\n              count: all\n              capabilities: [gpu]\n'
compose_case "the GPU for home-keys" home "service home-keys sets deploy, which can reserve host devices; only beszel-agent, home-server, llama may reserve the GPU" "text = text.replace('    container_name: home-keys\n', '    container_name: home-keys\n$gpu_reservation')"
compose_case "home-server reserving more than the GPU" home "service home-server sets deploy .*; it may only reserve all NVIDIA GPUs" "text = text.replace('capabilities: [gpu]', 'capabilities: [gpu, video]', 1)"
compose_case "home-server reserving one GPU by id" home "service home-server sets deploy .*; it may only reserve all NVIDIA GPUs" "text = text.replace('              count: all\n', '              device_ids: [\"GPU-0\"]\n', 1)"
compose_case "the film library read-only in home-server" home 'service home-server mounts /srv/media/movies as .*; it may only mount it at /data/media/films, with' "text = text.replace('$films_mount', '$films_mount        read_only: true\n')"
compose_case "the series library at another path" home 'service home-server mounts /srv/media/shows as .*; it may only mount it at /data/media/series' "text = text.replace('        target: /data/media/series\n', '        target: /series\n')"
compose_case "the film library created by Docker when missing" home 'service home-server mounts /srv/media/movies as .*with bind.create_host_path: false' "text = text.replace('$films_mount        bind:\n          create_host_path: false\n', '$films_mount')"
compose_case "the film library in home-keys" home 'service home-keys has a "bind" mount of "/srv/media/movies"; a release may only use its named volumes and tmpfs' "text = text.replace('        target: /keys\n', '        target: /keys\n      - type: bind\n$films_mount        bind:\n          create_host_path: false\n', 1)"
compose_case "the film library in Garage" media 'service garage has a "bind" mount of "/srv/media/movies"; a release may only use its named volumes and tmpfs, and /srv/media/s3' "text = text.replace('        source: /srv/media/s3\n', '        source: /srv/media/movies\n')"
compose_case "the media group for home-keys" home "service home-keys sets group_add, which gives it the files of another account's group; only home-server may add a group" "text = text.replace('    container_name: home-keys\n', '    container_name: home-keys\n    group_add: [\"2000\"]\n')"
compose_case "the root group for home-server" home 'service home-server adds the groups \["0"\]; it may add exactly \["2000"\], the media account' "text = text.replace('      - \"\${MEDIA_GID}\"\n', '      - \"0\"\n')"
compose_case "a second group for home-server" home 'service home-server adds the groups \["2000", "2001"\]' "text = text.replace('      - \"\${MEDIA_GID}\"\n', '      - \"\${MEDIA_GID}\"\n      - \"2001\"\n')"
compose_case "the media group for the file manager" media "service sftpgo sets group_add, which gives it the files of another account's group" "text = text.replace('    container_name: sftpgo\n', '    container_name: sftpgo\n    group_add: [\"2000\"]\n')"
compose_case "home-server on llm, Ollama's old line" home 'network llm is "llm"; the home stack may only join the existing network\(s\) home-llm and media' "text = text.replace('      - home-llm\n    healthcheck:', '      - home-llm\n      - llm\n    healthcheck:', 1).replace('networks:\n  media:\n', 'networks:\n  llm:\n    name: llm\n    external: true\n  media:\n')"
compose_case "home-keys on home-llm" home "service home-keys joins home-llm; home-keys may only join media" "text = text.replace('    networks:\n      - media\n\n  home-server:', '    networks:\n      - media\n      - home-llm\n\n  home-server:')"
# The guard on its own, against the resolved models of the checked-in stacks.
for stack in database portfolio ai media home; do
  repos=()
  bundle=good
  case "$stack" in
    database) bundle=hgood ;;
    portfolio) bundle=hgood repos=("$portfolio_repo") ;;
    ai) repos=(--service-user=2001:2001) ;;
    media) repos=(--service-user=2000:2000) ;;
    home) repos=(--service-user=65532:65532 --media-gid=2000 "$home_repo") ;;
  esac
  TAILSCALE_IP="$tailscale_ip" "$REAL_DOCKER" compose --file "$work/$bundle/$stack/docker-compose.yml" --project-directory "$work/$bundle/$stack" config --no-env-resolution --format json >"$work/$stack.json"
  python3 -I "$guard" "$work/$stack.json" "$work/$bundle/$stack" "$stack" "--tailscale-ip=$tailscale_ip" "${repos[@]}" >"$work/guard.out" || { cat "$work/guard.out"; echo "FAIL the guard refuses the checked-in $stack stack"; exit 1; }
done
if python3 -I "$guard" "$work/ai.json" "$work/good/ai" ai "--tailscale-ip=$tailscale_ip" >"$work/guard.out"; then echo "FAIL the guard accepted the ai stack without its service account"; exit 1; fi
if python3 -I "$guard" "$work/media.json" "$work/good/media" media --service-user=2000:2000 >"$work/guard.out"; then echo "FAIL the guard accepted a tailnet port without the Tailscale address"; exit 1; fi
if python3 -I "$guard" "$work/media.json" "$work/good/media" media --tailscale-ip=100.101.102.104 --service-user=2000:2000 >"$work/guard.out"; then echo "FAIL the guard accepted a port bound to another address"; exit 1; fi
grep -qF "on 100.101.102.104" "$work/guard.out" || { cat "$work/guard.out"; echo "FAIL wrong refusal for a port on another address"; exit 1; }
if python3 -I "$guard" "$work/media.json" "$work/good/media" media --tailscale-ip=192.168.1.50 --service-user=2000:2000 >"$work/guard.out"; then echo "FAIL the guard took a LAN address for the Tailscale one"; exit 1; fi
if python3 -I "$guard" "$work/media.json" "$work/good/media" media "--tailscale-ip=$tailscale_ip" --service-user=2001:2001 >"$work/guard.out"; then echo "FAIL the guard ran the media stack as the ai account"; exit 1; fi
if python3 -I "$guard" "$work/home.json" "$work/good/home" home "--tailscale-ip=$tailscale_ip" --service-user=65532:65532 --media-gid=2000 >"$work/guard.out"; then echo "FAIL the guard accepted Home's image with no host.env repository"; exit 1; fi
if python3 -I "$guard" "$work/home.json" "$work/good/home" home "--tailscale-ip=$tailscale_ip" --service-user=65532:65532 "$home_repo" >"$work/guard.out"; then echo "FAIL the guard let home-server add a group with no media gid given"; exit 1; fi
grep -qF "no media gid was given" "$work/guard.out" || { cat "$work/guard.out"; echo "FAIL wrong refusal for a missing media gid"; exit 1; }
if python3 -I "$guard" "$work/home.json" "$work/good/home" home "--tailscale-ip=$tailscale_ip" --service-user=65532:65532 --media-gid=2001 "$home_repo" >"$work/guard.out"; then echo "FAIL the guard let home-server join a group other than the media account's"; exit 1; fi
if python3 -I "$guard" "$work/home.json" "$work/good/home" home "--tailscale-ip=$tailscale_ip" --service-user=65532:65532 --media-gid=0 "$home_repo" >"$work/guard.out"; then echo "FAIL the guard took root's group for the media group"; exit 1; fi
if python3 -I "$guard" "$work/home.json" "$work/good/home" home "--tailscale-ip=$tailscale_ip" --service-user=2000:2000 "$home_repo" >"$work/guard.out"; then echo "FAIL the guard ran the home stack as the media account"; exit 1; fi
if python3 -I "$guard" "$work/portfolio.json" "$work/hgood/portfolio" portfolio >"$work/guard.out"; then echo "FAIL the guard accepted app images no host.env names"; exit 1; fi
for gone in hypernova tunnel crm; do
  if python3 -I "$guard" "$work/portfolio.json" "$work/hgood/portfolio" "$gone" >"$work/guard.out"; then echo "FAIL the guard accepted the stack $gone"; exit 1; fi
done
echo "ok   the guard alone passes the checked-in stacks and needs the host's app repositories"

### Failed after install: the previous verified release is named

fake_host=hetzner
installed_state
sleep 1
echo 3 >"$state/psql.rc"
expect_refused "provision.sql fails" "FAILED: before the app stacks changed, provision\\.sql failed" "$work/hsecond.tgz" release
grep -qF "the last verified release was $base_id" "$work/out" || { cat "$work/out"; echo "FAIL the provision failure does not name the last verified release"; exit 1; }
grep -qF "password '***'" "$work/out" || { cat "$work/out"; echo "FAIL the psql error was not shown with its literal masked"; exit 1; }
grep -qE '^compose .*/portfolio up' "$state/calls" && { echo "FAIL an app stack started after provision.sql failed"; exit 1; }
[ "$(current_release)" = "$base_id" ] || { echo "FAIL a provision failure moved current"; exit 1; }
grep -qF "rollback cannot fix this" "$work/out" || { cat "$work/out"; echo "FAIL the provision failure advertises a rollback"; exit 1; }
grep -qF "revert that change on master and run release" "$work/out" || { cat "$work/out"; echo "FAIL the provision failure does not name the revert recovery"; exit 1; }
grep -q 'action rollback' "$work/out" && { cat "$work/out"; echo "FAIL the provision failure recommends a rollback"; exit 1; }
grep -q '^start watchtower$' "$state/calls" || { echo "FAIL Watchtower was not started again after a provision failure"; exit 1; }
[ "$(cat "$state/running/watchtower")" = "true false" ] || { echo "FAIL Watchtower does not run after a provision failure"; exit 1; }
rm "$state/psql.rc"
echo "ok   a provision.sql failure leaves the app stacks and current untouched and names a recovery that can fix it"

installed_state
sleep 1
echo 1 >"$state/up.database.rc"
expect_refused "the database does not come up healthy" "FAILED: before the app stacks changed, the database did not come up healthy" "$work/hsecond.tgz" release
for want in "the last verified release was $base_id" "rollback cannot fix this" "revert that change on master and run release" "current still names $base_id. A rollback cannot fix this"; do
  grep -qF -- "$want" "$work/out" || { cat "$work/out"; echo "FAIL the database failure does not print: $want"; exit 1; }
done
grep -q 'action rollback' "$work/out" && { cat "$work/out"; echo "FAIL the database failure recommends a rollback"; exit 1; }
grep -qE '^compose .*/portfolio up' "$state/calls" && { echo "FAIL an app stack started after the database failed"; exit 1; }
[ "$(current_release)" = "$base_id" ] || { echo "FAIL a database failure moved current"; exit 1; }
echo "ok   a database failure leaves current untouched and names a recovery that can fix it"

new_state
echo 1 >"$state/up.database.rc"
expect_refused "the database of a first release does not come up healthy" "installed but not current; no release is current yet\\. A rollback cannot fix this" "$work/hgood.tgz" release
grep -q 'the last verified release was' "$work/out" && { cat "$work/out"; echo "FAIL a first release names a last verified release"; exit 1; }

installed_state
sleep 1
printf '404' >"$state/curl.www.arbikullakshi.com"
expect_refused "Traefik answers 404 for a host" "Traefik answered 404 on http for www\\.arbikullakshi\\.com/, expected a redirect" "$work/hsecond.tgz" release
grep -qF "the last verified release was $base_id" "$work/out" || { cat "$work/out"; echo "FAIL the 404 failure does not name the last verified release"; exit 1; }

installed_state
sleep 1
echo "true true" >"$state/running/edge-socket-proxy"
expect_refused "Traefik's socket proxy restart-looping" "edge-socket-proxy is not running" "$work/hsecond.tgz" release
unset fake_host

installed_state
sleep 1
echo 1 >"$state/up.home.rc"
expect_refused "an app stack that does not start" "FAILED: home did not start" "$work/second.tgz" release
for want in "the last verified release was $base_id" "rollback only if an app image causes" "revert that change on master and run release"; do
  grep -qF -- "$want" "$work/out" || { cat "$work/out"; echo "FAIL the app start failure does not print: $want"; exit 1; }
done
[ ! -e "$state/stack/current/.verified" ] || { echo "FAIL a release whose app stack did not start was marked verified"; exit 1; }
grep -q '^start watchtower$' "$state/calls" || { echo "FAIL Watchtower was not started again after an app start failure"; exit 1; }
[ "$(cat "$state/running/watchtower")" = "true false" ] || { echo "FAIL Watchtower does not run after an app start failure"; exit 1; }
echo "ok   an app start failure says when a rollback helps and when to revert on master"

installed_state
sleep 1
sed -i 's,^c26 /home-server running always healthy home$,c26 /home-server running always starting home,' "$state/containers"
expect_refused "a container that never turns healthy" "not ready after 1s: home-server:starting" "$work/second.tgz" release
grep -qF "the last verified release was $base_id" "$work/out" || { cat "$work/out"; echo "FAIL the failure does not name the last verified release"; exit 1; }
grep -qF "rollback only if an app image causes" "$work/out" || { cat "$work/out"; echo "FAIL the verify failure does not qualify the rollback"; exit 1; }
[ "$(readlink "$state/stack/previous")" = "releases/$base_id" ] || { echo "FAIL the verified release is not kept as previous"; exit 1; }
[ ! -e "$state/stack/current/.verified" ] || { echo "FAIL an unhealthy release was marked verified"; exit 1; }
failed_id="$(current_release)"
sed -i 's,starting home$,healthy home,' "$state/containers"
sleep 1
expect_ok "a release after a failed one keeps the last verified release" "$base_id is kept as the previous release" "$work/good.tgz" release
[ ! -e "$state/stack/releases/$failed_id" ] || { echo "FAIL the failed release was not pruned"; exit 1; }

installed_state
sleep 1
touch "$state/crashloop/home-server"
expect_refused "a home-server that crash-loops between polls" "not ready after 1s: home-server:running for [0-9]+s of 30s \\(restarted [0-9]+ times\\)" "$work/second.tgz" release
[ ! -e "$state/stack/current/.verified" ] || { echo "FAIL a crash-looping release was marked verified"; exit 1; }
[ "$(readlink "$state/stack/previous")" = "releases/$base_id" ] || { echo "FAIL the verified release is not kept as previous after a crash loop"; exit 1; }
grep -q '^curl ' "$state/calls" && { echo "FAIL the routes were checked before the containers settled"; exit 1; }
watchtower_order "a crash-looping release" "stop pull up start"
rm "$state/crashloop/home-server"
echo "ok   a container that restarts between polls never counts as ready"

installed_state
sleep 1
date -u -d '-5 seconds' +%Y-%m-%dT%H:%M:%S.%NZ >"$state/started/home-server"
expect_refused "a home-server that started 5 s ago" "not ready after 1s: home-server:running for [0-9]+s of 30s \\(restarted 0 times\\)" "$work/second.tgz" release
echo "ok   a container up for less than the settle window is not ready yet"

installed_state
sleep 1
echo 'not-a-time' >"$state/started/home-server"
expect_refused "a container with an unreadable StartedAt" "not ready after 1s: home-server:started at an unreadable time" "$work/second.tgz" release

# F-008: a container that compose ps lists but docker inspect no longer finds
# (Watchtower recreated it in between) is pending, never silently skipped.
installed_state
sleep 1
touch "$state/vanished/c26"
expect_refused "a listed container is gone before the inspect" "not ready after 1s: 1 of 12 listed containers could not be inspected" "$work/second.tgz" release
[ ! -e "$state/stack/current/.verified" ] || { echo "FAIL a release with an uninspected container was marked verified"; exit 1; }
grep -q '^curl ' "$state/calls" && { echo "FAIL the routes were checked before every container was inspected"; exit 1; }

installed_state
sleep 1
for c in c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 c11 c12 c13 c14 c15 c16 c17 c18 c19 c20 c21 c22 c23 c24 c25 c26 c27 c28 c29; do touch "$state/vanished/$c"; done
expect_refused "every listed container is gone before the inspect" "not ready after 1s: 12 of 12 listed containers could not be inspected" "$work/second.tgz" release
[ ! -e "$state/stack/current/.verified" ] || { echo "FAIL a release with no inspected container was marked verified"; exit 1; }

installed_state
sleep 1
touch "$state/vanished-once/c26"
# Room for a second poll of every listed container on a slow runner.
apply_wait_seconds=15
expect_ok "a container gone for one poll is checked on the next" "every container is running and healthy" "$work/second.tgz" release
unset apply_wait_seconds
[ "$(grep -c '^inspect ' "$state/calls")" -ge 2 ] || { echo "FAIL verify did not poll again after an uninspected container"; exit 1; }

installed_state
sleep 1
echo 1 >"$state/ps.ai.rc"
expect_refused "docker compose ps fails for one stack" "not ready after 1s: docker compose ps failed for ai" "$work/second.tgz" release
[ ! -e "$state/stack/current/.verified" ] || { echo "FAIL a release whose ai containers were not listed was marked verified"; exit 1; }
echo "ok   a container that compose ps lists but verify cannot inspect is never taken as ready"

installed_state
sleep 1
echo 'level=WARN msg="blocked request" method=POST URL=/v1.51/containers/abc/stop' >"$state/logs/autoheal-socket-proxy"
expect_refused "a socket proxy logged a blocked request" "autoheal-socket-proxy refused Docker API calls autoheal made" "$work/second.tgz" release
grep -qF "the last verified release was $base_id" "$work/out" || { cat "$work/out"; echo "FAIL the proxy failure does not name the last verified release"; exit 1; }

installed_state
sleep 1
echo 'level=error msg="Error response from daemon: Forbidden"' >"$state/logs/watchtower"
expect_refused "Watchtower logged a Docker API error" "Watchtower cannot use the Docker API" "$work/second.tgz" release

installed_state
sleep 1
echo 'level=WARN msg="blocked request" reason="path not allowed" method=GET URL=/containers/abc/json' >"$state/logs/beszel-socket-proxy"
expect_refused "Beszel's socket proxy refused an agent call" "beszel-socket-proxy refused Docker API calls beszel-agent made" "$work/second.tgz" release

installed_state
sleep 1
echo "exited 1" >"$state/oneshot/garage-setup"
expect_refused "garage-setup failed" "garage-setup exited with status 1; docker logs garage-setup on the host says why" "$work/second.tgz" release

installed_state
sleep 1
echo "exited 1" >"$state/oneshot/home-keys"
expect_refused "home-keys failed" "home-keys exited with status 1; docker logs home-keys on the host says why" "$work/second.tgz" release

installed_state
sleep 1
echo "running 0" >"$state/oneshot/beszel-pair"
expect_refused "beszel-pair never finishes" "beszel-pair is still running 0 after 1s" "$work/second.tgz" release

installed_state
sleep 1
touch "$state/oneshot-missing/garage-setup"
expect_refused "garage-setup was never created" "garage-setup was never created" "$work/second.tgz" release

### Verbs, root and overrides

new_state
expect_refused "no verb" "usage: infra-apply" /dev/null
expect_refused "an unknown verb" "usage: infra-apply" /dev/null rollback
expect_refused "extra arguments" "usage: infra-apply" /dev/null release now
if [ "$(id -u)" -ne 0 ]; then
  if env -u INFRA_APPLY_STACK_DIR "$apply" status </dev/null >"$work/out" 2>&1; then cat "$work/out"; echo "FAIL ran without root"; exit 1; fi
  grep -q "must run as root" "$work/out" || { cat "$work/out"; echo "FAIL wrong refusal without root"; exit 1; }
  echo "ok   refused: running without root"
  if SUDO_USER=deploy INFRA_APPLY_STACK_DIR="$state/stack" INFRA_APPLY_HOST_FILE="$state/host.env" "$apply" status </dev/null >"$work/out" 2>&1; then
    cat "$work/out"; echo "FAIL honoured overrides under sudo"; exit 1
  fi
  grep -q "must run as root" "$work/out" || { cat "$work/out"; echo "FAIL overrides were honoured under sudo"; exit 1; }
  echo "ok   refused: path overrides under sudo"
fi

### The gate

gate_run() {
  rm -f "$state/sudo.args" "$state/sudo.stdin"
  PATH="$work/bin:$PATH" FAKE_STATE="$state" "$@" <"$work/good.tgz" >"$work/out" 2>&1
}
new_state
for verb in release status; do
  if ! gate_run env SSH_ORIGINAL_COMMAND="$verb" "$gate"; then cat "$work/out"; echo "FAIL gate refused $verb"; exit 1; fi
  [ "$(cat "$state/sudo.args")" = "-n /usr/local/sbin/infra-apply $verb" ] || { echo "FAIL gate ran: $(cat "$state/sudo.args")"; exit 1; }
  cmp -s "$work/good.tgz" "$state/sudo.stdin" || { echo "FAIL gate did not pass stdin through for $verb"; exit 1; }
  echo "ok   gate allows: $verb"
done
refuse_command() {
  local label="$1" rc=0
  shift
  gate_run "$@" "$gate" || rc=$?
  [ "$rc" -eq 64 ] || { cat "$work/out"; echo "FAIL gate exited $rc for: $label"; exit 1; }
  grep -q "infra-deploy-gate: refused; this key may only run one of: release, status" "$work/out" || { cat "$work/out"; echo "FAIL gate refused without its message: $label"; exit 1; }
  [ ! -e "$state/sudo.args" ] || { echo "FAIL gate called sudo for: $label"; exit 1; }
  echo "ok   gate refuses: $label"
}
refuse_command "an interactive login" env -u SSH_ORIGINAL_COMMAND
refuse_command "an empty command" env SSH_ORIGINAL_COMMAND=
refuse_command "rollback" env SSH_ORIGINAL_COMMAND=rollback
refuse_command "a chained command" env "SSH_ORIGINAL_COMMAND=release; id"
refuse_command "a verb with arguments" env SSH_ORIGINAL_COMMAND="status now"
refuse_command "a leading space" env SSH_ORIGINAL_COMMAND=" status"
refuse_command "a trailing newline" env SSH_ORIGINAL_COMMAND="$(printf 'status\nid')"
refuse_command "a shell" env SSH_ORIGINAL_COMMAND=bash
refuse_command "scp" env SSH_ORIGINAL_COMMAND="scp -t /tmp"
refuse_command "sftp" env SSH_ORIGINAL_COMMAND=internal-sftp
refuse_command "an upper-case verb" env SSH_ORIGINAL_COMMAND=RELEASE

echo "release-scripts: all cases passed"
