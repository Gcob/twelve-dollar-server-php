#!/usr/bin/env bash
# Sets up the server box of the score search: a fresh Ubuntu 24.04 EC2 box with ONE vCPU (CPU options at launch), made the droplet's size,
# with the submission installed the way the challenge's bench installs it and started by systemd. Runs as root, from a copy of this repo's
# tree (`git archive`), on the server box only.
#
#   sudo bash lab/score/server-setup.sh --shape                         adds mem=2G to the kernel's boot line, updates grub, reboots. Nothing else.
#   sudo bash lab/score/server-setup.sh --launch-epoch <epoch>          after the reboot: everything below
#   sudo bash lab/score/server-setup.sh --check                         only the checks, no install
#   sudo bash lab/score/server-setup.sh --cap-only --launch-epoch <e>   only re-arms the 240-minute shutdown
#
# The install, in order: the shape checks (a FAIL stops here, nothing is installed), the shutdown cap re-armed with the time left (the reboot
# of --shape cleared it), a wait for Ubuntu's first-boot jobs (cloud-init and the package manager's lock: on one vCPU they can hold it past
# install.sh's 120 s, and they are not disabled), the user `deploy`, the submission copied to /srv/php-Gcob, `bash install.sh` as root (timed),
# `build.sh` as deploy, the seed (/srv/seed/feed.db: it must already be there, sent from the load box by `k6-setup.sh --push-seed`; it is
# made root's and read-only), /srv/data for deploy, the controller (/srv/score/), the unit installed and enabled but not started, then one
# `server-ctl.sh restart` and the checks of the running service. The challenge's 42 checks are not run here: they need jq, which stays off this
# box, so they run from the load box (`k6-setup.sh --check-42`). `curl` is on this box because Ubuntu's image ships it, and `server-ctl.sh
# restart` polls /health with it: the checks say so when it is missing.
#
# Every line is `ok`, `FAIL` or `info`, then the check's name and what it saw; the exit code is 0 only when nothing failed. The files the shape
# checks read can be swapped (SCORE_CPUINFO, SCORE_MEMINFO, SCORE_SWAPS, SCORE_MODULES), and so can the unit's cgroup and /proc
# (SCORE_UNIT_CGROUP, SCORE_PROC), the user the service must run as (SCORE_SETUP_USER), the clock (SCORE_SETUP_NOW) and the folder of grub's
# drop-ins (SCORE_GRUB_DIR): lab/check.sh feeds it fixtures that way.
set -euo pipefail

CPUINFO="${SCORE_CPUINFO:-/proc/cpuinfo}"
MEMINFO="${SCORE_MEMINFO:-/proc/meminfo}"
SWAPS="${SCORE_SWAPS:-/proc/swaps}"
MODULES="${SCORE_MODULES:-/proc/modules}"
UNIT=php-gcob
UNIT_CGROUP="${SCORE_UNIT_CGROUP:-/sys/fs/cgroup/system.slice/$UNIT.service}"
PROC="${SCORE_PROC:-/proc}"
SERVICE_USER="${SCORE_SETUP_USER:-deploy}"
GRUB_DIR="${SCORE_GRUB_DIR:-/etc/default/grub.d}"
CAP_MINUTES=240
MEM_LIMIT_MIB=2048
# CAP_NET_BIND_SERVICE is capability 10: the bit 0x400.
AMBIENT_WANT=0000000000000400
NOFILE_WANT=65535
CURL="${SCORE_CURL:-curl}"

TREE="$(cd "$(dirname "$0")/../.." && pwd)"
SUBMISSION=/srv/php-Gcob
SEED=/srv/seed/feed.db

usage() { echo "usage: server-setup.sh --shape | --launch-epoch <epoch> | --check | --cap-only --launch-epoch <epoch>" >&2; exit 2; }

