#!/usr/bin/env bash
# Tests roles/quiet/files/infra-quiet against a fake nvidia-smi and a fake
# cpufreq tree in a temp dir (INFRA_QUIET_NVIDIA_SMI, INFRA_QUIET_CPUFREQ,
# INFRA_QUIET_CONFIG; INFRA_QUIET_NOW sets the clock for auto). Nothing here
# touches the local GPU or CPU.
#
#   bash ci/quiet-scripts.sh
#
# Prints "ok   ..." per case and stops with "FAIL ..." on the first failure.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
quiet="$root/roles/quiet/files/infra-quiet"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

# state/gpu: one "<index>, <limit>, <default>, <min>, <max>, <persistence>" line per GPU,
# what --query-gpu prints; -pl and -pm change it. state/smi.err: every call fails with it.
# state/pl.rc: -pl fails with that code.
cat >"$work/bin/nvidia-smi" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
state="$FAKE_STATE"
printf '%s\n' "$*" >>"$state/smi.calls"
if [ -f "$state/smi.err" ]; then cat "$state/smi.err" >&2; exit 9; fi
case "$*" in
  "--query-gpu=index,power.limit,power.default_limit,power.min_limit,power.max_limit,persistence_mode --format=csv,noheader,nounits")
    cat "$state/gpu" ;;
  "-i "*" -pl "*)
    [ ! -f "$state/pl.rc" ] || exit "$(cat "$state/pl.rc")"
    awk -F', ' -v OFS=', ' -v i="$2" -v w="$4" '$1 == i { $2 = w } { print }' "$state/gpu" >"$state/gpu.new"
    mv "$state/gpu.new" "$state/gpu" ;;
  "-i "*" -pm 1")
    awk -F', ' -v OFS=', ' -v i="$2" '$1 == i { $6 = "Enabled" } { print }' "$state/gpu" >"$state/gpu.new"
    mv "$state/gpu.new" "$state/gpu" ;;
  *) echo "fake nvidia-smi: unsupported: $*" >&2; exit 2 ;;
esac
SH
chmod +x "$work/bin/nvidia-smi"

count=0
state=""
new_state() {
  local policy
  count=$((count + 1))
  state="$work/state$count"
  mkdir -p "$state/cpufreq"
  : >"$state/smi.calls"
  echo "0, 184.00, 184.00, 125.00, 184.00, Enabled" >"$state/gpu"
  # A hybrid CPU: two policies with different maxima.
  for policy in policy0:4000000 policy4:3000000; do
    mkdir -p "$state/cpufreq/${policy%%:*}"
    echo "${policy##*:}" >"$state/cpufreq/${policy%%:*}/cpuinfo_max_freq"
    echo 800000 >"$state/cpufreq/${policy%%:*}/cpuinfo_min_freq"
    echo "${policy##*:}" >"$state/cpufreq/${policy%%:*}/scaling_max_freq"
  done
  printf '%s\n' "# Managed by Ansible" "QUIET_START=23:00" "QUIET_END=08:00" "QUIET_TIMEZONE=Europe/Berlin" \
    "QUIET_GPU_POWER_LIMIT_W=130" "QUIET_CPU_MAX_PERCENT=70" >"$state/quiet.env"
}

setting() {
  sed -i "s|^$1=.*|$1=$2|" "$state/quiet.env"
}

run_quiet() {
  FAKE_STATE="$state" INFRA_QUIET_CONFIG="$state/quiet.env" INFRA_QUIET_CPUFREQ="$state/cpufreq" \
    INFRA_QUIET_NVIDIA_SMI="${smi:-$work/bin/nvidia-smi}" "$quiet" "$@" >"$work/out" 2>&1
}

one_line() {
  [ "$(wc -l <"$work/out")" -eq 1 ] || { cat "$work/out"; echo "FAIL more or less than one log line: $1"; exit 1; }
}

expect_ok() {
  local name="$1" want="$2"
  shift 2
  if ! run_quiet "$@"; then cat "$work/out"; echo "FAIL expected success: $name"; exit 1; fi
  one_line "$name"
  grep -qE -- "$want" "$work/out" || { cat "$work/out"; echo "FAIL wrong log line (wanted '$want'): $name"; exit 1; }
}

expect_failed() {
  local name="$1" want="$2"
  shift 2
  if run_quiet "$@"; then cat "$work/out"; echo "FAIL expected failure: $name"; exit 1; fi
  one_line "$name"
  grep -qE -- "$want" "$work/out" || { cat "$work/out"; echo "FAIL failed for the wrong reason (wanted '$want'): $name"; exit 1; }
}

gpu_limit() {
  cut -d, -f2 "$state/gpu" | tr -d ' '
}

cpu_max() {
  printf '%s %s' "$(cat "$state/cpufreq/policy0/scaling_max_freq")" "$(cat "$state/cpufreq/policy4/scaling_max_freq")"
}

