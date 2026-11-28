#!/bin/sh
#-------------------------------------------------------------------------------
# File:         tools/fetch_corpus.sh
#
# Description:  Fetches Phil Harvey's "ExifTool Meta Information Repository"
#               (https://exiftool.org/sample_images.html) -- sample JPEGs with
#               the original metadata of several thousand camera models, one
#               <Make>.tar.gz per manufacturer, image data replaced, metadata
#               kept -- for `make test-corpus` (doc/cli-tests.md, "Corpus run").
#
#               Called by `make corpus-fetch`. The target directory is
#               gitignored (vendor/exiftool-samples/ by default); nothing of it
#               is ever committed.
#
#               Repeatable and incremental:
#                 * the archive list comes from the page's table itself, so a
#                   new manufacturer is picked up without editing this script;
#                   the table is kept as manifest.txt (TSV: archive, make,
#                   models, size, last updated);
#                 * an archive is downloaded only when it is missing or its
#                   "Last Updated" date or size in the table changed since the
#                   last download (archives/manifest.txt, the table as it was
#                   when the archives were fetched; without it: when the
#                   archive's mtime -- the server's, kept by curl -R -- is not
#                   that date);
#                 * an archive is unpacked into <dir>/<Make>/ only when that
#                   directory is missing or older than the archive.
#               Without network access an existing directory is reused: put the
#               archives into <dir>/archives/ by hand and run with --offline.
#
#               Portable sh: runs with GNU tools (Linux, Git Bash on Windows)
#               and BSD tools (macOS). It works inside <dir> with relative
#               paths only, so that a Windows path ("D:/...") never reaches
#               tar, which would take the colon for a remote host.
#
#               --manifest-only fetches the page alone and writes
#               manifest.txt, without downloading or unpacking any archive:
#               a cheap fingerprint of the corpus' current state (CI keys
#               its cache of <dir>/archives/ on it).
#
# Usage:        tools/fetch_corpus.sh [--offline | --manifest-only] [DIR]
#               DIR defaults to vendor/exiftool-samples in the repository.
#
# Layout:       <dir>/archives/<Make>.tar.gz   the downloads, untouched
#               <dir>/<Make>/<file>            unpacked (as in the archive)
#               <dir>/archives/manifest.txt    the table the archives match
#               <dir>/manifest.txt             the page's table, as TSV
#               <dir>/sample_images.html       the page itself
#               <dir>/README                   origin and usage note
#-------------------------------------------------------------------------------
set -eu

BASE_URL='https://exiftool.org'
PAGE="$BASE_URL/sample_images.html"

offline=
manifest_only=
case "${1:-}" in
    --offline)       offline=1; shift ;;
    --manifest-only) manifest_only=1; shift ;;
esac

repo=$(cd "$(dirname "$0")/.." && pwd)
dir=${1:-"$repo/vendor/exiftool-samples"}
mkdir -p "$dir/archives"
cd "$dir"

# The date (UTC, YYYY-MM-DD) of a file's mtime: GNU date -r FILE, else BSD
# stat; empty when neither works (the archive is then fetched again).
mtime_date() {
    date -u -r "$1" +%Y-%m-%d 2>/dev/null ||
        TZ=UTC stat -f %Sm -t %Y-%m-%d "$1" 2>/dev/null || true
}

cat > README <<README
ExifTool sample images -- NOT part of the lexiftool repository (gitignored)

Source:  $PAGE
         ("ExifTool Meta Information Repository" by Phil Harvey), one archive
         per manufacturer, fetched by tools/fetch_corpus.sh (make corpus-fetch).
Licence: the page states no licence. It says only that, "to conserve space and
         avoid copyright problems, the main image has been replaced, and the
         large preview image (and any other information found after the JPEG
         EOI) has been removed", while the APP segments are kept as they were.
         Used here solely as test input for make test-corpus; do not
         redistribute or commit.
Layout:  archives/<Make>.tar.gz, <Make>/<file>, manifest.txt (the page's table:
         archive, make, models, size, last updated), archives/manifest.txt
         (the table as it was when the archives were downloaded).
