#!/usr/bin/env bash
# Tests rollback resolution against fakes: release-images.sh resolve reads a
# status fixture and asks a fake registry (docker buildx imagetools inspect) for
# digests; the pins it prints then build a --pin bundle that infra-apply
# releases in the fake host from ci/release-fakes.sh. Nothing here contacts a
# server or a registry.
#
#   bash ci/rollback-scripts.sh
#
# Prints "ok   ..." per case and stops with "FAIL ..." on the first failure.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
script="$root/release-images.sh"
apply="$root/roles/common/files/infra-apply"
guard="$root/roles/common/files/infra-compose-guard"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/registry-bin"
# shellcheck source=ci/release-fakes.sh
. "$here/release-fakes.sh"
host_power_key="$(jq -r .home_power_key "$here/sample-extra-vars.json")"

# The registry fake lives apart from the host fakes: resolve only ever runs
# `docker buildx imagetools inspect`.
cat >"$work/registry-bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_REGISTRY.calls"
if [ "$1 $2 $3" != "buildx imagetools inspect" ] || [ "$4" != --format ] || [ "$5" != '{{json .Manifest.Digest}}' ]; then
  echo "fake docker: unsupported $*" >&2
  exit 2
fi
digest="$(awk -v ref="$6" '$1 == ref { print $2 }' "$FAKE_REGISTRY")"
[ -n "$digest" ] || { echo "ERROR: $6: not found" >&2; exit 1; }
printf '"%s"\n' "$digest"
SH
chmod +x "$work/registry-bin/docker"

P="$portfolio_repo"
H="$home_repo"
sha=0123456789abcdef0123456789abcdef01234567
registry="$work/registry"
printf '%s %s\n' "$P:$sha" "$(d 7)" "$H@$(d 5)" "$(d 5)" >"$registry"

cur=20261014T100000Z-aaaaaaaaaaaa
prev=20261013T100000Z-bbbbbbbbbbbb

# Normal: the image runs, the current release recorded it, and the host still
# holds two older digests. One fixture serves both hosts: each host's status
# names only its own image, and resolve reads only the one it needs.
cat >"$work/normal.txt" <<ST
infra-apply: current release: $cur (verified), following :latest, auto-updates on
infra-apply: previous release: none
infra-apply: image portfolio ref=$P:latest digest=$(d 12) created=2026-10-12T10:00:00Z
infra-apply: image home-server ref=$H:latest digest=$(d 52) created=2026-10-13T10:00:00Z
infra-apply: known $P digest=$(d 12) created=2026-10-12 10:00:00 +0000 UTC
infra-apply: known $P digest=$(d 11) created=2026-10-05 10:00:00 +0000 UTC
infra-apply: known $P digest=$(d 10) created=2026-09-28 10:00:00 +0000 UTC
infra-apply: known $H digest=$(d 52) created=2026-10-13 10:00:00 +0000 UTC
infra-apply: known $H digest=$(d 51) created=2026-10-06 10:00:00 +0000 UTC
infra-apply: recorded $cur portfolio=$P@$(d 12)
infra-apply: recorded $cur home-server=$H@$(d 52)
NAME IMAGE STATUS
ST

# The weekly prune removed the old images: the previous digests are known only
# from the previous release's record.
cat >"$work/recorded.txt" <<ST
infra-apply: current release: $cur (verified), following :latest, auto-updates on
infra-apply: previous release: $prev (verified), following :latest, auto-updates on
infra-apply: image portfolio ref=$P:latest digest=$(d 12) created=2026-10-12T10:00:00Z
infra-apply: image home-server ref=$H:latest digest=$(d 52) created=2026-10-13T10:00:00Z
infra-apply: known $P digest=$(d 12) created=2026-10-12 10:00:00 +0000 UTC
infra-apply: known $H digest=$(d 52) created=2026-10-13 10:00:00 +0000 UTC
infra-apply: recorded $cur portfolio=$P@$(d 12)
infra-apply: recorded $cur home-server=$H@$(d 52)
infra-apply: recorded $prev portfolio=$P@$(d 41)
infra-apply: recorded $prev home-server=$H@$(d 44)
NAME IMAGE STATUS
ST