mode="" launch_epoch=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --shape) mode=shape ;;
    --check) mode=check ;;
    --cap-only) mode=cap ;;
    --launch-epoch) [ "$#" -ge 2 ] || usage; launch_epoch="$2"; shift ;;
    *) usage ;;
  esac
  shift
done
[ -n "$mode" ] || mode=install
[ -z "$launch_epoch" ] || [[ "$launch_epoch" =~ ^[0-9]+$ ]] || usage
{ [ "$mode" != install ] && [ "$mode" != cap ]; } || [ -n "$launch_epoch" ] || usage

failed=0
ok() { echo "ok    $1: $2"; }
bad() { echo "FAIL  $1: $2"; failed=1; }
info() { echo "info  $1: $2"; }

# --- --shape -----------------------------------------------------------------------------------------------------------------------
# Why 99-: Ubuntu's cloud image sets the boot line's options in /etc/default/grub.d/50-cloudimg-settings.cfg, and the drop-ins are read in
# name order, so this one appends to what the image set. Appending, never replacing, keeps the image's console and NVMe options.
shape_boot() {
  mkdir -p "$GRUB_DIR"
  printf '%s\n' '# The droplet has 2 GB: the kernel uses only that much of this box'"'"'s memory (lab/score/server-setup.sh --shape).' \
    'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT mem=2G"' >"$GRUB_DIR/99-twelve-dollar-mem.cfg"
  update-grub
  echo "shape: mem=2G is on the boot line, rebooting"
  reboot
}

# --- the shape checks ----------------------------------------------------------------------------------------------------------------
# Each check says ok or FAIL. The CPUs are counted in cpuinfo (what nproc reads on a box that has no CPU restriction).
check_shape() {
  local cpus mem_kb swaps
  cpus="$(grep -c '^processor' "$CPUINFO" || true)"
  if [ "$cpus" = 1 ]; then ok cpus "1 CPU"; else bad cpus "$cpus CPUs, the droplet has 1 (launch with --cpu-options CoreCount=1,ThreadsPerCore=1)"; fi
  mem_kb="$(awk '/^MemTotal:/ {print $2}' "$MEMINFO")"
  if [ -n "$mem_kb" ] && [ $((mem_kb / 1024)) -le "$MEM_LIMIT_MIB" ]; then ok memory "MemTotal $((mem_kb / 1024)) MiB, at most $MEM_LIMIT_MIB"
  else bad memory "MemTotal ${mem_kb:-?} kB, over $MEM_LIMIT_MIB MiB (is mem=2G on the boot line? run --shape)"; fi
  swaps="$(tail -n +2 "$SWAPS" | grep -c . || true)"
  if [ "$swaps" = 0 ]; then ok swap "no swap"; else bad swap "$swaps swap areas: $(tail -n +2 "$SWAPS" | awk '{print $1}' | paste -sd' ' -)"; fi
  if grep -q '^nf_conntrack ' "$MODULES"; then info conntrack "nf_conntrack is loaded"; else info conntrack "nf_conntrack is not loaded"; fi
}

