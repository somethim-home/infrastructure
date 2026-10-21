#!/usr/bin/env bash
# Tests roles/host/files/home-power against a temp request directory, key,
# state file and a fake systemctl (HOME_POWER_DIR, HOME_POWER_KEY_FILE,
# HOME_POWER_STATE, HOME_POWER_SYSTEMCTL; HOME_POWER_NOW sets the clock,
# HOME_POWER_DELAY=0 skips the wait). Requests are signed here the way Home
# signs them (docs/host.md, "Power requests from Home"). Nothing here powers
# anything off.
#
#   bash ci/power-scripts.sh
#
# Prints "ok   ..." per case and stops with "FAIL ..." on the first failure.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
power="$root/roles/host/files/home-power"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

cat >"$work/bin/systemctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_STATE/systemctl.calls"
[ ! -f "$FAKE_STATE/systemctl.rc" ] || exit "$(cat "$FAKE_STATE/systemctl.rc")"
SH
chmod +x "$work/bin/systemctl"

readonly key=SGFybmVzc0hvbWVQb3dlcktleTAxMjM0NTY3ODlhYmM=
readonly t0=1792500000
count=0
state=""
clock="$t0"
new_state() {
  count=$((count + 1))
  state="$work/state$count"
  mkdir -p "$state/requests" "$state/lib"
  chmod 700 "$state/requests" "$state/lib"
  (umask 077 && printf '%s\n' "$key" >"$state/power.key")
  : >"$state/systemctl.calls"
  clock="$t0"
}

# sign <key> <action> <requested_at> <nonce>: the hmac Home puts in the request.
sign() {
  python3 -I -c 'import base64, hashlib, hmac, sys
key, action, at, nonce = sys.argv[1:]
print(hmac.new(base64.b64decode(key), f"home-power/v1\n{action}\n{at}\n{nonce}".encode(), hashlib.sha256).hexdigest())' "$@"
}

fresh_nonce() {
  python3 -I -c 'import secrets; print(secrets.token_hex(16))'
}

# request <action> [<requested_at> [<nonce> [<signing key>]]]: a signed request, written the
# way Home writes it (a dot file renamed into place).
request() {
  local action="$1" at="${2:-$clock}" nonce="${3:-$(fresh_nonce)}" signing="${4:-$key}"
  last_nonce="$nonce"
  printf '{"action": "%s", "requested_at": %s, "nonce": "%s", "hmac": "%s"}' \
    "$action" "$at" "$nonce" "$(sign "$signing" "$action" "$at" "$nonce")" >"$state/requests/.request.tmp"
  mv "$state/requests/.request.tmp" "$state/requests/request.json"
}

run_power() {
  FAKE_STATE="$state" HOME_POWER_DIR="$state/requests" HOME_POWER_KEY_FILE="$state/power.key" \
    HOME_POWER_STATE="$state/lib/state.json" HOME_POWER_SYSTEMCTL="$work/bin/systemctl" \
    HOME_POWER_NOW="$clock" HOME_POWER_DELAY=0 python3 -I "$power" "$@" >"$work/out" 2>&1
}

fail() {
  cat "$work/out"
  echo "FAIL $*"
  exit 1
}

# expect <name> <exit code> <log pattern>: one run; the directory is empty after it.
expect() {
  local name="$1" rc="$2" want="$3" got=0
  run_power || got=$?
  [ "$got" -eq "$rc" ] || fail "exit $got, expected $rc: $name"
  grep -qE -- "$want" "$work/out" || fail "no log line matching '$want': $name"
  [ -z "$(ls -A "$state/requests")" ] || { ls -la "$state/requests"; fail "the request directory is not empty: $name"; }
}

acted() {
  [ "$(cat "$state/systemctl.calls")" = "$1" ] || { cat "$state/systemctl.calls"; fail "systemctl was called with '$(paste -sd '|' "$state/systemctl.calls")', expected '$1'"; }
}

not_acted() {
  [ ! -s "$state/systemctl.calls" ] || { cat "$state/systemctl.calls"; fail "systemctl was called: $1"; }
}

### accepted

new_state
request poweroff
expect "a valid poweroff" 0 "^home-power: accepted poweroff, requested 0 s ago; poweroff in 0 s$"
acted "--no-block poweroff"
grep -q "$last_nonce" "$work/out" && fail "the log shows the whole nonce"
python3 -I -c 'import json, sys; s = json.load(open(sys.argv[1])); assert s["last_action_at"] == int(sys.argv[2]) and sys.argv[3] in s["nonces"], s' \
  "$state/lib/state.json" "$clock" "$last_nonce" || fail "the state does not record the action and its nonce"
