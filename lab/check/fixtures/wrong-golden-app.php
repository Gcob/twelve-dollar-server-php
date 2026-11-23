<?php
// A challenge server that answers one golden wrong: the real app, on a database where post 250000 has another body. The challenge's
// test.sh must fail on `GET /posts/250000 == golden` and on nothing else (the feed holds only the newest 20 posts).
// Start it like the app (lab/challenge-test.sh --server lab/check/fixtures/wrong-golden-app.php).

$db = new PDO('sqlite:' . getenv('SQLITE_PATH'), null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
$db->exec("UPDATE posts SET body = 'not the body of the seed' WHERE id = 250000");
unset($db);

require __DIR__ . '/../../app/server.php';
