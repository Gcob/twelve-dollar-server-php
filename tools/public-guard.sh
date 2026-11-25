#!/usr/bin/env bash
# The public guard: this repository is public, so nothing private may reach it. It refuses e-mail addresses,
# absolute home paths (/Users/<name>, /home/<name>), the Mac's per-user temp folder (/var/folders/..., also as
# /private/var/folders/...), AWS's traces (IPv4 addresses, `ip-N-N-N-N` host names, resource ids, 12-digit account
# ids) and every word of a private denylist.
#
#   bash tools/public-guard.sh tree        # scan every tracked file as it is on disk (lab/check.sh runs this)
#   bash tools/public-guard.sh pre-push    # scan what a push sends: added lines and commit messages (.githooks/pre-push)
#   bash tools/public-guard.sh stdin       # scan text given on stdin (the self-test)
#
# The denylist is private on purpose: listing the words here would publish them. It lives in the factory repo, one
# fixed string per line (`#` starts a comment), matched case-insensitively:
#   ../twelve-dollar-server-factory/guard/denylist.txt   (override with PUBLIC_GUARD_DENYLIST)
# Without it, `pre-push` refuses to push: a guard that silently checks nothing is worse than none.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DENYLIST="${PUBLIC_GUARD_DENYLIST:-$REPO/../twelve-dollar-server-factory/guard/denylist.txt}"

# Why: generic addresses are fine (examples, GitHub's noreply). Everything else is a real person's address.
EMAIL_RE='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
EMAIL_OK_RE='@(example\.(com|org|net)|users\.noreply\.github\.com)|noreply@|^git@'
HOME_RE='/(Users|home)/[A-Za-z0-9._-]+'
HOME_OK_RE='/(Users|home)/(\.\.\.|runner|user|me|you|example|<[^>]*>)'
# Why: macOS puts a per-user hash in every temp folder (/var/folders/<hash>/T/...). It names no one, but it is as private as a home path.
TEMP_RE='/var/folders/'
# Why: a run on AWS leaves addresses, ids and account numbers in its output, and a result that quotes one names a real box.
# An IPv4 address is a run of exactly four dotted numbers up to 255 (a version string has three, or five); the addresses that name no box
# (loopback, 0.0.0.0, the link-local range of EC2's metadata service, the documentation ranges) are fine, and so is the one example of the challenge's own README (its k6 command line, quoted in
# docs/ and in lab/macro/k6/realistic.js: a private address no box of ours has). The ids are the kinds EC2 prints, with the 8 or 17 hex digits it
# gives them; an id and the 12-digit account number must stand alone, so a hash that holds 12 digits, or the decimals of a rate, are not an account.
IPV4_OK_RE='^(127\.|169\.254\.|0\.0\.0\.0$|192\.0\.2\.|198\.51\.100\.|203\.0\.113\.)'
IPV4_EXAMPLE_RE='BASE_URL=http://10\.0\.0\.5( |$)'
HOST_RE='ip-[0-9]{1,3}-[0-9]{1,3}-[0-9]{1,3}-[0-9]{1,3}'
AWS_ID_RE='(^|[^A-Za-z0-9])(i|sg|vol|eni|ami|subnet|vpc|pg|key)-([0-9a-f]{17}|[0-9a-f]{8})($|[^A-Za-z0-9])'
ACCOUNT_RE='(^|[^0-9A-Za-z.])[0-9]{12}($|[^0-9A-Za-z.]|\.($|[^0-9]))'

# scan_aws_traces <file of "<where>:<text>" lines>: one finding a line that holds an AWS trace. Whole-file passes, because a result file can hold
# thousands of numbers and a pass a line would take minutes.
scan_aws_traces() {
  grep -E "$HOST_RE" "$1" | sed -E 's/^([^:]*):.*/\1: an AWS host name/' || true
  grep -E "$AWS_ID_RE" "$1" | sed -E 's/^([^:]*):.*/\1: an AWS resource id/' || true
  grep -E "$ACCOUNT_RE" "$1" | sed -E 's/^([^:]*):.*/\1: a 12-digit account id/' || true
  grep -E '[0-9]+(\.[0-9]+){3}' "$1" | OK="$IPV4_OK_RE" EXAMPLE="$IPV4_EXAMPLE_RE" awk '
    {
      where = substr($0, 1, index($0, ":") - 1)
      text = substr($0, index($0, ":") + 1)
      gsub(ENVIRON["EXAMPLE"], "", text)
      while (match(text, /[0-9]+(\.[0-9]+)+/)) {
        run = substr(text, RSTART, RLENGTH)
        text = substr(text, RSTART + RLENGTH)
        n = split(run, p, ".")
        if (n == 4 && p[1] <= 255 && p[2] <= 255 && p[3] <= 255 && p[4] <= 255 && run !~ ENVIRON["OK"]) { print where ": an IPv4 address"; break }
      }
    }' || true
}

