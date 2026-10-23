#!/bin/sh
# capi/build-linux.sh VARIANT - builds the C API prototype (Linux x86-64).
#
#   embedded  everything inside the library, as in the standalone
#             executable: runs itself in the standalone builder container
#             (podman image lexiftool-builder-linux, `make image-linux`),
#             zig cc. Output in capi/build/embedded/:
#               liblexiftool.a   static, musl: lexiftool.c + the setup of
#                                standalone/main.c (lx_setup, compiled
#                                with -DLX_NO_MAIN) + the embedded modules
#                                (standalone/genembed.lua, blob.c) + sys.c
#                                + Lua 5.5.1, PCRE2, zlib, brotli, zstd
#                                (decoder), liblzma, libbz2 and the Lua C
#                                modules (cipher.aes and cipher.rc4
#                                included, in libluamods.a), merged
#                                into one archive; the entries compressed
#                                as in the standalone build (COMPRESS, the
#                                codec, default that of SA_COMPRESS)
#               liblexiftool.so  shared, glibc 2.17, -fPIC, the same
#                                objects against the image's PIC archives
#                                (lib/x86_64-gnu-pic); exports only the
#                                lexiftool_* functions
#               example, test_capi            linked statically (musl)
#               example-so, test_capi-so      linked against the .so
#   rock      the library only (lexiftool.c), Lua modules and C modules
#             loaded from package.path / package.cpath at run time; host
#             gcc against the system's Lua 5.5 (-llua). Output in
#             capi/build/rock/ (also an ASan build, *-asan).
#   test      runs the checks against all builds (see below).
#
# Run from anywhere; paths are taken from the script's location.

set -eu

VARIANT="${1:?usage: build-linux.sh embedded|rock|test}"
CAPI="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$CAPI/.." && pwd)"
OUT="$CAPI/build"
mkdir -p "$OUT"
echo '*' > "$OUT/.gitignore"

# the build's own version/identity (CONTRIBUTING.md "Configuration",
# _G.LEXIFTOOL_PORT_VERSION; same scheme as Makefile.standalone's
# SA_IDENTITY). Run on the host: the "embedded" variant has no git inside
# its builder container, so it is computed before the re-exec below and
# passed in via LEXIFTOOL_PORT_VERSION instead of calling this again.
portversion() {
    git -C "$PROJECT" describe --tags --always --long --dirty --match 'v*' 2>/dev/null || echo Unknown
}

