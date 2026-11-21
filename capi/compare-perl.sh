#!/bin/sh
# capi/compare-perl.sh TMPDIR NAME=EXAMPLE... - lexiftool_image_info against
# Perl's Image::ExifTool, for the test variants of build-linux.sh,
# build-macos.sh and build-windows.sh.
#
# 1. capi/example of every build given (NAME=path of its example program,
#    NAME a shell identifier) and capi/info_dump.pl (the same calls through
#    the Perl library) print the same dump; one run per case over all of
#    t/images. CAPI_RUNNER, if set, runs the programs (wine).
#    Struct=1 leaves out the Geotag files: their structure order follows
#    Perl's hash order, which changes from run to run, and XISF.xisf, whose
#    result in Perl changes with what earlier calls in the same process
#    have loaded (the first ImageInfo differs from a second one of the same
#    file).
#    A case marked "dstgap" runs only against Perl 5.42.1 or later: its
#    zone's spring-forward gap meets dates in t/images, and lexiftool's
#    strftime normalizes such a time as that Perl does, where older ones
#    (and 5.42.0's isdst default, Perl GH #22351) differ
#    (doc/differences.md); the DST-free zone case runs everywhere.
# 2. the order and groups of lexiftool_image_info with Sort=Group0:1:2:4 ==
#    the keys of exiftool -php -l -G:0:1:2:4 -D (the command an exiftool
#    C++ client sends), file by file.
#
# The text tools run under LC_ALL=C: the keys may hold bytes that are not
# UTF-8, which BSD sed rejects under a UTF-8 locale.
#
# CAPI_PERL names the perl (default perl); it needs the optional modules
# of a full exiftool installation, as the CLI golden test's reference does
# (doc/cli-tests.md). Run from the repository root. Exit status 1 if
# anything differs.

set -eu

tmp=$1; shift
EXAMPLES="$*"
T=vendor/exiftool/t/images
PERL="${CAPI_PERL:-perl}"
status=0

# run NAME=PATH ARGS... (through CAPI_RUNNER, e.g. wine, when set)
run() {
    e=${1#*=}; shift
    # shellcheck disable=SC2086
    ${CAPI_RUNNER:-} "$e" "$@"
}

# a Perl whose ** is off in the last digits (the pow of the C library it
# is built with): XMP's ApertureValue (sqrt(2) ** $val) is left out of
# the comparison there (doc/differences.md, "Bugs of the Perl interpreter")
skip='^FileAccessDate	'
if [ "$("$PERL" -e 'print sqrt(2) ** 6')" != 8 ]; then
    echo "image_info vs Perl: XMP ApertureValue left out (this Perl's ** is inexact:" \
         "sqrt(2) ** 6 = $("$PERL" -e 'print sqrt(2) ** 6'))"
    skip="$skip|^ApertureValue	XMP	"
fi

# same A B: the two dumps agree but for FileAccessDate, which every read
# may move on (when, depends on the platform's atime policy), and the
# lines left out above
same() {
    LC_ALL=C grep -E -v "$skip" "$1" > "$1.cmp"
    LC_ALL=C grep -E -v "$skip" "$2" > "$2.cmp"
    cmp -s "$1.cmp" "$2.cmp"
}

all=$(ls "$T"/*)
nostruct=$(ls "$T"/* | grep -v -e '/Geotag\.' -e '/XISF\.xisf$')
newstrftime=$("$PERL" -e 'print $] >= 5.042001 ? 1 : 0')
n=0; bad=0
while IFS='|' read -r opts files; do
    [ -n "$opts$files" ] || continue
    n=$((n + 1))
    case "$files" in
        dstgap)   if [ "$newstrftime" = 0 ]; then
                      echo "image_info vs Perl: $opts skipped (Perl $("$PERL" -e 'print $^V')" \
                           "keeps a time in the DST gap, doc/differences.md)"
                      continue
                  fi
                  set -- $all ;;
        all)      set -- $all ;;
        nostruct) set -- $nostruct ;;
        *)        set -- "$T/$files" ;;
    esac
    # shellcheck disable=SC2086
    "$PERL" capi/info_dump.pl $opts "$@" < /dev/null > "$tmp/info-$n.perl" 2>&1
    for e in $EXAMPLES; do
        name=${e%%=*}
        # shellcheck disable=SC2086
        run "$e" $opts "$@" < /dev/null > "$tmp/info-$n.$name" 2>&1
        if same "$tmp/info-$n.perl" "$tmp/info-$n.$name"; then
            echo "$name: image_info == Perl: ${opts:-(defaults)} [$files]"
        else
            echo "$name: image_info DIFFERS from Perl: ${opts:-(defaults)} [$files]," \
                 "diff $tmp/info-$n.perl $tmp/info-$n.$name"; bad=1
        fi
    done
done <<'CASES'
|all
-b|all
-o Duplicates=0|all
-o PrintConv=0|all
-o Sort=Group0:1:2:4|all
-o Unknown=1 -o ListSep=;|all
-o Lang=de|all
-o TimeZone=America/New_York -o DateFormat=%Y-%m-%dT%H:%M:%S%z|dstgap
-o TimeZone=IST-5:30 -o DateFormat=%Y-%m-%dT%H:%M:%S%z|all
-t ThumbnailImage -t PreviewImage -t Make -t EXIF:* -t Make|all
-t all -t -EXIF:all|all
-t Composite:all -t Model#|all
-o Struct=1|nostruct
CASES
[ $bad = 0 ] || status=1

for e in $EXAMPLES; do eval "same_${e%%=*}=0 diffs_${e%%=*}=0"; done
for f in $all; do
    "$PERL" vendor/exiftool/exiftool -php -l -G:0:1:2:4 -D -sep ", " "$f" 2>/dev/null |
        LC_ALL=C sed -n 's/^  "\([^"]*\)" => .*/\1/p' | LC_ALL=C grep -v '^SourceFile$' > "$tmp/php.keys" || true
    for e in $EXAMPLES; do
        name=${e%%=*}
        run "$e" -o Sort=Group0:1:2:4 "$f" |
            LC_ALL=C awk -F'\t' 'NF > 5 { print $2 ":" $3 ":" $4 ":" ($7 > 0 ? "Copy" $7 : "") ":" $1 }' \
            > "$tmp/info.keys"
        if cmp -s "$tmp/php.keys" "$tmp/info.keys"; then eval "same_$name=\$((same_$name + 1))"
        else eval "diffs_$name=\$((diffs_$name + 1))"; echo "  $name: -php keys differ: $f"; fi
    done
done
for e in $EXAMPLES; do
    name=${e%%=*}
    eval "same=\$same_$name diffs=\$diffs_$name"
    echo "$name: image_info order/groups == exiftool -php -G:0:1:2:4: $same files, $diffs differ"
    [ "$diffs" = 0 ] || status=1
done
exit $status
