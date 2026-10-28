#!/usr/bin/env bash
# Turns a rollback target into the pin build-bundle.sh --pin applies:
#
#   release-images.sh resolve <home|hetzner> <target> < status.txt > pins.env
#
# status.txt is the output of `ssh deploy@<host> status` (infra-apply status).
# Each host runs one app image: hetzner the portfolio, home Home's home-server.
# The target is one of:
#   latest           follow <repo>:latest (auto-updates stay on for it)
#   current          pin the digest that runs now
#   previous         pin the first digest that differs from the one running now,
#                    from the current release's recorded digests, then the
#                    previous release's, then the images still on the host
#   <40-hex sha>     portfolio only: its :<full commit sha> tag, by digest
#   sha256:<digest>  that digest, after checking the registry has it
# A digest is always pulled from GHCR, which keeps untagged versions.
# Prints RELEASE_MODE=pinned and the host's image line; notes go to stderr.
# The registry lookups need `docker login ghcr.io` first.
set -euo pipefail

usage() {
  printf 'usage: release-images.sh resolve <home|hetzner> <target> < status.txt > pins.env\n' >&2
  exit 64
}

fail() {
  printf 'release-images: %s\n' "$*" >&2
  exit 1
}

note() {
  printf 'release-images: %s\n' "$*" >&2
}

here="$(cd "$(dirname "$0")" && pwd)"
readonly digest_pattern='^sha256:[0-9a-f]{64}$'

repo_for() {
  local key="$1" repo
  repo="$(sed -n "s/^$key:[[:space:]]*\\([^[:space:]#]*\\)[[:space:]]*\$/\\1/p" "$here/production.yml" | tr -d '"')"
  [[ "$repo" =~ ^[a-z0-9.-]+(/[a-z0-9._-]+)+$ ]] || fail "production.yml does not set $key to an image repository"
  printf '%s\n' "$repo"
}

registry_digest() {
  local out
  out="$(docker buildx imagetools inspect --format '{{json .Manifest.Digest}}' "$1" 2>/dev/null)" || return 1
  out="${out//\"/}"
  [[ "$out" =~ $digest_pattern ]] || return 1
  printf '%s\n' "$out"
}

# status_lines <extended regex with one group>: that group of every matching
# status line, in order.
status_lines() {
  sed -nE "s#^infra-apply: $1\$#\\1#p" "$status"
}

regex_escape() {
  printf '%s' "${1//./\\.}"
}

running_digest() {
  local container="$1"
  status_lines "image $container ref=[^[:space:]]+ digest=(sha256:[0-9a-f]{64}) created=.*" | head -n 1
}

release_id() {
  status_lines "$1 release: ([0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}) \\((verified|not verified)\\), .*" | head -n 1
}

recorded_digest() {
  local id="$1" container="$2" repo="$3"
  [ -n "$id" ] || return 0
  status_lines "recorded $id $container=$(regex_escape "$repo")@(sha256:[0-9a-f]{64})" | head -n 1
}

previous_digest() {
  local container="$1" repo="$2" running="$3" candidate
  for candidate in \
    "$(recorded_digest "$current_id" "$container" "$repo")" \
    "$(recorded_digest "$previous_id" "$container" "$repo")" \
    $(status_lines "known $(regex_escape "$repo") digest=(sha256:[0-9a-f]{64}) created=.*"); do
    if [ -n "$candidate" ] && [ "$candidate" != "$running" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# resolve_one <key> <container> <repo> <target> <allow sha>: prints KEY=ref.
resolve_one() {
  local key="$1" container="$2" repo="$3" target="$4" allow_sha="$5" running digest
  case "$target" in
    latest)
      printf '%s=%s:latest\n' "$key" "$repo"
      return 0
      ;;
    current | previous)
      running="$(running_digest "$container")"
      [[ "$running" =~ $digest_pattern ]] || fail "status names no running digest for $container; pass an explicit sha256 digest; see status"
      if [ "$target" = current ]; then
        digest="$running"
      else
        digest="$(previous_digest "$container" "$repo" "$running")" ||
          fail "no previous digest of $repo is known for $container; pass an explicit sha256 digest; see status"
      fi
      note "$container: $target is $digest"
      printf '%s=%s:latest@%s\n' "$key" "$repo" "$digest"
      ;;
    sha256:*)
      [[ "$target" =~ $digest_pattern ]] || fail "$key: $(printf '%q' "$target") is not sha256:<64 hex characters>"
      registry_digest "$repo@$target" >/dev/null || fail "$repo@$target does not exist in the registry"
      printf '%s=%s:latest@%s\n' "$key" "$repo" "$target"
      ;;
    *)
      if [ "$allow_sha" = yes ] && [[ "$target" =~ ^[0-9a-f]{40}$ ]]; then
        digest="$(registry_digest "$repo:$target")" || fail "$repo:$target does not exist in the registry (the portfolio publishes :<full commit sha> for every master build)"
        note "$container: $target is $digest"
        printf '%s=%s:%s@%s\n' "$key" "$repo" "$target" "$digest"
        return 0
      fi
      if [ "$allow_sha" = yes ]; then
        fail "$key: $(printf '%q' "$target") is not latest, current, previous, a 40-character commit sha or sha256:<digest>"
      fi
      fail "$key: $(printf '%q' "$target") is not latest, current, previous or sha256:<digest> (only the portfolio publishes commit tags)"
      ;;
  esac
}

resolve() {
  local host="$1" target="$2" out
  if [ "$target" = latest ]; then
    fail "the target is latest; that is not a rollback, use resume"
  fi
  status="$(mktemp)"
  trap 'rm -f "$status" "$status.pins"' EXIT
  cat >"$status"
  [ -s "$status" ] || fail "no status output arrived on stdin"
  current_id="$(release_id current)"
  previous_id="$(release_id previous)"
  out="$status.pins"
  {
    printf 'RELEASE_MODE=pinned\n'
    case "$host" in
      hetzner) resolve_one PORTFOLIO_IMAGE portfolio "$(repo_for portfolio_image_repo)" "$target" yes ;;
      home) resolve_one HOME_IMAGE home-server "$(repo_for home_image_repo)" "$target" no ;;
      *) usage ;;
    esac
  } >"$out"
  cat "$out"
}

[ "$#" -ge 1 ] || usage
case "$1" in
  resolve)
    [ "$#" -eq 3 ] || usage
    resolve "$2" "$3"
    ;;
  *) usage ;;
esac
