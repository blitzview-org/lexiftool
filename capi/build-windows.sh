#!/bin/sh
# capi/build-windows.sh VARIANT - builds and tests the C API on Windows
# (x86-64). The variants that run on Windows expect Git Bash (or another
# POSIX shell) with the compiler in the environment.
#
#   embedded  everything inside the library, as in the standalone
#             executable. Built on Linux in the standalone builder
#             container (podman image lexiftool-builder-windows, `make
#             image-windows`; the script runs itself there), mingw-w64,
#             from the image's archives (lib/x86_64): lexiftool.c + the
#             setup of standalone/main.c (lx_setup, -DLX_NO_MAIN) + the
#             embedded modules (standalone/genembed.lua, blob.c; entries
#             compressed as in the standalone build: COMPRESS, default
#             zstd) + sys.c + Lua 5.5, PCRE2, zlib, brotli, zstd (decoder),
#             liblzma, libbz2 and the Lua C modules; in all of these
#             objects every global symbol but lexiftool_* gets the prefix
#             lxint_ (objcopy; a partial link into one object as on Linux
#             breaks the unwind tables of PE objects), and the modules'
#             dllexport directives are removed.
#             Output in capi/build/windows/:
#               include/lexiftool.h
#               lib/liblexiftool.a        MinGW, static: those objects
#                                         (compile with -DLEXIFTOOL_STATIC)
#               bin/lexiftool.dll         shared, from the same objects,
#                                         exports lexiftool_* only (.def);
#                                         imports KERNEL32 and msvcrt only
#               lib/liblexiftool.dll.a    MinGW import library
#               lib/lexiftool.lib         import library for MSVC (dlltool)
#               lib/lexiftool.def         the exports
#               lib/pkgconfig/lexiftool.pc  (prefix relative to itself;
#                                         --static: -DLEXIFTOOL_STATIC)
#               bin/                      example, test_capi, test_threads,
#                                         test_sideeffects (.exe), each
#                                         linked against the static library
#                                         (NAME) and the DLL (NAME-dll)
#   rock      on Windows with MSVC (cl in the environment, e.g. from the
#             Developer Command Prompt): the library only (lexiftool.c),
#             Lua modules and C modules loaded from package.path /
#             package.cpath at run time, against the Lua 5.5 that luarocks
#             is configured for (LUA_INCDIR, LUA_LIBDIR and LUALIB of
#             `luarocks config`; CAPI_LUA the interpreter, default lua).
#             Output in capi/build/rock-windows/: example, test_capi,
#             test_threads, test_sideeffects (.exe).
#   msvc      on Windows with MSVC, after "embedded" (its output copied
#             there): the programs compiled with cl and linked against
#             lexiftool.lib, the DLL next to them -- the MSVC link test --
#             in capi/build/windows/msvc/; test_hostlibs too, with the
#             Lua of luarocks (as for "rock") and a zlib (ZLIB_DIR:
#             include/zlib.h, lib/zlib.lib, bin/zlib1.dll on PATH).
#   test      runs test_capi, test_threads and test_sideeffects of every
#             build there is (rock-windows: the modules from LUA_PATH_5_5 /
#             LUA_CPATH_5_5, which the caller sets; windows: static and
#             DLL; windows/msvc), test_hostlibs where built, and compares
#             lexiftool_image_info with Perl's Image::ExifTool
#             (capi/compare-perl.sh; CAPI_PERL names the perl, default
#             perl). CAPI_RUNNER runs the programs (wine on Linux; there
#             the Perl comparison is left out unless CAPI_PERL is set).
#
# Run from anywhere; paths are taken from the script's location.

set -eu

VARIANT="${1:?usage: build-windows.sh embedded|rock|msvc|test}"
CAPI="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$CAPI/.." && pwd)"
OUT="$CAPI/build"
mkdir -p "$OUT"
echo '*' > "$OUT/.gitignore"

# shared with build-linux.sh and build-macos.sh
. "$CAPI/common.sh"

PROGRAMS="example test_capi test_threads test_sideeffects"

# a path as cl takes it inside an option (-Fo, -Fe, -I): Git Bash converts
# "-Fo/d/a/x.obj" not at all and takes "-FoD:/a/x.obj" for a path list
# ("D" and "/a/x.obj", the latter on drive A:); cygpath -w gives
# D:\a\x.obj, which it leaves alone. Elsewhere the path stays.
native() {
    if command -v cygpath > /dev/null 2>&1; then cygpath -w "$1"; else echo "$1"; fi
}

