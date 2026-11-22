<?php
// The DIY server of the runtime bake-off: our own event loop (ext-event, one process) and our own HTTP/1.1 parser
// (diy-connection.php), answering through handler.php (GET /noop and GET /posts/:id). Port: PORT (default 8080).
//
// lab/macro.sh, lab/conformance.sh and lab/conns.sh start it with the extensions loaded in this order:
//   --ext sockets --ext event
// (sockets before event, which depends on it; sockets also sets TCP_NODELAY and reads it back).
//
// Per connection: one DiyPeer (the connection's parser state, its read event, its write event when it has one), made at accept.
// A request allocates only its own strings, the array of its header lines and its response. The listening socket has one persistent read event and accepts until the queue is empty. A connection has a
// persistent read event all its life, except while its write buffer is over the limit (DiyConnection::WRITE_LIMIT), and a
// write event only while it has bytes the socket did not take.

require __DIR__ . '/handler.php';
require __DIR__ . '/diy-connection.php';

if (!extension_loaded('event') || !extension_loaded('sockets')) {
    fwrite(STDERR, "bake-diy: ext-event and ext-sockets must be loaded (start with --ext sockets --ext event)\n");
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

    /** @param resource $listener */
    public function __construct($listener)
    {
        $this->base = new EventBase();
        $this->onReadable = $this->onReadable(...);
        $this->onWritable = $this->onWritable(...);
        $this->listen = new Event($this->base, $listener, Event::READ | Event::PERSIST, $this->onAccept(...), $listener);
        $this->listen->add();
    }

    public function loopMethod(): string
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

$port = (int) (getenv('PORT') ?: 8080);
$backlog = 4096;

// The database copy takes a few seconds, so the server listens only once it is done.
handler_boot();

// One process, so no SO_REUSEPORT. PHP asks for SO_REUSEADDR by default.
$listener = stream_socket_server(
    "tcp://0.0.0.0:$port",
    $errno,
    $errstr,
    STREAM_SERVER_BIND | STREAM_SERVER_LISTEN,
    stream_context_create(['socket' => ['backlog' => $backlog, 'so_reuseport' => false]])
);
if ($listener === false) {
    fwrite(STDERR, "bake-diy: cannot listen on 0.0.0.0:$port: $errstr ($errno)\n");
    exit(1);
}
stream_set_blocking($listener, false);
// Why: TCP_NODELAY on the listening socket is inherited by the sockets it accepts on Linux (the first accepted socket reports it).
$socket = socket_import_stream($listener);
socket_set_option($socket, SOL_TCP, TCP_NODELAY, 1);

$server = new DiyServer($listener);
echo "listening on 0.0.0.0:$port\n";
echo 'loop: ' . $server->loopMethod() . "\n";
// What the kernel says about the listening socket (the backlog cannot be read back, so it is what was asked).
echo "socket: backlog=$backlog tcp_nodelay=" . (int) (bool) socket_get_option($socket, SOL_TCP, TCP_NODELAY) . "\n";
$server->run();
