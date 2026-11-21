<?php
// Proves the harness; it is not the result of any step. See "Micro benchmarks" in lab/README.md for the format.
return [
    'json_encode small array' => [
        'setup' => fn() => ['id' => 42, 'name' => 'ada', 'tags' => ['a', 'b'], 'ok' => true],
        'run' => fn(array $post) => json_encode($post),
        'check' => fn($result) => $result === '{"id":42,"name":"ada","tags":["a","b"],"ok":true}',
    ],
    'ctype_digit "12345"' => [
        'run' => fn() => ctype_digit('12345'),
        'check' => fn($result) => $result === true,
    ],
    'ctype_digit "12a"' => [
        'run' => fn() => ctype_digit('12a'),
        'check' => fn($result) => $result === false,
    ],
];
