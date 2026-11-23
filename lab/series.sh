# The per-second series of a lab run, shared by lab/realistic.sh and lab/macro.sh --per-second. Sourced, never run.
# Needs, from the caller: PROBE (the probe container's name), SERVER (the server container's name), server_id and server_pid, tmp (a
# scratch folder), fail (a function that prints and exits 1), and lab/lib.sh sourced.
# Why: the variables named above are the caller's, so shellcheck sees them as unassigned.
# shellcheck shell=bash disable=SC2154

# sampler_start <name> <database path in the server's container, or ->: starts ONE sampler loop in the probe container (lab/macro/sampler.php:
# CPU, Pss_Anon, memory.current, the WAL's size and frames, fds and page faults, once a second), never one `docker exec` a second.
sampler_start() {
  docker exec "$PROBE" rm -f /tmp/sampler-stop "/tmp/$1.samples"
  docker exec -d "$PROBE" php -d display_errors=stderr /lab/macro/sampler.php "$server_id" "$server_pid" "$2" /tmp/sampler-stop "/tmp/$1.samples" 86400
}

# sampler_stop <name>: stops the loop and leaves its lines in $tmp/<name>.samples.
sampler_stop() {
  docker exec "$PROBE" touch /tmp/sampler-stop
  # The sampler writes one last line at the next second, then sees the stop file.
  sleep 1.3
  docker exec "$PROBE" cat "/tmp/$1.samples" >"$tmp/$1.samples"
}

# series_build <name> <the aggregator's result file>: the rows of the run, one per second (the aggregator's latency, the sampler's readings and
# the server's telemetry lines of the same second), in $tmp/<name>.series.json. Reads $tmp/<name>.samples and the server's log.
series_build() {
  docker logs "$SERVER" >"$tmp/$1.serverlog" 2>&1
  jq -nc --slurpfile agg "$2" --slurpfile samples "$tmp/$1.samples" --rawfile log "$tmp/$1.serverlog" \
    '{per_second: $agg[0].per_second, samples: $samples, log: $log}' >"$tmp/$1.series.in"
  docker exec -i "$PROBE" php /lab/macro/series.php <"$tmp/$1.series.in" >"$tmp/$1.series.json" \
    || fail "the per-second series could not be built from the readings"
}

# series_print <file with the rows as a JSON array>: the per-second table, one row per second, columns per endpoint found in the run.
series_print() {
  echo "per second (sec: seconds from the start of the run; per endpoint: requests, then p50/p99/max latency in ms; cpu: the server's CPU in us per second;"
  echo "memory in MiB at the end of the second; wal: the file's KiB and the frames in use; faults: minor and major in the second; cb max: the server's longest callback"
  echo "in ms; gc: runs/collected; - means no reading):"
  jq -r '. as $rows
    | ([$rows[].endpoints | keys[]] | unique) as $eps
    | def n: if . == null then "-" else . end;
      def r1: if . == null then "-" else . * 10 | round / 10 end;
      (["sec", "VUs", "req"] + $eps + ["cpu us/s", "PssAnon", "mem.cur", "wal KiB", "frames", "fds", "minflt", "majflt", "cb max", "gc"]) | @tsv,
      ($rows[] | . as $r
        | ([($r.second - $rows[0].second), ($r.vus | n), $r.requests]
           + ($eps | map(. as $e | $r.endpoints[$e] | if . == null then "-" else "\(.count) \(.p50)/\(.p99)/\(.max)" end))
           + [($r.server.cpu_usec | n), ($r.server.pss_anon_kb | if . == null then null else . / 1024 end | r1),
              ($r.server.memory_current | if . == null then null else . / 1048576 end | r1),
              ($r.server.wal_bytes | if . == null then null else . / 1024 | round end | n), ($r.server.wal_frames | n), ($r.server.fds | n),
              ($r.server.minflt | n), ($r.server.majflt | n), ($r.telemetry.longest_callback_ms | n),
              (if $r.telemetry == null then "-" else "\($r.telemetry.gc_runs)/\($r.telemetry.gc_collected)" end)]) | @tsv)' "$1" | column -t -s "$(printf '\t')"
}