### start, end, and both again: idempotent

new_state
expect_ok "start" "^infra-quiet: quiet hours \\(23:00-08:00 Europe/Berlin\\): GPU0 130.00 W, was 184.00 W; CPU top frequency 70% of its maximum on 2 policies \\(2 changed\\)$" start
[ "$(gpu_limit)" = 130.00 ] && [ "$(cpu_max)" = "2800000 2100000" ] || { cat "$state/gpu"; cpu_max; echo "FAIL start did not lower the GPU limit and the CPU maxima"; exit 1; }
: >"$state/smi.calls"
expect_ok "start again" "GPU0 already 130.00 W; CPU top frequency 70% of its maximum on 2 policies \\(0 changed\\); no change$" start
grep -q -- '-pl' "$state/smi.calls" && { cat "$state/smi.calls"; echo "FAIL a second start set the power limit again"; exit 1; }
echo "ok   start: GPU 130 W, each CPU policy 70% of its own maximum; a second start changes nothing"
expect_ok "end" "^infra-quiet: normal hours: GPU0 184.00 W \\(its default\\), was 130.00 W; CPU top frequency back to its maximum on 2 policies \\(2 changed\\)$" end
[ "$(gpu_limit)" = 184.00 ] && [ "$(cpu_max)" = "4000000 3000000" ] || { cat "$state/gpu"; cpu_max; echo "FAIL end did not restore the defaults"; exit 1; }
expect_ok "end again" "no change$" end
echo "ok   end: the GPU's default limit and cpuinfo_max_freq back; a second end changes nothing"

### auto: whichever the clock says, over midnight or not

new_state
for now in 23:00 23:30 00:00 07:59; do
  INFRA_QUIET_NOW="$now" expect_ok "auto at $now" "^infra-quiet: auto at $now Europe/Berlin: quiet hours" auto
done
for now in 08:00 12:00 22:59; do
  INFRA_QUIET_NOW="$now" expect_ok "auto at $now" "^infra-quiet: auto at $now Europe/Berlin: normal hours" auto
done
[ "$(gpu_limit)" = 184.00 ] || { echo "FAIL auto in the day left the GPU limited"; exit 1; }
setting QUIET_START 01:00
setting QUIET_END 05:00
INFRA_QUIET_NOW=03:00 expect_ok "auto inside a window that does not cross midnight" "quiet hours \\(01:00-05:00" auto
INFRA_QUIET_NOW=23:30 expect_ok "auto after a window that does not cross midnight" "normal hours" auto
expect_ok "auto on the real clock" "^infra-quiet: auto at [0-2][0-9]:[0-5][0-9] Europe/Berlin: (quiet|normal) hours" auto
echo "ok   auto: quiet from the start minute up to (not including) the end minute, across midnight or not"

### the card's range, persistence mode, several GPUs

new_state
setting QUIET_GPU_POWER_LIMIT_W 100
expect_ok "a limit below the card's minimum" "GPU0 125.00 W \\(its minimum, above the 100 W asked for\\)" start
[ "$(gpu_limit)" = 125.00 ] || { echo "FAIL a limit below the minimum was not raised to it"; exit 1; }
setting QUIET_GPU_POWER_LIMIT_W 250
expect_ok "a limit above the card's maximum" "GPU0 184.00 W \\(its maximum, below the 250 W asked for\\)" start
new_state
printf '%s\n' "0, 184.00, 184.00, 125.00, 184.00, Disabled" "1, 250.00, 250.00, 100.00, 300.00, Enabled" >"$state/gpu"
expect_ok "two GPUs, one without persistence mode" "GPU0 persistence mode turned on; GPU0 130.00 W, was 184.00 W; GPU1 130.00 W, was 250.00 W" start
[ "$(grep -n -- '-i 0 -pm 1' "$state/smi.calls" | cut -d: -f1)" -lt "$(grep -n -- '-i 0 -pl 130.00' "$state/smi.calls" | cut -d: -f1)" ] ||
  { cat "$state/smi.calls"; echo "FAIL persistence mode was not turned on before the limit was set"; exit 1; }
: >"$state/smi.calls"
expect_ok "end leaves persistence mode alone" "GPU0 184.00 W \\(its default\\)" end
grep -q -- '-pm' "$state/smi.calls" && { echo "FAIL end touched persistence mode"; exit 1; }
new_state
echo "0, [N/A], [N/A], [N/A], [N/A], Enabled" >"$state/gpu"
expect_ok "a GPU without power limits" "GPU0: no power limit to set, skipped; CPU" start
echo "ok   GPU: a limit outside the card's range goes to the nearest end; persistence mode on first; every GPU; [N/A] skipped"

### nothing to control

