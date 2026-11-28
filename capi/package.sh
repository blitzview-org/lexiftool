#!/bin/sh
# capi/package.sh PLATFORM - the release zip of the embedded C API
# (linux | macos | windows), from the output of `build-PLATFORM.sh
# embedded` (make capi-linux / capi-macos / capi-windows), packed in the
# builder container of that platform (the script runs itself there: the
# license texts are the image's /opt/lx/licenses, the very files the
# standalone zip carries, and zip is the one standalone/build.sh uses).
#
# Output in capi/build/dist/:
#   lexiftool-capi-PLATFORM-VERSION.zip, holding one folder of the same
#   name (without .zip); VERSION as in the standalone zip (standalone/
#   build.sh): the bare tag on an exact, clean release, the identity
#   otherwise -- the identity the library was built with
#   (capi/build/DIR/identity.txt), so name and content always agree.
#   The folder:
#     README.txt                     what is where, how to link
#     LICENSE, LICENSE-THIRD-PARTY   this repository
#     licenses/                      the license texts of the built-in
#                                    components (standalone/check-licenses.sh)
#     doc/capi.md                    the API (doc/capi.md)
#     example.c                      capi/example.c
#     include/lexiftool.h
#     linux:   lib/liblexiftool.a, lib/liblexiftool.so.API,
#              lib/liblexiftool.so -> liblexiftool.so.API,
#              lib/pkgconfig/lexiftool.pc
#     macos:   lib/liblexiftool.a, lib/liblexiftool.API.dylib,
#              lib/liblexiftool.dylib -> liblexiftool.API.dylib,
#              lib/pkgconfig/lexiftool.pc (universal: x86_64 and arm64)
#     windows: bin/lexiftool.dll, lib/lexiftool.lib (MSVC),
#              lib/liblexiftool.dll.a (MinGW, the DLL),
#              lib/liblexiftool.a (MinGW, static), lib/lexiftool.def,
#              lib/pkgconfig/lexiftool.pc
#   API = LEXIFTOOL_API_VERSION. The unversioned names (for -llexiftool)
#   are symbolic links, stored as such (zip --symlinks): the unpackers of
#   Linux and macOS (Info-ZIP unzip, bsdtar/libarchive, 7-Zip, the Archive
#   Utility) restore them, and a copy instead would add the whole shared
#   library to the download a second time (7 MB zipped on Linux). Should
#   an unpacker leave a small text file instead, README.txt says how to
#   make the link.
#   The library files are the very files of capi/build/DIR/ (compared
#   after packing), which the CI tests.
#
# Reproducible: SOURCE_DATE_EPOCH (default: the last commit's time) sets
# the entries' times; modes fixed, entries sorted, no extra fields -- as
# standalone/build.sh.

set -eu

PLATFORM="${1:?usage: package.sh linux|macos|windows}"
CAPI="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$CAPI/.." && pwd)"
OUT="$CAPI/build"

. "$CAPI/common.sh"

case "$PLATFORM" in
    linux)   DIR=embedded ;;
    macos)   DIR=macos ;;
    windows) DIR=windows ;;
    *) echo "package.sh: unknown platform '$PLATFORM'" >&2; exit 1 ;;
esac
src="$OUT/$DIR"
[ -f "$src/identity.txt" ] || {
    echo "package.sh: $src/identity.txt missing (build-$PLATFORM.sh embedded first)" >&2; exit 1; }

if [ ! -d /opt/lx ]; then
    exec podman run --rm -e SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(sourcedate)}" \
        -v "$PROJECT:/project" "lexiftool-builder-$PLATFORM" \
        sh /project/capi/package.sh "$PLATFORM"
fi
# --- in the builder container ---
: "${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH must be set (passed in by the host part above)}"
API=$(apiversion)
identity=$(cat "$src/identity.txt")
zipname="lexiftool-capi-$PLATFORM-$(zipversion "$identity").zip"
folder=${zipname%.zip}
dist="$OUT/dist"
stage="$OUT/stage-$PLATFORM"
rm -rf "$stage" "$dist/lexiftool-capi-$PLATFORM-"*.zip
mkdir -p "$stage/$folder/licenses" "$stage/$folder/doc" "$stage/$folder/include" \
    "$stage/$folder/lib/pkgconfig" "$dist"
f="$stage/$folder"

# the libraries: the files of the build ("SOURCE [NAME]" relative to src
# and to the folder)
case "$PLATFORM" in
linux)
    libs="lib/liblexiftool.a lib/liblexiftool.so.$API lib/pkgconfig/lexiftool.pc"
    devlink="lib/liblexiftool.so.$API lib/liblexiftool.so" ;;
macos)
    libs="lib/liblexiftool.a lib/liblexiftool.$API.dylib lib/pkgconfig/lexiftool.pc"
    devlink="lib/liblexiftool.$API.dylib lib/liblexiftool.dylib" ;;