# Reads lines on stdin, each "<where>:<text>"; prints one line per finding, without the private word itself.
scan() {
  local where text line hits=0 word words=() tmp findings
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064 # Why: expand now, the variable is local.
  trap "rm -rf '$tmp'" RETURN
  : > "$tmp/words"
  if [ -f "$DENYLIST" ]; then
    sed -E 's/#.*//; s/^[[:space:]]+//; s/[[:space:]]+$//; /^$/d' "$DENYLIST" > "$tmp/words"
    while IFS= read -r word; do words+=("$word"); done < "$tmp/words"
  fi
  cat > "$tmp/in"
  # Why: one grep pass keeps only the lines that may hold something; the loop below then checks few lines.
  {
    grep -E -e "$EMAIL_RE" -e "$HOME_RE" -e "$TEMP_RE" "$tmp/in"
    [ -s "$tmp/words" ] && grep -iF -f "$tmp/words" "$tmp/in"
  } | sort -u > "$tmp/candidates"
  while IFS= read -r line; do
    where="${line%%:*}"
    text="${line#*:}"
    if grep -Eo "$EMAIL_RE" <<<"$text" | grep -Evq "$EMAIL_OK_RE"; then
      echo "$where: an e-mail address"; hits=$((hits + 1))
    fi
    if grep -Eo "$HOME_RE" <<<"$text" | grep -Evq "$HOME_OK_RE"; then
      echo "$where: an absolute home path"; hits=$((hits + 1))
    fi
    if grep -Eq "$TEMP_RE" <<<"$text"; then
      echo "$where: the Mac's per-user temp folder"; hits=$((hits + 1))
    fi
    for word in ${words[@]+"${words[@]}"}; do
      if grep -iqF -- "$word" <<<"$text"; then
        echo "$where: a word of the private denylist"; hits=$((hits + 1))
      fi
    done
  done < "$tmp/candidates"
  findings="$(scan_aws_traces "$tmp/in")"
  if [ -n "$findings" ]; then echo "$findings"; hits=$((hits + $(grep -c '' <<<"$findings"))); fi
  [ "$hits" = 0 ]
}

# Why: this file names the patterns it looks for, so it would flag itself.
SELF=tools/public-guard.sh

mode_tree() {
  # Why: the tracked files as they are on disk, so an edit not yet committed is caught too.
  git -C "$REPO" grep -n -I -e '' -- . ":!$SELF" | sed -E 's/^([^:]+):([0-9]+):/\1 line \2:/' | scan
}

mode_pre_push() {
  [ -f "$DENYLIST" ] || {
    echo "public guard: the private denylist is missing ($DENYLIST). Nothing was pushed."
    echo "  Clone the factory repo next to this one, or set PUBLIC_GUARD_DENYLIST."
    return 1
  }
  local local_sha remote_sha range sha failed=0 out
  while read -r _ local_sha _ remote_sha; do
    [ -z "${local_sha:-}" ] && continue
    [[ "$local_sha" =~ ^0+$ ]] && continue
    # Why: a commit already reachable from a remote-tracking ref is already public, since origin (the public repo) is
    # the only remote: scanning it again blocks nothing. A second remote means revisiting this rule.
    if [[ "$remote_sha" =~ ^0+$ ]]; then
      range=("$local_sha" --not --remotes)
    else
      range=("$remote_sha..$local_sha" --not --remotes)
    fi
    for sha in $(git -C "$REPO" rev-list "${range[@]}"); do
      out="$(
        {
          git -C "$REPO" log -1 --format=%B "$sha" | sed "s/^/message:/"
          # Why: only the lines this commit adds; a line it removes is a fix, not a leak.
          git -C "$REPO" show --format= --unified=0 --no-color "$sha" -- . ":!$SELF" \
            | awk '/^\+\+\+ /{f=substr($0,7); next} /^\+/{print f ":" substr($0,2)}'
        } | scan
      )" || { failed=1; printf '%s\n' "$out" | sed "s/^/${sha:0:7} /"; }
    done
  done
  [ "$failed" = 0 ] || { echo "public guard: nothing was pushed. Fix the commits above (amend or rebase locally)."; return 1; }
}

case "${1:-}" in
  tree) mode_tree ;;
  pre-push) mode_pre_push ;;
  stdin) sed 's/^/stdin:/' | scan ;;
  *) echo "usage: $0 tree|pre-push|stdin" >&2; exit 2 ;;
esac
