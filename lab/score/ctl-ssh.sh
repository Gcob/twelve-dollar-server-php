#!/usr/bin/env bash
# The server controller the driver runs on the load box (`search.sh --ctl "bash lab/score/ctl-ssh.sh <user>@<server address>"`): each command
# of the controller's interface (lab/score/ctl-local.sh has the list) goes over ssh to /srv/score/server-ctl.sh on the server box, as root
# through sudo. The one thing ssh cannot do is `sample-stop <dir>`: the driver's folder is on this box, the sampler's files are on the other,
# so the sampler works in a fixed folder there and `sample-stop` brings its files back into <dir> here.
#
#   bash lab/score/ctl-ssh.sh <user>@<host> restart | sample-start <dir> | sample-stop <dir> | facts | died
#
# SCORE_SSH_KEY names the key (ssh's own default otherwise), SCORE_REMOTE_CTL the remote command (default `sudo /srv/score/server-ctl.sh`) and
# SCORE_REMOTE_DIR the server box's folder for one run's samples (default /tmp/score-sample): lab/check.sh swaps them. The ssh options keep a
# missing key from asking for a password and a lost box from hanging a run: BatchMode, a 10 s connection timeout, keep-alives.
set -euo pipefail

REMOTE_CTL="${SCORE_REMOTE_CTL:-sudo /srv/score/server-ctl.sh}"
REMOTE_DIR="${SCORE_REMOTE_DIR:-/tmp/score-sample}"

usage() { echo "usage: ctl-ssh.sh <user>@<host> restart | sample-start <dir> | sample-stop <dir> | facts | died" >&2; exit 2; }
[ "$#" -ge 2 ] || usage
host="$1" command="$2"
shift 2

ssh_args=(-n -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=15 -o LogLevel=ERROR)
[ -z "${SCORE_SSH_KEY:-}" ] || ssh_args+=(-i "$SCORE_SSH_KEY")
remote() { ssh "${ssh_args[@]}" "$host" "$@"; }

case "$command" in
  restart | facts | died)
    [ "$#" -eq 0 ] || usage
    remote "$REMOTE_CTL" "$command" ;;
  sample-start)
    [ "$#" -eq 1 ] || usage
    remote "$REMOTE_CTL" sample-start "$REMOTE_DIR" ;;
  sample-stop)
    [ "$#" -eq 1 ] || usage
    mkdir -p "$1"
    remote "$REMOTE_CTL" sample-stop "$REMOTE_DIR" >/dev/null
    remote tar -C "$REMOTE_DIR" --exclude=./sampler.pid -cf - . | tar -C "$1" -xf - ;;
  *) usage ;;
esac
