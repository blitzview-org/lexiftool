#!/usr/bin/env bash
#-------------------------------------------------------------------------------
# File:         tools/bench_cli.sh
#
# Description:  Performance comparison of two exiftool command lines -- the
#               Perl original and lexiftool -- on the same machine, in the
#               same run, over a small set of everyday cases
#               (doc/benchmark.md). Both tools are timed by hyperfine in one
#               invocation per case, directly after each other, so the ratio
#               between them is meaningful even on a shared machine whose
#               absolute times vary.
#
#               Cases (files from vendor/exiftool/t/images, copied to a
#               temporary directory): start-up (-ver); a mix of six file
#               types (JPEG Canon and Nikon, DNG, QuickTime, PDF, XMP), each
#               read as one process per call and as a -stay_open session of
#               SESSION commands on the same file, plus the empty session;
#               a write, likewise as single calls and as a session; one
#               process over the whole image directory. The
#               report takes a session's time per command as the
#               processing of that file type and the rest of a single call
#               as start-up (-ver) plus the loading of the format modules.
#
#               Per case and tool hyperfine records wall-clock mean, min,
#               standard deviation and user/system CPU time (--export-json);
#               one extra run per case and tool under GNU time measures the
#               peak resident set size (skipped, with a note, when
#               /usr/bin/time is not GNU time). tools/bench_report.lua then
#               writes OUTDIR/README.md (Markdown table), benchmark.svg and
#               benchmark-dark.svg (bar charts) and results.json.
#
# Syntax:       tools/bench_cli.sh OUTDIR PERL_CMD LEXIFTOOL_CMD [RUNS]
#                 OUTDIR         results directory (created)
#                 PERL_CMD       the Perl exiftool command line, one string, e.g.
#                                'perl -Ivendor/exiftool/lib vendor/exiftool/exiftool'
#                 LEXIFTOOL_CMD  the lexiftool command line, e.g. dist-linux/lexiftool
#                 RUNS           timed runs per case and tool (default 20)
#               Environment: BENCH_IMAGES (default vendor/exiftool/t/images),
#               BENCH_LUA (the Lua for the report, default: lua5.5, lua5.4 or
#               lua, whichever is found), BENCH_WARMUP (default 2),
#               BENCH_SESSION (commands per -stay_open session, default 30).
#               Sessions and the directory run RUNS/4 times (at least 3).
#               Needs hyperfine and jq; GNU time for the memory column.
#               Run from the repository root (the Makefile's `bench` target
#               does).
#-------------------------------------------------------------------------------
set -eu

