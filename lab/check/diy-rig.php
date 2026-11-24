<?php
// Shared by the tests that run a DiyServer (diy-group-commit-test.php, app-group-commit-test.php): a server on a TCP port of this machine and
// clients in this process, with the loop driven one turn at a time (DiyServer::turn()). Needs ext-event and ext-sockets, and the handler
// (handler_handle) of the test.

require_once __DIR__ . '/../servers/diy-server.php';

const RIG_FIRST_PORT = 18290;

/** A server on a port of its own, and its clients' view of it. */
final class DiyRig
{
    public DiyServer $server;
    /** @var list<resource> */
    public array $clients = [];
    /** @var array<int, string> what each client has read so far */
    public array $got = [];
    private Event $heartbeat;
    private int $port;
    private static int $ports = 0;

    /**
     * @param Closure(list<Closure>): list<array{int, string}>|null $commit the group commit of the server, or null for the plain loop
     * @param string|null $loop a loop preset (diy_loop_presets()); null: the first argument the test file was started with, if there is one
     *                          (`php diy-group-commit-test.php nolock` runs every case on that preset), else the default loop
     */
    public function __construct(?Closure $commit = null, ?string $loop = null)
    {
        $loop ??= $_SERVER['argv'][1] ?? null;
        // Why a port for each: a server that went out of scope is only freed by the garbage collector, and it still listens until then.
        $this->port = RIG_FIRST_PORT + self::$ports++;
        $listener = diy_listen('127.0.0.1', $this->port, 128);
        $this->server = new DiyServer($listener, null, null, null, $commit, $loop);
        // Why: a turn blocks until an event is ready, and a case that fails would wait forever. A timer that repeats makes every turn end within 50 ms.
        $base = Closure::bind(fn () => $this->base, $this->server, DiyServer::class)();
        $this->heartbeat = new Event($base, -1, Event::TIMEOUT | Event::PERSIST, static function (): void {
        });
        $this->heartbeat->add(0.05);
    }

    public function connect(): int
    {
        $client = stream_socket_client('tcp://127.0.0.1:' . $this->port, $errno, $errstr, 2);
        if ($client === false) {
            throw new RuntimeException("cannot connect: $errstr");
        }
        stream_set_blocking($client, false);
        $this->clients[] = $client;
        $this->got[count($this->clients) - 1] = '';
        return count($this->clients) - 1;
    }

    public function send(int $client, string $bytes): void
    {
        fwrite($this->clients[$client], $bytes);
    }

    /** Turns the loop until client $client has read $length bytes, or 2 s have passed. Returns what it has read. */
    public function readFrom(int $client, int $length): string
    {
        $deadline = hrtime(true) + 2_000_000_000;
        while (strlen($this->got[$client]) < $length && hrtime(true) < $deadline) {
            $this->server->turn();
            $this->collect();
        }
        return $this->got[$client];
    }

    /** Reads what every client has received, without turning the loop. */
    public function collect(): void
    {
        foreach ($this->clients as $i => $client) {
            $this->got[$i] .= (string) fread($client, 65536);
        }
    }

    public function turns(int $n): void
    {
        for ($i = 0; $i < $n; $i++) {
            $this->server->turn();
            $this->collect();
        }
    }

    public function close(): void
    {
        foreach ($this->clients as $client) {
            @fclose($client);
        }
    }
}