# --- the service checks ----------------------------------------------------------------------------------------------------------------
# The unit's processes come from its cgroup. For each: the user, the open files limit (soft and hard, systemd's LimitNOFILE) and the ambient
# capabilities (CapAmb of /proc/<pid>/status, decoded when capsh is there).
check_service() {
  local pids=() pid uid user users="" limits_bad="" caps_bad="" soft hard capamb decoded="" nproc_seen
  # Why: the sampler reads the ENA's allowance counters with ethtool; the install adds it when the image has none.
  if command -v ethtool >/dev/null 2>&1; then info ethtool "present (the sampler reads the ENA's counters with it)"; else info ethtool "missing: the sampler cannot read the ENA's allowance counters"; fi
  # Why: nothing installs curl here (the image has it); `server-ctl.sh restart` polls /health with it, and without it every restart would fail after 60 s.
  if command -v "$CURL" >/dev/null 2>&1; then ok curl "present (server-ctl.sh restart polls /health with it)"; else bad curl "missing: server-ctl.sh restart polls /health with it, and Ubuntu's image ships it"; fi
  if systemctl is-active --quiet "$UNIT"; then ok unit "$UNIT is active"; else bad unit "$UNIT is not active"; fi
  if [ -r "$UNIT_CGROUP/cgroup.procs" ]; then
    while read -r pid; do pids+=("$pid"); done <"$UNIT_CGROUP/cgroup.procs"
  fi
  nproc_seen="${#pids[@]}"
  if [ "$nproc_seen" = 0 ]; then
    bad user "no process in $UNIT_CGROUP"
    bad limits "no process in $UNIT_CGROUP"
    bad capability "no process in $UNIT_CGROUP"
    return
  fi
  for pid in "${pids[@]}"; do
    uid="$(awk '/^Uid:/ {print $2}' "$PROC/$pid/status")"
    user="$(id -nu "$uid" 2>/dev/null || echo "uid$uid")"
    [ "$user" = "$SERVICE_USER" ] || users+=" $pid:$user"
    read -r soft hard < <(awk '/^Max open files/ {print $4, $5}' "$PROC/$pid/limits")
    { [ "$soft" = "$NOFILE_WANT" ] && [ "$hard" = "$NOFILE_WANT" ]; } || limits_bad+=" $pid:$soft/$hard"
    capamb="$(awk '/^CapAmb:/ {print $2}' "$PROC/$pid/status")"
    [ "$capamb" = "$AMBIENT_WANT" ] || caps_bad+=" $pid:$capamb"
  done
  if [ -z "$users" ]; then ok user "$nproc_seen processes run as $SERVICE_USER"; else bad user "not $SERVICE_USER:$users"; fi
  if [ -z "$limits_bad" ]; then ok limits "$nproc_seen processes have Max open files $NOFILE_WANT"; else bad limits "expected $NOFILE_WANT/$NOFILE_WANT (soft/hard):$limits_bad"; fi
  if [ -z "$caps_bad" ]; then
    command -v capsh >/dev/null 2>&1 && decoded=" ($(capsh --decode="$AMBIENT_WANT" | sed 's/^[^=]*=//'))"
    ok capability "$nproc_seen processes have CapAmb $AMBIENT_WANT$decoded"
  else bad capability "expected CapAmb $AMBIENT_WANT (cap_net_bind_service):$caps_bad"; fi
}

# --- the 240-minute cap ----------------------------------------------------------------------------------------------------------------
# cap_minutes <launch epoch> <now>: the minutes left of the cap, rounded up, at least 1.
cap_minutes() {
  local left=$(($1 + CAP_MINUTES * 60 - $2))
  if [ "$left" -le 0 ]; then echo 1; else echo $(((left + 59) / 60)); fi
}

arm_cap() {
  local now minutes
  now="${SCORE_SETUP_NOW:-$(date +%s)}"
  minutes="$(cap_minutes "$launch_epoch" "$now")"
  shutdown -h "+$minutes" >/dev/null 2>&1 || { bad cap "shutdown -h +$minutes failed"; return; }
  if [ "$((launch_epoch + CAP_MINUTES * 60))" -le "$now" ]; then bad cap "the $CAP_MINUTES-minute cap is already past: the box shuts down in 1 minute"
  else ok cap "the box shuts down in $minutes minutes ($CAP_MINUTES minutes after the launch)"; fi
}

# --- the install -----------------------------------------------------------------------------------------------------------------------
# Ubuntu's first-boot jobs (cloud-init, then unattended upgrades and the apt timers' units) take the package manager's lock. Waiting for them
# is part of the setup; stopping them would change the box.
wait_for_first_boot() {
  local began now
  began="$(date +%s)"
  cloud-init status --wait >/dev/null 2>&1 || true
  while locked; do sleep 2; done
  now="$(date +%s)"
  echo "info  first-boot: waited $((now - began)) s for cloud-init and the package manager's lock"
}
locked() {
  local file
  for file in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock; do
    [ -e "$file" ] || continue
    if command -v fuser >/dev/null 2>&1; then fuser "$file" >/dev/null 2>&1 && return 0
    else pgrep -x 'apt|apt-get|dpkg|unattended-upgr' >/dev/null && return 0; fi
  done
  return 1
}

