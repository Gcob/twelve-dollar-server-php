# The numbers of one k6 run, from the files its samplers left. Called by lab/score/score-lib.sh (`score_run_json`), never by hand.
#
#   jq -n -f lab/score/analyze.jq --rawfile rest rest.tsv --rawfile loadbox loadbox.csv --rawfile server server.csv \
#      --rawfile server_start server-start.txt --rawfile server_end server-end.txt --argjson summary <summary.json or null> \
#      --rawfile rest2 <file> --rawfile loadbox2 <file> --argjson summary2 <summary.json or null> --argjson meta <object>
#
# meta: kind, users, duration_s, k6_exit, healthy_s, server_died (bool), dial_errors (count of dial errors in k6's log), cgroup_layout,
# k6_started (epoch seconds of the k6 container's start, or null), loop (the server's `loop:` line, or null) and, for a run on two k6 halves,
# halves: {users: [a, b], exits: [a, b], started: [a, b]} (k6_exit is then the run's: 0 when both halves exited 0). The *2 inputs are the
# second half's (empty files and null with one half); rest, loadbox and summary are the first half's.
#
# Two halves: each half is its own k6 with its own REST samples. The plateau is the seconds where BOTH halves report their target VUs
# (the intersection of their windows); the plateau's requests are the sum of the halves' over it, so req/s and us/req follow. p95 and p99
# are each half's (the run's number is the worse one, `halves` keeps both). A half is over the load box's line by its own CPUs (its cpuset)
# and its own memory share. `halves` holds each half's numbers; it is null with one half.
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

# A difference that is null when either side is unknown (a server.csv with no row, a cgroup that was gone).
def diff($a; $b): if $a == null or $b == null then null else $a - $b end;
# A one-second entry whose two rows both have the cgroup's CPU time (the columns are empty once the service's cgroup is gone).
def has_cg: .prev.cg_usage_usec != null and .cur.cg_usage_usec != null;

def window($rows; $s; $e): [$rows[] | select(.ts >= $s and .ts <= $e)];

