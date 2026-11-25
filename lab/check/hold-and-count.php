<?php
// For lab/check.sh, on the submission (which has no telemetry to say which process answered): holds <n> connections open at once, each
// answered with one GET /health, and counts the sockets in /proc/<pid>/fd of each process it is given before the connections and while they
// are held. A process whose count grew accepted some of them. Runs in the server's container (`docker exec`), so it sees the server's pids.
//
//   php hold-and-count.php <port> <n> <pid>...
//
// Prints {"answered": <n>, "workers": {"<pid>": {"before": <sockets>, "during": <sockets>}, ...}} and exits 0 when every connection was answered.

const REQUEST = "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";

/** The sockets a process has open, from its descriptor table. */
function sockets(int $pid): int
{
    $count = 0;
    foreach (glob("/proc/$pid/fd/*") ?: [] as $fd) {
        $count += str_starts_with((string) @readlink($fd), 'socket:') ? 1 : 0;
    }
    return $count;
}

$port = (int) ($argv[1] ?? 0);
$n = (int) ($argv[2] ?? 0);
$pids = array_map('intval', array_slice($argv, 3));
if ($port < 1 || $n < 1 || $pids === []) {
    fwrite(STDERR, "usage: hold-and-count.php <port> <n> <pid>...\n");
    exit(2);
}

$workers = [];
foreach ($pids as $pid) {
    $workers[$pid] = ['before' => sockets($pid)];
}
$held = [];
$answered = 0;
for ($i = 0; $i < $n; $i++) {
    $fp = @stream_socket_client("tcp://127.0.0.1:$port", $errno, $errstr, 2);
    if ($fp === false) {
        continue;
    }
    stream_set_timeout($fp, 2);
    fwrite($fp, REQUEST);
    $head = (string) fread($fp, 12);
    $answered += str_starts_with($head, 'HTTP/1.1 200') ? 1 : 0;
    $held[] = $fp;
}
foreach ($pids as $pid) {
    $workers[$pid]['during'] = sockets($pid);
}
echo json_encode(['answered' => $answered, 'workers' => $workers]) . "\n";
exit($answered === $n ? 0 : 1);
