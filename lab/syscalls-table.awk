# Reads the table of `strace -c` into `<syscall> <calls> <errors>` lines, the total last, and drops the time columns (strace slows the
# server, so its times mean nothing; only counts are kept). A syscall that never failed has no errors column: the table then has 5 fields
# instead of 6, and the syscall is always the last one.
#   awk -f lab/syscalls-table.awk <strace -c output file>
/^-+ -+ / { rule++; next }
rule == 1 && NF == 6 { print $6, $4, $5 }
rule == 1 && NF == 5 { print $5, $4, 0 }
rule == 2 && NF == 6 && $6 == "total" { print "total", $4, $5 }
rule == 2 && NF == 5 && $5 == "total" { print "total", $4, 0 }