case "$VARIANT" in
embedded)
    obj="$OUT/windows"
    if [ ! -d /opt/lx ]; then
        exec podman run --rm -e COMPRESS="${COMPRESS:-}" \
            -e LEXIFTOOL_PORT_VERSION="$(portversion)" \
            -v "$PROJECT:/project" lexiftool-builder-windows \
            sh /project/capi/build-windows.sh embedded
    fi
    # --- in the builder container ---
    LX=/opt/lx
    SA="$PROJECT/standalone"
    o="$obj/obj"
    rm -rf "$obj"; mkdir -p "$o" "$obj/include" "$obj/lib/pkgconfig" "$obj/bin"
    T=x86_64-w64-mingw32
    CC=$T-gcc
    CFLAGS="-O2 -Wall"
    L="$LX/lib/x86_64"
    LIBS="-lluamods -lbrotli -lzstd -lpcre2-8 -lz -llzma -lbz2 -llua55"
    API=$(apiversion)
    EXPORTS=$(exports)
    : "${LEXIFTOOL_PORT_VERSION:?LEXIFTOOL_PORT_VERSION must be set (passed in by the host part above)}"
    COMPRESS="${COMPRESS:-zstd}"
    case "$COMPRESS" in
        zstd) CODEC=zstd; TOOL="$LX/bin/zstd" ;;
        *)    CODEC=none; TOOL="" ;;
    esac
    set -x
    "$LX/bin/lua55" "$SA/genembed.lua" "$o" "$PROJECT" 0 "$CODEC" "$TOOL" "$LEXIFTOOL_PORT_VERSION"
    genheader "$LX/bin/lua55" "$o/session_lua.h"
    $CC $CFLAGS -I"$LX/include" -I"$o" -I"$CAPI" -DLEXIFTOOL_CAPI_EMBEDDED -DLEXIFTOOL_STATIC \
        -DLEXIFTOOL_PORT_VERSION="\"$LEXIFTOOL_PORT_VERSION\"" \
        -c "$CAPI/lexiftool.c" -o "$o/lexiftool.o"
    $CC $CFLAGS -I"$LX/include" -I"$SA" -I"$o" -DLX_NO_MAIN -c "$SA/main.c" -o "$o/setup.o"
    $CC $CFLAGS -I"$SA" -c "$o/embedded_index.c" -o "$o/embedded_index.o"
    (cd "$o" && $CC $CFLAGS -I"$SA" -c "$SA/blob.c" -o "$o/blob.o")
    $CC $CFLAGS -I"$LX/include" -DLEXIFTOOL_LUA_VERSION_NUM=505 \
        -c "$PROJECT/src/lexiftool/sys.c" -o "$o/sys.o"
    # the static library: the own objects and every member of the
    # archives, in each of them every global symbol but lexiftool_*
    # renamed with the prefix lxint_ (objcopy --redefine-syms), so that
    # none can clash with or bind to a host's own Lua, zlib, ... -- not one
    # relocatable object as on Linux: a partial link (ld -r) of PE objects
    # breaks their unwind tables (.pdata/.xdata), and Lua's errors unwind
    # through them -- and without the modules' -export directives
    # (.drectve, from their dllexport): the DLL exports what its .def
    # names, nothing else
    set +x
    mkdir -p "$o/members" "$o/renamed"
    for a in $LIBS; do
        a=${a#-l}
        mkdir -p "$o/members/$a"
        (cd "$o/members/$a" && $T-ar x "$L/lib$a.a")
        for f in "$o/members/$a"/*.o; do mv "$f" "$o/members/$a-$(basename "$f")"; done
        rmdir "$o/members/$a"
    done
    cp "$o/lexiftool.o" "$o/setup.o" "$o/embedded_index.o" "$o/blob.o" "$o/sys.o" "$o/members/"
    $T-nm -g --defined-only "$o"/members/*.o |
        awk 'NF == 3 && $3 !~ /^lexiftool_/ { print $3, "lxint_" $3 }' | sort -u > "$o/rename.txt"
    for f in "$o"/members/*.o; do
        $T-objcopy --redefine-syms="$o/rename.txt" --strip-debug --remove-section=.drectve \
            "$f" "$o/renamed/$(basename "$f")"
    done
    set -x
    rm -f "$obj/lib/liblexiftool.a"
    $T-ar rcs "$obj/lib/liblexiftool.a" "$o"/renamed/*.o
    # the DLL, its import libraries (MinGW, MSVC) and .def
    { echo "LIBRARY lexiftool.dll"; echo "EXPORTS"; for e in $EXPORTS; do echo "    $e"; done; } \
        > "$obj/lib/lexiftool.def"
    # shellcheck disable=SC2046
    $CC -shared -s -static-libgcc $(for e in $EXPORTS; do printf -- '-Wl,-u,%s ' "$e"; done) \
        "$obj/lib/lexiftool.def" "$obj/lib/liblexiftool.a" \
        -Wl,--out-implib,"$obj/lib/liblexiftool.dll.a" -o "$obj/bin/lexiftool.dll"
    $T-dlltool -d "$obj/lib/lexiftool.def" -D lexiftool.dll -l "$obj/lib/lexiftool.lib"
    cp "$CAPI/lexiftool.h" "$obj/include/lexiftool.h"
    # the programs: against the static library and the DLL
    for p in $PROGRAMS; do
        $CC -O2 -Wall -I"$obj/include" -DLEXIFTOOL_TEST_EMBEDDED -DLEXIFTOOL_STATIC "$CAPI/$p.c" \
            "$obj/lib/liblexiftool.a" -static -o "$obj/bin/$p.exe"
        $CC -O2 -Wall -I"$obj/include" -DLEXIFTOOL_TEST_EMBEDDED "$CAPI/$p.c" \
            -L"$obj/lib" -llexiftool.dll -static-libgcc -o "$obj/bin/$p-dll.exe"
    done
    set +x
    pkgconfig "$obj/lib/pkgconfig/lexiftool.pc" "" "-DLEXIFTOOL_STATIC"
    # checks: only lexiftool_* and lxint_* global (static), only
    # lexiftool_* exported (DLL); the DLL and the programs import the
    # system DLLs every Windows has only
    status=0
    $T-nm -g --defined-only "$obj/lib/liblexiftool.a" | awk 'NF == 3 && $3 !~ /^lxint_/ { print $3 }' \
        > "$o/global.txt"
    $T-objdump -p "$obj/bin/lexiftool.dll" |
        awk '/^\[Ordinal\/Name Pointer\] Table/ { t = 1; next } t && NF == 0 { t = 0 } t { print $NF }' \
        > "$o/exported.txt"
    for f in global exported; do
        if grep -v '^lexiftool_' "$o/$f.txt"; then
            echo "embedded: $f symbols beyond lexiftool_* (above)" >&2; status=1
        fi
        for e in $EXPORTS; do
            grep -qx "$e" "$o/$f.txt" || { echo "embedded: $e not $f" >&2; status=1; }
        done
    done
    for f in "$obj/bin/lexiftool.dll" "$obj/bin/test_capi.exe" "$obj/bin/test_capi-dll.exe"; do
        $T-objdump -p "$f" | grep 'DLL Name' | sort -u | tee "$o/dlls.txt"
        if grep -viE 'DLL Name: (KERNEL32|msvcrt|lexiftool)\.dll' "$o/dlls.txt"; then
            echo "embedded: unexpected DLL import in $f" >&2; status=1
        fi
    done
    ls -l "$obj/lib" "$obj/bin"
    exit $status
    ;;

rock)
    obj="$OUT/rock-windows"
    rm -rf "$obj"; mkdir -p "$obj"
    obj=$(native "$obj") C=$(native "$CAPI")
    LUA=${CAPI_LUA:-$(command -v lua5.5 || command -v lua)}
    incdir=$(luarocks config variables.LUA_INCDIR)
    lib="$(luarocks config variables.LUA_LIBDIR)/$(luarocks config variables.LUALIB)"
    set -x
    genheader "$LUA" "$obj/session_lua.h"
    # (cl's options with "-", not "/": Git Bash would take them for paths)
    cl -nologo -O2 -W3 -I"$incdir" -I"$obj" -DLEXIFTOOL_STATIC \
        -DLEXIFTOOL_PORT_VERSION="\"$(portversion)\"" -c "$C/lexiftool.c" -Fo"$obj/lexiftool.obj"
    for p in $PROGRAMS; do
        cl -nologo -O2 -W3 -I"$incdir" -I"$C" -DLEXIFTOOL_STATIC "$C/$p.c" "$obj/lexiftool.obj" \
            "$lib" -Fo"$obj/$p.obj" -Fe"$obj/$p.exe"
    done
    set +x
    ls -l "$obj"
    ;;

msvc)
    obj="$OUT/windows"
    [ -f "$obj/lib/lexiftool.lib" ] || { echo "msvc: $obj/lib/lexiftool.lib missing (embedded)" >&2; exit 1; }
    m="$obj/msvc"
    rm -rf "$m"; mkdir -p "$m"
    cp "$obj/bin/lexiftool.dll" "$m/"
    obj=$(native "$obj") m=$(native "$m") C=$(native "$CAPI")
    set -x
    for p in $PROGRAMS; do
        cl -nologo -O2 -W3 -I"$obj/include" -DLEXIFTOOL_TEST_EMBEDDED "$C/$p.c" \
            "$obj/lib/lexiftool.lib" -Fo"$m/$p.obj" -Fe"$m/$p.exe"
    done
    # test_hostlibs: the Lua of luarocks and a zlib (ZLIB_DIR) in the host
    if [ -n "${ZLIB_DIR:-}" ]; then
        incdir=$(luarocks config variables.LUA_INCDIR)
        lib="$(luarocks config variables.LUA_LIBDIR)/$(luarocks config variables.LUALIB)"
        cl -nologo -O2 -W3 -I"$obj/include" -I"$incdir" -I"$ZLIB_DIR/include" "$C/test_hostlibs.c" \
            "$obj/lib/lexiftool.lib" "$lib" "$ZLIB_DIR/lib/zlib.lib" -Fo"$m/test_hostlibs.obj" \
            -Fe"$m/test_hostlibs.exe"
    fi
    set +x
    ls -l "$m"
    ;;

test)
    cd "$PROJECT"
    R=${CAPI_RUNNER:-}
    # absolute paths as the Windows programs take them (test_sideeffects
    # changes its directory): cygpath under Git Bash, winepath under wine
    winpath() {
        if command -v cygpath > /dev/null 2>&1; then cygpath -m "$1"
        elif [ -n "$R" ] && command -v winepath > /dev/null 2>&1; then winepath -w "$1" 2>/dev/null
        else echo "$1"; fi
    }
    tmp=capi/build/test-windows; rm -rf "$tmp"; mkdir -p "$tmp"
    T=$(winpath "$PROJECT/vendor/exiftool/t/images")
    status=0
    examples=""
    for b in "rock rock-windows" "mingw windows/bin" "dll windows/bin -dll" "msvc windows/msvc"; do
        set -- $b
        dir="capi/build/$2" sfx="${3:-}"
        [ -f "$dir/test_capi$sfx.exe" ] || { echo "$1: not built"; continue; }
        examples="$examples $1=$dir/example$sfx.exe"
        tests="test_capi test_threads test_sideeffects"
        [ -f "$dir/test_hostlibs$sfx.exe" ] && tests="$tests test_hostlibs"
        for p in $tests; do
            args=""
            [ $p = test_threads ] && args="${CAPI_THREADS:-8} 2"
            rm -rf "$tmp/$1-$p"; mkdir -p "$tmp/$1-$p"
            # shellcheck disable=SC2086
            if $R "$dir/$p$sfx.exe" "$T" "$(winpath "$PROJECT/$tmp/$1-$p")" $args > "$tmp/$1-$p.txt" 2>&1; then
                echo "$1: $p $(grep -c '^ok' "$tmp/$1-$p.txt") ok"
            else
                grep -E '^not ok|^#' "$tmp/$1-$p.txt" | sed "s/^/$1: /"
                echo "$1: $p FAILED, see $tmp/$1-$p.txt"; status=1
            fi
        done
    done
    if [ -n "$examples" ] && { [ -z "$R" ] || [ -n "${CAPI_PERL:-}" ]; }; then
        # shellcheck disable=SC2086
        sh "$CAPI/compare-perl.sh" "$tmp" $examples || status=1
    fi
    exit $status
    ;;

*)
    echo "build-windows.sh: unknown variant '$VARIANT'" >&2; exit 1 ;;
esac