[ "$(stat -c %a "$state/lib/state.json")" = 600 ] || fail "the state file is not private"
echo "ok   a signed poweroff: systemctl --no-block poweroff, the request removed, the action and nonce recorded"

new_state
request reboot $((clock - 120))
expect "a valid reboot two minutes old" 0 "^home-power: accepted reboot, requested 120 s ago; reboot in 0 s$"
acted "--no-block reboot"
echo "ok   a signed reboot, two minutes old: systemctl --no-block reboot"

new_state
# The real clock: the dot file's age is judged by its modification time.
clock="$(date +%s)"
nonce=deadbeefdeadbeefdeadbeefdeadbeef
printf '{"action":"poweroff","requested_at":%s,"nonce":"%s","hmac":"%s"}' "$clock" "$nonce" \
  "$(sign "$key" poweroff "$clock" "$nonce")" >"$state/requests/.request.tmp"
( sleep 1 && mv "$state/requests/.request.tmp" "$state/requests/request.json" ) &
expect "a request renamed into place while the run waits" 0 "accepted poweroff"
wait
acted "--no-block poweroff"
echo "ok   a half-written request (dot file) is waited for and read once it is renamed into place"

### refused: the signature

new_state
request poweroff "$clock" "$(fresh_nonce)" SGFybmVzc1dyb25nS2V5MDEyMzQ1Njc4OWFiY2RlZmc=
expect "signed with another key" 0 "^home-power: refused request.json: it is not signed with the power key \\(wrong hmac\\); removed$"
not_acted "a request signed with another key"
new_state
request poweroff
sed -i 's/"action": "poweroff"/"action": "reboot"/' "$state/requests/request.json"
expect "a signed poweroff changed to reboot" 0 "wrong hmac"
not_acted "a request whose action was changed after signing"
new_state
request poweroff "$clock" 11111111111111111111111111111111
sed -i 's/"nonce": "1/"nonce": "2/' "$state/requests/request.json"
expect "a signed request with another nonce" 0 "wrong hmac"
not_acted "a request whose nonce was changed after signing"
echo "ok   wrong hmac (another key, or the action or nonce changed after signing): refused and removed, nothing run"

### refused: time, replay, rate limit

new_state
request poweroff $((clock - 121))
expect "a request 121 s old" 0 "it was made 121 s ago, more than 120 s; removed$"
not_acted "a stale request"
new_state
request poweroff $((clock + 5))
expect "a request from the future" 0 "it was made 5 s in the future; removed$"
not_acted "a request from the future"
new_state
request poweroff $((clock + 3600))
cp "$state/requests/request.json" "$work/future.json"
expect "a request dated an hour ahead" 0 "it was made 3600 s in the future; removed$"
clock=$((clock + 3600))
cp "$work/future.json" "$state/requests/request.json"
expect "the same request when its time has come" 0 "it replays nonce [0-9a-f]{8}\\.\\.\\., seen before; removed$"
not_acted "a future request replayed when its time came"
echo "ok   stale (over two minutes) or future requests: refused, and a future one cannot be replayed later"

new_state
request poweroff
cp "$state/requests/request.json" "$work/replay.json"
expect "the first of a replayed pair" 0 "accepted poweroff"
: >"$state/systemctl.calls"
cp "$work/replay.json" "$state/requests/request.json"
clock=$((clock + 30))
expect "the same request again" 0 "it replays nonce [0-9a-f]{8}\\.\\.\\., seen before; removed$"
not_acted "a replayed request"
echo "ok   a replayed request (same nonce): refused"

new_state
request reboot
expect "the first action" 0 "accepted reboot"
: >"$state/systemctl.calls"
clock=$((clock + 60))
request poweroff
expect "a second action a minute later" 0 "it comes 60 s after the last accepted action; the next is allowed in 540 s; removed$"
not_acted "an action inside the rate limit"
clock=$((clock + 539))
request poweroff
expect "just inside ten minutes" 0 "the next is allowed in 1 s"
not_acted "an action one second inside the rate limit"
clock=$((clock + 1))
request poweroff
expect "ten minutes after the first" 0 "accepted poweroff"
acted "--no-block poweroff"
echo "ok   rate limit: one accepted action per ten minutes, across runs (the state file)"

