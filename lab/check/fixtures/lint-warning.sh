#!/usr/bin/env bash
# Not part of the lab: one known warning (SC2046, an unquoted command substitution), so lab/check.sh can prove that its
# lint check is able to fail. It is excluded from the normal scan.
# SC2086 (an unquoted variable) would not do: shellcheck rates it "info", below the warning level the lab lints at.
echo $(date)
