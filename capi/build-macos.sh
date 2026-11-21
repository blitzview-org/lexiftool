#!/bin/sh
# capi/build-macos.sh VARIANT - builds and tests the C API on macOS
# (x86_64 and arm64).
#
#   embedded  everything inside the library, as in the standalone
#             executable. Built on Linux in the standalone builder
#             container (podman image lexiftool-builder-macos, `make
#             image-macos`; the script runs itself there), zig cc for
#             macOS 11 and later, from the image's archives of the same
#             kind (lib/x86_64, lib/aarch64): per architecture lexiftool.c
#             + the setup of standalone/main.c (lx_setup, -DLX_NO_MAIN) +
#             the embedded modules (standalone/genembed.lua, blob.c;
#             entries compressed as in the standalone build: COMPRESS,
#             default zstd) + sys.c, and every member of the Lua, PCRE2,
#             zlib, brotli, zstd, liblzma, libbz2 and Lua C module
#             archives; in all of them every global symbol but
#             lexiftool_* is marked private external (capi/macho_hide.lua:
#             Mach-O has no objcopy to localize symbols, as on Linux), and
#             a relocatable link (zig cc -r) into one object turns those
#             into local ones: only lexiftool_* stays global.
#             The two architectures are joined with llvm-lipo. Output in
#             capi/build/macos/:
#               include/lexiftool.h
#               lib/liblexiftool.a            universal, that object
#               lib/liblexiftool.API.dylib    universal, shared, install
#                                             name @rpath/liblexiftool.API.dylib
#                                             (API = LEXIFTOOL_API_VERSION),
#                                             exports lexiftool_* only
#               lib/liblexiftool.dylib        -> liblexiftool.API.dylib
#               lib/pkgconfig/lexiftool.pc    (prefix relative to itself)
#               bin/                          example, test_capi,
#                                             test_threads, test_sideeffects,
#                                             universal, each linked against
#                                             the static archive (NAME) and
#                                             the shared library (NAME-so,
#                                             rpath @loader_path/../lib)
#             The programs run on a Mac only ("test", CI).
#   rock      on a Mac: the library only (lexiftool.c), Lua modules and C
#             modules loaded from package.path / package.cpath at run
#             time; host cc (CC, default cc) against the Lua 5.5 that
#             luarocks is configured for (LUA_INCDIR and LUA_LIBDIR of
#             `luarocks config`, or CAPI_LUA_INCDIR / CAPI_LUA_LIB: the
#             include directory and the library file). A static liblua is
#             linked whole (-force_load), so that the C modules, loaded as
#             bundles, find the complete Lua API in the program. Output in
#             capi/build/rock-macos/: example, test_capi, test_threads,
#             test_sideeffects.
#   test      on a Mac: test_capi, test_threads and test_sideeffects of
#             every build there is (rock: the modules found as by the
#             launcher, or through LUA_PATH_5_5/LUA_CPATH_5_5 when set;
#             embedded: static and shared), test_hostlibs when pkg-config
#             knows a Lua and zlib of the host (CAPI_HOST_PC, default "lua
#             zlib"), and lexiftool_image_info against Perl's
#             Image::ExifTool (capi/compare-perl.sh; CAPI_PERL names the
#             perl, default perl).
#
# Run from anywhere; paths are taken from the script's location.

set -eu

VARIANT="${1:?usage: build-macos.sh embedded|rock|test}"
CAPI="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$CAPI/.." && pwd)"
OUT="$CAPI/build"
mkdir -p "$OUT"
echo '*' > "$OUT/.gitignore"

# shared with build-linux.sh: the version, session.lua as a C array
. "$CAPI/common.sh"

