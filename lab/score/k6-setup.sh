#!/usr/bin/env bash
# Sets up the load box of the score search: a fresh Ubuntu 24.04 EC2 box (m5.4xlarge, three secondary private addresses) that runs
# lab/score/search.sh against the server box. Runs from a copy of this repo's tree (`git archive`) on the load box only.
#
#   sudo bash lab/score/k6-setup.sh                      the setup (below); prints the box's ssh public key last
#   bash lab/score/k6-setup.sh --check [<server>]        one line a check: k6, nofile, addresses, ports, load.js, tokens, conntrack, and ssh when a
#                                                        server address is given. Exit 1 when one fails.
#   bash lab/score/k6-setup.sh --rtt <server>            100 pings, 0.2 s apart: only min, avg and max (nothing that names a box)
#   bash lab/score/k6-setup.sh --push-seed <server>      scp of the seed to /srv/seed/ on the server box, sha256 compared on both sides
#   bash lab/score/k6-setup.sh --check-42 <server>       the challenge's test/test.sh against http://<server>:80, must end passed=42 failed=0
#                                                        (it writes to the database: the next restart gives a fresh copy)
#   bash lab/score/k6-setup.sh --allowance               the ENA's counters with `allowance` in their name (conntrack_allowance_available among them)
#   bash lab/score/k6-setup.sh --print-ips               the interface's addresses, comma separated, for run-k6.sh --local-ips
#   bash lab/score/k6-setup.sh --smoke <server>          one minute of the real run at 100 users (lab/score/run-k6.sh): the native-Linux path of the
#                                                        drivers (the load box's cgroup path, k6's summary, the server box's files) on the real boxes
#
# The setup, in order: the packages (jq, node and sqlite3 for the seed, git, ethtool, openssl); Docker CE from Docker's apt with
# {"iptables": false} in /etc/docker/daemon.json BEFORE its first start (Docker's iptables rules would load nf_conntrack, whose 262,144-entry
# table fills above about 128,000 users; k6 runs on the host network and needs no NAT), the pinned k6 image and the helper image pulled and built
# (a build on a box without NAT needs --network host); the secondary private addresses read from the instance metadata (IMDSv2) and added to the
# interface if the OS has not; the ephemeral port range 1024 to 65535 (`sysctl -w` and /etc/sysctl.d/); the challenge cloned at commit 162699a at
# /srv/challenge with bench/load.js's git blob hash checked; the seed built there (lab/seed.sh, which checks its content hash) and its
# tokens.json put in /srv/challenge/seed/, where bench/load.js and run-k6.sh look; an ssh key made for the user below. The seed's feed.db stays in
# lab/data/ for --push-seed. The user (K6_SETUP_USER, default the one who ran sudo, else ubuntu) runs everything but the setup itself.
#
# Where it reads can be swapped (K6_SETUP_CHALLENGE, K6_SETUP_METADATA, K6_SETUP_PORT_RANGE_FILE, K6_SETUP_SEED, K6_SETUP_REMOTE_SEED_DIR,
# K6_SETUP_REMOTE_SUDO, SCORE_MODULES): lab/check.sh runs it on fixtures. The output stays private (it names addresses in a few places): only
# --rtt's line is meant for the public results.
set -euo pipefail

LAB="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib.sh
source "$LAB/lib.sh"
# shellcheck source=score-lib.sh
source "$LAB/score/score-lib.sh"

CHALLENGE="${K6_SETUP_CHALLENGE:-/srv/challenge}"
CHALLENGE_URL=https://github.com/arjaythedev/twelve-dollar-server-challenge
CHALLENGE_COMMIT=162699a
OPERATOR="${K6_SETUP_USER:-${SUDO_USER:-ubuntu}}"
META="${K6_SETUP_METADATA:-http://169.254.169.254}"
PORT_RANGE_FILE="${K6_SETUP_PORT_RANGE_FILE:-/proc/sys/net/ipv4/ip_local_port_range}"
MODULES="${SCORE_MODULES:-/proc/modules}"
SEED="${K6_SETUP_SEED:-$LAB/data/feed.db}"
REMOTE_SEED_DIR="${K6_SETUP_REMOTE_SEED_DIR:-/srv/seed}"
REMOTE_SUDO="${K6_SETUP_REMOTE_SUDO:-sudo}"
CONNTRACK_MAX=1048576
SECONDARY_ADDRESSES=3

