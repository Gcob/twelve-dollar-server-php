<?php
// Fixture of lab/check.sh: the harness must report the case whose check fails, skip it, and still time the others.
return [
    'wrong variant (strlen of "abc" is not 4)' => [
        'run' => fn() => strlen('abc'),
        'check' => fn($result) => $result === 4 ? true : "expected 4, got $result",
    ],
    'right variant' => [
        'run' => fn() => strlen('abc'),
        'check' => fn($result) => $result === 3,
    ],
];
