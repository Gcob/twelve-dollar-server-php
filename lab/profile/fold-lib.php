<?php
// Folds a profile (the collapsed stacks Excimer writes, see lab/servers/diy-profile.php) into the steps of a request, with the rules
// of lab/profile/steps.rules. Used by lab/profile/fold.php; lab/check/fold-test.php tests it on a fixture.

const FOLD_STEPS = [
    'S1' => 'S1 accept connections',
    'S2' => 'S2 read and parse',
    'S3' => 'S3 route',
    'S4' => 'S4 verify the JWT',
    'S5' => 'S5 validate the input',
    'S6' => 'S6 query SQLite',
    'S7' => 'S7 build the JSON',
    'S8' => 'S8 write the response',
    'S9' => 'S9 durability',
    'loop' => 'event loop',
    'unclassified' => 'unclassified',
];
const FOLD_SHARED = 'shared';

/**
 * @return array{steps: array<string, string>, prefixes: array<string, string>, routes: array<string, string>} the `step` rules by exact
 *         frame name and by prefix (the name without its *), the `route` rules by frame name
 * @throws InvalidArgumentException a line that is not a rule, an unknown step
 */
function fold_parse_rules(string $text): array
{
    $rules = ['steps' => [], 'prefixes' => [], 'routes' => []];
    foreach (explode("\n", $text) as $number => $line) {
        $line = trim($line);
        if ($line === '' || $line[0] === '#') {
            continue;
        }
        $parts = preg_split('/\s+/', $line, 3);
        $kind = $parts[0];
        $where = 'rules line ' . ($number + 1) . ": $line";
        if (count($parts) < 3 || !in_array($kind, ['step', 'route'], true)) {
            throw new InvalidArgumentException("$where: expected `step <frame> <step>` or `route <frame> <endpoint>`");
        }
        [, $frame, $value] = $parts;
        if ($kind === 'route') {
            $rules['routes'][$frame] = $value;
            continue;
        }
        if (!isset(FOLD_STEPS[$value]) || $value === 'unclassified') {
            throw new InvalidArgumentException("$where: unknown step '$value'");
        }
        if (str_ends_with($frame, '*')) {
            $rules['prefixes'][substr($frame, 0, -1)] = $value;
        } else {
            $rules['steps'][$frame] = $value;
        }
    }
    return $rules;
}

/** The step of a frame, or null when no rule names it (an exact rule wins over a prefix, the longest prefix over a shorter). */
function fold_step_of_frame(array $rules, string $frame): ?string
{
    if (isset($rules['steps'][$frame])) {
        return $rules['steps'][$frame];
    }
    $best = null;
    $bestLength = -1;
    foreach ($rules['prefixes'] as $prefix => $step) {
        if (str_starts_with($frame, $prefix) && strlen($prefix) > $bestLength) {
            $best = $step;
            $bestLength = strlen($prefix);
        }
    }
    return $best;
}

/**
 * The step and the endpoint of one stack (frames from the outermost to the innermost). The step is the LEAF frame's: a leaf no rule
 * names is unclassified, whatever its callers are. Excimer never shows an internal function as a frame, so the leaf is always a PHP
 * function of ours, and a renamed or new one must show up as unclassified instead of adding its cost to its caller's step.
 *
 * @param list<string> $frames
 * @return array{string, string} the step key (a key of FOLD_STEPS) and the endpoint name (FOLD_SHARED when no route function is on the stack)
 */
function fold_classify(array $rules, array $frames): array
{
    $step = fold_step_of_frame($rules, $frames[count($frames) - 1]) ?? 'unclassified';
    $endpoint = FOLD_SHARED;
    foreach ($frames as $frame) {
        if (isset($rules['routes'][$frame])) {
            $endpoint = $rules['routes'][$frame];
            break;
        }
    }
    return [$step, $endpoint];
}

/**
 * Counts the samples of a collapsed profile per step and endpoint.
 *
 * @return array{samples: int, cells: array<string, array<string, int>>, unknown: array<string, int>} cells[step][endpoint]; unknown: the
 *         leaf frame of each unclassified stack, with its samples
 */