case "$VARIANT" in
embedded)
    obj="$OUT/macos"
    if [ ! -d /opt/lx ]; then
        exec podman run --rm -e COMPRESS="${COMPRESS:-}" \
            -e LEXIFTOOL_PORT_VERSION="$(portversion)" \
            -v "$PROJECT:/project" lexiftool-builder-macos \
            sh /project/capi/build-macos.sh embedded
    fi
    # --- in the builder container ---
    LX=/opt/lx
    SA="$PROJECT/standalone"
    rm -rf "$obj"; mkdir -p "$obj/include" "$obj/lib/pkgconfig" "$obj/bin"
    CFLAGS="-O2 -Wall -ffunction-sections -fdata-sections"
    ARCHIVES="luamods brotli zstd pcre2-8 z lzma bz2 lua55"
    API=$(apiversion)
    EXPORTS=$(exports)
    : "${LEXIFTOOL_PORT_VERSION:?LEXIFTOOL_PORT_VERSION must be set (passed in by the host part above)}"
    COMPRESS="${COMPRESS:-zstd}"
    case "$COMPRESS" in
        zstd) CODEC=zstd; TOOL="$LX/bin/zstd" ;;
        *)    CODEC=none; TOOL="" ;;
    esac
    status=0
    set -x
    for ARCH in x86_64 aarch64; do
        o="$obj/obj-$ARCH"
        mkdir -p "$o/members"
        CC="zig cc -target $ARCH-macos-none -mmacosx-version-min=11.0"
        "$LX/bin/lua55" "$SA/genembed.lua" "$o" "$PROJECT" 0 "$CODEC" "$TOOL" "$LEXIFTOOL_PORT_VERSION"
        genheader "$LX/bin/lua55" "$o/session_lua.h"
        $CC $CFLAGS -I"$LX/include" -I"$o" -I"$CAPI" -DLEXIFTOOL_CAPI_EMBEDDED \
            -DLEXIFTOOL_PORT_VERSION="\"$LEXIFTOOL_PORT_VERSION\"" \
            -c "$CAPI/lexiftool.c" -o "$o/lexiftool.o"
        $CC $CFLAGS -I"$LX/include" -I"$SA" -I"$o" -DLX_NO_MAIN -c "$SA/main.c" -o "$o/setup.o"
        $CC $CFLAGS -I"$SA" -c "$o/embedded_index.c" -o "$o/embedded_index.o"
        (cd "$o" && $CC $CFLAGS -I"$SA" -c "$SA/blob.c" -o "$o/blob.o")
        $CC $CFLAGS -I"$LX/include" -DLEXIFTOOL_LUA_VERSION_NUM=505 \
            -c "$PROJECT/src/lexiftool/sys.c" -o "$o/sys.o"
        # every archive member (a relocatable link searches no archives),
        # each archive in a directory of its own (member names repeat)
        members=""
        set +x
        for a in $ARCHIVES; do
            mkdir -p "$o/members/$a"
            (cd "$o/members/$a" && llvm-ar-14 x "$LX/lib/$ARCH/lib$a.a")
            members="$members $(ls "$o/members/$a"/*.o)"
        done
        set -x
        # only lexiftool_* global, then one relocatable object in which
        # the private external symbols become local
        # shellcheck disable=SC2086
        "$LX/bin/lua55" "$CAPI/macho_hide.lua" "$o/lexiftool.o" "$o/setup.o" "$o/embedded_index.o" \
            "$o/blob.o" "$o/sys.o" $members
        # shellcheck disable=SC2086
        $CC -r -o "$o/liblexiftool.o" "$o/lexiftool.o" "$o/setup.o" "$o/embedded_index.o" \
            "$o/blob.o" "$o/sys.o" $members
        rm -f "$o/liblexiftool.a"
        llvm-ar-14 rcs "$o/liblexiftool.a" "$o/liblexiftool.o"
        # shared library from the same object (unreferenced code dropped;
        # arm64: signed ad hoc by the linker, as macOS requires there)
        $CC -dynamiclib -s -Wl,-dead_strip -Wl,-install_name,@rpath/liblexiftool.$API.dylib \
            -Wl,-compatibility_version,$API.0.0 -Wl,-current_version,$API.0.0 \
            "$o/liblexiftool.o" -o "$o/liblexiftool.$API.dylib"
        if [ $ARCH = aarch64 ] && ! llvm-objdump-14 --macho --private-headers "$o/liblexiftool.$API.dylib" |
                grep -q LC_CODE_SIGNATURE; then
            echo "embedded: arm64 dylib not signed" >&2; status=1
        fi
        # checks: only lexiftool_* global/exported
        llvm-nm-14 -g --defined-only "$o/liblexiftool.o" | awk 'NF == 3 { print $3 }' > "$o/global.txt"
        # (the linker's own ___dso_handle and __mh_dylib_header aside)
        llvm-nm-14 -g --defined-only "$o/liblexiftool.$API.dylib" | awk 'NF == 3 { print $3 }' |
            grep -v -x -e ___dso_handle -e __mh_dylib_header > "$o/exported.txt"
        for f in global exported; do
            if grep -v '^_lexiftool_' "$o/$f.txt"; then
                echo "embedded: $ARCH: $f symbols beyond lexiftool_* (above)" >&2; status=1
            fi
            for e in $EXPORTS; do
                grep -qx "_$e" "$o/$f.txt" || { echo "embedded: $ARCH: $e not $f" >&2; status=1; }
            done
        done
        # only libSystem
        llvm-objdump-14 --macho --dylibs-used "$o/liblexiftool.$API.dylib" | tail -n +2 | tee "$o/dylibs.txt"
        if grep -v '/usr/lib/libSystem' "$o/dylibs.txt" | grep -v "@rpath/liblexiftool.$API.dylib"; then
            echo "embedded: $ARCH: unexpected shared library" >&2; status=1
        fi
        # the programs: against the static archive and the shared library
        for p in example test_capi test_threads test_sideeffects; do
            $CC -O2 -Wall -I"$CAPI" -DLEXIFTOOL_TEST_EMBEDDED "$CAPI/$p.c" "$o/liblexiftool.a" \
                -o "$o/$p"
            $CC -O2 -Wall -I"$CAPI" -DLEXIFTOOL_TEST_EMBEDDED "$CAPI/$p.c" "$o/liblexiftool.$API.dylib" \
                -Wl,-rpath,@loader_path/../lib -o "$o/$p-so"
        done
    done
    # universal files
    llvm-lipo-14 -create "$obj/obj-x86_64/liblexiftool.a" "$obj/obj-aarch64/liblexiftool.a" \
        -output "$obj/lib/liblexiftool.a"
    llvm-lipo-14 -create "$obj/obj-x86_64/liblexiftool.$API.dylib" "$obj/obj-aarch64/liblexiftool.$API.dylib" \
        -output "$obj/lib/liblexiftool.$API.dylib"
    ln -sf "liblexiftool.$API.dylib" "$obj/lib/liblexiftool.dylib"
    for p in example test_capi test_threads test_sideeffects; do
        for s in "" -so; do
            llvm-lipo-14 -create "$obj/obj-x86_64/$p$s" "$obj/obj-aarch64/$p$s" -output "$obj/bin/$p$s"
        done
    done
    cp "$CAPI/lexiftool.h" "$obj/include/lexiftool.h"
    set +x
    pkgconfig "$obj/lib/pkgconfig/lexiftool.pc" "" ""
    llvm-lipo-14 -info "$obj/lib/liblexiftool.a" "$obj/lib/liblexiftool.$API.dylib"
    rm -rf "$obj"/obj-*/members
    ls -l "$obj/lib" "$obj/bin"
    exit $status
    ;;