README

if [ -z "$offline" ]; then
    curl -fsSL -o sample_images.html.tmp "$PAGE"
    mv sample_images.html.tmp sample_images.html
    # One table row per make:
    #   <tr><td>&nbsp;Canon</td><td align='center'>727</td>
    #   <td align='right'>6.9 MB&nbsp;</td>
    #   <td>&nbsp;<a href='Canon.tar.gz'>Canon.tar.gz</a></td>
    #   <td align='center'>2025-12-17</td></tr>
    # (awk, not sed: BSD sed writes no newline or tab for \n and \t)
    tr -d '\r\n' < sample_images.html |
        awk '{
            n = split($0, rows, "<tr>")
            for (i = 2; i <= n; i++) {
                r = rows[i]
                if (index(r, ".tar.gz'"'"'") == 0) continue
                gsub(/&nbsp;/, "", r)
                gsub(/<\/td>/, "\t", r)
                gsub(/<[^>]*>/, "", r)
                c = split(r, f, "\t")
                if (c >= 5) print f[4] "\t" f[1] "\t" f[2] "\t" f[3] "\t" f[5]
            }
        }' |
        LC_ALL=C sort > manifest.txt.new
    n=$(wc -l < manifest.txt.new | tr -d ' ')
    [ "$n" -gt 0 ] || { echo "fetch_corpus: no archives found on $PAGE" >&2; exit 1; }
    echo "fetch_corpus: $n archives listed on $PAGE"
    if [ -n "$manifest_only" ]; then
        mv manifest.txt.new manifest.txt
        exit 0
    fi
    # the table the archives on disk were downloaded against (kept inside
    # archives/, so that it travels with them, e.g. through a CI cache)
    touch archives/manifest.txt
    fetched=0
    while IFS="$(printf '\t')" read -r a make models size updated; do
        f="archives/$a"
        if [ -s "$f" ]; then
            old=$(awk -F'\t' -v a="$a" '$1 == a { print $4 "\t" $5 }' archives/manifest.txt)
            if [ -n "$old" ]; then
                [ "$old" != "$(printf '%s\t%s' "$size" "$updated")" ] || continue
            else
                [ "$(mtime_date "$f")" != "$updated" ] || continue
            fi
        fi
        curl -fsSL -R -o "$f.part" "$BASE_URL/$a"
        mv "$f.part" "$f"
        # a fresh download is always unpacked anew (curl -R gives it the
        # server's mtime, which may well be older than the old directory)
        top=$(tar tzf "$f" | head -n 1 | cut -d/ -f1)
        [ -z "$top" ] || [ "$top" = archives ] || rm -rf "./$top"
        fetched=$((fetched + 1))
    done < manifest.txt.new
    cp manifest.txt.new archives/manifest.txt
    mv manifest.txt.new manifest.txt
    echo "fetch_corpus: $fetched archive(s) downloaded"
fi

# Unpack. An archive holds exactly one top-level directory (<Make>/); a stale
# one is removed first so files dropped upstream do not linger.
unpacked=0
for f in archives/*.tar.gz; do
    [ -e "$f" ] || continue
    top=$(tar tzf "$f" | head -n 1 | cut -d/ -f1)
    [ -n "$top" ] && [ "$top" != archives ] || continue
    if [ -d "$top" ] && [ ! "$f" -nt "$top" ]; then continue; fi
    rm -rf "./$top"
    tar xzf "$f"
    touch "$top"
    unpacked=$((unpacked + 1))
done
echo "fetch_corpus: $unpacked archive(s) unpacked"

# Totals over the manufacturer directories (du -k and find: no GNU-only
# options).
files=0
makes=0
kb=0
for d in */; do
    d=${d%/}
    [ -d "$d" ] && [ "$d" != archives ] || continue
    makes=$((makes + 1))
    files=$((files + $(find "$d" -type f | wc -l)))
    kb=$((kb + $(du -sk "$d" | cut -f1)))
done
echo "fetch_corpus: $files files in $makes manufacturer directories ($((kb / 1024)) MB) under $dir"
