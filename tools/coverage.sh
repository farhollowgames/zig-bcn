#!/bin/sh
# Runs the instrumented differential tests, reports coverage of the original
# sources and checks it against tools/coverage-required.txt. Called by
# `zig build coverage`; see build.zig.
#   coverage.sh <test-exe> <reference.so> <rules> <out-dir> <source>...
set -eu
exe=$1 shared=$2 rules=$3 out=$4
shift 4
mkdir -p "$out"
LLVM_PROFILE_FILE="$out/differential.profraw" "$exe"
llvm-profdata merge -sparse "$out/differential.profraw" -o "$out/differential.profdata"
llvm-cov report -show-branch-summary -show-region-summary=false \
    "$shared" -instr-profile="$out/differential.profdata" "$@" | tee "$out/report.txt"
llvm-cov report -show-functions -show-branch-summary -show-region-summary=false \
    "$shared" -instr-profile="$out/differential.profdata" "$@" > "$out/functions.txt"
# Per-line counts with branch counts, one file per source, for finding what
# the tests miss: uncovered lines show a count of 0 and missed branch
# directions show ": 0]".
llvm-cov show -show-branches=count -show-line-counts -format=text \
    -output-dir="$out/show" "$shared" -instr-profile="$out/differential.profdata" "$@"

awk '
    # The rules file comes first.
    NR == FNR {
        if ($0 ~ /^[ \t]*(#|$)/) next
        key = $1 "|" $2
        rule[key] = (NF == 2) ? "0 0" : (NF == 3 ? $3 : $3 " " $4)
        if ($2 == "*") wildcard[$1] = 1
        next
    }
    /^File / {
        file = $2
        gsub(/^'\''|'\'':$/, "", file)
        sub(/.*\/reference\//, "", file)
        next
    }
    # Function rows: name, then regions, missed, cover, lines, missed, cover,
    # branches, missed, cover.
    NF == 10 && $10 ~ /%$/ && $1 != "Name" && $1 != "TOTAL" {
        key = file "|" $1
        seen[key] = 1
        if (key in rule) want = rule[key]
        else if (file in wildcard) want = "0 0"
        else next
        if (want == "skip") next
        got = $6 " " $9
        if (got != want) {
            printf "coverage: %s %s: missed lines and branches %s, want %s\n", file, $1, got, want
            bad = 1
        }
    }
    END {
        for (key in rule) {
            split(key, part, "|")
            if (part[2] != "*" && !(key in seen)) {
                printf "coverage: no function %s in %s\n", part[2], part[1]
                bad = 1
            }
        }
        if (bad) exit 1
        print "coverage: every required function is covered as declared"
    }
' "$rules" "$out/functions.txt"
