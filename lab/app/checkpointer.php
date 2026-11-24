<?php
// The checkpointer of lab/app/server.php (APP_CHECKPOINTER=<ms>): its own process and its own connection to the database, running
// `PRAGMA wal_checkpoint(PASSIVE)` every <ms> milliseconds so that the server's connection never has to (it runs with wal_autocheckpoint = 0).
// A passive checkpoint copies the WAL's frames into the database file without blocking the writer or a reader, and copies only as far as
// the oldest reader allows.
//
//   php checkpointer.php <database path> <ms>
//
// It ends when its standard input closes: the server holds the other end of that pipe, so the end of the server, killed or not, ends it.

[, $path, $ms] = $argv + [null, '', ''];
if ($path === '' || !ctype_digit($ms) || (int) $ms < 1) {
    fwrite(STDERR, "checkpointer: usage: checkpointer.php <database path> <ms>\n");
    exit(2);
}
$db = new PDO('sqlite:' . $path, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
$db->exec('PRAGMA busy_timeout = 5000');
$checkpoint = $db->prepare('PRAGMA wal_checkpoint(PASSIVE)');
$seconds = intdiv((int) $ms, 1000);
$micro = ((int) $ms % 1000) * 1000;
while (true) {
    $read = [STDIN];
    $write = $except = null;
    // A readable stdin is the server's end of the pipe closing (nothing is ever written to it); false is an error: end as well.
    if (stream_select($read, $write, $except, $seconds, $micro) !== 0) {
        exit(0);
    }
    $checkpoint->execute();
    $checkpoint->fetchAll();
}