rock)
    obj="$OUT/rock-macos"
    rm -rf "$obj"; mkdir -p "$obj"
    CC=${CC:-cc}
    LUA=${CAPI_LUA:-$(command -v lua5.5 || command -v lua)}
    incdir=${CAPI_LUA_INCDIR:-$(luarocks config variables.LUA_INCDIR)}
    lib=${CAPI_LUA_LIB:-}
    if [ -z "$lib" ]; then
        libdir=$(luarocks config variables.LUA_LIBDIR)
        lib=$(ls "$libdir"/liblua5.5.dylib "$libdir"/liblua.5.5.dylib "$libdir"/liblua.dylib \
                 "$libdir"/liblua5.5.a "$libdir"/liblua.a 2>/dev/null | head -1)
    fi
    [ -n "$lib" ] || { echo "rock: no Lua library found (CAPI_LUA_LIB)" >&2; exit 1; }
    case "$lib" in
        *.a) lualib="-Wl,-force_load,$lib" ;;
        *)   lualib="$lib" ;;
    esac
    set -x
    genheader "$LUA" "$obj/session_lua.h"
    $CC -O2 -g -Wall -Wextra -I"$incdir" -I"$obj" -DLEXIFTOOL_PORT_VERSION="\"$(portversion)\"" \
        -c "$CAPI/lexiftool.c" -o "$obj/lexiftool.o"
    for p in example test_capi test_threads test_sideeffects; do
        $CC -O2 -g -Wall -Wextra -I"$CAPI" "$CAPI/$p.c" "$obj/lexiftool.o" $lualib -o "$obj/$p"
    done
    set +x
    ls -l "$obj"
    ;;