install_submission() {
  local log=/var/log/php-gcob-install.log began secs
  id deploy >/dev/null 2>&1 || useradd -m deploy
  rm -rf "$SUBMISSION"
  mkdir -p /srv
  cp -a "$TREE/submissions/php-Gcob" "$SUBMISSION"
  chown -R deploy:deploy "$SUBMISSION"
  echo "info  install: running install.sh as root (about 4 minutes on one vCPU), log $log"
  began="$(date +%s)"
  (cd "$SUBMISSION" && bash install.sh >"$log" 2>&1) || { tail -n 30 "$log"; bad install "install.sh failed"; return 1; }
  secs=$(($(date +%s) - began))
  ok install "install.sh took $secs s: $(grep '^installed: ' "$log" | tail -n 1)"
  runuser -u deploy -- bash "$SUBMISSION/build.sh" >"$log.build" 2>&1 || { tail -n 30 "$log.build"; bad build "build.sh failed as deploy"; return 1; }
  ok build "build.sh passed as deploy"
}

install_seed_and_unit() {
  [ -f "$SEED" ] || { bad seed "$SEED is missing: send it first from the load box (k6-setup.sh --push-seed)"; return 1; }
  chown root:root /srv/seed "$SEED"
  chmod 0755 /srv/seed
  chmod 0444 "$SEED"
  ok seed "$SEED is root's and read-only, sha256 $(sha256sum "$SEED" | cut -d' ' -f1)"
  install -d -o deploy -g deploy -m 0755 /srv/data
  install -d -m 0755 /srv/score
  install -m 0755 "$TREE/lab/score/server-ctl.sh" "$TREE/lab/score/server-sample.sh" /srv/score/
  install -m 0644 "$TREE/lab/score/php-gcob.service" /etc/systemd/system/$UNIT.service
  systemctl daemon-reload
  systemctl enable "$UNIT" >/dev/null 2>&1
  ok unit-installed "$UNIT.service installed and enabled, not started"
}

install_all() {
  local secs
  # The seed is checked before the long install: a missing seed is a one-minute fix, not a 4-minute wait.
  [ -f "$SEED" ] || { bad seed "$SEED is missing: send it first from the load box (k6-setup.sh --push-seed)"; return 1; }
  wait_for_first_boot
  # Why: the sampler reads the server box's ENA allowance counters with ethtool. Not a tuning: nothing it does touches the measured path.
  command -v ethtool >/dev/null 2>&1 || apt-get -o DPkg::Lock::Timeout=120 install -y -q ethtool >/dev/null
  install_submission || return 1
  install_seed_and_unit || return 1
  secs="$(/srv/score/server-ctl.sh restart | tail -n 1)" || { bad restart "server-ctl.sh restart failed"; return 1; }
  ok restart "healthy $secs s after the start, on a fresh copy of the seed"
}

summary() {
  if [ "$failed" = 0 ]; then echo "server-setup: ok"; else echo "server-setup: FAILED" >&2; exit 1; fi
}

case "$mode" in
  shape) shape_boot ;;
  cap) arm_cap; summary ;;
  check) check_shape; check_service; summary ;;
  install)
    check_shape
    [ "$failed" = 0 ] || { echo "server-setup: the shape is wrong, nothing was installed" >&2; exit 1; }
    arm_cap
    [ "$failed" = 0 ] || { echo "server-setup: nothing was installed" >&2; exit 1; }
    install_all || { echo "server-setup: FAILED" >&2; exit 1; }
    check_service
    summary ;;
esac