# A first release: nothing but the running digests is known.
grep -v -e ' known ' "$work/recorded.txt" | grep -v -e "recorded $prev " |
  sed "s/^infra-apply: previous release: .*/infra-apply: previous release: none/" >"$work/noprev.txt"

resolve() {
  local status="$1"
  shift
  PATH="$work/registry-bin:$PATH" FAKE_REGISTRY="$registry" "$script" resolve "$@" <"$status" >"$work/pins" 2>"$work/err"
}
resolves() {
  local name="$1" want="$2" status="$3"
  shift 3
  resolve "$status" "$@" || { cat "$work/err"; echo "FAIL expected a resolution: $name"; exit 1; }
  printf '%b' "$want" | cmp -s - "$work/pins" || { printf 'got:\n'; cat "$work/pins"; printf 'wanted:\n%b' "$want"; echo "FAIL wrong pins: $name"; exit 1; }
  echo "ok   resolved: $name"
}
refuses() {
  local name="$1" want="$2" status="$3"
  shift 3
  if resolve "$status" "$@"; then cat "$work/pins"; echo "FAIL expected a refusal: $name"; exit 1; fi
  grep -qE -- "$want" "$work/err" || { cat "$work/err"; echo "FAIL refused for the wrong reason (wanted '$want'): $name"; exit 1; }
  [ ! -s "$work/pins" ] || { cat "$work/pins"; echo "FAIL printed pins despite refusing: $name"; exit 1; }
  echo "ok   refused: $name"
}
pins() {
  printf 'RELEASE_MODE=pinned\\n%s=%s\\n' "$1" "$2"
}

### Resolution

resolves "the portfolio's previous digest, from the older images on the host" "$(pins PORTFOLIO_IMAGE "$P:latest@$(d 11)")" "$work/normal.txt" hetzner previous
cp "$work/pins" "$work/previous-pins.env"
resolves "Home's previous digest, from the older images on the host" "$(pins HOME_IMAGE "$H:latest@$(d 51)")" "$work/normal.txt" home previous
cp "$work/pins" "$work/home-previous-pins.env"
resolves "the portfolio's previous digest, from the previous release's record" "$(pins PORTFOLIO_IMAGE "$P:latest@$(d 41)")" "$work/recorded.txt" hetzner previous
resolves "Home's previous digest, from the previous release's record" "$(pins HOME_IMAGE "$H:latest@$(d 44)")" "$work/recorded.txt" home previous
resolves "a portfolio commit sha" "$(pins PORTFOLIO_IMAGE "$P:$sha@$(d 7)")" "$work/normal.txt" hetzner "$sha"
grep -qx "buildx imagetools inspect --format {{json .Manifest.Digest}} $P:$sha" "$registry.calls" || { echo "FAIL the commit tag was not looked up in the registry"; exit 1; }
resolves "the running portfolio" "$(pins PORTFOLIO_IMAGE "$P:latest@$(d 12)")" "$work/normal.txt" hetzner current
resolves "an explicit sha256 digest the registry has" "$(pins HOME_IMAGE "$H:latest@$(d 5)")" "$work/normal.txt" home "$(d 5)"
grep -qx "buildx imagetools inspect --format {{json .Manifest.Digest}} $H@$(d 5)" "$registry.calls" || { echo "FAIL the digest was not checked in the registry"; exit 1; }

### Refusals