usage() { sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

failed=0
ok() { echo "ok    $1: $2"; }
bad() { echo "FAIL  $1: $2"; failed=1; }
info() { echo "info  $1: $2"; }
as_root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

# --- the network: the interface and its addresses ------------------------------------------------------------------------------------------
default_iface() { ip route show default | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}'; }
imds_token() { curl -fsS -m 3 -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 300" "$META/latest/api/token"; }

# read_metadata_addresses: sets IMDS_ADDRS (the interface's private addresses, the primary first) and IMDS_CIDR (the subnet's), from IMDSv2.
IMDS_ADDRS=() IMDS_CIDR=""
read_metadata_addresses() {
  local token mac line
  token="$(imds_token)" || return 1
  imds() { curl -fsS -m 3 -H "X-aws-ec2-metadata-token: $token" "$META/latest/meta-data/$1"; }
  mac="$(imds network/interfaces/macs/ | head -n 1 | tr -d '/')" || return 1
  [ -n "$mac" ] || return 1
  IMDS_ADDRS=()
  while IFS= read -r line; do [ -z "$line" ] || IMDS_ADDRS+=("$line"); done < <(imds "network/interfaces/macs/$mac/local-ipv4s")
  IMDS_CIDR="$(imds "network/interfaces/macs/$mac/subnet-ipv4-cidr-block")" || return 1
  [ "${#IMDS_ADDRS[@]}" -gt 0 ]
}

# iface_addresses <interface>: the IPv4 addresses on it, one a line.
iface_addresses() { ip -4 -o addr show dev "$1" | awk '{print $4}' | cut -d/ -f1; }

# --- the checks ----------------------------------------------------------------------------------------------------------------------------
check_k6() {
  local want out
  want="${LAB_K6_IMAGE#*:}"
  want="v${want%%@*}"
  docker image inspect "$LAB_K6_IMAGE" >/dev/null 2>&1 || { bad k6 "the pinned image is not pulled: $LAB_K6_IMAGE"; return; }
  out="$(docker run --rm "$LAB_K6_IMAGE" version 2>&1 | head -n 1)" || true
  if [[ "$out" == "k6 $want "* ]]; then ok k6 "$out"; else bad k6 "expected k6 $want, got '$out'"; fi
}

check_nofile() {
  local n
  docker image inspect "$LAB_K6_IMAGE" >/dev/null 2>&1 || { bad nofile "the pinned image is not pulled"; return; }
  n="$(docker run --rm --entrypoint sh --ulimit nofile=1048576:1048576 "$LAB_K6_IMAGE" -c 'ulimit -n' 2>&1 | tail -n 1)" || true
  if [ "$n" = 1048576 ]; then ok nofile "1048576 open files in a container (the limit run-k6.sh asks for)"; else bad nofile "a container gets '$n' open files, not 1048576"; fi
}

check_addresses() {
  local iface have missing="" ip
  if ! read_metadata_addresses; then bad addresses "the instance metadata (IMDSv2) did not answer: this is not an EC2 box"; return; fi
  iface="$(default_iface)"
  [ -n "$iface" ] || { bad addresses "no default route"; return; }
  have="$(iface_addresses "$iface")" || { bad addresses "cannot read the addresses of $iface"; return; }
  for ip in "${IMDS_ADDRS[@]}"; do grep -qx "$ip" <<<"$have" || missing+=" $ip"; done
  if [ "${#IMDS_ADDRS[@]}" != $((SECONDARY_ADDRESSES + 1)) ]; then
    bad addresses "the metadata lists ${#IMDS_ADDRS[@]} addresses, expected $((SECONDARY_ADDRESSES + 1)) (the primary and $SECONDARY_ADDRESSES secondary)"
  elif [ -n "$missing" ]; then bad addresses "not on $iface:$missing"
  else ok addresses "${#IMDS_ADDRS[@]} addresses on $iface (the primary and $SECONDARY_ADDRESSES secondary)"; fi
}

check_ports() {
  local lo hi
  read -r lo hi <"$PORT_RANGE_FILE" || { bad ports "cannot read $PORT_RANGE_FILE"; return; }
  if [ "$lo" = 1024 ] && [ "$hi" = 65535 ]; then ok ports "ephemeral ports 1024 to 65535"; else bad ports "ephemeral ports $lo to $hi, expected 1024 to 65535"; fi
}

check_load_js() {
  local file="$CHALLENGE/bench/load.js"
  [ -f "$file" ] || { bad load.js "no $file"; return; }
  if score_load_js_ok "$file"; then ok load.js "git blob $SCORE_LOAD_JS_BLOB, the challenge's script at $CHALLENGE_COMMIT"
  else bad load.js "git blob $(git hash-object "$file"), not the challenge's script (expected $SCORE_LOAD_JS_BLOB): it would not measure the challenge's test"; fi
}

check_tokens() {
  if [ -s "$CHALLENGE/seed/tokens.json" ]; then ok tokens "$CHALLENGE/seed/tokens.json is there"; else bad tokens "no tokens.json in $CHALLENGE/seed/ (the seed was not built)"; fi
}

# Docker's own rules would load nf_conntrack, which is off on purpose (D99). If it is loaded anyway, its table is made big enough and it is said.
check_conntrack() {
  if grep -q '^nf_conntrack ' "$MODULES"; then
    as_root sysctl -w "net.netfilter.nf_conntrack_max=$CONNTRACK_MAX" >/dev/null
    info conntrack "nf_conntrack is loaded: nf_conntrack_max set to $CONNTRACK_MAX (something loaded it: Docker's iptables rules were not off?)"
  else info conntrack "nf_conntrack is not loaded"; fi
}

ssh_opts=(-n -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o LogLevel=ERROR)
operator_home() {
  local home
  home="$(getent passwd "$OPERATOR" 2>/dev/null | cut -d: -f6)" || true
  echo "${home:-$HOME}"
}
use_key() {
  local key
  key="$(operator_home)/.ssh/id_ed25519"
  [ ! -f "$key" ] || ssh_opts+=(-i "$key")
}

check_ssh() {
  use_key
  if ssh "${ssh_opts[@]}" "$OPERATOR@$1" true >/dev/null 2>&1; then ok ssh "the server box answers over ssh as $OPERATOR with this box's key"
  else bad ssh "ssh to the server box failed (is this box's public key in its authorized_keys? is the security group open between the boxes?)"; fi
}

# run_checks [<server>]: every check, one line each; ssh only when a server is given.
run_checks() {
  check_k6
  check_nofile
  check_addresses
  check_ports
  check_load_js
  check_tokens
  check_conntrack
  [ -z "${1:-}" ] || check_ssh "$1"
}

cmd_check() {
  run_checks "${1:-}"
  [ "$failed" = 0 ] || exit 1
}

# --- the measures between the boxes ----------------------------------------------------------------------------------------------------------
cmd_rtt() {
  local out line
  out="$(ping -q -c 100 -i 0.2 "$1" 2>&1)" || { echo "FAIL  rtt: no answer to ping (does the security group allow ICMP between the boxes?)"; exit 1; }
  line="$(grep -E '^(rtt|round-trip) ' <<<"$out" | head -n 1 | sed 's/.* = //; s/ ms$//')"
  [ -n "$line" ] || { echo "FAIL  rtt: no summary line in ping's output"; exit 1; }
  IFS=/ read -r min avg max _ <<<"$line"
  echo "rtt: min $min ms, avg $avg ms, max $max ms ($(sed -n 's/^\([0-9]*\) packets transmitted.*/\1/p' <<<"$out") packets, $(sed -n 's/.* \([0-9.]*\)% packet loss.*/\1/p' <<<"$out") % lost)"
}

cmd_push_seed() {
  local here there
  [ -f "$SEED" ] || { bad seed "no $SEED (the setup builds it)"; exit 1; }
  use_key
  here="$(sha "$SEED")"
  # shellcheck disable=SC2029 # Why: the folder and the sudo word are meant to expand here.
  ssh "${ssh_opts[@]}" "$OPERATOR@$1" "$REMOTE_SUDO mkdir -p '$REMOTE_SEED_DIR' && $REMOTE_SUDO chown \"\$(id -un)\" '$REMOTE_SEED_DIR'" || { bad seed "cannot prepare $REMOTE_SEED_DIR on the server box"; exit 1; }
  scp "${ssh_opts[@]:1}" "$SEED" "$OPERATOR@$1:$REMOTE_SEED_DIR/feed.db" || { bad seed "scp failed"; exit 1; }
  there="$(ssh "${ssh_opts[@]}" "$OPERATOR@$1" "sha256sum '$REMOTE_SEED_DIR/feed.db'" | cut -d' ' -f1)"
  if [ "$here" = "$there" ]; then ok seed "sha256 $here on both boxes"; else bad seed "sha256 $here here, '$there' on the server box"; exit 1; fi
}

cmd_check_42() {
  local out
  out="$(bash "$CHALLENGE/test/test.sh" "http://$1:80" 2>&1)" || true
  if [ "$(tail -n 1 <<<"$out")" = "passed=42 failed=0" ]; then ok challenge-test "passed=42 failed=0"
  else
    grep -E 'FAIL' <<<"$out" | head -n 10 || true
    bad challenge-test "$(tail -n 1 <<<"$out")"
    exit 1
  fi
}

cmd_allowance() {
  local iface line name value
  iface="$(default_iface)"
  [ -n "$iface" ] || { echo "FAIL  allowance: no default route" >&2; exit 1; }
  as_root ethtool -S "$iface" | while IFS= read -r line; do
    case "$line" in *allowance*) name="${line%%:*}"; name="${name// /}"; value="${line##*: }"; echo "ena $name $value" ;; esac
  done
}

cmd_print_ips() {
  local iface ips
  iface="$(default_iface)"
  [ -n "$iface" ] || { echo "FAIL  ips: no default route" >&2; exit 1; }
  ips="$(iface_addresses "$iface" | paste -sd, -)"
  [ -n "$ips" ] || { echo "FAIL  ips: no address on $iface" >&2; exit 1; }
  echo "$ips"
}

# One minute of the real run, at 100 users, against the real server box: what the Mac's smoke could not run.
cmd_smoke() {
  local out ips
  use_key
  out="$(mktemp -d /tmp/score-smoke.XXXXXX)"
  ips="$(cmd_print_ips)"
  bash "$LAB/score/run-k6.sh" --base-url "http://$1:80" --ctl "bash $LAB/score/ctl-ssh.sh $OPERATOR@$1" --out "$out/run" --kind warmup --users 100 --duration 1m \
    --local-ips "$ips" --challenge "$CHALLENGE" || { bad smoke "run-k6.sh failed, see $out/run/run.json"; exit 1; }
  [ "$(jq -r '.k6_exit' "$out/run/run.json")" = 0 ] && ok smoke-k6 "k6 exited 0" || bad smoke-k6 "k6 exited $(jq -r '.k6_exit' "$out/run/run.json")"
  [ -s "$out/run/summary.json" ] && ok smoke-summary "summary.json written by k6 (the container's user can write the run folder)" || bad smoke-summary "no summary.json"
  jq -e '(.loadbox.k6_memory_peak_bytes // 0) > 0' "$out/run/run.json" >/dev/null && ok smoke-loadbox "the load box's sampler read k6's cgroup ($(jq -r '.loadbox.k6_cgroup_layout' "$out/run/run.json"))" \
    || bad smoke-loadbox "loadbox.csv has no k6 memory: the cgroup path is wrong on this box"
  jq -e '(.server.memory_current_peak // 0) > 0 and (.server.rss_peak // 0) > 0' "$out/run/run.json" >/dev/null && ok smoke-server "the server box's samples came back and are filled" \
    || bad smoke-server "server.csv is empty or missing columns"
  info smoke "the run is in $out/run: $(jq -c '{users, p95_ms, error_rate, http_reqs, vu_init_s, healthy_s}' "$out/run/run.json")"
  [ "$failed" = 0 ] || exit 1
}

# --- the setup -----------------------------------------------------------------------------------------------------------------------------
apt_get() { DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 -y -q "$@"; }

install_packages() {
  cloud-init status --wait >/dev/null 2>&1 || true
  apt_get update
  apt_get install ca-certificates curl gnupg jq sqlite3 nodejs git openssh-client ethtool openssl iputils-ping
}

# Why daemon.json comes first: the package starts the daemon when it installs, and Docker's iptables rules load nf_conntrack at that start.
install_docker() {
  local was_active=0 before=""
  mkdir -p /etc/docker
  [ ! -f /etc/docker/daemon.json ] || before="$(cat /etc/docker/daemon.json)"
  printf '{"iptables": false}\n' >/etc/docker/daemon.json
  if ! command -v docker >/dev/null 2>&1; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" >/etc/apt/sources.list.d/docker.list
    apt_get update
    apt_get install docker-ce docker-ce-cli containerd.io
  else
    systemctl is-active --quiet docker && was_active=1
    [ "$was_active" = 0 ] || [ "$before" = '{"iptables": false}' ] || systemctl restart docker
  fi
  systemctl enable --now docker
  usermod -aG docker "$OPERATOR"
  docker pull -q "$LAB_K6_IMAGE" >/dev/null
  # Why --network host: with iptables off the bridge has no NAT, so a build's `apt-get` would reach nothing. run-k6.sh builds this image when it
  # is missing (lab_ensure_tools_image), even on a Linux host where it does not use it.
  docker image inspect "$LAB_TOOLS_IMAGE" >/dev/null 2>&1 || docker build --network host -q -t "$LAB_TOOLS_IMAGE" -f "$LAB/images/Dockerfile.tools" "$LAB/images" >/dev/null
}

setup_addresses() {
  local iface have ip
  read_metadata_addresses || { echo "k6-setup: the instance metadata (IMDSv2) did not answer" >&2; exit 1; }
  iface="$(default_iface)"
  have="$(iface_addresses "$iface")"
  for ip in "${IMDS_ADDRS[@]}"; do
    grep -qx "$ip" <<<"$have" || { ip addr add "$ip/${IMDS_CIDR#*/}" dev "$iface"; echo "added $ip to $iface"; }
  done
}

# The range 1024 to 65535 gives a client 64,512 ports a destination, k6 needs them for its connections to the server (and its REST port, 6565, is
# bound before any connection is made).
setup_ports() {
  sysctl -w net.ipv4.ip_local_port_range="1024 65535" >/dev/null
  printf 'net.ipv4.ip_local_port_range = 1024 65535\n' >/etc/sysctl.d/90-twelve-dollar-ports.conf
}

setup_challenge() {
  if [ ! -d "$CHALLENGE/.git" ]; then git clone -q "$CHALLENGE_URL" "$CHALLENGE"; fi
  git -C "$CHALLENGE" checkout -q "$CHALLENGE_COMMIT"
  score_load_js_ok "$CHALLENGE/bench/load.js" || { echo "k6-setup: bench/load.js is not the challenge's script at $CHALLENGE_COMMIT" >&2; exit 1; }
  # lab/seed.sh builds lab/data/{feed.db,tokens.json}, and its upstream script checks the content hash (it exits 1 on a mismatch).
  REFERENCE_DIR="$CHALLENGE" bash "$LAB/seed.sh"
  install -m 0644 "$LAB/data/tokens.json" "$CHALLENGE/seed/tokens.json"
  chown -R "$OPERATOR:" "$LAB/data"
}

setup_key() {
  local home key
  home="$(operator_home)"
  key="$home/.ssh/id_ed25519"
  if [ ! -f "$key" ]; then
    sudo -u "$OPERATOR" mkdir -p -m 0700 "$home/.ssh"
    sudo -u "$OPERATOR" ssh-keygen -q -t ed25519 -N '' -C "score-loadbox" -f "$key"
  fi
  echo "the load box's public key (put it in $OPERATOR's authorized_keys on the server box):"
  cat "$key.pub"
}

cmd_setup() {
  [ "$(id -u)" = 0 ] || { echo "k6-setup: run the setup as root (sudo)" >&2; exit 2; }
  install_packages
  install_docker
  setup_addresses
  setup_ports
  setup_challenge
  # The setup ends with its own checks, all but the ssh one: the server box has no key yet.
  run_checks
  [ "$failed" = 0 ] || { echo "k6-setup: a check failed, see above" >&2; exit 1; }
  setup_key
}

[ "$#" -ge 1 ] || { cmd_setup; exit 0; }
case "$1" in
  --check) [ "$#" -le 2 ] || usage; cmd_check "${2:-}" ;;
  --rtt) [ "$#" -eq 2 ] || usage; cmd_rtt "$2" ;;
  --push-seed) [ "$#" -eq 2 ] || usage; cmd_push_seed "$2" ;;
  --check-42) [ "$#" -eq 2 ] || usage; cmd_check_42 "$2" ;;
  --allowance) [ "$#" -eq 1 ] || usage; cmd_allowance ;;
  --print-ips) [ "$#" -eq 1 ] || usage; cmd_print_ips ;;
  --smoke) [ "$#" -eq 2 ] || usage; cmd_smoke "$2" ;;
  *) usage ;;
esac
