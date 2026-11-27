#!/usr/bin/env perl
# Does submissions/php-Gcob/ring.php still equal the lab's ring minus its hooks?
#
#   perl lab/check/ring-sync.pl <lab ring-server.php> <lab ring-server.h> <submission ring.php>
#
# It derives what the submission's ring must be from the lab's file, by the rules the copy followed, and compares. Both sides are read
# without their comments and without any whitespace, so a reformatting or a reworded comment is not a difference; any other is.
# The rules, each of which must still apply to the lab's file (else the lab's ring moved where the copy cut something, and this says so):
#   - the statistics (the counters, counters(), slotsInUse(), statsLine(), run()'s telemetry argument and its stats line) are out;
#   - the test hooks (URING_FAIL_STEP and the `fail_step` option) and the environment knobs (URING_*, ring_env_int()) are out,
#     the three pool sizes being constants (RING_RECV_BUFFERS, RING_SEND_SLOTS, RING_MAX_TABLE) of the lab's defaults;
#   - RingLoop::count() and AppRing's $tableFull (written, never read) are out;
#   - ring_open_or_exit() is out (the submission falls back instead of exiting);
#   - the C declarations are the constant RING_CDEF, equal to ring-server.h, instead of a read of that file;
#   - the messages say `server`, not `ring-server`.
# What it does not look at: everything before `final class RingRefused` (the guards of the lab's file against ring_unavailable(), the
# constants, the declarations' own comments), the comments themselves, and whatever follows a ` // ` on a line of code.
# Prints one line per difference and exits 1, or exits 0 when the submission's ring is the derived one.
use strict;
use warnings;

my ($labFile, $headerFile, $subFile) = @ARGV;
die "usage: ring-sync.pl <ring-server.php> <ring-server.h> <ring.php>\n" unless defined $subFile;