test)
    T="$PROJECT/vendor/exiftool/t/images"
    tmp="$OUT/test-macos"; rm -rf "$tmp"; mkdir -p "$tmp"
    cd "$PROJECT"
    [ -n "${LUA_PATH_5_5:-}" ] || rock_paths
    status=0
    examples=""
    for b in "rock rock-macos" "embedded macos/bin" "shared macos/bin -so"; do
        set -- $b
        dir="$OUT/$2" sfx="${3:-}"
        [ -x "$dir/test_capi$sfx" ] || { echo "$1: not built"; continue; }
        examples="$examples $1=$dir/example$sfx"
        for p in test_capi test_threads test_sideeffects; do
            args=""
            [ $p = test_threads ] && args="${CAPI_THREADS:-8} 2"
            rm -rf "$tmp/$1-$p"; mkdir -p "$tmp/$1-$p"
            # shellcheck disable=SC2086
            if "$dir/$p$sfx" "$T" "$tmp/$1-$p" $args > "$tmp/$1-$p.txt" 2>&1; then
                echo "$1: $p $(grep -c '^ok' "$tmp/$1-$p.txt") ok"
            else
                grep -E '^not ok|^#' "$tmp/$1-$p.txt" | sed "s/^/$1: /"
                echo "$1: $p FAILED, see $tmp/$1-$p.txt"; status=1
            fi
        done
    done
    # test_hostlibs: built here, against the host's Lua and zlib
    if [ -f "$OUT/macos/lib/liblexiftool.a" ] && pkg-config --exists ${CAPI_HOST_PC:-lua zlib} 2>/dev/null; then
        hostlibs=$(pkg-config --cflags --libs ${CAPI_HOST_PC:-lua zlib})
        lib="$OUT/macos/lib"
        set -x
        # shellcheck disable=SC2086
        ${CC:-cc} -O2 -Wall -I"$OUT/macos/include" "$CAPI/test_hostlibs.c" "$lib/liblexiftool.a" \
            $hostlibs -o "$tmp/test_hostlibs"
        # shellcheck disable=SC2086
        ${CC:-cc} -O2 -Wall -I"$OUT/macos/include" "$CAPI/test_hostlibs.c" -L"$lib" -llexiftool \
            -Wl,-rpath,"$lib" $hostlibs -o "$tmp/test_hostlibs-so"
        set +x
        for p in test_hostlibs test_hostlibs-so; do
            mkdir -p "$tmp/$p"
            if "$tmp/$p" "$T" "$tmp/$p" > "$tmp/$p.txt" 2>&1; then
                echo "embedded: $p $(grep -c '^ok' "$tmp/$p.txt") ok"
            else
                grep -E '^not ok' "$tmp/$p.txt"; echo "embedded: $p FAILED, see $tmp/$p.txt"; status=1
            fi
        done
    elif [ -f "$OUT/macos/lib/liblexiftool.a" ]; then
        echo "embedded: test_hostlibs skipped (pkg-config knows no ${CAPI_HOST_PC:-lua zlib})"
    fi
    if [ -n "$examples" ]; then
        # shellcheck disable=SC2086
        sh "$CAPI/compare-perl.sh" "$tmp" $examples || status=1
    fi
    exit $status
    ;;

*)
    echo "build-macos.sh: unknown variant '$VARIANT'" >&2; exit 1 ;;
esac
