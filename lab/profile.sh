# The profile of a lab run (--profile <file>), shared by lab/realistic.sh and lab/macro.sh. Sourced, never run.
# Needs, from the caller: PROBE, SERVER and K6C (the containers' names), server_id and k6_id, tmp (a scratch folder), probe and
# lines_to_json (its functions), profile_out (the --profile value, empty when off), LAB_EXT and LAB_ENV, and lab/lib.sh sourced.
# Why: the variables named above are the caller's, so shellcheck sees them as unassigned.
# shellcheck shell=bash disable=SC2154

# Where the server writes its collapsed stacks inside its container (the container's own disk: /lab is read-only), and how often it
# writes them (lab/servers/diy-profile.php: DiyProfile::FLUSH_S).
LAB_PROFILE_FILE=/tmp/profile.collapsed
LAB_PROFILE_FLUSH_S=2

# profile_prepare: with --profile, the server runs the profiler: ext-excimer loaded (never globally: only this server), APP_PROFILE set,
# and the telemetry off unless the caller sets it (a profile of the server as it is, not of the telemetry's timers).
profile_prepare() {
  [ -n "$profile_out" ] || return 0
  local e kv has_excimer="" telemetry_set=""
  for e in "${LAB_EXT[@]}"; do [ "$e" != excimer ] || has_excimer=1; done
  [ -n "$has_excimer" ] || LAB_EXT+=(excimer)
  LAB_ENV+=("APP_PROFILE=$LAB_PROFILE_FILE")
  for kv in "${LAB_ENV[@]+"${LAB_ENV[@]}"}"; do [[ "$kv" != APP_TELEMETRY=* ]] || telemetry_set=1; done
  if [ -z "$telemetry_set" ]; then LAB_ENV+=(APP_TELEMETRY=0); fi
}

# profile_check_image: stops the run (exit 1) when the image has no Excimer (the 8.6 image: lab/results/excimer-on-php-8.6.md).
profile_check_image() {
  [ -n "$profile_out" ] || return 0
  docker exec "$PROBE" php -d extension=excimer -r 'exit(extension_loaded("excimer") ? 0 : 1);' >/dev/null 2>&1 \
    || fail "--profile: this image has no Excimer (lab/results/excimer-on-php-8.6.md says why the 8.6 image has none)"
}

profile_cpu_json=""
# profile_begin: reads the server's cgroup (user and system CPU) at the start of the profiled window: the server has just answered, the
# profiler runs since before its first request, and the seed copy (made before the server started) is not in the window.
profile_begin() {
  [ -n "$profile_out" ] || return 0
  profile_cpu_json="$(probe cpu "$server_id" "$k6_id" | lines_to_json | jq -c '{user_usec: .server.user_usec, system_usec: .server.system_usec}')"
}

# profile_collect <requests in the window>: waits for the server's next write of the file (it writes every LAB_PROFILE_FLUSH_S seconds),
# reads the cgroup again, copies the collapsed stacks out of the container into $profile_out and folds them (lab/profile/fold.php) into
# $tmp/profile-fold.txt; sets profile_json (the caller starts it at null, which is what it stays when the profiler is off). The window runs
# from profile_begin to the read after that wait: the warm-up, the ramps and the plateaus, and an idle second or two.
profile_collect() {
  [ -n "$profile_out" ] || return 0
  local requests="$1" end_json user_usec system_usec samples us_per_req fold_args=() unclassified period=0.001 kv
  for kv in "${LAB_ENV[@]}"; do [[ "$kv" != APP_PROFILE_PERIOD=* ]] || period="${kv#*=}"; done
  sleep "$(awk -v s="$LAB_PROFILE_FLUSH_S" 'BEGIN { print s + 0.5 }')"
  end_json="$(probe cpu "$server_id" "$k6_id" | lines_to_json | jq -c '{user_usec: .server.user_usec, system_usec: .server.system_usec}')"
  mkdir -p "$(dirname "$profile_out")"
  docker exec "$SERVER" cat "$LAB_PROFILE_FILE" >"$profile_out" || fail "cannot read the profile out of the server container ($LAB_PROFILE_FILE)"
  samples="$(awk '{ s += $NF } END { print s + 0 }' "$profile_out")"
  [ "$samples" -gt 0 ] || fail "the profile holds no sample (the server wrote $LAB_PROFILE_FILE, empty)"
  user_usec="$(jq -n --argjson a "$profile_cpu_json" --argjson b "$end_json" '$b.user_usec - $a.user_usec')"
  system_usec="$(jq -n --argjson a "$profile_cpu_json" --argjson b "$end_json" '$b.system_usec - $a.system_usec')"
  us_per_req=""
  if [ "$requests" -gt 0 ]; then
    us_per_req="$(awk -v u="$user_usec" -v s="$system_usec" -v n="$requests" 'BEGIN { printf "%.2f", (u + s) / n }')"
    fold_args+=(--us-per-req "$us_per_req")
  fi
  docker exec -i "$PROBE" php /lab/profile/fold.php - "${fold_args[@]+"${fold_args[@]}"}" <"$profile_out" >"$tmp/profile-fold.txt" \
    || fail "lab/profile/fold.php failed on the profile"
  unclassified="$(awk '/^unclassified: / { gsub(/[(%)]/, "", $4); print $4 }' "$tmp/profile-fold.txt")"
  profile_json="$(jq -n --arg file "$profile_out" --argjson samples "$samples" --argjson user "$user_usec" --argjson system "$system_usec" \
    --argjson requests "$requests" --argjson period "$period" --arg us_per_req "$us_per_req" --arg unclassified "${unclassified:-0}" --rawfile fold "$tmp/profile-fold.txt" '
    {collapsed_file: ($file | split("/") | last), period_s: $period,
     window: "from the server'"'"'s first answer to the end of the load plus the wait for the last write of the file",
     samples: $samples, sampled_cpu_ms: ($samples * $period * 1000),
     cgroup: {user_usec: $user, system_usec: $system, system_share: (if ($user + $system) > 0 then ($system / ($user + $system) * 1000 | round / 1000) else null end)},
     samples_over_cgroup_cpu: (if ($user + $system) > 0 then ($samples * $period * 1000000 / ($user + $system) * 1000 | round / 1000) else null end),
     requests_in_window: $requests,
     profiled_cpu_usec_per_request: (if $us_per_req == "" then null else ($us_per_req | tonumber) end),
     unclassified_share: ($unclassified | tonumber / 100), fold: $fold}')"
}

# profile_print: the fold table, then the cgroup's user and system split of the same window.
profile_print() {
  [ -n "$profile_out" ] || return 0
  echo "profile (the server ran with Excimer on CPU time: its CPU per request is NOT the baseline's):"
  cat "$tmp/profile-fold.txt"
  jq -r '"cgroup CPU over the profiled window: user \(.cgroup.user_usec / 1000 | round) ms, system \(.cgroup.system_usec / 1000 | round) ms (\(.cgroup.system_share * 100 | round) % in the kernel); samples \(.samples) at \(.period_s * 1000) ms, so \(.samples_over_cgroup_cpu * 100 | round) % of that CPU is in the profile; kernel time spent inside a syscall shows in the PHP frame that made it (fread, fwrite, stream_socket_accept)",
         "collapsed stacks: \(.collapsed_file)"' <<<"$profile_json"
}