def lb_report($h; $pw):
  (seconds($h.lb)) as $lb_s
  | (if $pw then [$lb_s[] | select(.ts >= $pw.start and .ts <= $pw.end)] else [] end) as $lb_plat
  | ([$lb_plat[] | busy_share | select(. != null)] | maxn) as $cpu_max
  | ([$lb_plat[] | ((busy_share // 0) > 0.85)]) as $hot
  | ($hot | map(select(.)) | length) as $hot_n
  | ($hot | reduce .[] as $x ({run: 0, max: 0}; if $x then .run += 1 | .max = ([.max, .run] | max) else .run = 0 end) | .max) as $streak
  | ([$h.lb[].k6_mem_current, $h.lb[].k6_mem_peak | select(. != null)] | maxn) as $k6_mem
  | ([$h.lb[].mem_total_kb | select(. != null)] | maxn) as $mem_kb
  | {reason: (if ($hot | length) > 0 and ($hot_n * 10 > ($hot | length) or $streak >= 5) then "the load box's CPU was over 85 % on \($hot_n) of \($hot | length) plateau seconds (\($streak) in a row at most, peak \($cpu_max * 100 | round) %)"
              elif $k6_mem != null and $mem_kb != null and $k6_mem > $mem_kb * 1024 * 0.9 then "the k6 container held \($k6_mem / 1048576 | round) MiB, over 90 % of the load box's memory"
              else null end),
     cpu_max: $cpu_max, plateau_seconds: ($hot | length), seconds_over_85: $hot_n, longest_streak_over_85: $streak, k6_memory_peak_bytes: $k6_mem, mem_total_kb: $mem_kb};

# --- inputs ------------------------------------------------------------------------------------------------------------------------
# One entry a k6 half (one with --halves 1): its users, exit, start, REST rows, load box rows, summary, and the rows at its target VUs.
def summ($s): (($s // {}) | .metrics // {}) as $m
  | {dur: (($m.http_req_duration // {}) | (.values // .)), failed: (($m.http_req_failed // {}) | (.values // .)), reqs: (($m.http_reqs // {}) | (.values // .))};

csv($server) as $srv
| ([$srv[] | select(.cg_usage_usec != null)]) as $srv_cg
| ($meta.halves // null) as $hm
| (if $hm == null then
     [{users: $meta.users, exit: $meta.k6_exit, started: $meta.k6_started, rest: $rest, loadbox: $loadbox, summary: $summary}]
   else
     [range(0; 2) as $i | {users: $hm.users[$i], exit: $hm.exits[$i], started: $hm.started[$i],
                           rest: (if $i == 0 then $rest else $rest2 end), loadbox: (if $i == 0 then $loadbox else $loadbox2 end),
                           summary: (if $i == 0 then $summary else $summary2 end)}]
   end
   | map(. as $h | $h + {rows: rest_rows($h.rest), lb: csv($h.loadbox)} + summ($h.summary)
         | . as $h | . + {plat: [$h.rows[] | select(.vus == $h.users)]})) as $halves_in
| $meta.users as $users
# The plateau: from the latest first at-target row to the earliest last one (with one half, its own first and last rows).
| (if ($halves_in | map(.plat | length >= 2) | all) then {start: ([$halves_in[].plat[0].ts] | max), end: ([$halves_in[].plat[-1].ts] | min)} else null end
   | if . != null and .end > .start then . else null end) as $pw
| (if $pw then ($pw.end - $pw.start) else null end) as $plateau_s
# Each half's requests over the window, read at its start and end (interpolated: the halves' REST rows are not on the same milliseconds).
| (if $pw then ([$halves_in[] | .plat as $p | at($p; $pw.end; "reqs") - at($p; $pw.start; "reqs")] | add) else null end) as $plateau_reqs
| (lines($server_start; "nproc")[0] // null | if . == null then null else tonumber end) as $nproc

# --- the server, over the plateau and the whole run -----------------------------------------------------------------------------------
| (seconds($srv)) as $srv_s
| (if $pw then [$srv_s[] | select(.ts >= $pw.start and .ts <= $pw.end)] else [] end) as $srv_plat
| (if $pw and ($srv_cg | length) > 1 then at($srv_cg; $pw.start; "cg_usage_usec") else null end) as $use_s
| (if $pw and ($srv_cg | length) > 1 then at($srv_cg; $pw.end; "cg_usage_usec") else null end) as $use_e
| (if $use_s != null and $use_e != null and $plateau_s > 0 then ($use_e - $use_s) / ($plateau_s * 1000000) else null end) as $service_share
| ([$srv_plat[] | select(has_cg) | (.cur.cg_usage_usec - .prev.cg_usage_usec) / (.dt * 1000000)]) as $svc_seconds
| (lines($server_end; "sampler_cpu_ms")[0] // null | if . == null then null else tonumber end) as $samp_ms
| (lines($server_end; "sampler_wall_ms")[0] // null | if . == null then null else tonumber end) as $samp_wall
| (if $samp_ms != null and ($samp_wall // 0) > 0 then $samp_ms / $samp_wall else null end) as $sampler_cores
| ([$srv_plat[] | busy_share | select(. != null)]) as $busy_plat
| ([$srv_plat[] as $s | ($s | busy_share) as $b
    | (if $s | has_cg then (($s.cur.cg_usage_usec - $s.prev.cg_usage_usec) / ($s.dt * 1000000)) else null end) as $cores
    | select($b != null and $cores != null and $nproc != null and $nproc > 0)
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
# An end file that is missing or empty (the sampler died) says nothing: the OOM lines at the end are unknown, never 0.
| (if ($server_end | test("\\S") | not) or (lines($server_end; "oom-unread") | length) > 0 then null else (lines($server_end; "oom") | length) end) as $oom_e
# The kernel's `TCP: out of memory` lines (the sampler prints them as `tcp-oom`, apart from the OOM killer's): the same reading, new ones in the run.
| (if (lines($server_start; "oom-unread") | length) > 0 then null else (lines($server_start; "tcp-oom") | length) end) as $tcp_oom_s
| (if ($server_end | test("\\S") | not) or (lines($server_end; "oom-unread") | length) > 0 then null else (lines($server_end; "tcp-oom") | length) end) as $tcp_oom_e
| diff($srv_last.listen_drops; $srv_first.listen_drops) as $drops
| ([$srv[].mem_available_kb | select(. != null)] | minn) as $avail_min

# --- the load box (lb_report, above: one report a half) -----------------------------------------------------------------------------------
| ($halves_in | length) as $nh
| ([$halves_in | to_entries[] | .key as $i | lb_report(.value; $pw) | .reason |= (if . != null and $nh > 1 then "half \($i + 1): " + . else . end)]) as $lbs
| ([$lbs[].reason | select(. != null)] | .[0]) as $over_line

# The order: k6, memory, the service's death, network, TCP memory, fds, CPU, else latency. Network is only the packets-a-second allowance
# (`pps_allowance_exceeded`, a count of packets EC2 held back) and only on a run that failed: a passing run grows it too and says nothing.
# TCP memory is a failing run whose kernel log has `TCP: out of memory` lines it did not have at the start.
| ($meta.k6_exit == 0) as $pass
| (if $pass then null
   elif $over_line != null then "k6"
   elif ($oom_e != null and $oom_s != null and $oom_e > $oom_s) or ($avail_min != null and $avail_min < 102400) then "memory"
   elif $meta.server_died then "died"
   elif $ena_diff != null and (($ena_diff.pps_allowance_exceeded // 0) > 0) then "network"
   elif $tcp_oom_e != null and $tcp_oom_s != null and $tcp_oom_e > $tcp_oom_s then "tcp-memory"
   elif ($drops != null and $drops > 0) or ($meta.dial_errors > 0 and ($fds_max | to_entries | any(.value >= 65435))) then "fds"
   elif ($svc_seconds | median) != null and ($svc_seconds | median) > 0.88 then "cpu"
   else "latency-below-saturation" end) as $wall

| {
    kind: $meta.kind, users: $users, duration_s: $meta.duration_s, k6_exit: $meta.k6_exit, pass: $pass,
    void: (($pass | not) and $over_line != null), void_reason: (if $pass then null else $over_line end),
    p95_ms: ([$halves_in[].dur["p(95)"] | select(. != null)] | maxn), p99_ms: ([$halves_in[].dur["p(99)"] | select(. != null)] | maxn),
    error_rate: (if $nh == 1 then ($halves_in[0].failed | .value // .rate)
                 else ([$halves_in[] | ((.failed | .value // .rate) // 0) * (.reqs.count // 0)] | add) as $bad
                      | ([$halves_in[].reqs.count // 0] | add) as $all
                      | if $all > 0 then $bad / $all else null end end),
    http_reqs: ([$halves_in[].reqs.count | select(. != null)] | if length == 0 then null else add end),
    plateau: (if $pw then {start: $pw.start, end: $pw.end, seconds: $plateau_s, http_reqs: $plateau_reqs,
                           req_per_s: (if $plateau_s > 0 then $plateau_reqs / $plateau_s else null end)} else null end),
    vu_init_s: ([$halves_in[] | ([.rows[] | select(.vus != null and .vus > 0)] | first) as $f
                 | if $f != null and .started != null then $f.ts - .started else null end | select(. != null)] | maxn),
    server: {
      cpu_busy_median: ($busy_plat | median), cpu_busy_max: ($busy_plat | maxn),
      service_share: $service_share, service_share_median: ($svc_seconds | median), others_median: ($others | median), sampler_cores: $sampler_cores,
      us_per_req: (if $use_s != null and $use_e != null and ($plateau_reqs // 0) > 0 then ($use_e - $use_s) / $plateau_reqs else null end),
      accepts_per_s_median: ($acc_plat | median), accepts_per_s_max_plateau: ($acc_plat | maxn), accepts_per_s_max_run: ($acc_all | maxn),
      memory_current_peak: ([$srv[].mem_current | select(. != null)] | maxn),
      memory_peak_file: ([$srv[].mem_peak | select(. != null)] | maxn),
      rss_peak: ([$srv[].rss_bytes | select(. != null)] | maxn),
      mem_available_min_kb: $avail_min,
      tcp_inuse_peak: ([$srv[].tcp_inuse | select(. != null)] | maxn),
      tcp_mem_peak: ([$srv[].tcp_mem | select(. != null)] | maxn),
      tcp_tw_peak: ([$srv[].tcp_tw | select(. != null)] | maxn),
      listen_overflows: diff($srv_last.listen_overflows; $srv_first.listen_overflows),
      listen_drops: $drops,
      retrans_segs: diff($srv_last.retrans_segs; $srv_first.retrans_segs),
      ena_allowance_diff: $ena_diff,
      oom_lines_start: $oom_s, oom_lines_end: $oom_e, tcp_oom_lines_start: $tcp_oom_s, tcp_oom_lines_end: $tcp_oom_e,
      loop: ($meta.loop // null),
      fds_max: $fds_max,
      rows: ($srv | length)
    },
    loadbox: {over_line: ($over_line != null), cpu_max: ([$lbs[].cpu_max | select(. != null)] | maxn), plateau_seconds: ([$lbs[].plateau_seconds] | max),
              seconds_over_85: ([$lbs[].seconds_over_85] | max), longest_streak_over_85: ([$lbs[].longest_streak_over_85] | max),
              k6_memory_peak_bytes: ([$lbs[].k6_memory_peak_bytes | select(. != null)] | maxn), mem_total_kb: ([$lbs[].mem_total_kb | select(. != null)] | maxn),
              k6_cgroup_layout: $meta.cgroup_layout},
    half_start_skew_s: ($hm.skew_s // null),
    halves: (if $nh == 1 then null
             else [$halves_in | to_entries[] | .key as $i | .value as $h | $lbs[$i] as $lb
                   | ([$h.plat[] | select(.reqs != null)]) as $p
                   | {half: ($i + 1), users: $h.users, k6_exit: $h.exit, pass: ($h.exit == 0),
                      void: (($pass | not) and $lb.reason != null), void_reason: (if $pass then null else $lb.reason end),
                      p95_ms: $h.dur["p(95)"], p99_ms: $h.dur["p(99)"], error_rate: ($h.failed | .value // .rate), http_reqs: $h.reqs.count,
                      plateau: (if ($p | length) >= 2 then {start: $p[0].ts, end: $p[-1].ts, seconds: ($p[-1].ts - $p[0].ts), http_reqs: ($p[-1].reqs - $p[0].reqs)} else null end),
                      loadbox: ($lb | del(.reason) + {over_line: ($lb.reason != null)})}]
             end),
    healthy_s: $meta.healthy_s, service_died: $meta.server_died, dial_errors: $meta.dial_errors,
    wall: $wall
  }
