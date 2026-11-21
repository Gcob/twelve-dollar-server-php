<?php
// Shows which of Workerman's 5 request caches are filled after the same HTTP request went through the protocol twice, on
// each of the two trees in the image (/opt/workerman/stock and /opt/workerman/nocache).
//
//   bash lab/run.sh 8.5 php /lab/servers/workerman-caches.php
//
// One line per tree and cache, `filled` or `empty`. Exit 0 only if all 5 are filled on `stock` and all 5 empty on `nocache`.
// Both trees declare the same classes, so each one is read in a child process of its own (`php <this file> child <tree>`).
// The caches are function-local `static` variables: they are read with Reflection, not by looking at the output.

const TREES = ['stock', 'nocache'];

// Class, method, name of the static variable that holds the cache.
const CACHES = [
    'TcpConnection::baseRead' => [Workerman\Connection\TcpConnection::class, 'baseRead', 'requests'],
    'Http::input' => [Workerman\Protocols\Http::class, 'input', 'cache'],
    'Request::parseHeaders' => [Workerman\Protocols\Http\Request::class, 'parseHeaders', 'cache'],
    'Request::parseGet' => [Workerman\Protocols\Http\Request::class, 'parseGet', 'cache'],
    'Request::parsePost' => [Workerman\Protocols\Http\Request::class, 'parsePost', 'cache'],
];

// The request has a query string and a form body, so that header(), get() and post() all have something to parse.
const RAW_REQUEST = "POST /posts/1?page=2&sort=new HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/x-www-form-urlencoded\r\n"
    . "Content-Length: 12\r\n\r\ntext=hello+x";

if (($argv[1] ?? '') === 'child') {
    exit(child($argv[2] ?? ''));
}
exit(parent_run());

function child(string $tree): int
{
    require "/opt/workerman/$tree/autoload.php";

    $loop = new Workerman\Events\Select();
    [$server, $client] = stream_socket_pair(STREAM_PF_UNIX, STREAM_SOCK_STREAM, STREAM_IPPROTO_IP);
    $connection = new Workerman\Connection\TcpConnection($loop, $server, '127.0.0.1:1');
    $connection->protocol = Workerman\Protocols\Http::class;
    $answered = 0;
    $connection->onMessage = function ($connection, $request) use (&$answered): void {
        $request->header('host');
        $request->get('page');
        $request->post('text');
        $answered++;
    };

    // Twice: the first request fills the caches, the second is the one a cache would answer.
    for ($i = 0; $i < 2; $i++) {
        fwrite($client, RAW_REQUEST);
        $connection->baseRead($server);
    }
    if ($answered !== 2) {
        fwrite(STDERR, "onMessage ran $answered times, expected 2\n");
        return 1;
    }

    foreach (CACHES as $label => [$class, $method, $name]) {
        $statics = (new ReflectionMethod($class, $method))->getStaticVariables();
        echo $label, ' ', empty($statics[$name]) ? 'empty' : 'filled', "\n";
    }
    return 0;
}

function parent_run(): int
{
    $ok = true;
    foreach (TREES as $tree) {
        $command = [PHP_BINARY, '-d', 'display_errors=stderr', __FILE__, 'child', $tree];
        $process = proc_open($command, [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
        $out = stream_get_contents($pipes[1]);
        $err = stream_get_contents($pipes[2]);
        $status = proc_close($process);
        if ($status !== 0) {
            echo "FAIL  $tree: the child exited $status: ", trim($err), "\n";
            $ok = false;
            continue;
        }
        $want = $tree === 'stock' ? 'filled' : 'empty';
        $states = [];
        foreach (explode("\n", trim($out)) as $line) {
            [$label, $state] = explode(' ', $line);
            $states[$label] = $state;
            echo str_pad($tree, 8), str_pad($label, 26), $state, $state === $want ? '' : "   <- expected $want", "\n";
        }
        if (count($states) !== count(CACHES) || array_unique(array_values($states)) !== [$want]) {
            $ok = false;
        }
    }
    echo $ok ? "OK: 5 caches filled on stock, 5 empty on nocache\n" : "FAIL: the caches are not as expected\n";
    return $ok ? 0 : 1;
}
