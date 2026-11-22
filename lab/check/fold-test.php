<?php
// The fold of lab/profile/fold-lib.php on lab/check/fixtures/profile-collapsed.txt, a profile written by hand whose shares are known
// (1,000 samples: the numbers below are counted from the file, not computed by the fold), with the committed rules.
// Run: bash lab/run.sh 8.5 php /lab/check/fold-test.php

require __DIR__ . '/../profile/fold-lib.php';

$failures = 0;
function check(string $name, bool $ok, string $detail = ''): void
{
    global $failures;
    if ($ok) {
        echo "ok    $name\n";
    } else {
        $failures++;
        echo "FAIL  $name" . ($detail === '' ? '' : ": $detail") . "\n";
    }
}

$rules = fold_parse_rules(file_get_contents(__DIR__ . '/../profile/steps.rules'));
$counted = fold_count($rules, file_get_contents(__DIR__ . '/fixtures/profile-collapsed.txt'));

// --- the shares of the fixture ----------------------------------------------------------------------------------------------
$byStep = [];
foreach ($counted['cells'] as $step => $endpoints) {
    $byStep[$step] = array_sum($endpoints);
}
check('1,000 samples', $counted['samples'] === 1000, (string) $counted['samples']);
$expected = ['loop' => 100, 'S1' => 20, 'S2' => 200, 'S3' => 40, 'S4' => 80, 'S5' => 30, 'S6' => 365, 'S7' => 100, 'S8' => 60, 'unclassified' => 5];
ksort($expected);
ksort($byStep);
check('every step holds the samples counted by hand', $byStep === $expected, json_encode($byStep));
check('S9 has no sample: a commit is inside the write query', !isset($byStep['S9']));
check('the steps add up to all the samples', array_sum($byStep) === $counted['samples']);
check('the feed route: S3 10, S6 250, S7 90', ($counted['cells']['S3']['GET /feed'] ?? 0) === 10 && ($counted['cells']['S6']['GET /feed'] ?? 0) === 250 && ($counted['cells']['S7']['GET /feed'] ?? 0) === 90);
check('a sample with no route function on its stack is shared (the parse, the loop, the write)', ($counted['cells']['S2']['shared'] ?? 0) === 200 && ($counted['cells']['loop']['shared'] ?? 0) === 100 && ($counted['cells']['S8']['shared'] ?? 0) === 60);
check('the POST /posts steps: S4 80 (the JWT, two stacks), S5 30, S6 70', ($counted['cells']['S4']['POST /posts'] ?? 0) === 80 && ($counted['cells']['S5']['POST /posts'] ?? 0) === 30 && ($counted['cells']['S6']['POST /posts'] ?? 0) === 70);

// --- unknown frames -----------------------------------------------------------------------------------------------------------
check('an unknown frame, alone or under a frame no rule names, is unclassified, 5 samples', ($byStep['unclassified'] ?? 0) === 5 && $counted['unknown'] === ['mysteryFrame' => 5], json_encode($counted['unknown']));
check('an unknown frame under a known one does not hide it: like_insert under route_like is S6 of POST /posts/:id/like', ($counted['cells']['S6']['POST /posts/:id/like'] ?? 0) === 5);
check('the innermost matching frame wins: a stack through handler_handle and route_feed ending in feed_query is S6, not S3', fold_classify($rules, ['DiyServer::run', 'handler_handle', 'route_feed', 'feed_query']) === ['S6', 'GET /feed']);
check('a stack with no frame at all of a rule is unclassified and shared', fold_classify($rules, ['never_heard_of_it']) === ['unclassified', 'shared']);

// --- the rules ------------------------------------------------------------------------------------------------------------------
$r = fold_parse_rules("# a comment\n\nstep exact S1\nstep pre* S2\nstep prefix_longer* S3\nroute r GET /r\n");
check('an exact rule names one frame, a trailing * names a prefix', fold_step_of_frame($r, 'exact') === 'S1' && fold_step_of_frame($r, 'exactly') === null && fold_step_of_frame($r, 'prefix_x') === 'S2');
check('the longest prefix wins, an exact rule wins over a prefix', fold_step_of_frame($r, 'prefix_longer_still') === 'S3' && fold_step_of_frame(fold_parse_rules("step pre* S2\nstep prefix S4\n"), 'prefix') === 'S4');
foreach (['step onlytwo' => 'a rule with two words', "step f S42" => 'an unknown step', "step f unclassified" => 'unclassified as a rule target', 'stepp f S1' => 'an unknown kind'] as $bad => $why) {
    try {
        fold_parse_rules($bad);
        check("$why is refused", false, 'no exception');
    } catch (InvalidArgumentException $e) {
        check("$why is refused", str_contains($e->getMessage(), 'rules line 1'), $e->getMessage());
    }
}

// --- the table --------------------------------------------------------------------------------------------------------------------
$table = fold_table($rules, $counted);
$lines = explode("\n", substr($table, 0, strpos($table, 'samples:')));
check('the table has a row per step (S1 to S9, the event loop, unclassified) and an all row', count(array_filter($lines, static fn($l) => preg_match('/^(S[1-9] |event loop|unclassified|all)/', $l))) === 12);
check('the all row reads 100.0 %', (bool) preg_grep('/^all .*100\.0%$/', $lines));
check('S6 shows 36.5 % in all, GET /feed 25.0 %', (bool) preg_grep('/^S6 query SQLite .*25\.0%.* 36\.5%$/', $lines), $table);
check('without --us-per-req no cell gives microseconds', !preg_match('/\d ?us\b/', $table));
$withUs = fold_table($rules, $counted, 40.0);
check('with --us-per-req 40, GET /feed S6 adds 25 % of 40 us = 10.0 us and the table says how many it has', str_contains($withUs, '25.0% 10.0us') && str_contains($withUs, '40.0 us per request'));
check('the unclassified frames are named under the table', str_contains($table, 'unclassified: 5 samples (0.5%)') && str_contains($table, 'mysteryFrame (5)'));
check('the within-endpoint block: GET /feed is 71.4 % S6 (250 of its 350)', (bool) preg_grep('/^S6 query SQLite\s+-?\s*.*71\.4%/', explode("\n", substr($table, strpos($table, 'within each endpoint')))));

echo $failures === 0 ? "all ok\n" : "$failures failed\n";
exit($failures === 0 ? 0 : 1);