refuses "the target latest" "use resume" "$work/normal.txt" hetzner latest
refuses "a sha256 digest the registry does not have" "$H@$(d 6) does not exist in the registry" "$work/normal.txt" home "$(d 6)"
refuses "no previous portfolio digest known" "no previous digest of $P is known for portfolio; pass an explicit sha256 digest; see status" "$work/noprev.txt" hetzner previous
refuses "no previous Home digest known" "no previous digest of $H is known for home-server; .*see status" "$work/noprev.txt" home previous
refuses "a 12-character portfolio sha (the portfolio publishes the full sha)" "is not latest, current, previous, a 40-character commit sha" "$work/normal.txt" hetzner "${sha:0:12}"
refuses "a portfolio sha the registry does not have" "does not exist in the registry" "$work/normal.txt" hetzner "$(printf 'f%.0s' $(seq 40))"
refuses "a commit sha for Home" "only the portfolio publishes commit tags" "$work/normal.txt" home "$sha"
refuses "a version tag" "is not latest, current, previous, a 40-character commit sha" "$work/normal.txt" hetzner v1.2.3
refuses "a short digest" "is not sha256:<64 hex" "$work/normal.txt" home sha256:abc
grep -v 'image home-server' "$work/normal.txt" >"$work/nohome.txt"
refuses "no running Home digest" "status names no running digest for home-server" "$work/nohome.txt" home current
: >"$work/empty.txt"
refuses "an empty status" "no status output arrived" "$work/empty.txt" hetzner previous
refuses "the wrong argument count" "usage" "$work/normal.txt" previous
refuses "an unknown host" "usage" "$work/normal.txt" crm previous
refuses "the old four-target form" "usage" "$work/normal.txt" previous previous previous previous

### The resolved pins build a bundle infra-apply releases as pinned

printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeRollbackFakeRollbackFakeRollbackFake01 infra-deploy-test' >"$work/deploy_key.pub"
jq --arg key "$work/deploy_key.pub" '. + {deploy_key_file: $key}' "$here/sample-extra-vars.json" >"$work/vars.json"
mapfile -t secrets < <(jq -r 'del(.ghcr_username, .portfolio_google_client_id, .home_owner_email, .r2_public_bucket, .r2_private_bucket, .media_public_base, .cf_origin_cert, .cf_origin_key) | .[] | select(. != "")' "$here/sample-extra-vars.json")
"$root/build-bundle.sh" --host hetzner --pin "$work/previous-pins.env" "$work/vars.json" "$work/rollback.tgz" >"$work/build.log" 2>&1 ||
  { cat "$work/build.log"; echo "FAIL build-bundle.sh --pin refused the resolved pins"; exit 1; }
no_secret_in "$work/build.log" "build-bundle.sh --pin"
mkdir "$work/rollback"
tar -xzf "$work/rollback.tgz" -C "$work/rollback"
grep -qx 'RELEASE_MODE=pinned' "$work/rollback/release.env" || { echo "FAIL the rollback bundle is not a pinned release"; exit 1; }
grep -qxF "PORTFOLIO_IMAGE=$P:latest@$(d 11)" "$work/rollback/portfolio/.env" || { echo "FAIL the portfolio pin is not in portfolio/.env"; exit 1; }
"$root/build-bundle.sh" --host home --pin "$work/home-previous-pins.env" "$work/vars.json" "$work/home-rollback.tgz" >"$work/build.log" 2>&1 ||
  { cat "$work/build.log"; echo "FAIL build-bundle.sh --pin refused Home's resolved pin"; exit 1; }
tar -xzOf "$work/home-rollback.tgz" home/.env | grep -qxF "HOME_IMAGE=$H:latest@$(d 51)" || { echo "FAIL the Home pin is not in home/.env"; exit 1; }
if "$root/build-bundle.sh" --host home --pin "$work/previous-pins.env" "$work/vars.json" "$work/wrong.tgz" >"$work/build.log" 2>&1; then
  echo "FAIL build-bundle.sh applied the portfolio's pin to the home bundle"; exit 1
fi
echo "ok   bundle: build-bundle.sh --pin applies the resolved pin to its host's bundle alone"

fake_host=hetzner
new_state
running_image portfolio "$P:latest@$(d 11)" 11
expect_ok "the rollback bundle" "RELEASE OK: [0-9]{8}T[0-9]{6}Z-[0-9a-f]{12} is current, pinned \\(PORTFOLIO_IMAGE\\), auto-updates paused for them" "$work/rollback.tgz" release
printf '%s\n' "portfolio=$P@$(d 11)" |
  cmp -s - "$state/stack/current/running-images.env" || { cat "$state/stack/current/running-images.env"; echo "FAIL the rollback release did not record the pinned digest"; exit 1; }
echo "ok   infra-apply runs the rolled-back digest and records it"

echo "rollback scripts: all cases passed"
