#!/usr/bin/env bash
# The public guard: this repository is public, so nothing private may reach it. It refuses e-mail addresses,
# absolute home paths (/Users/<name>, /home/<name>), the Mac's per-user temp folder (/var/folders/..., also as
# /private/var/folders/...) and every word of a private denylist.
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

# Reads lines on stdin, each "<where>:<text>"; prints one line per finding, without the private word itself.
scan() {
  local where text line hits=0 word words=() tmp
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