function fold_count(array $rules, string $collapsed): array
{
    $cells = [];
    $unknown = [];
    $samples = 0;
    foreach (explode("\n", $collapsed) as $line) {
        $space = strrpos($line, ' ');
        if ($space === false || $line === '') {
            continue;
        }
        $count = (int) substr($line, $space + 1);
        $frames = explode(';', substr($line, 0, $space));
        [$step, $endpoint] = fold_classify($rules, $frames);
        $cells[$step][$endpoint] = ($cells[$step][$endpoint] ?? 0) + $count;
        $samples += $count;
        if ($step === 'unclassified') {
            $leaf = $frames[count($frames) - 1];
            $unknown[$leaf] = ($unknown[$leaf] ?? 0) + $count;
        }
    }
    arsort($unknown);
    return ['samples' => $samples, 'cells' => $cells, 'unknown' => $unknown];
}

/** The endpoint columns, in the order the rules name them (the ones with no sample still get a column), then shared. */
function fold_columns(array $rules): array
{
    return array_merge(array_values(array_unique($rules['routes'])), [FOLD_SHARED]);
}

/**
 * The table, as text. Every cell is a share of ALL the samples (so the whole table sums to 100 %, and a column's total is its weight);
 * with $usPerRequest, each cell also gives the microseconds it adds to the average request (its share of $usPerRequest). A second block
 * gives, for each endpoint column, the shares of that endpoint's own samples.
 *
 * @param array{samples: int, cells: array<string, array<string, int>>, unknown: array<string, int>} $counted
 */
function fold_table(array $rules, array $counted, ?float $usPerRequest = null): string
{
    $columns = fold_columns($rules);
    $total = max(1, $counted['samples']);
    $cell = static function (int $n, int $of) use ($usPerRequest, $total): string {
        $share = $n / max(1, $of) * 100;
        $text = sprintf('%.1f%%', $share);
        return $usPerRequest === null ? $text : sprintf('%s %.1fus', $text, $n / $total * $usPerRequest);
    };
    $rows = [];
    $columnTotals = array_fill_keys($columns, 0);
    foreach (FOLD_STEPS as $key => $label) {
        $row = [$label];
        $rowTotal = 0;
        foreach ($columns as $column) {
            $n = $counted['cells'][$key][$column] ?? 0;
            $columnTotals[$column] += $n;
            $rowTotal += $n;
            $row[] = $cell($n, $total);
        }
        $row[] = $cell($rowTotal, $total);
        $rows[] = $row;
    }
    $rows[] = array_merge(['all'], array_map(static fn(string $c): string => $cell($columnTotals[$c], $total), $columns), [$cell($counted['samples'], $total)]);

    $header = array_merge(['step'], $columns, ['all']);
    $out = fold_format([$header, ...$rows]);
    $out .= sprintf("samples: %d%s\n", $counted['samples'], $usPerRequest === null ? '' : sprintf(', %.1f us per request on average', $usPerRequest));
    $out .= "each cell: share of all samples" . ($usPerRequest === null ? '' : ' and the microseconds it adds to the average request') . "; S9 is inside S6 (autocommit)\n\n";

    $out .= "within each endpoint (share of that column's own samples):\n";
    $within = [];
    foreach (FOLD_STEPS as $key => $label) {
        $row = [$label];
        foreach ($columns as $column) {
            $row[] = $columnTotals[$column] === 0 ? '-' : sprintf('%.1f%%', ($counted['cells'][$key][$column] ?? 0) / $columnTotals[$column] * 100);
        }
        $within[] = $row;
    }
    $within[] = array_merge(['weight in all samples'], array_map(static fn(string $c): string => sprintf('%.1f%%', $columnTotals[$c] / $total * 100), $columns));
    $out .= fold_format([array_merge(['step'], $columns), ...$within]);

    $unclassified = array_sum($counted['cells']['unclassified'] ?? []);
    if ($unclassified > 0) {
        $out .= sprintf("\nunclassified: %d samples (%.1f%%), leaf frames:", $unclassified, $unclassified / $total * 100);
        foreach (array_slice($counted['unknown'], 0, 5, true) as $frame => $n) {
            $out .= " $frame ($n)";
        }
        $out .= "\n";
    }
    return $out;
}

/** @param list<list<string>> $rows the first column left-aligned, the others right-aligned */
function fold_format(array $rows): string
{
    $widths = [];
    foreach ($rows as $row) {
        foreach ($row as $i => $text) {
            $widths[$i] = max($widths[$i] ?? 0, strlen($text));
        }
    }
    $out = '';
    foreach ($rows as $row) {
        $cells = [];
        foreach ($row as $i => $text) {
            $cells[] = $i === 0 ? str_pad($text, $widths[$i]) : str_pad($text, $widths[$i], ' ', STR_PAD_LEFT);
        }
        $out .= rtrim(implode('  ', $cells)) . "\n";
    }
    return $out;
}