# session.lua as a C array: genheader LUA OUTFILE
genheader() {
    "$1" - "$CAPI/session.lua" "$2" <<'LUA'
local f = assert(io.open(arg[1], "rb")); local s = f:read("a"); f:close()
local o = assert(io.open(arg[2], "wb"))
o:write("/* generated from capi/session.lua - do not edit */\n",
        "static const unsigned char lx_session_lua[] = {\n")
for i = 1, #s, 16 do
    local t = {}
    for j = i, math.min(i + 15, #s) do t[#t + 1] = tostring(s:byte(j)) end
    o:write("    ", table.concat(t, ","), ",\n")
end
o:write("};\nstatic const size_t lx_session_lua_len = ", #s, ";\n")
o:close()
LUA
}

case "$VARIANT" in
embedded)
    if [ ! -d /opt/lx ]; then
        # not in the builder container yet: identity computed here, on the
        # host -- the builder container has no git -- and passed through
        exec podman run --rm -e COMPRESS="${COMPRESS:-}" \
            -e LEXIFTOOL_PORT_VERSION="$(portversion)" \
            -v "$PROJECT:/project" lexiftool-builder-linux \
            sh /project/capi/build-linux.sh embedded
    fi
    LX=/opt/lx
    SA="$PROJECT/standalone"
    obj="$OUT/embedded"
    rm -rf "$obj"; mkdir -p "$obj"
    CC="zig cc -target x86_64-linux-musl"
    CFLAGS="-O2 -Wall -ffunction-sections -fdata-sections"
    : "${LEXIFTOOL_PORT_VERSION:?LEXIFTOOL_PORT_VERSION must be set (passed in by the re-exec above)}"
    set -x
    # entries compressed as in the standalone build (standalone/build.sh;
    # the default codec is Makefile.standalone's SA_COMPRESS)
    COMPRESS="${COMPRESS:-zstd}"
    case "$COMPRESS" in
        zstd) CODEC=zstd; TOOL="$LX/bin/zstd" ;;
        *)    CODEC=none; TOOL="" ;;
    esac
    "$LX/bin/lua55" "$SA/genembed.lua" "$obj" "$PROJECT" 0 "$CODEC" "$TOOL" "$LEXIFTOOL_PORT_VERSION"
    genheader "$LX/bin/lua55" "$obj/session_lua.h"
    own() {     # own <suffix> <cc + flags...>: the library's own objects
        sfx="$1"; shift
        "$@" -I"$LX/include" -I"$obj" -I"$CAPI" -DLEXIFTOOL_CAPI_EMBEDDED \
            -DLEXIFTOOL_PORT_VERSION="\"$LEXIFTOOL_PORT_VERSION\"" \
            -c "$CAPI/lexiftool.c" -o "$obj/lexiftool$sfx.o"
        "$@" -I"$LX/include" -I"$SA" -I"$obj" -DLX_NO_MAIN -c "$SA/main.c" -o "$obj/setup$sfx.o"
        "$@" -I"$SA" -c "$obj/embedded_index.c" -o "$obj/embedded_index$sfx.o"
        (cd "$obj" && "$@" -I"$SA" -c "$SA/blob.c" -o "$obj/blob$sfx.o")
        "$@" -I"$LX/include" -DLEXIFTOOL_LUA_VERSION_NUM=505 \
            -c "$PROJECT/src/lexiftool/sys.c" -o "$obj/sys$sfx.o"
    }
    OWN() { echo "$obj/lexiftool$1.o $obj/setup$1.o $obj/embedded_index$1.o $obj/blob$1.o $obj/sys$1.o"; }

    # static archive (musl): own objects + all dependency archives (GNU ar
    # MRI script)
    own "" $CC $CFLAGS
    ar rcs "$obj/libown.a" $(OWN "")
    L="$LX/lib/x86_64"
    printf 'CREATE %s\nADDLIB %s\nADDLIB %s\nADDLIB %s\nADDLIB %s\nADDLIB %s\nADDLIB %s\nADDLIB %s\nADDLIB %s\nADDLIB %s\nSAVE\nEND\n' \
        "$obj/liblexiftool.a" "$obj/libown.a" "$L/libluamods.a" "$L/libbrotli.a" "$L/libzstd.a" \
        "$L/libpcre2-8.a" "$L/libz.a" "$L/liblzma.a" "$L/libbz2.a" "$L/liblua55.a" | ar -M
    ranlib "$obj/liblexiftool.a"
    rm "$obj/libown.a"
    for p in example test_capi; do
        $CC $CFLAGS -I"$CAPI" -c "$CAPI/$p.c" -o "$obj/$p.o"
        $CC -static -Wl,--gc-sections "$obj/$p.o" -L"$obj" -llexiftool -o "$obj/$p"
    done

    # shared library (glibc, PIC): only lexiftool_* visible -- hidden by
    # default in the own objects, and a version script for the archives'
    # symbols (lua_*, pcre2_*, ...)
    SOCC="zig cc -target x86_64-linux-gnu.2.17"
    own "-pic" $SOCC $CFLAGS -fPIC -fvisibility=hidden
    printf '{\n  global: lexiftool_*;\n  local: *;\n};\n' > "$obj/exports.map"
    $SOCC -shared -s -Wl,--gc-sections -Wl,--version-script="$obj/exports.map" \
        -Wl,-soname,liblexiftool.so $(OWN "-pic") -L"$LX/lib/x86_64-gnu-pic" \
        -Wl,--start-group -lluamods -lbrotli -lzstd -lpcre2-8 -lz -llzma -lbz2 -llua55 -Wl,--end-group \
        -lm -o "$obj/liblexiftool.so"
    for p in example test_capi; do
        $SOCC $CFLAGS -I"$CAPI" "$CAPI/$p.c" -L"$obj" -llexiftool \
            -Wl,-rpath,'$ORIGIN' -o "$obj/$p-so"
    done
    set +x
    echo "exported symbols of liblexiftool.so:"
    nm -D --defined-only "$obj/liblexiftool.so" | awk '{print "  " $3}'
    if nm -D --defined-only "$obj/liblexiftool.so" | awk '{print $3}' | grep -v '^lexiftool_'; then
        echo "liblexiftool.so exports more than lexiftool_*" >&2; exit 1
    fi
    ls -l "$obj/liblexiftool.a" "$obj/liblexiftool.so" "$obj/example" "$obj/test_capi"
    ;;

rock)
    obj="$OUT/rock"
    rm -rf "$obj"; mkdir -p "$obj"
    LUA=lua5.5
    CC=${CC:-gcc}
    set -x
    genheader "$LUA" "$obj/session_lua.h"
    for san in "" "-asan"; do
        flags="-O2 -g -Wall -Wextra"
        [ -n "$san" ] && flags="-O1 -g -Wall -fsanitize=address -fno-omit-frame-pointer"
        $CC $flags -I"$obj" -DLEXIFTOOL_PORT_VERSION="\"$(portversion)\"" \
            -c "$CAPI/lexiftool.c" -o "$obj/lexiftool$san.o"
        ar rcs "$obj/liblexiftool$san.a" "$obj/lexiftool$san.o"
        for p in example test_capi; do
            $CC $flags -I"$CAPI" "$CAPI/$p.c" "$obj/liblexiftool$san.a" -llua -lm -o "$obj/$p$san"
        done
    done
    set +x
    ls -l "$obj"/liblexiftool*.a
    ;;