new_state
request reboot
expect "a rate-limited request's nonce" 0 "accepted reboot"
clock=$((clock + 30))
request poweroff
cp "$state/requests/request.json" "$work/limited.json"
expect "rate-limited" 0 "the next is allowed in 570 s"
clock=$((clock + 60))
cp "$work/limited.json" "$state/requests/request.json"
expect "a rate-limited request replayed" 0 "seen before"
echo "ok   a refused but signed request's nonce is remembered too"

### refused: what is asked for

new_state
for action in halt suspend kexec; do
  request "$action"
  expect "a signed $action" 0 "it asks for $action, which is neither poweroff nor reboot; removed$"
done
not_acted "an unknown action"
request poweroff
expect "poweroff after refused unknown actions" 0 "accepted poweroff"
echo "ok   unknown actions (halt, suspend, kexec), even signed: refused, and they do not count against the rate limit"

### junk

junk() {
  local name="$1" want="$2"
  printf '%s' "$3" >"$state/requests/request.json"
  expect "$name" 0 "$want"
}
new_state
nonce="$(fresh_nonce)"
mac="$(sign "$key" poweroff "$clock" "$nonce")"
junk "not JSON" "it is not JSON; removed$" 'poweroff please'
junk "empty" "it is not JSON" ''
junk "binary" "it is not JSON" "$(printf '\377\376\001')"
junk "a JSON list" "does not have exactly the fields" '["poweroff"]'
junk "a field missing" "does not have exactly the fields" "{\"action\": \"poweroff\", \"requested_at\": $clock, \"nonce\": \"$nonce\"}"
junk "an extra field" "does not have exactly the fields" "{\"action\": \"poweroff\", \"requested_at\": $clock, \"nonce\": \"$nonce\", \"hmac\": \"$mac\", \"command\": \"rm -rf /\"}"
junk "an action with a space" "has an action that is not a lowercase word" "{\"action\": \"poweroff now\", \"requested_at\": $clock, \"nonce\": \"$nonce\", \"hmac\": \"$mac\"}"
junk "requested_at as a string" "has a requested_at that is not Unix seconds" "{\"action\": \"poweroff\", \"requested_at\": \"$clock\", \"nonce\": \"$nonce\", \"hmac\": \"$mac\"}"
junk "requested_at as true" "has a requested_at that is not Unix seconds" "{\"action\": \"poweroff\", \"requested_at\": true, \"nonce\": \"$nonce\", \"hmac\": \"$mac\"}"
junk "requested_at with a fraction" "has a requested_at that is not Unix seconds" "{\"action\": \"poweroff\", \"requested_at\": $clock.5, \"nonce\": \"$nonce\", \"hmac\": \"$mac\"}"
junk "a short nonce" "has a nonce that is not 32 to 64 lowercase hex digits" "{\"action\": \"poweroff\", \"requested_at\": $clock, \"nonce\": \"abc\", \"hmac\": \"$mac\"}"
junk "an hmac in capitals" "has an hmac that is not 64 lowercase hex digits" "{\"action\": \"poweroff\", \"requested_at\": $clock, \"nonce\": \"$nonce\", \"hmac\": \"${mac^^}\"}"
junk "more than 4 KiB" "it is 4097 bytes, more than 4096; removed$" "$(head -c 4097 /dev/zero | tr '\0' ' ')"
not_acted "junk"
grep -q "$mac" "$work/out" && fail "a log line shows the hmac"
echo "ok   junk (not JSON, wrong fields, wrong types, too big): refused and removed, nothing run, nothing of it logged"

new_state
ln -s /etc/hostname "$state/requests/request.json"
expect "request.json as a link" 0 "it cannot be opened as a file \\(Too many levels of symbolic links\\); removed$"
[ -f /etc/hostname ] || fail "the link's target was removed"
mkfifo "$state/requests/request.json"
expect "request.json as a pipe" 0 "it is not a regular file; removed$"
mkdir -p "$state/requests/request.json/deeper"
ln -s /etc "$state/requests/request.json/deeper/etc"
expect "request.json as a directory" 0 "it is not a regular file; removed$"
[ -f /etc/hostname ] || fail "removing a directory followed a link out of it"
not_acted "a link, pipe or directory"
echo "ok   request.json as a link, a pipe or a directory: not followed, not blocked on, removed"

