# Makes the sampler files of one made-up k6 run, for lab/check.sh check_score:
#   awk -v dir=<folder> -v 'opts=key=value key=value ...' -f make-run.awk
# A run of `users` users: a 5 s ramp, a 10 s plateau, a 3 s ramp down, one row a second. The REST rows are at .0 of each second, the load
# box's at .1 and the server's at .4, so the plateau has to be matched by time. The plateau serves `rate` requests a second (20 outside
# it), the service burns `svc` cores, the server box (2 CPUs) is `busy` busy, the load box (4 CPUs) is `lbbusy` busy, and `lbspike` busy
# at its seconds `lbspikes` (the plateau is seconds 5 to 5 + plateau - 1 for the load box's rows). Written by hand so that the expected numbers of the check come from arithmetic, not from the code:
#   plateau: from second 5 to second 15, 10 s; plateau requests 10 * rate; service burns 10 * svc * 1,000,000 us on it;
#   passive opens: 40 a second on the plateau (55 at second 9), 10 outside it, 90 at second 2.
# Options (defaults): plateau=10 (its length in seconds) lbspikes=9 (the seconds, comma separated, where the load box is `lbspike` busy) users=100 rate=1000 svc=0.5 busy=0.6 lbbusy=0.3 lbspike=0.3 k6mib=200 avail=2000000 drops=0 fds=130 p95=120 p99=300
# err=0 instant=0 (1: the users are there from the first second, and the first `early404` rows have no http_reqs metric, as in a 1-user run) early404=0 oom=0 (OOM lines at the end) ena=0 (growth of the ENA counter pps_allowance_exceeded) cavail=0 (change of the gauge conntrack_allowance_available, which is not a count of anything bad) sampler_ms=50 (the sampler's CPU time) svcspike=svc (cores burnt at the server rows `svcspikes`, comma separated, none by default: the plateau's mean and median second of the service's share can then differ) nocg=-1 (from that second on, the server rows have no cgroup columns, as when the service's cgroup is gone and the sampler goes on) srvrows=1 (0: server.csv has its header and no row) shift=0 (seconds: the REST and load box rows are that much later than the server's, as the second k6 half's are when it starts late) bwena=0 (growth of the ENA counter bw_in_allowance_exceeded) ctexc=0 (growth of the ENA counter conntrack_allowance_exceeded) tcpoom=0 (`TCP: out of memory` lines new at the end; the start file has 1 old one).
function opt(name, def) { return (name in V) ? V[name] : def }
BEGIN {
  n = split(opts, o, " ")
  for (i = 1; i <= n; i++) { split(o[i], kv, "="); V[kv[1]] = kv[2] }
  users = opt("users", 100) + 0; rate = opt("rate", 1000) + 0; svc = opt("svc", 0.5) + 0; busy = opt("busy", 0.6) + 0
  lbbusy = opt("lbbusy", 0.3) + 0; lbspike = opt("lbspike", 0.3) + 0; k6mib = opt("k6mib", 200) + 0; avail = opt("avail", 2000000) + 0
  drops = opt("drops", 0) + 0; fds = opt("fds", 130) + 0; p95 = opt("p95", 120) + 0; p99 = opt("p99", 300) + 0; err = opt("err", 0) + 0
  instant = opt("instant", 0) + 0; early404 = opt("early404", 0) + 0; oom = opt("oom", 0) + 0; ena = opt("ena", 0) + 0; cavail = opt("cavail", 0) + 0; sampler_ms = opt("sampler_ms", 50) + 0
  plateau = opt("plateau", 10) + 0
  ns = split(opt("lbspikes", "9"), sp, ","); for (i = 1; i <= ns; i++) SPIKE[sp[i] + 0] = 1
  svcspike = opt("svcspike", svc) + 0; nocg = opt("nocg", -1) + 0; srvrows = opt("srvrows", 1) + 0
  ns = split(opt("svcspikes", ""), sp, ","); for (i = 1; i <= ns; i++) if (sp[i] != "") SVCSPIKE[sp[i] + 0] = 1
  bwena = opt("bwena", 0) + 0; tcpoom = opt("tcpoom", 0) + 0; shift = opt("shift", 0) + 0; ctexc = opt("ctexc", 0) + 0
  t0 = 1700000000; ramp = 5; down = 3; rows = ramp + plateau + down
  rest = dir "/rest.tsv"; lb = dir "/loadbox.csv"; srv = dir "/server.csv"
  printf "" > rest
  print "ts,cpu_user,cpu_nice,cpu_system,cpu_idle,cpu_iowait,cpu_irq,cpu_softirq,cpu_steal,k6_mem_current,k6_mem_peak,mem_total_kb" > lb
  print "ts,cpu_user,cpu_nice,cpu_system,cpu_idle,cpu_iowait,cpu_irq,cpu_softirq,cpu_steal,cg_usage_usec,mem_current,mem_peak,rss_bytes,mem_available_kb,tcp_inuse,tcp_tw,tcp_mem,passive_opens,active_opens,curr_estab,retrans_segs,listen_overflows,listen_drops,fds" > srv
  reqs = 0; lbu = 0; lbi = 0; su = 0; si = 0; use = 0; po = 0; retr = 0; dr = 0
  for (i = 0; i <= rows; i++) {
    if (i < ramp) vus = instant ? users : int(users * i / ramp)
    else if (i <= ramp + plateau) vus = users
    else vus = users - int(users * (i - ramp - plateau) / down)
    if (i > 0) reqs += (i > ramp && i <= ramp + plateau) ? rate : 20
    nometric = "{\"errors\":[{\"status\":\"404\",\"title\":\"Not Found\"}]}"
    c = (i < early404) ? nometric : sprintf("{\"data\":{\"attributes\":{\"sample\":{\"count\":%d,\"rate\":1}}}}", reqs)
    r = (i < early404) ? nometric : "{\"data\":{\"attributes\":{\"sample\":{\"rate\":0}}}}"
    printf "%.3f\t{\"data\":{\"attributes\":{\"sample\":{\"value\":%d}}}}\t%s\t%s\t\n", t0 + shift + i, vus, c, r >> rest
    b = (i in SPIKE) ? lbspike : lbbusy
    if (i > 0) { lbu += b * 400; lbi += (1 - b) * 400 }
    m = (k6mib + i) * 1048576
    printf "%.3f,%d,0,0,%d,0,0,0,0,%d,%d,8000000\n", t0 + shift + i + 0.1, lbu, lbi, m, m >> lb
    if (i > 0) {
      su += busy * 200; si += (1 - busy) * 200; use += ((i in SVCSPIKE) ? svcspike : svc) * 1000000; retr += 3
      po += (i >= 5 && i <= 14) ? ((i == 9) ? 55 : 40) : ((i == 2) ? 90 : 10)
    }
    if (i == 10) dr = drops
    f = ""
    if (i == 0) f = "11:100;12:90"
    if (i == 10) f = "11:120;12:" fds
    mc = 100000000 + i * 1000000
    if (!srvrows) continue
    if (nocg >= 0 && i >= nocg) printf "%.3f,%d,0,0,%d,0,0,0,0,,,,0,%d,%d,%d,%d,%d,0,0,%d,0,%d,\n", t0 + i + 0.4, su, si, avail, 10 * i, i, 2 * i, po, retr, dr >> srv
    else printf "%.3f,%d,0,0,%d,0,0,0,0,%d,%d,%d,%d,%d,%d,%d,%d,%d,0,0,%d,0,%d,%s\n", t0 + i + 0.4, su, si, use, mc, mc, mc / 2, avail, 10 * i, i, 2 * i, po, retr, dr, f >> srv
  }
  print "nproc 2\nena bw_in_allowance_exceeded 5\nena pps_allowance_exceeded 7\nena conntrack_allowance_available 100000\nena conntrack_allowance_exceeded 0\noom Out of memory: Killed process 1 (old)\ntcp-oom TCP: out of memory -- consider tuning tcp_mem" > (dir "/server-start.txt")
  print "nproc 2\nena bw_in_allowance_exceeded " (5 + bwena) "\nena pps_allowance_exceeded " (7 + ena) "\nena conntrack_allowance_available " (100000 + cavail) "\nena conntrack_allowance_exceeded " (ctexc) "\noom Out of memory: Killed process 1 (old)\ntcp-oom TCP: out of memory -- consider tuning tcp_mem" > (dir "/server-end.txt")
  for (i = 1; i <= tcpoom; i++) print "tcp-oom TCP: out of memory -- consider tuning tcp_mem" >> (dir "/server-end.txt")
  for (i = 1; i <= oom; i++) print "oom Out of memory: Killed process " (100 + i) " (php)" >> (dir "/server-end.txt")
  print "sampler_cpu_ms " sampler_ms "\nsampler_wall_ms 10000" >> (dir "/server-end.txt")
  printf "{\"metrics\":{\"http_req_duration\":{\"avg\":15,\"med\":11,\"p(95)\":%s,\"p(99)\":%s,\"max\":900},\"http_req_failed\":{\"value\":%s,\"passes\":0,\"fails\":0},\"http_reqs\":{\"count\":%d,\"rate\":50}}}\n", p95, p99, err, reqs > (dir "/summary.json")
}
