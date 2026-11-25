#!/usr/bin/env bash
# Stands in for the server controller in lab/check.sh check_score: logs every call to $FAKE_LOG; `restart` prints 3 healthy seconds.
# FAKE_FACTS_FAIL=1 makes `facts` fail. The sampler files come from fake-k6.sh.
set -euo pipefail
echo "ctl $1" >>"$FAKE_LOG"
case "$1" in
  restart) echo 3 ;;
  facts) [ "${FAKE_FACTS_FAIL:-}" != 1 ] || exit 1; echo '{"cpu_model":"fake","nproc":2,"mem_total_mib":2048,"kernel":"6.8","swap_mib":0}' ;;
esac