usage() { echo "usage: tools/bench_cli.sh OUTDIR PERL_CMD LEXIFTOOL_CMD [RUNS]" >&2; exit 2; }
[ $# -ge 3 ] && [ $# -le 4 ] || usage
OUT=$1 PERL_CMD=$2 LUA_CMD=$3 RUNS=${4:-20}
IMAGES=${BENCH_IMAGES:-vendor/exiftool/t/images}
WARMUP=${BENCH_WARMUP:-2}
SESSION=${BENCH_SESSION:-30}
HERE=$(cd "$(dirname "$0")" && pwd)

for tool in hyperfine jq; do
    command -v "$tool" >/dev/null || { echo "bench_cli.sh: $tool not found" >&2; exit 1; }
done
LUA=${BENCH_LUA:-$(command -v lua5.5 || command -v lua5.4 || command -v lua || true)}
[ -n "$LUA" ] || { echo "bench_cli.sh: no Lua interpreter for the report (BENCH_LUA)" >&2; exit 1; }
[ -d "$IMAGES" ] || { echo "bench_cli.sh: no image directory $IMAGES (BENCH_IMAGES)" >&2; exit 1; }
# GNU time: BusyBox/bash builtins have no -f %M
TIME=
if [ -x /usr/bin/time ] && /usr/bin/time -f %M true >/dev/null 2>&1; then TIME=/usr/bin/time; fi

IMAGES=$(cd "$IMAGES" && pwd)
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
rm -f "$OUT"/*.json "$OUT"/*.tsv
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# the files the cases use, copied once; the write case works on a fresh copy
# per run (hyperfine --prepare)
for f in Canon.jpg Nikon.jpg DNG.dng QuickTime.mov PDF.pdf XMP.jpg; do
    [ -f "$IMAGES/$f" ] || { echo "bench_cli.sh: $IMAGES/$f missing" >&2; exit 1; }
    cp "$IMAGES/$f" "$WORK/$f"
done
# the mix: one read case per file type, each as single calls and as a
# -stay_open session of SESSION commands on the same file (the session's
# time per command is the processing alone; what a single call costs on top
# of start-up and processing is the loading of the format modules)
MIX='canon Canon.jpg|nikon Nikon.jpg|dng DNG.dng|mov QuickTime.mov|pdf PDF.pdf|xmp XMP.jpg'
printf -- '-stay_open\nFalse\n' > "$WORK/empty.args"
# the write session alternates two values, so that every command rewrites
# the file (an unchanged value leaves it untouched)
{ i=0; while [ $i -lt "$SESSION" ]; do
      printf -- '-overwrite_original\n-Artist=Benchmark%d\n%s\n-execute\n' $((i % 2 + 1)) "$WORK/write.jpg"; i=$((i + 1)); done
  printf -- '-stay_open\nFalse\n'; } > "$WORK/session-write.args"
echo "$MIX" | tr '|' '\n' | while read -r key file; do
    { i=0; while [ $i -lt "$SESSION" ]; do printf -- '-j\n-G1\n%s\n-execute\n' "$WORK/$file"; i=$((i + 1)); done
      printf -- '-stay_open\nFalse\n'; } > "$WORK/session-$key.args"
done

# name | description | arguments (@W@ = the work directory, @I@ = the image directory)
# read-* and session-* pair up by file type; the long cases (sessions, the
# directory) run RUNS_LONG times instead of RUNS
CASES="
start|start-up only|-ver
read-canon|JPEG with maker notes (Canon)|-j -G1 @W@/Canon.jpg
read-nikon|JPEG with maker notes (Nikon)|-j -G1 @W@/Nikon.jpg
read-dng|DNG|-j -G1 @W@/DNG.dng
read-mov|QuickTime MOV|-j -G1 @W@/QuickTime.mov
read-pdf|PDF|-j -G1 @W@/PDF.pdf
read-xmp|JPEG with XMP|-j -G1 @W@/XMP.jpg
write-jpeg|write a tag into a JPEG copy|-overwrite_original -Artist=Benchmark @W@/write.jpg
dir-read|all test images, one process|-j -G1 -q -r @I@
session-canon|session of @S@ commands, Canon.jpg|-stay_open True -@ @W@/session-canon.args
session-nikon|session of @S@ commands, Nikon.jpg|-stay_open True -@ @W@/session-nikon.args
session-dng|session of @S@ commands, DNG.dng|-stay_open True -@ @W@/session-dng.args
session-mov|session of @S@ commands, QuickTime.mov|-stay_open True -@ @W@/session-mov.args
session-pdf|session of @S@ commands, PDF.pdf|-stay_open True -@ @W@/session-pdf.args
session-xmp|session of @S@ commands, XMP.jpg|-stay_open True -@ @W@/session-xmp.args
session-write|session of @S@ writes, JPEG copy|-stay_open True -@ @W@/session-write.args
session-empty|empty session|-stay_open True -@ @W@/empty.args
"
RUNS_LONG=$(( RUNS / 4 )); [ "$RUNS_LONG" -ge 3 ] || RUNS_LONG=3

: > "$OUT/cases.def.tsv"
: > "$OUT/rss.tsv"
echo "$CASES" | while IFS='|' read -r name desc raw; do
    [ -n "$name" ] || continue
    args=${raw//@W@/$WORK}; args=${args//@I@/$IMAGES}
    shown=${raw//@W@\//}; shown=${shown//@I@/IMAGES}
    desc=${desc//@S@/$SESSION}
    printf '%s\t%s\t%s\n' "$name" "$desc" "$shown" >> "$OUT/cases.def.tsv"
    echo "== $name: $args"
    extra=(); runs=$RUNS
    case $name in
        write-jpeg)    extra=(--prepare "cp $WORK/Canon.jpg $WORK/write.jpg") ;;
        session-write) extra=(--prepare "cp $WORK/Canon.jpg $WORK/write.jpg"); runs=$RUNS_LONG ;;
        dir-read)      extra=(--ignore-failure); runs=$RUNS_LONG ;;   # exit status 1 when a file could not be read
        session-*)     runs=$RUNS_LONG ;;
    esac
    # -N: no shell in between, the commands are started directly; both tools
    # in one hyperfine call, so they run on the same machine state
    hyperfine -N --warmup "$WARMUP" --runs "$runs" "${extra[@]}" \
        --command-name exiftool --command-name lexiftool \
        --export-json "$OUT/$name.json" \
        "$PERL_CMD $args" "$LUA_CMD $args" >/dev/null
    # peak RSS, one run per tool (deterministic enough), GNU time
    if [ -n "$TIME" ]; then
        for tool in exiftool lexiftool; do
            case $tool in exiftool) cmd=$PERL_CMD ;; *) cmd=$LUA_CMD ;; esac
            case $name in write-jpeg|session-write) cp "$WORK/Canon.jpg" "$WORK/write.jpg" ;; esac
            # shellcheck disable=SC2086
            $TIME -f %M -o "$WORK/rss.txt" $cmd $args >/dev/null 2>&1 || true
            printf '%s\t%s\t%s\n' "$name" "$tool" "$(tail -1 "$WORK/rss.txt")" >> "$OUT/rss.tsv"
        done
    fi
done

# the measurements as one TSV: case, tool, mean, min, stddev, user, system (seconds)
: > "$OUT/cases.tsv"
for f in "$OUT"/*.json; do
    name=$(basename "$f" .json)
    jq -r --arg c "$name" '.results[] | [$c, .command, .mean, .min, .stddev, .user, .system] | @tsv' "$f" >> "$OUT/cases.tsv"
done

# metadata
exiftool_ver=$($PERL_CMD -ver 2>/dev/null | head -1)
lexiftool_ver=$($LUA_CMD -ver -v 2>/dev/null | sed -n 's/^lexiftool port \([^,]*\),.*/\1/p')
identity=$(git -C "$HERE/.." describe --tags --always --long --dirty --match 'v*' 2>/dev/null || echo unknown)
cpu=$(sed -n 's/^model name\s*: //p' /proc/cpuinfo 2>/dev/null | head -1)
os=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")
{
    printf 'date\t%s\n' "$(date -u +%Y-%m-%d)"
    printf 'identity\t%s\n' "$identity"
    printf 'exiftool_version\t%s\n' "$exiftool_ver"
    printf 'lexiftool_version\t%s\n' "${lexiftool_ver:-$identity}"
    printf 'perl_version\t%s\n' "$(perl -e 'print $^V')"
    printf 'cpu\t%s\n' "${cpu:-unknown}"
    printf 'os\t%s\n' "${os:-unknown}"
    printf 'runs\t%s\n' "$RUNS"
    printf 'warmup\t%s\n' "$WARMUP"
    printf 'session\t%s\n' "$SESSION"
    printf 'images\t%s\n' "$(find "$IMAGES" -maxdepth 1 -type f | wc -l)"
    printf 'hyperfine\t%s\n' "$(hyperfine --version)"
    printf 'rss\t%s\n' "${TIME:+GNU time}"
} > "$OUT/meta.tsv"

"$LUA" "$HERE/bench_report.lua" "$OUT"
echo "bench_cli.sh: results in $OUT (README.md, benchmark.svg, benchmark-dark.svg, results.json)"
