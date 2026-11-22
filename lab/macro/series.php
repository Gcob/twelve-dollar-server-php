<?php
// Merges a run's readings into its per-second series (series_merge in series-lib.php): reads one JSON object on stdin,
// {"per_second": [...the aggregator's rows], "samples": [...the sampler's lines], "log": "<the server's log text>"}, and prints the rows
// as JSON. It runs in the probe container, which has PHP; the harness has no PHP of its own to count on.

require __DIR__ . '/series-lib.php';

$in = json_decode((string) stream_get_contents(STDIN), true);
if (!is_array($in) || !isset($in['per_second'], $in['samples'])) {
    fwrite(STDERR, "series: stdin must be a JSON object with per_second and samples\n");
    exit(1);
}
$rows = series_merge($in['per_second'], $in['samples'], telemetry_parse((string) ($in['log'] ?? '')));
foreach ($rows as &$row) {
    // Why: PHP writes an empty array as `[]`, and a second with no request has no endpoint: an object, for the readers of the JSON.
    $row['endpoints'] = (object) $row['endpoints'];
    if ($row['telemetry'] !== null) {
        $row['telemetry']['requests'] = (object) ($row['telemetry']['requests'] ?? []);
    }
}
unset($row);
echo json_encode($rows, JSON_UNESCAPED_SLASHES), "\n";
