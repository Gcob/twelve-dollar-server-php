<?php
// The event loop of the DIY servers (lab/servers/bake-diy.php, lab/app/server.php): ext-event, one process, one DiyConnection
// (diy-connection.php) per client socket.
//
// Per connection: one DiyPeer (the connection's parser state, its read event, its write event when it has one), made at accept.
// A request allocates only its own strings, the array of its header lines and its response. The listening socket has one persistent
// read event and accepts until the queue is empty. A connection has a persistent read event all its life, except while its write
// buffer is over the limit (DiyConnection::WRITE_LIMIT), and a write event only while it has bytes the socket did not take.
//
// A server starts with the extensions loaded in this order: `--ext sockets --ext event` (sockets before event, which depends on
// it; sockets also sets TCP_NODELAY and reads it back).

require_once __DIR__ . '/diy-connection.php';

if (!extension_loaded('event') || !extension_loaded('sockets')) {
    fwrite(STDERR, "diy-server: ext-event and ext-sockets must be loaded (start with --ext sockets --ext event)\n");
    exit(1);
}

final class DiyPeer
{
    public ?Event $read = null;
    public ?Event $write = null;
    public bool $reading = true;
    public bool $writing = false;

    /** @param resource $stream */
    public function __construct(public readonly DiyConnection $conn, public readonly mixed $stream)
    {
    }
}

final class DiyServer
{
    private EventBase $base;
    private Event $listen;
    private bool $nodelayChecked = false;
    private readonly Closure $onReadable;
    private readonly Closure $onWritable;

    /**
     * @param resource $listener
     * @param DiyTelemetry|null $telemetry when given, every callback of the loop is timed and a line is printed each second
     *                                      (lab/servers/diy-telemetry.php, loaded by the caller); null: nothing is added to the loop
     */
    public function __construct($listener, private readonly ?object $telemetry = null)
    {
        $this->base = new EventBase();
        $onReadable = $this->onReadable(...);
        $onWritable = $this->onWritable(...);
        $onAccept = $this->onAccept(...);
        if ($telemetry !== null) {
            $onReadable = $telemetry->timed($onReadable);
            $onWritable = $telemetry->timed($onWritable);
            $onAccept = $telemetry->timed($onAccept);
        }
        $this->onReadable = $onReadable;
        $this->onWritable = $onWritable;
        $this->listen = new Event($this->base, $listener, Event::READ | Event::PERSIST, $onAccept, $listener);
        $this->listen->add();
    }

    public function loopMethod(): string
    {
        return $this->base->getMethod();
    }

    public function run(): void
    {
        $this->telemetry?->start($this->base);
        $this->base->dispatch();
    }

    /** @param resource $listener */
    private function onAccept($fd, int $what, $listener): void
    {
        // Until the queue is empty: a burst of connections is taken in one callback. At the fd limit accept() fails the same
        // way, and the listening event fires again at once (shedding there is for a later phase).
        while (($client = @stream_socket_accept($listener, 0)) !== false) {
            stream_set_blocking($client, false);
            // Why: PHP gives each socket an 8 KiB read buffer by default; nothing here reads through it.
            stream_set_read_buffer($client, 0);
            if (!$this->nodelayChecked) {
                $this->nodelayChecked = true;
                $nodelay = (int) (bool) socket_get_option(socket_import_stream($client), SOL_TCP, TCP_NODELAY);
                echo "accepted socket: tcp_nodelay=$nodelay\n";
            }
            $peer = new DiyPeer(new DiyConnection($client), $client);
            $peer->read = new Event($this->base, $client, Event::READ | Event::PERSIST, $this->onReadable, $peer);
            $peer->read->add();
        }
    }

    private function onReadable($fd, int $what, DiyPeer $peer): void
    {
        $this->settle($peer, $peer->conn->onReadable());
    }

    private function onWritable($fd, int $what, DiyPeer $peer): void
    {
        $this->settle($peer, $peer->conn->onWritable());
    }

    /** Frees a finished connection, or turns its events on and off to what it now waits for. */
    private function settle(DiyPeer $peer, bool $alive): void
    {
        if (!$alive) {
            // The events go first (they hold the stream and the peer), then the stream.
            $peer->read?->free();
            $peer->write?->free();
            $peer->read = $peer->write = null;
            $peer->conn->close();
            return;
        }
        $wantsWrite = $peer->conn->wantsWrite();
        if ($wantsWrite !== $peer->writing) {
            $peer->writing = $wantsWrite;
            if ($wantsWrite) {
                $peer->write ??= new Event($this->base, $peer->stream, Event::WRITE | Event::PERSIST, $this->onWritable, $peer);
                $peer->write->add();
            } else {
                $peer->write->del();
            }
        }
        $wantsRead = $peer->conn->wantsRead();
        if ($wantsRead !== $peer->reading) {
            $peer->reading = $wantsRead;
            $wantsRead ? $peer->read->add() : $peer->read->del();
        }
    }
}


/**
 * The listening socket of a DIY server: bound on $host:$port, non-blocking, with TCP_NODELAY. Exits with a message when it cannot
 * listen. One process serves, so no SO_REUSEPORT (PHP asks for SO_REUSEADDR by default).
 *
 * @return resource
 */
function diy_listen(string $host, int $port, int $backlog)
{
    $listener = stream_socket_server(
        "tcp://$host:$port",
        $errno,
        $errstr,
        STREAM_SERVER_BIND | STREAM_SERVER_LISTEN,
        stream_context_create(['socket' => ['backlog' => $backlog, 'so_reuseport' => false]])
    );
    if ($listener === false) {
        fwrite(STDERR, "diy-server: cannot listen on $host:$port: $errstr ($errno)\n");
        exit(1);
    }
    stream_set_blocking($listener, false);
    // Why: TCP_NODELAY on the listening socket is inherited by the sockets it accepts on Linux (the first accepted socket reports it).
    socket_set_option(socket_import_stream($listener), SOL_TCP, TCP_NODELAY, 1);
    return $listener;
}

/** The `socket:` boot line: what the kernel says about the listening socket (the backlog cannot be read back, so it is what was asked). */
function diy_socket_line($listener, int $backlog): string
{
    return "socket: backlog=$backlog tcp_nodelay=" . (int) (bool) socket_get_option(socket_import_stream($listener), SOL_TCP, TCP_NODELAY);
}
