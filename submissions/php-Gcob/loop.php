<?php
// The event loop of the server: ext-event, one process, one DiyConnection (connection.php) per client socket.
//
// Per connection: one DiyPeer (the connection's parser state, its read event, its write event when it has one), made at accept.
// A request allocates only its own strings, the array of its header lines and its response. The listening socket has one persistent
// read event and accepts until the queue is empty. A connection has a persistent read event all its life, except while its write
// buffer is over the limit (DiyConnection::WRITE_LIMIT), and a write event only while it has bytes the socket did not take.
//
// Two limits on connections. The hard one is the process's file descriptors: when accept() fails for want of one the loop stops
// listening (the clients wait in the kernel's backlog) and listens again when a client connection closes. The soft one is the
// constructor's $softConnLimit: a response built while more connections than that are open says `Connection: close`, and its
// connection ends once it is written, so a process serves more users than it has descriptors when they rarely send a request.
// An idle connection is never closed by either limit.
//
// A server starts with the extensions loaded in this order: `sockets`, then `event` (which depends on it; sockets also sets TCP_NODELAY
// and reads it back).

require_once __DIR__ . '/connection.php';

if (!extension_loaded('event') || !extension_loaded('sockets')) {
    fwrite(STDERR, "diy-server: ext-event and ext-sockets must be loaded\n");
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
    private readonly DiyConnectionCount $count;
    /** True while the listening event is deleted because accept() ran out of file descriptors. */
    private bool $acceptPaused = false;
    private bool $pauseReported = false;
    /** @var array{object, string} the loop's callbacks */
    private readonly array $onReadable;
    private readonly array $onWritable;

    /**
     * @param resource $listener
     * @param int $softConnLimit a response built while more client connections than this are open says `Connection: close` and ends its
     *                           connection
     */
    public function __construct($listener, int $softConnLimit)
    {
        $this->count = new DiyConnectionCount($softConnLimit);
        $this->base = new EventBase();
        $onAccept = [$this, 'onAccept'];
        $this->onReadable = [$this, 'onReadable'];
        $this->onWritable = [$this, 'onWritable'];
        $this->listen = new Event($this->base, $listener, Event::READ | Event::PERSIST, $onAccept, $listener);
        $this->listen->add();
    }

    /** The boot line's `loop:` value: the method libevent chose. */
    public function loopLine(): string
    {
        return $this->base->getMethod();
    }

    public function run(): void
    {
        $this->base->dispatch();
    }

    /** @param resource $listener */
    private function onAccept($fd, int $what, $listener): void
    {
        // Until the queue is empty: a burst of connections is taken in one callback.
        while (true) {
            error_clear_last();
            $client = @stream_socket_accept($listener, 0);
            if ($client === false) {
                break;
            }
            stream_set_blocking($client, false);
            // Why: PHP gives each socket an 8 KiB read buffer by default; nothing here reads through it.
            stream_set_read_buffer($client, 0);
            if (!$this->nodelayChecked) {
                $this->nodelayChecked = true;
                $nodelay = (int) (bool) socket_get_option(socket_import_stream($client), SOL_TCP, TCP_NODELAY);
                echo "accepted socket: tcp_nodelay=$nodelay\n";
            }
            $this->count->opened();
            $peer = new DiyPeer(new DiyConnection($client, $this->count), $client);
            $peer->read = new Event($this->base, $client, Event::READ | Event::PERSIST, $this->onReadable, $peer);
            $peer->read->add();
        }
        // An empty queue and a process out of file descriptors both end the loop above. In the second the connection stays in the backlog
        // and the listening event would fire again at once: stop listening until a client connection closes and frees a descriptor.
        $error = error_get_last()['message'] ?? '';
        if (str_contains($error, 'Too many open files')) {
            $this->listen->del();
            $this->acceptPaused = true;
            // Why a flag of its own: the line is printed once per process, however many times the accept pauses.
            if (!$this->pauseReported) {
                $this->pauseReported = true;
                fwrite(STDERR, "diy-server: out of file descriptors with {$this->count->open} client connections open ($error): " .
                    "accepting again when one closes, clients wait in the backlog meanwhile\n");
            }
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
            $this->count->closed();
            if ($this->acceptPaused) {
                $this->acceptPaused = false;
                $this->listen->add();
            }
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
 * The listening socket of the server: bound on $host:$port with SO_REUSEPORT (each worker binds the same port and the kernel splits the new
 * connections between them), non-blocking, with TCP_NODELAY. Exits with a message when it cannot listen.
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
        stream_context_create(['socket' => ['backlog' => $backlog, 'so_reuseport' => true]])
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