test)
    T="$PROJECT/vendor/exiftool/t/images"
    tmp="$OUT/test"; rm -rf "$tmp"; mkdir -p "$tmp"
    cd "$PROJECT"
    # the rock variant finds the modules as the repo's launcher does
    LP="$PROJECT/src/?.lua;$PROJECT/src/?/init.lua;$HOME/.luarocks/share/lua/5.5/?.lua;/usr/share/lua/5.5/?.lua"
    LCP="$PROJECT/build/5.5/?.so;$HOME/.luarocks/lib/lua/5.5/?.so;/usr/lib/lua/5.5/?.so"
    export LUA_PATH_5_5="$LP" LUA_CPATH_5_5="$LCP"
    status=0
    # 1. example output == CLI output
    ./lexiftool -j vendor/exiftool/t/images/Canon.jpg > "$tmp/cli-j.txt"
    ./lexiftool -ver > "$tmp/cli-ver.txt"
    cat "$tmp/cli-j.txt" "$tmp/cli-ver.txt" > "$tmp/cli.txt"
    if [ -x dist-linux/lexiftool ]; then
        (dist-linux/lexiftool -j vendor/exiftool/t/images/Canon.jpg; dist-linux/lexiftool -ver) > "$tmp/standalone.txt"
        cmp "$tmp/cli.txt" "$tmp/standalone.txt" && echo "standalone executable == CLI"
    fi
    # builds: name, example, test_capi
    for b in "embedded example test_capi" "shared example-so test_capi-so" \
             "rock example test_capi"; do
        set -- $b
        v=$1
        d="$OUT/$v"
        [ "$v" = shared ] && d="$OUT/embedded"
        exe="$d/$2"
        [ -x "$exe" ] || { echo "$v: not built"; continue; }
        "$exe" vendor/exiftool/t/images/Canon.jpg > "$tmp/$v-example.txt" 2> "$tmp/$v-example.err"
        if diff "$tmp/cli.txt" "$tmp/$v-example.txt" > "$tmp/$v-example.diff"; then
            echo "$v: example output == CLI (-j Canon.jpg, -ver)"
        else
            echo "$v: example output DIFFERS from CLI, see $tmp/$v-example.diff"; status=1
        fi
        # 2. the API tests (100 commands, two sessions, -b, image_info, ...)
        mkdir -p "$tmp/$v-scratch"
        "$d/$3" "$T" 100 "$tmp/$v-thumb.jpg" "$tmp/$v-info-thumb.jpg" "$tmp/$v-scratch" \
            > "$tmp/$v-test.txt" 2>&1 || status=1
        grep -E '^(not ok|#)' "$tmp/$v-test.txt" | sed "s/^/$v: /"
        ./lexiftool -b -ThumbnailImage "$T/ExifTool.jpg" > "$tmp/cli-thumb.jpg" 2>/dev/null
        if cmp "$tmp/cli-thumb.jpg" "$tmp/$v-thumb.jpg" && cmp "$tmp/cli-thumb.jpg" "$tmp/$v-info-thumb.jpg"; then
            echo "$v: -b output == CLI (execute and image_info)"
        else
            status=1
        fi
    done
    # 3. leaks: ASan (LeakSanitizer) and valgrind, rock variant
    if [ -x "$OUT/rock/test_capi-asan" ]; then
        mkdir -p "$tmp/asan-scratch"
        if ASAN_OPTIONS=detect_leaks=1 "$OUT/rock/test_capi-asan" "$T" 100 \
                "$tmp/asan-thumb.jpg" "$tmp/asan-info-thumb.jpg" "$tmp/asan-scratch" \
                > "$tmp/asan.txt" 2>&1; then
            echo "rock: ASan + LeakSanitizer clean ($(grep -c '^ok' "$tmp/asan.txt") ok)"
        else
            echo "rock: ASan FAILED, see $tmp/asan.txt"; status=1
        fi
    fi
    if command -v valgrind > /dev/null && [ -x "$OUT/rock/test_capi" ]; then
        if valgrind --leak-check=full --errors-for-leak-kinds=definite,indirect \
                --error-exitcode=9 "$OUT/rock/test_capi" "$T" 100 > "$tmp/valgrind.txt" 2>&1; then
            echo "rock: valgrind clean"
        elif grep -q 'Fatal error at startup' "$tmp/valgrind.txt"; then
            echo "rock: valgrind skipped (cannot run here, see $tmp/valgrind.txt)"
        else
            echo "rock: valgrind FAILED, see $tmp/valgrind.txt"; status=1
        fi
    fi
    # 4. memory per command: the RSS after 100 and after 1000 commands
    for b in "embedded test_capi" "shared test_capi-so" "rock test_capi"; do
        set -- $b
        d="$OUT/$1"
        [ "$1" = shared ] && d="$OUT/embedded"
        [ -x "$d/$2" ] || continue
        r100=$("$d/$2" "$T" 100 | sed -n 's/^# 100 commands: RSS .* -> \([0-9]*\) kB$/\1/p')
        r1000=$("$d/$2" "$T" 1000 | sed -n 's/^# 1000 commands: RSS .* -> \([0-9]*\) kB$/\1/p')
        echo "$1: RSS after 100 commands ${r100} kB, after 1000 commands ${r1000} kB"
    done
    exit $status
    ;;
*)
    echo "build-linux.sh: unknown variant '$VARIANT'" >&2; exit 1 ;;
esac