sub slurp { my $f = shift; open my $h, '<', $f or die "cannot read $f: $!\n"; local $/; return scalar <$h>; }
sub no_comments {
    my $t = shift;
    $t =~ s{/\*.*?\*/}{}gs;
    $t =~ s{(?:^|(?<=\s))//[^\n]*}{}gm;
    return $t;
}
sub squash { my $t = shift; $t =~ s/\s+//g; return $t; }
sub plain { return squash(no_comments(shift)); }

my @problems;
my $lab = slurp($labFile);
my $sub = slurp($subFile);

foreach my $name (qw(counters slotsInUse count statsLine)) {
    $lab =~ s/\n( {4})(?:public |private )function $name\(.*?\n\1\}\n/\n/s or push @problems, "rule: the lab has no method $name() to cut";
}
foreach my $name (qw(ring_env_int ring_open_or_exit)) {
    $lab =~ s/\nfunction $name\(.*?\n\}\n/\n/s or push @problems, "rule: the lab has no function $name() to cut";
}
my $counters = 'turns|flushes|cqes|requests|accepted|acceptPauses|shortSends|bigSends|sendWaits|recvDry|stalls|limitCloses|provides|provideErrors';
$lab =~ s/^[ \t]*(?:public|private)(?: readonly)? \??\w+ \$(?:$counters|failStep|tableFull|last)\b[^;\n]*;\n//mg;

(my $labTail = $lab) =~ s/\A.*?(?=final class RingRefused)//s or push @problems, "the lab's file has no `final class RingRefused`";
(my $subTail = $sub) =~ s/\A.*?(?=final class RingRefused)//s or push @problems, "the submission's file has no `final class RingRefused`";
$labTail = plain($labTail);
$subTail = plain($subTail);

sub rule {
    my ($name, $from, $to) = @_;
    my ($f, $t) = (squash($from), squash($to));
    $labTail =~ s/\Q$f\E/$t/g or push @problems, "rule: $name no longer applies to the lab's file";
}
sub rule_re {
    my ($name, $re, $to) = @_;
    $labTail =~ s/$re/$to/g or push @problems, "rule: $name no longer applies to the lab's file";
}

# The knobs and the way the pool sizes reach AppRing come first: later rules read what they leave.
rule_re('the environment knobs', qr/\$recvBuffers=ring_env_int\(.*?\$ffi=FFI::cdef\(file_get_contents\(__DIR__\.'\/ring-server\.h'\),'libc\.so\.6'\);/,
    squash(q{$ffi = FFI::cdef(RING_CDEF, 'libc.so.6');}));
rule('the first ring chooses', q~$totals = new RingTotals(); $rings = []; try {~, q~$totals = new RingTotals(); $rings = []; $buffers = 'auto'; try {~);
rule('the pool constants', q{['recv_buffers' => $recvBuffers, 'send_slots' => $sendSlots, 'table_size' => $tableSize, 'soft_limit' => $softLimit,
    'buffers' => $buffers, 'previous' => $rings[$i - 1] ?? null, 'fail_step' => $i === $count - 1 || $failStep === 'buffer_ring_all' ? $failStep : null]},
    q{['recv_buffers' => RING_RECV_BUFFERS, 'send_slots' => RING_SEND_SLOTS, 'table_size' => RING_MAX_TABLE, 'soft_limit' => $softLimit,
    'buffers' => $buffers, 'previous' => $rings[$i - 1] ?? null]});
# The hooks.
rule_re('the fail_step option', qr/\$this->failStep=\$options\['fail_step'\]\?\?null;/, '');
rule_re('the failing steps', qr/\$this->failStep==='\w+'(?:\|\|\$this->failStep==='\w+')*\?0:/, '');
rule('the provide count', q{$count = $this->recvBuffers; $this->prep(self::OP_PROVIDE_BUFFERS, 0, 0, $count,}, q{$this->prep(self::OP_PROVIDE_BUFFERS, 0, 0, $this->recvBuffers,});
# The statistics.
rule_re('the counters', qr/\$this->(?:$counters)(?:\+\+|\+=[^;]*);/, '');
rule_re('$tableFull', qr/\$this->tableFull=(?:true|false);/, '');
rule_re('$tableFull test', qr/if\(!\$this->tableFull\)\{\}/, '');
rule('run() argument', q{public function run(bool $telemetry): never}, q{public function run(): never});
rule('run() clock', q{$next = time() + 1; $count = 0;}, '');
rule('run() got', q{$got = $activeGot =}, q{$activeGot =});
rule('run() got true', q{$got = true;}, '');
rule('run() stats line', q{if ($telemetry && (!$got || (++$count & 63) === 0) && time() >= $next) { $next = time() + 1;
    if (($line = $this->statsLine()) !== null) { echo $line, "\n"; } }}, '');
rule('ring_serve() argument', q{string $host, int $port, bool $telemetry, ?Closure}, q{string $host, int $port, ?Closure});
rule('ring_serve() run', q{$loop->run($telemetry);}, q{$loop->run();});
rule_re('the messages', qr/ring-server(?=[\[:])/, 'server');

if ($labTail ne $subTail) {
    my $i = 0;
    $i++ while $i < length($labTail) && $i < length($subTail) && substr($labTail, $i, 1) eq substr($subTail, $i, 1);
    my $from = $i > 60 ? $i - 60 : 0;
    push @problems, 'the submission\'s ring is not the lab\'s ring minus its hooks: from "' . substr($subTail, $from, 140) . '" the derived one reads "' . substr($labTail, $from, 140) . '"';
}

# The C declarations: the lab's header and the constant.
my ($cdef) = $sub =~ /const RING_CDEF = <<<'C'\n(.*?)\nC;/s;
if (!defined $cdef) {
    push @problems, 'the submission has no RING_CDEF';
} elsif (plain(slurp($headerFile)) ne plain($cdef)) {
    push @problems, 'RING_CDEF is not the lab\'s ring-server.h';
}

# The pool sizes: the constants are the knobs' defaults.
my %want = (RING_RECV_BUFFERS => qr/ring_env_int\('URING_RECV_BUFFERS', (\d+),/, RING_SEND_SLOTS => qr/ring_env_int\('URING_SEND_SLOTS', (\d+),/,
    RING_MAX_TABLE => qr/ring_env_int\('URING_TABLE_SIZE', (\d+),/);
foreach my $const (sort keys %want) {
    my ($default) = slurp($labFile) =~ $want{$const};
    my ($value) = $sub =~ /^const $const = (\d+);/m;
    push @problems, "the lab's default for $const is not readable" unless defined $default;
    push @problems, "$const is " . ($value // 'missing') . ", the lab's default is " . ($default // '?') if defined $default && (!defined $value || $value ne $default);
}

print "$_\n" for @problems;
exit(@problems ? 1 : 0);