new_state
printf 'x' >"$state/requests/evil.sh"
mkdir "$state/requests/dir"
ln -s / "$state/requests/root"
expect "other names" 0 "^home-power: removed 'evil.sh', which is not a request \\(request.json is the only name read\\)$"
grep -q "removed 'root'" "$work/out" || fail "a link with another name was not removed"
printf 'x' >"$state/requests/$(printf 'bad\nname')"
expect "a name with a line break" 0 "removed 'bad\\?name'"
[ "$(wc -l <"$work/out")" -eq 1 ] || fail "a name with a line break broke the log line"
printf 'x' >"$state/requests/.stale.tmp"
touch -d @$((clock - 60)) "$state/requests/.stale.tmp"
expect "an abandoned dot file" 0 "removed '.stale.tmp'"
not_acted "other names"
echo "ok   other names (files, directories, links, dot files left over a minute): removed, one log line each"

### the key, the state, systemctl

new_state
rm "$state/power.key"
request poweroff
expect "no key" 1 "^home-power: FAILED: the power key .*/power.key cannot be read \\(No such file or directory\\); every request is refused"
grep -q "it cannot be checked" "$work/out" || fail "the request was not refused without a key"
not_acted "no key"
new_state
chmod 644 "$state/power.key"
request poweroff
expect "a key others can read" 1 "is not private to root \\(owner root, mode 0600\\)"
not_acted "a readable key"
new_state
echo "not-a-key" >"$state/power.key"
request poweroff
expect "a malformed key" 1 "does not hold base64 of 32 bytes"
not_acted "a malformed key"
new_state
rm "$state/power.key"
ln -s /etc/hostname "$state/power.key"
request poweroff
expect "a key that is a link" 1 "the power key .* cannot be read \\(Too many levels of symbolic links\\)"
not_acted "a linked key"
echo "ok   a missing, readable, malformed or linked key: every request refused and removed, exit 1"

new_state
echo '{"last_action_at": null, "nonces": []}' >"$state/lib/state.json"
request poweroff
expect "a corrupt state" 1 "FAILED: the state .* is not a state this script wrote; every request is refused"
not_acted "a corrupt state"
new_state
echo '{' >"$state/lib/state.json"
request poweroff
expect "a state that is not JSON" 1 "FAILED: the state"
not_acted "a state that is not JSON"
echo "ok   a corrupt state: every request refused, exit 1 (never an action without its rate limit)"

new_state
echo 1 >"$state/systemctl.rc"
request reboot
expect "systemctl fails" 1 "^home-power: FAILED: systemctl reboot exited 1$"
echo "ok   systemctl failing: exit 1 with a FAILED line"

new_state
run_power || fail "an empty directory failed"
[ ! -s "$work/out" ] || fail "an empty directory logged something"
[ ! -e "$state/lib/state.json" ] || fail "an empty directory wrote a state"
if run_power extra; then fail "an argument was accepted"; fi
grep -q '^usage: home-power' "$work/out" || fail "no usage line"
echo "ok   an empty directory: silent, exit 0; any argument: usage"

### the units

if command -v systemd-analyze >/dev/null 2>&1; then
  mkdir "$work/units"
  cp "$root/roles/host/files/home-power.path" "$root/roles/host/files/home-power.service" "$work/units/"
  systemd-analyze verify "$work/units/home-power.path" "$work/units/home-power.service" >"$work/out" 2>&1 || fail "systemd-analyze verify refused the units"
  [ ! -s "$work/out" ] || fail "systemd-analyze verify warned about the units"
  echo "ok   home-power.path and home-power.service pass systemd-analyze verify"
fi
grep -qx 'DirectoryNotEmpty=/run/home-power' "$root/roles/host/files/home-power.path" || { echo "FAIL home-power.path does not watch /run/home-power"; exit 1; }
grep -qx 'ExecStart=/usr/bin/python3 -I /usr/local/sbin/home-power' "$root/roles/host/files/home-power.service" || { echo "FAIL home-power.service does not run the script isolated"; exit 1; }
grep -qx 'CapabilityBoundingSet=CAP_DAC_OVERRIDE' "$root/roles/host/files/home-power.service" || { echo "FAIL home-power.service keeps more capabilities than it needs"; exit 1; }

echo "power-scripts: all cases passed"