new_state
smi="$work/no-such-nvidia-smi" expect_ok "no nvidia-smi" "GPU: no nvidia-smi, skipped; CPU top frequency 70% of its maximum on 2 policies \\(2 changed\\)" start
new_state
rm -rf "$state/cpufreq"/*
expect_ok "no cpufreq" "GPU0 130.00 W, was 184.00 W; CPU: no cpufreq, skipped$" start
new_state
rm -rf "$state/cpufreq"/*
smi="$work/no-such-nvidia-smi" expect_ok "neither" "GPU: no nvidia-smi, skipped; CPU: no cpufreq, skipped; no change$" start
echo "ok   no nvidia-smi or no cpufreq: that part is skipped, the other still applied"

### failures

new_state
echo "Failed to initialize NVML: Driver/library version mismatch" >"$state/smi.err"
expect_failed "nvidia-smi fails" "^infra-quiet: FAILED: quiet hours .*GPU: nvidia-smi: Failed to initialize NVML: Driver/library version mismatch; CPU top frequency 70% of its maximum on 2 policies \\(2 changed\\)$" start
new_state
echo 3 >"$state/pl.rc"
expect_failed "nvidia-smi -pl refused" "FAILED: GPU0: nvidia-smi -pl 130.00 refused" start
[ "$(cpu_max)" = "2800000 2100000" ] || { echo "FAIL a GPU failure stopped the CPU part"; exit 1; }
new_state
echo garbage >"$state/cpufreq/policy4/cpuinfo_max_freq"
expect_failed "an unreadable cpufreq policy" "FAILED: CPU: cannot read the frequencies in .*/policy4" start
[ "$(cat "$state/cpufreq/policy0/scaling_max_freq")" = 2800000 ] || { echo "FAIL one bad policy stopped the others"; exit 1; }
if [ "$(id -u)" -ne 0 ]; then
  new_state
  chmod 444 "$state/cpufreq/policy0/scaling_max_freq"
  expect_failed "a refused scaling_max_freq" "FAILED: CPU: .*/policy0 refused scaling_max_freq 2800000" start
fi
echo "ok   a failed part exits 1 with one FAILED line; the other parts are still applied"

### invalid settings change nothing

invalid() {
  local name="$1" key="$2" value="$3" want="$4"
  new_state
  if [ -n "$key" ]; then setting "$key" "$value"; fi
  expect_failed "$name" "^infra-quiet: FAILED: $want; nothing was changed$" start
  [ ! -s "$state/smi.calls" ] && [ "$(cpu_max)" = "4000000 3000000" ] || { cat "$state/smi.calls"; echo "FAIL an invalid setting changed something: $name"; exit 1; }
}
invalid "a start that is not a time" QUIET_START 25:00 "QUIET_START '25:00' is not HH:MM"
invalid "an end that is not a time" QUIET_END 8:00 "QUIET_END '8:00' is not HH:MM"
invalid "the same start and end" QUIET_END 23:00 "QUIET_START and QUIET_END are both 23:00"
invalid "an unknown zone" QUIET_TIMEZONE Mars/Olympus "QUIET_TIMEZONE 'Mars/Olympus' is not a time zone in /usr/share/zoneinfo"
invalid "a zone that climbs out of zoneinfo" QUIET_TIMEZONE ../../etc/passwd "QUIET_TIMEZONE '../../etc/passwd' is not a time zone in /usr/share/zoneinfo"
invalid "watts that are not a number" QUIET_GPU_POWER_LIMIT_W 130W "QUIET_GPU_POWER_LIMIT_W '130W' is not whole watts from 50 to 1000"
invalid "too few watts" QUIET_GPU_POWER_LIMIT_W 10 "QUIET_GPU_POWER_LIMIT_W '10' is not whole watts from 50 to 1000"
invalid "too low a CPU percent" QUIET_CPU_MAX_PERCENT 20 "QUIET_CPU_MAX_PERCENT '20' is not a whole percent from 30 to 100"
invalid "a CPU percent over 100" QUIET_CPU_MAX_PERCENT 150 "QUIET_CPU_MAX_PERCENT '150' is not a whole percent from 30 to 100"
new_state
echo "QUIET_EXTRA=1" >>"$state/quiet.env"
expect_failed "an unknown setting" "unknown setting 'QUIET_EXTRA'" start
new_state
rm "$state/quiet.env"
expect_failed "no settings file" "quiet.env is missing \\(provision with --tags quiet\\); nothing was changed" start
new_state
INFRA_QUIET_NOW=7:00 expect_failed "auto with a bad clock" "the time '7:00' is not HH:MM" auto
new_state
if run_quiet; then echo "FAIL no mode was accepted"; exit 1; fi
grep -q '^usage: infra-quiet start|end|auto$' "$work/out" || { cat "$work/out"; echo "FAIL no usage line"; exit 1; }
[ ! -s "$state/smi.calls" ] || { echo "FAIL a usage error touched the GPU"; exit 1; }
echo "ok   invalid settings, an unknown setting, no settings file or no mode: exit non-zero, nothing changed"

echo "quiet-scripts: all cases passed"
