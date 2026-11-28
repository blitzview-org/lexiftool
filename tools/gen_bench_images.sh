#!/usr/bin/env bash
#-------------------------------------------------------------------------------
# File:         tools/gen_bench_images.sh
#
# Description:  Builds the benchmark's camera JPEGs (bench/images/, the
#               session-jpeg case of tools/bench_cli.sh, doc/benchmark.md):
#               one ordinary camera or phone JPEG per maker, with the
#               metadata of one of ExifTool's test images and a small
#               synthetic picture. The files are committed; this script
#               documents how they were made and rebuilds them.
#
#               Inputs: the vendored ExifTool's test images
#               (vendor/exiftool/t/images, the SOURCES below), the vendored
#               Perl exiftool (perl -Ivendor/exiftool/lib
#               vendor/exiftool/exiftool), ImageMagick 7 (`magick`).
#
#               Per file, in a temporary directory:
#                 1. the picture: a plain two-colour gradient, no noise,
#                    1000x750, 4:2:0, quality 90, no metadata of its own
#                      magick -size 1000x750 gradient:#2f5f8f-#d8b878 \
#                        -sampling-factor 2x2 -strip -quality 90 base.jpg
#                    (small on purpose: a 4000x3000 picture of 6.7 MB with
#                    the same metadata reads no slower in either tool)
#                 2. all metadata of the source, maker notes included, in
#                    place of the picture's own; -unsafe adds the tags -all
#                    leaves out (InteropIFD, CompressedBitsPerPixel, ...)
#                      exiftool -o OUT -all= -TagsFromFile SRC -all:all \
#                        -unsafe base.jpg
#                 3. a 160x120 thumbnail (IFD1) and, where the maker notes
#                    of the source have a writable preview (Nikon
#                    PreviewIFD, Olympus, Pentax), a 640x480 preview; both
#                    are the same gradient at quality 85
#                      exiftool -overwrite_original \
#                        -ThumbnailImage<=thumb.jpg -PreviewImage<=preview.jpg OUT
#                    (exiftool writes PreviewImage only where the maker
#                    notes have it and leaves the others unchanged)
#
#               The source images carry placeholder thumbnails and previews
#               of a few bytes, which -all:all does not copy (image data);
#               step 3 replaces them. What else does not survive the copy is
#               listed in bench/images/README.md. The output is the same
#               for the same ImageMagick and exiftool versions (the JPEG
#               encoder decides the picture bytes).
#
# Syntax:       tools/gen_bench_images.sh [OUTDIR]
#                 OUTDIR  default bench/images
#               Run from the repository root.
#-------------------------------------------------------------------------------
set -eu

OUT=${1:-bench/images}
IMAGES=vendor/exiftool/t/images
EXIFTOOL=(perl -Ivendor/exiftool/lib vendor/exiftool/exiftool)
# one source per maker: the camera and phone JPEGs of t/images with the most
# complete maker notes
SOURCES="Canon1DmkIII NikonD70 Sony OlympusE1 Panasonic FujiFilm Pentax Apple"

command -v magick >/dev/null || { echo "gen_bench_images.sh: ImageMagick 7 (magick) not found" >&2; exit 1; }
[ -f "$IMAGES/Canon1DmkIII.jpg" ] || { echo "gen_bench_images.sh: no $IMAGES (vendor/exiftool checkout)" >&2; exit 1; }
mkdir -p "$OUT"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

gradient() {   # gradient SIZE QUALITY FILE
    magick -size "$1" 'gradient:#2f5f8f-#d8b878' -sampling-factor 2x2 -strip -quality "$2" "$3"
}
gradient 1000x750 90 "$WORK/base.jpg"
gradient 160x120 85 "$WORK/thumb.jpg"
gradient 640x480 85 "$WORK/preview.jpg"

for src in $SOURCES; do
    out=$OUT/bench_$src.jpg
    rm -f "$out"
    "${EXIFTOOL[@]}" -q -o "$out" -all= -TagsFromFile "$IMAGES/$src.jpg" -all:all -unsafe "$WORK/base.jpg"
    "${EXIFTOOL[@]}" -q -overwrite_original '-ThumbnailImage<='"$WORK/thumb.jpg" \
        '-PreviewImage<='"$WORK/preview.jpg" "$out"
    echo "$out ($(wc -c < "$out") bytes)"
done
