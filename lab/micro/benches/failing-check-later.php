<?php
// Fixture of lab/check.sh: a check that passes in the first process of a run and fails in the next ones (the file lives in
// the container's temp folder, which is new for every micro.sh run). Stands for a bench that writes to its database copy.
// The harness must skip the case, whatever process failed, and still time the other one.
$seen = sys_get_temp_dir() . '/micro-fixture-check-seen';
return [
    'passes once, then fails' => [
        'run' => fn() => strlen('abc'),
        'check' => function ($result) use ($seen) {
            static $firstProcess = null;
            $firstProcess ??= !file_exists($seen);
            touch($seen);
            return ($firstProcess && $result === 3) ? true : 'state left by an earlier process';
        },
    ],
    'always right' => [
        'run' => fn() => strlen('abc'),
        'check' => fn($result) => $result === 3,
    ],
];
