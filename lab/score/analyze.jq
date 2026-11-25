# The numbers of one k6 run, from the files its samplers left. Called by lab/score/score-lib.sh (`score_run_json`), never by hand.
#
#   jq -n -f lab/score/analyze.jq --rawfile rest rest.tsv --rawfile loadbox loadbox.csv --rawfile server server.csv \
#      --rawfile server_start server-start.txt --rawfile server_end server-end.txt --argjson summary <summary.json or null> --argjson meta <object>
#
# meta: kind, users, duration_s, k6_exit, healthy_s, server_died (bool), dial_errors (count of dial errors in k6's log), cgroup_layout,
# k6_started (epoch seconds of the k6 container's start, or null).
#
# Every sample row starts with an epoch in seconds with milliseconds (`1732459200.123`). The two boxes of the AWS run sync to Amazon Time
# Sync, so the plateau, which the load box reads from k6's REST API, is matched to the server's rows by time: the server's counters are
# interpolated at the plateau's first and last second, never taken from "the row with the same second".

# --- parsing -----------------------------------------------------------------------------------------------------------------------
def csv($text):
  ($text | split("\n") | map(select(length > 0))) as $l
  | if ($l | length) < 2 then [] else
    ($l[0] | split(",")) as $h
    | [$l[1:][] | split(",") as $f
       | [range(0; $h | length)] | map({key: $h[.], value: ($f[.] // "")}) | from_entries
       | with_entries(.value |= (if . == "" then null else (tonumber? // .) end))]
  end;

# k6 has no http_reqs or http_req_failed metric until its first request: a 404 body. While k6 answers (vus is there) that is a count of 0.
def rest_rows($text):
  [$text | split("\n")[] | select(length > 0) | split("\t") as $f
   | (try ($f[1] | fromjson | .data.attributes.sample.value) catch null) as $vus
   | {ts: ($f[0] | tonumber + 0),
      vus: $vus,
      reqs: (if $vus == null then null else (try ($f[2] | fromjson | .data.attributes.sample.count) catch 0) // 0 end),
      failed: (if $vus == null then null else (try ($f[3] | fromjson | .data.attributes.sample.rate) catch 0) // 0 end)}];

def lines($text; $key): [$text | split("\n")[] | select(startswith($key + " ")) | .[($key | length) + 1:]];

# --- helpers -----------------------------------------------------------------------------------------------------------------------
def median: sort | if length == 0 then null elif length % 2 == 1 then .[length / 2 | floor] else (.[length / 2 - 1] + .[length / 2]) / 2 end;
def maxn: if length == 0 then null else max end;
def minn: if length == 0 then null else min end;

# The value of a cumulative counter at time $t, interpolated between the two rows around it.
def at($rows; $t; $f):
  ([$rows[] | select(.ts <= $t)] | last) as $a
  | ([$rows[] | select(.ts >= $t)] | first) as $b
  | if $a == null or $b == null then null
    elif $a.ts == $b.ts then $a[$f]
    else $a[$f] + ($b[$f] - $a[$f]) * ($t - $a.ts) / ($b.ts - $a.ts) end;

# One entry per second between two consecutive rows: the time of the later row and the differences of every counter.
def seconds($rows):
  [range(1; $rows | length) as $j | {ts: $rows[$j].ts, dt: ($rows[$j].ts - $rows[$j - 1].ts), prev: $rows[$j - 1], cur: $rows[$j]}];

def cpu_total: .cpu_user + .cpu_nice + .cpu_system + .cpu_idle + .cpu_iowait + .cpu_irq + .cpu_softirq + .cpu_steal;
# The share of the box that was not idle in that second (iowait counts as idle: nothing runs).
def busy_share: ((.cur | cpu_total) - (.prev | cpu_total)) as $t
  | if $t <= 0 then null else 1 - (((.cur.cpu_idle - .prev.cpu_idle) + (.cur.cpu_iowait - .prev.cpu_iowait)) / $t) end;

def window($rows; $s; $e): [$rows[] | select(.ts >= $s and .ts <= $e)];

# --- inputs ------------------------------------------------------------------------------------------------------------------------
(rest_rows($rest)) as $rest_rows
| csv($server) as $srv
| csv($loadbox) as $lb
| $meta.users as $users
| ([$rest_rows[] | select(.vus == $users)]) as $plat_rows
| (if ($plat_rows | length) >= 2 then {start: $plat_rows[0].ts, end: $plat_rows[-1].ts} else null end) as $pw
| (if $pw then ($pw.end - $pw.start) else null end) as $plateau_s
| (if $pw then ($plat_rows[-1].reqs - $plat_rows[0].reqs) else null end) as $plateau_reqs
| (($summary // {}) | .metrics // {}) as $m
| (($m.http_req_duration // {}) | (.values // .)) as $dur
| (($m.http_req_failed // {}) | (.values // .)) as $failed
| (($m.http_reqs // {}) | (.values // .)) as $reqs
| (lines($server_start; "nproc")[0] // null | if . == null then null else tonumber end) as $nproc

# --- the server, over the plateau and the whole run -----------------------------------------------------------------------------------
| (seconds($srv)) as $srv_s
| (if $pw then [$srv_s[] | select(.ts >= $pw.start and .ts <= $pw.end)] else [] end) as $srv_plat
| (if $pw and ($srv | length) > 1 then at($srv; $pw.start; "cg_usage_usec") else null end) as $use_s
| (if $pw and ($srv | length) > 1 then at($srv; $pw.end; "cg_usage_usec") else null end) as $use_e
| (if $use_s != null and $use_e != null and $plateau_s > 0 then ($use_e - $use_s) / ($plateau_s * 1000000) else null end) as $service_share
| (lines($server_end; "sampler_cpu_ms")[0] // null | if . == null then null else tonumber end) as $samp_ms
| (lines($server_end; "sampler_wall_ms")[0] // null | if . == null then null else tonumber end) as $samp_wall
| (if $samp_ms != null and ($samp_wall // 0) > 0 then $samp_ms / $samp_wall else null end) as $sampler_cores
| ([$srv_plat[] | busy_share | select(. != null)]) as $busy_plat
| ([$srv_plat[] as $s | ($s | busy_share) as $b
    | (($s.cur.cg_usage_usec - $s.prev.cg_usage_usec) / ($s.dt * 1000000)) as $cores
    | select($b != null and $nproc != null and $nproc > 0)
    | $b - ($cores + ($sampler_cores // 0)) / $nproc]) as $others
| ([$srv_plat[] | (.cur.passive_opens - .prev.passive_opens) / .dt]) as $acc_plat
| ([$srv_s[] | (.cur.passive_opens - .prev.passive_opens) / .dt]) as $acc_all
| (if ($srv | length) > 0 then $srv[-1] else {} end) as $srv_last
| (if ($srv | length) > 0 then $srv[0] else {} end) as $srv_first
| ([$srv[].fds | select(. != null and type == "string") | split(";")[] | split(":") | {pid: .[0], n: (.[1] | tonumber)}]
   | group_by(.pid) | map({key: .[0].pid, value: (map(.n) | max)}) | from_entries) as $fds_max
| (lines($server_start; "ena") | map(split(" ") | {key: .[0], value: (.[1] | tonumber)}) | from_entries) as $ena_s
| (lines($server_end; "ena") | map(split(" ") | {key: .[0], value: (.[1] | tonumber)}) | from_entries) as $ena_e
| (if (lines($server_start; "ena-unread") | length) > 0 or (lines($server_end; "ena-unread") | length) > 0 or ($ena_e | length) == 0 then null
   else ($ena_e | with_entries(.value -= ($ena_s[.key] // 0))) end) as $ena_diff
| (if (lines($server_start; "oom-unread") | length) > 0 then null else (lines($server_start; "oom") | length) end) as $oom_s
| (if (lines($server_end; "oom-unread") | length) > 0 then null else (lines($server_end; "oom") | length) end) as $oom_e
| ($srv_last.listen_drops - $srv_first.listen_drops) as $drops
| ([$srv[].mem_available_kb | select(. != null)] | minn) as $avail_min

# --- the load box --------------------------------------------------------------------------------------------------------------------
| (seconds($lb)) as $lb_s
| (if $pw then [$lb_s[] | select(.ts >= $pw.start and .ts <= $pw.end)] else [] end) as $lb_plat
| ([$lb_plat[] | busy_share | select(. != null)] | maxn) as $lb_cpu_max
| ([$lb[].k6_mem_current, $lb[].k6_mem_peak | select(. != null)] | maxn) as $k6_mem_peak
| ([$lb[].mem_total_kb | select(. != null)] | maxn) as $lb_mem_kb
| (if $lb_cpu_max != null and $lb_cpu_max > 0.85 then "the load box's CPU reached \($lb_cpu_max * 100 | round) % on a plateau second"
   elif $k6_mem_peak != null and $lb_mem_kb != null and $k6_mem_peak > $lb_mem_kb * 1024 * 0.9 then "the k6 container held \($k6_mem_peak / 1048576 | round) MiB, over 90 % of the load box's memory"
   else null end) as $void_reason

# Why only `_exceeded`: conntrack_allowance_available is a gauge (it falls as connections open and rises as they close), not a count of drops.
| ($meta.k6_exit == 0) as $pass
| (if $pass then null
   elif $void_reason != null then "k6"
   elif ($oom_e != null and $oom_s != null and $oom_e > $oom_s) or ($avail_min != null and $avail_min < 102400) then "memory"
   elif $meta.server_died then "died"
   elif $ena_diff != null and ($ena_diff | to_entries | any(.value > 0 and (.key | endswith("_exceeded")))) then "network"
   elif ($drops != null and $drops > 0) or ($meta.dial_errors > 0 and ($fds_max | to_entries | any(.value >= 65435))) then "fds"
   elif $service_share != null and $service_share > 0.88 then "cpu"
   else "latency-below-saturation" end) as $wall

| {
    kind: $meta.kind, users: $users, duration_s: $meta.duration_s, k6_exit: $meta.k6_exit, pass: $pass,
    void: ($void_reason != null), void_reason: $void_reason,
    p95_ms: $dur["p(95)"], p99_ms: $dur["p(99)"],
    error_rate: ($failed.value // $failed.rate),
    http_reqs: $reqs.count,
    plateau: (if $pw then {start: $pw.start, end: $pw.end, seconds: $plateau_s, http_reqs: $plateau_reqs,
                           req_per_s: (if $plateau_s > 0 then $plateau_reqs / $plateau_s else null end)} else null end),
    vu_init_s: (([$rest_rows[] | select(.vus != null and .vus > 0)] | first) as $f
                | if $f != null and $meta.k6_started != null then $f.ts - $meta.k6_started else null end),
    server: {
      cpu_busy_median: ($busy_plat | median), cpu_busy_max: ($busy_plat | maxn),
      service_share: $service_share, others_median: ($others | median), sampler_cores: $sampler_cores,
      us_per_req: (if $use_s != null and $use_e != null and ($plateau_reqs // 0) > 0 then ($use_e - $use_s) / $plateau_reqs else null end),
      accepts_per_s_median: ($acc_plat | median), accepts_per_s_max_plateau: ($acc_plat | maxn), accepts_per_s_max_run: ($acc_all | maxn),
      memory_current_peak: ([$srv[].mem_current | select(. != null)] | maxn),
      memory_peak_file: ([$srv[].mem_peak | select(. != null)] | maxn),
      rss_peak: ([$srv[].rss_bytes | select(. != null)] | maxn),
      mem_available_min_kb: $avail_min,
      tcp_inuse_peak: ([$srv[].tcp_inuse | select(. != null)] | maxn),
      tcp_mem_peak: ([$srv[].tcp_mem | select(. != null)] | maxn),
      tcp_tw_peak: ([$srv[].tcp_tw | select(. != null)] | maxn),
      listen_overflows: ($srv_last.listen_overflows - $srv_first.listen_overflows),
      listen_drops: $drops,
      retrans_segs: ($srv_last.retrans_segs - $srv_first.retrans_segs),
      ena_allowance_diff: $ena_diff,
      oom_lines_start: $oom_s, oom_lines_end: $oom_e,
      fds_max: $fds_max,
      rows: ($srv | length)
    },
    loadbox: {cpu_max: $lb_cpu_max, k6_memory_peak_bytes: $k6_mem_peak, mem_total_kb: $lb_mem_kb, k6_cgroup_layout: $meta.cgroup_layout},
    healthy_s: $meta.healthy_s, service_died: $meta.server_died, dial_errors: $meta.dial_errors,
    wall: $wall
  }