windows)
    mkdir -p "$f/bin"
    libs="bin/lexiftool.dll lib/lexiftool.lib lib/liblexiftool.dll.a lib/liblexiftool.a lib/lexiftool.def lib/pkgconfig/lexiftool.pc"
    devlink="" ;;
esac
for l in $libs; do
    [ -f "$src/$l" ] || { echo "package.sh: $src/$l missing" >&2; exit 1; }
    cp "$src/$l" "$f/$l"
done
# shellcheck disable=SC2086
[ -z "$devlink" ] || { set -- $devlink; ln -s "$(basename "$1")" "$f/$2"; }
cp "$src/include/lexiftool.h" "$f/include/"
cp "$CAPI/example.c" "$f/"
cp "$PROJECT/doc/capi.md" "$f/doc/"
cp "$PROJECT/LICENSE" "$PROJECT/LICENSE-THIRD-PARTY" "$f/"
cp /opt/lx/licenses/* "$f/licenses/"

# README.txt
{
    echo "lexiftool C API, $identity"
    echo
    echo "lexiftool (a Lua port of ExifTool) as an in-process library for C and"
    echo "C++ programs: Lua 5.5, the lexiftool modules and every library they"
    echo "need are inside; the API is include/lexiftool.h, described in"
    echo "doc/capi.md (LEXIFTOOL_API_VERSION $API). example.c is a complete"
    echo "program (reads the tags of files and prints them)."
    echo
    case "$PLATFORM" in
    linux)
        echo "Linux x86-64, glibc 2.17 or newer; the library needs libc, libm and"
        echo "libpthread only."
        echo
        echo "  lib/liblexiftool.so.$API   shared (soname liblexiftool.so.$API); exports"
        echo "                          lexiftool_* only"
        echo "  lib/liblexiftool.so     -> liblexiftool.so.$API, for -llexiftool (should"
        echo "                          the unpacker have made it a small text file:"
        echo "                          ln -sf liblexiftool.so.$API lib/liblexiftool.so)"
        echo "  lib/liblexiftool.a      static"
        echo "  lib/pkgconfig/lexiftool.pc  finds its own directory"
        echo
        echo "  cc -Iinclude example.c -Llib -llexiftool -Wl,-rpath,\"\$PWD/lib\" -o example"
        echo "  cc -Iinclude example.c lib/liblexiftool.a -lm -lpthread -o example"
        echo "  PKG_CONFIG_PATH=\$PWD/lib/pkgconfig pkg-config --cflags --libs lexiftool"
        ;;
    macos)
        echo "macOS 11 or newer, universal (x86_64 and arm64); the library needs"
        echo "libSystem only. Not signed beyond the linker's ad-hoc signature:"
        echo "a downloaded copy may need xattr -dr com.apple.quarantine on this folder."
        echo
        echo "  lib/liblexiftool.$API.dylib  shared, install name"
        echo "                          @rpath/liblexiftool.$API.dylib; exports"
        echo "                          lexiftool_* only"
        echo "  lib/liblexiftool.dylib  -> liblexiftool.$API.dylib, for -llexiftool"
        echo "                          (should the unpacker have made it a small"
        echo "                          text file: ln -sf liblexiftool.$API.dylib"
        echo "                          lib/liblexiftool.dylib)"
        echo "  lib/liblexiftool.a      static"
        echo "  lib/pkgconfig/lexiftool.pc  finds its own directory"
        echo
        echo "  cc -Iinclude example.c -Llib -llexiftool -Wl,-rpath,\"\$PWD/lib\" -o example"
        echo "  cc -Iinclude example.c lib/liblexiftool.a -o example"
        ;;
    windows)
        echo "Windows x64; the DLL needs KERNEL32.dll and msvcrt.dll only."
        echo
        echo "  bin/lexiftool.dll       shared; exports lexiftool_* only; goes next"
        echo "                          to the program"
        echo "  lib/lexiftool.lib       its import library for MSVC"
        echo "  lib/liblexiftool.dll.a  its import library for MinGW (-llexiftool.dll)"
        echo "  lib/liblexiftool.a      static, MinGW only (define LEXIFTOOL_STATIC)"
        echo "  lib/lexiftool.def       the exports"
        echo "  lib/pkgconfig/lexiftool.pc  finds its own directory"
        echo
        echo "  cl -Iinclude example.c lib\\lexiftool.lib     (then copy bin\\lexiftool.dll)"
        echo "  gcc -Iinclude example.c -Llib -llexiftool.dll -o example.exe"
        echo "  gcc -Iinclude -DLEXIFTOOL_STATIC example.c lib/liblexiftool.a -static -o example.exe"
        ;;
    esac
    echo
    echo "Licenses: LICENSE (lexiftool, Image::ExifTool), LICENSE-THIRD-PARTY"
    echo "(every built-in component) and licenses/ (their license texts)."
} > "$f/README.txt"

sh "$PROJECT/standalone/check-licenses.sh" "$f"
# the packed libraries are the built ones
for l in $libs; do cmp "$src/$l" "$f/$l"; done

# what the packed files need and export, in the log (the build scripts
# check the same on the build's files): any surprise fails
status=0
bad() { echo "package.sh: $*" >&2; status=1; }
case "$PLATFORM" in
linux)
    so="$f/lib/liblexiftool.so.$API"
    readelf -d "$so" | grep -E 'NEEDED|SONAME'
    readelf -d "$so" | grep NEEDED | grep -vE '\[(libc\.so\.6|libm\.so\.6|libpthread\.so\.0)\]' &&
        bad "unexpected shared library"
    echo "symbol versions: $(objdump -T "$so" | grep -oE 'GLIBC_[0-9.]+' | sort -uV | tr '\n' ' ')"
    objdump -T "$so" | grep -E 'GLIBC_2\.(1[89]|[2-9][0-9])' && bad "symbol newer than GLIBC_2.17"
    nm -D --defined-only "$so" | awk '{ print $3 }' > "$stage/exported.txt"
    nm -g --defined-only "$f/lib/liblexiftool.a" | awk 'NF == 3 { print $3 }' > "$stage/global.txt"
    pre=""
    ;;
macos)
    dylib="$f/lib/liblexiftool.$API.dylib"
    llvm-lipo-14 -info "$f/lib/liblexiftool.a" "$dylib"
    for a in x86_64 arm64; do
        llvm-lipo-14 "$dylib" -verify_arch $a || bad "$a slice missing (dylib)"
        llvm-lipo-14 "$f/lib/liblexiftool.a" -verify_arch $a || bad "$a slice missing (archive)"
        llvm-objdump-14 --macho --arch=$a --dylibs-used "$dylib" | sed "s/^/$a: /"
        llvm-objdump-14 --macho --arch=$a --dylibs-used "$dylib" | tail -n +2 |
            grep -v -e /usr/lib/libSystem -e "@rpath/liblexiftool.$API.dylib" && bad "$a: unexpected library"
        minos=$(llvm-objdump-14 --macho --arch=$a --private-headers "$dylib" |
                awk '/LC_BUILD_VERSION/ { b = 1 } b && $1 == "minos" { print $2; exit }')
        echo "$a: minos $minos"
        [ "$minos" = 11.0 ] || bad "$a: minos $minos, not 11.0"
    done
    llvm-nm-14 --arch=x86_64 -g --defined-only "$dylib" | awk 'NF == 3 { print $3 }' |
        grep -v -x -e ___dso_handle -e __mh_dylib_header > "$stage/exported.txt"
    llvm-nm-14 --arch=arm64 -g --defined-only "$f/lib/liblexiftool.a" | awk 'NF == 3 { print $3 }' \
        > "$stage/global.txt"
    pre=_
    ;;
windows)
    T=x86_64-w64-mingw32
    $T-objdump -p "$f/bin/lexiftool.dll" | grep 'DLL Name'
    $T-objdump -p "$f/bin/lexiftool.dll" | grep 'DLL Name' | grep -viE 'DLL Name: (KERNEL32|msvcrt)\.dll' &&
        bad "unexpected DLL import"
    $T-objdump -p "$f/bin/lexiftool.dll" |
        awk '/^\[Ordinal\/Name Pointer\] Table/ { t = 1; next } t && NF == 0 { t = 0 } t { print $NF }' \
        > "$stage/exported.txt"
    $T-nm -g --defined-only "$f/lib/liblexiftool.a" | awk 'NF == 3 && $3 !~ /^lxint_/ { print $3 }' \
        > "$stage/global.txt"
    pre=""
    ;;
esac
for t in exported global; do
    grep -v "^${pre}lexiftool_" "$stage/$t.txt" && bad "$t symbols beyond lexiftool_* (above)"
    for e in $(exports); do grep -qx "$pre$e" "$stage/$t.txt" || bad "$e not $t"; done
done
echo "exported: $(sort -u "$stage/exported.txt" | wc -l) functions, lexiftool_* only"
rm -f "$stage/exported.txt" "$stage/global.txt"
[ $status = 0 ] || exit 1
# deterministic: fixed modes and times, sorted entries, no extra fields
find "$stage" -type d -exec chmod 755 {} +
find "$stage" -type f -exec chmod 644 {} +
case "$PLATFORM" in
    linux)   chmod 755 "$f/lib/liblexiftool.so.$API" ;;
    macos)   chmod 755 "$f/lib/liblexiftool.$API.dylib" ;;
    windows) chmod 755 "$f/bin/lexiftool.dll" ;;
esac
find "$stage" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
(cd "$stage" && find "$folder" \( -type f -o -type l \) | LC_ALL=C sort |
    TZ=UTC zip -X -D -y -9 -q "$dist/$zipname" -@)
rm -rf "$stage"
ls -l "$dist/$zipname"
sha256sum "$dist/$zipname"
echo "==> $dist/$zipname"
