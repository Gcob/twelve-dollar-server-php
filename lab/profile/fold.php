<?php
// Folds a profile into the steps of a request: one table, rows the steps (S1 to S9, the event loop, unclassified), columns the endpoints,
// "shared" (samples with no route function on their stack) and all.
//
//   php lab/profile/fold.php <collapsed file, or - for stdin> [--rules <file>] [--us-per-req <n>]
//
// The collapsed file is what lab/servers/diy-profile.php writes ("frame;frame;frame <count>" per line). --rules defaults to
// lab/profile/steps.rules. --us-per-req is the server's CPU per request (a number of microseconds, from the run, never from this file):
// each cell then also gives the microseconds it adds to the average request. Exit 1 on a usage error or an unreadable file.

require __DIR__ . '/fold-lib.php';

$args = array_slice($argv, 1);
$file = null;
$rulesFile = __DIR__ . '/steps.rules';
$usPerRequest = null;
while ($args) {
    $arg = array_shift($args);
    if ($arg === '--rules' && $args) {
        $rulesFile = array_shift($args);
    } elseif ($arg === '--us-per-req' && $args) {
        $value = array_shift($args);
        if (!is_numeric($value) || (float) $value <= 0) {
            fwrite(STDERR, "fold: --us-per-req wants a number above 0, got '$value'\n");
            exit(1);
        }
        $usPerRequest = (float) $value;
    } elseif ($file === null && ($arg === '-' || $arg[0] !== '-')) {
        $file = $arg;
    } else {
        fwrite(STDERR, "usage: php fold.php <collapsed file or -> [--rules <file>] [--us-per-req <n>]\n");
        exit(1);
    }
}
if ($file === null) {
    fwrite(STDERR, "usage: php fold.php <collapsed file or -> [--rules <file>] [--us-per-req <n>]\n");
    exit(1);
}
$collapsed = $file === '-' ? stream_get_contents(STDIN) : @file_get_contents($file);
$rulesText = @file_get_contents($rulesFile);
if ($collapsed === false || $rulesText === false) {
    fwrite(STDERR, 'fold: cannot read ' . ($collapsed === false ? $file : $rulesFile) . "\n");
    exit(1);
}
try {
    $rules = fold_parse_rules($rulesText);
} catch (InvalidArgumentException $e) {
    fwrite(STDERR, 'fold: ' . $e->getMessage() . "\n");
    exit(1);
}
$counted = fold_count($rules, $collapsed);
if ($counted['samples'] === 0) {
    fwrite(STDERR, "fold: the profile holds no sample\n");
    exit(1);
}
echo fold_table($rules, $counted, $usPerRequest);
