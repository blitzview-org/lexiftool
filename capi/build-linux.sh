#!/bin/sh
# capi/build-linux.sh VARIANT - builds and tests the C API (Linux x86-64).
#
#   embedded  everything inside the library, as in the standalone
#             executable. The libraries are built in the standalone
#             builder container (podman image lexiftool-builder-linux,
#             `make image-linux`; the script runs itself there), zig cc
#             for glibc 2.17, -fPIC, from the image's archives of the same
#             kind (lib/x86_64-gnu-pic): lexiftool.c + the setup of
#             standalone/main.c (lx_setup, compiled with -DLX_NO_MAIN) +
#             the embedded modules (standalone/genembed.lua, blob.c; the
#             entries stored as in the standalone build: COMPRESS, the
#             codec, default uncompressed as SA_COMPRESS) + sys.c + Lua 5.5.1,
#             PCRE2, zlib, brotli, zstd (decoder), liblzma, libbz2 and the
#             Lua C modules (libluamods.a), partially linked (ld -r) into
#             one object in which only lexiftool_* stays global (objcopy).
#             Output in capi/build/embedded/:
#               include/lexiftool.h
#               lib/liblexiftool.a        that object
#               lib/liblexiftool.so.API   shared, from the same object,
#                                         soname = LEXIFTOOL_API_VERSION,
#                                         exports lexiftool_* only
#               lib/liblexiftool.so       -> liblexiftool.so.API
#               lib/pkgconfig/lexiftool.pc  (prefix relative to itself)
#             Then, on the host with the host's cc (CC, default gcc) and
#             through lexiftool.pc, the programs in bin/: example,
#             test_capi, test_threads, test_sideeffects and test_hostlibs
#             (with a Lua and a zlib of its own: CAPI_HOST_PC, the
#             pkg-config names, default "lua5.4 zlib"), each linked
#             against the static archive (NAME) and the shared library
#             (NAME-so).
#   install   copies the embedded libraries, the header and lexiftool.pc
#             (prefix = PREFIX) to DESTDIR/PREFIX (default /usr/local):
#             include/, lib/, lib/pkgconfig/.
#   rock      the library only (lexiftool.c), Lua modules and C modules
#             loaded from package.path / package.cpath at run time; host
#             gcc against the system's Lua 5.5 (-llua; or CAPI_LUA_INCDIR
#             and CAPI_LUA_LIB, the include directory and the library
#             file, a static one linked whole; CAPI_LUA the interpreter,
#             default lua5.5). Output in capi/build/rock/ (also an ASan
#             build, *-asan).
#             test_threads and test_sideeffects are built there as well.
#             (The same variant as a shared library against the system's
#             Lua, for a system-wide installation, is the Makefile's
#             `capi-shared` and `install`.)
#   test      runs test_capi and test_threads against all builds there
#             are (the ASan build with LeakSanitizer), test_hostlibs
#             against the embedded ones, and compares lexiftool_image_info
#             (capi/example of every build) with Perl's Image::ExifTool
#             (capi/compare-perl.sh; CAPI_PERL names the perl, default
#             perl). The modules of the rock build are found as by the
#             launcher, or through LUA_PATH_5_5/LUA_CPATH_5_5 when set.
#   sideeffects  (after "rock" and/or "embedded") runs test_sideeffects of
#             every build there is (rock also with AddressSanitizer/
#             LeakSanitizer), and test_capi under valgrind where valgrind
#             runs (it needs the C library's symbols; if it cannot start,
#             the ASan/LSan runs are the memory check).
#   tsan      ThreadSanitizer: builds Lua (the version and checksum pinned
#             in standalone/fetch.sh, downloaded once), the Lua C modules
#             (luarocks install of the published rocks into a tree of its
#             own), lexiftool.sys, the C API and test_threads/test_capi, all
#             with -fsanitize=thread, in capi/build/tsan/, and runs them
#             (test_threads: TSAN_THREADS threads, default 8, file share
#             TSAN_SHARE, default 4). Any report fails. The C libraries the
#             rocks link (PCRE2, zlib, brotli, liblzma, libbz2) and the C
#             library itself are the system's, not instrumented.
#   tsan-embedded  ThreadSanitizer over the embedded build, in a container
#             of the builder image (its gcc): every dependency built from
#             the sources of standalone/fetch.sh by standalone/deps.sh
#             linux-tsan (once, into capi/build/tsan-embedded/lib), the own
#             objects of "embedded", test_threads and test_capi, all with
#             -fsanitize=thread, run as for "tsan". Only the C library is
#             not instrumented.
#
# Run from anywhere; paths are taken from the script's location.

set -eu

VARIANT="${1:?usage: build-linux.sh embedded|install|rock|test|sideeffects|tsan|tsan-embedded}"
CAPI="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$CAPI/.." && pwd)"
OUT="$CAPI/build"
mkdir -p "$OUT"
echo '*' > "$OUT/.gitignore"

# shared with build-macos.sh and build-windows.sh: portversion, apiversion,
# exports, genheader, pkgconfig, rock_paths
. "$CAPI/common.sh"

# tsan_run NAME DIR TMP: test_threads (TSAN_THREADS threads, default 8,
# file share TSAN_SHARE, default 4) and test_capi of DIR under
# ThreadSanitizer; any report fails (exits)
tsan_run() {
    name=$1 dir=$2 tmp=$3
    rm -rf "$tmp"; mkdir -p "$tmp/threads" "$tmp/capi"
    export TSAN_OPTIONS="halt_on_error=0 exitcode=66 ${TSAN_OPTIONS:-}"
    status=0
    for run in "test_threads threads ${TSAN_THREADS:-8} ${TSAN_SHARE:-4}" "test_capi capi 3"; do
        set -- $run
        p=$1 sub=$2; shift 2
        if "$dir/$p" "$T" "$tmp/$sub" "$@" > "$tmp/$p.txt" 2> "$tmp/$p-tsan.txt"; then
            echo "$name: $p $(grep -c '^ok' "$tmp/$p.txt") ok, no ThreadSanitizer report"
        else
            grep -E '^not ok' "$tmp/$p.txt" | sed "s/^/$name: $p: /"
            grep '^SUMMARY: ThreadSanitizer' "$tmp/$p-tsan.txt" | sort | uniq -c | sed "s/^/$name: $p: /"
            echo "$name: $p FAILED, see $tmp/$p.txt and $tmp/$p-tsan.txt"; status=1
        fi
    done
    exit $status
}

case "$VARIANT" in
embedded)
    obj="$OUT/embedded"
    if [ ! -d /opt/lx ]; then
        # 1. the libraries, in the builder container; the identity is
        #    computed here, on the host -- the builder container has no git
        #    -- and passed through
        podman run --rm -e COMPRESS="${COMPRESS:-}" \
            -e LEXIFTOOL_PORT_VERSION="$(portversion)" \
            -v "$PROJECT:/project" lexiftool-builder-linux \
            sh /project/capi/build-linux.sh embedded
        # 2. the programs, on the host, with the host's compiler: each
        #    linked once against the static archive, once against the
        #    shared library, through lexiftool.pc
        CC=${CC:-gcc}
        export PKG_CONFIG_PATH="$obj/lib/pkgconfig"
        cflags="$(pkg-config --cflags lexiftool) -DLEXIFTOOL_TEST_EMBEDDED"
        # (static: the archive, although the shared library is next to it)
        static=$(pkg-config --static --libs lexiftool |
                 sed 's/-llexiftool/-Wl,-Bstatic -llexiftool -Wl,-Bdynamic/')
        shared="$(pkg-config --libs lexiftool) -Wl,-rpath,$(pkg-config --variable=libdir lexiftool)"
        # test_hostlibs: a host with Lua and zlib of its own
        hostlibs=$(pkg-config --cflags --libs ${CAPI_HOST_PC:-lua5.4 zlib})
        mkdir -p "$obj/bin"
        set -x
        for p in example test_capi test_threads test_sideeffects test_hostlibs; do
            extra=""; [ $p = test_hostlibs ] && extra="$hostlibs -ldl"
            # shellcheck disable=SC2086
            $CC -O2 -g -Wall $cflags "$CAPI/$p.c" $static $extra -lpthread -o "$obj/bin/$p"
            # shellcheck disable=SC2086
            $CC -O2 -g -Wall $cflags "$CAPI/$p.c" $shared $extra -lpthread -o "$obj/bin/$p-so"
        done
        set +x
        # the static programs must not need the shared library
        if ldd "$obj/bin/test_capi" | grep -q liblexiftool; then
            echo "bin/test_capi is linked against liblexiftool.so" >&2; exit 1
        fi
        ls -l "$obj/lib" "$obj/bin"
        exit 0
    fi
    # --- in the builder container ---
    LX=/opt/lx
    SA="$PROJECT/standalone"
    o="$obj/obj"
    rm -rf "$obj"; mkdir -p "$o" "$obj/include" "$obj/lib/pkgconfig"
    # glibc 2.17, position-independent: the objects of both libraries, and
    # the archives of the image built the same way (lib/x86_64-gnu-pic)
    CC="zig cc -target x86_64-linux-gnu.2.17"
    CFLAGS="-O2 -Wall -fPIC -ffunction-sections -fdata-sections -fvisibility=hidden"
    L="$LX/lib/x86_64-gnu-pic"
    LIBS="-lluamods -lbrotli -lzstd -lpcre2-8 -lz -llzma -lbz2 -llua55"
    API=$(apiversion)
    EXPORTS=$(exports)
    : "${LEXIFTOOL_PORT_VERSION:?LEXIFTOOL_PORT_VERSION must be set (passed in by the host part above)}"
    set -x
    # entries compressed as in the standalone build (standalone/build.sh;
    # the default codec is Makefile.standalone's SA_COMPRESS)
    COMPRESS="${COMPRESS:-0}"
    case "$COMPRESS" in
        zstd) CODEC=zstd; TOOL="$LX/bin/zstd" ;;
        *)    CODEC=none; TOOL="" ;;
    esac
    "$LX/bin/lua55" "$SA/genembed.lua" "$o" "$PROJECT" 0 "$CODEC" "$TOOL" "$LEXIFTOOL_PORT_VERSION"
    genheader "$LX/bin/lua55" "$o/session_lua.h"
    # the library's own objects: the C API, the setup of standalone/main.c
    # (lx_setup, -DLX_NO_MAIN), the embedded modules (genembed.lua,
    # blob.c), lexiftool.sys
    $CC $CFLAGS -I"$LX/include" -I"$o" -I"$CAPI" -DLEXIFTOOL_CAPI_EMBEDDED \
        -DLEXIFTOOL_PORT_VERSION="\"$LEXIFTOOL_PORT_VERSION\"" \
        -c "$CAPI/lexiftool.c" -o "$o/lexiftool.o"
    $CC $CFLAGS -I"$LX/include" -I"$SA" -I"$o" -DLX_NO_MAIN -c "$SA/main.c" -o "$o/setup.o"
    $CC $CFLAGS -I"$SA" -c "$o/embedded_index.c" -o "$o/embedded_index.o"
    (cd "$o" && $CC $CFLAGS -I"$SA" -c "$SA/blob.c" -o "$o/blob.o")
    $CC $CFLAGS -I"$LX/include" -DLEXIFTOOL_LUA_VERSION_NUM=505 \
        -c "$PROJECT/src/lexiftool/sys.c" -o "$o/sys.o"

    # 1. one relocatable object: the own objects and the archive members
    #    they need (Lua, PCRE2, zlib, brotli, zstd, liblzma, libbz2, the
    #    Lua C modules), without the sections no lexiftool_* function
    #    reaches. 2. In it only lexiftool_* stays global: every other
    #    defined symbol becomes local, so that the library's Lua, zlib, ...
    #    can neither clash with nor bind to a host's own copies.
    ld -r --gc-sections $(for e in $EXPORTS; do printf -- '-u %s ' "$e"; done) \
        -o "$o/whole.o" "$o/lexiftool.o" "$o/setup.o" "$o/embedded_index.o" \
        "$o/blob.o" "$o/sys.o" -L"$L" --start-group $LIBS --end-group
    objcopy --wildcard --keep-global-symbol='lexiftool_*' --strip-debug \
        "$o/whole.o" "$o/liblexiftool.o"
    # static archive: that one object
    rm -f "$obj/lib/liblexiftool.a"
    ar rcsD "$obj/lib/liblexiftool.a" "$o/liblexiftool.o"
    # shared library from the same object; soname = API version, the
    # version script exports lexiftool_* only
    printf '{\n  global: lexiftool_*;\n  local: *;\n};\n' > "$o/exports.map"
    $CC -shared -s -Wl,--gc-sections -Wl,--version-script="$o/exports.map" \
        -Wl,-soname,liblexiftool.so.$API "$o/liblexiftool.o" -lm -lpthread \
        -o "$obj/lib/liblexiftool.so.$API"
    ln -sf "liblexiftool.so.$API" "$obj/lib/liblexiftool.so"
    cp "$CAPI/lexiftool.h" "$obj/include/lexiftool.h"
    set +x
    # pkg-config: relocatable here (${pcfiledir}); "install" writes the
    # installation prefix instead
    pkgconfig "$obj/lib/pkgconfig/lexiftool.pc" "-lm -lpthread" ""

    # checks: only lexiftool_* global/exported; nothing beyond the C
    # library (libc, libm, libpthread) and no symbol version newer than
    # GLIBC_2.17
    status=0
    nm -g --defined-only "$obj/lib/liblexiftool.a" | awk 'NF == 3 { print $3 }' > "$o/global.txt"
    nm -D --defined-only "$obj/lib/liblexiftool.so.$API" | awk '{ print $3 }' > "$o/exported.txt"
    for f in global exported; do
        if grep -v '^lexiftool_' "$o/$f.txt"; then
            echo "embedded: $f symbols beyond lexiftool_* (above)" >&2; status=1
        fi
        for e in $EXPORTS; do
            grep -qx "$e" "$o/$f.txt" || { echo "embedded: $e not $f" >&2; status=1; }
        done
    done
    readelf -d "$obj/lib/liblexiftool.so.$API" | grep -E 'NEEDED|SONAME' | tee "$o/needed.txt"
    if grep NEEDED "$o/needed.txt" | grep -vE '\[(libc\.so\.6|libm\.so\.6|libpthread\.so\.0)\]'; then
        echo "embedded: unexpected shared library" >&2; status=1
    fi
    if objdump -T "$obj/lib/liblexiftool.so.$API" | grep -E 'GLIBC_2\.(1[89]|[2-9][0-9])'; then
        echo "embedded: symbol newer than GLIBC_2.17" >&2; status=1
    fi
    echo "undefined symbols of liblexiftool.a (from the C library):"
    nm -u "$obj/lib/liblexiftool.a" | awk 'NF == 2 { print $2 }' | sort -u | tr '\n' ' '; echo
    ls -l "$obj/lib"
    exit $status
    ;;

rock)
    obj="$OUT/rock"
    rm -rf "$obj"; mkdir -p "$obj"
    LUA=${CAPI_LUA:-lua5.5}
    CC=${CC:-gcc}
    # the Lua: the system's (-llua), or CAPI_LUA_INCDIR + CAPI_LUA_LIB (a
    # static one linked whole, with its symbols exported for the C modules)
    luainc=${CAPI_LUA_INCDIR:+-I$CAPI_LUA_INCDIR}
    case "${CAPI_LUA_LIB:-}" in
        "")  lualib="-llua" ;;
        *.a) lualib="-Wl,--whole-archive $CAPI_LUA_LIB -Wl,--no-whole-archive -Wl,-E -ldl" ;;
        *)   lualib="$CAPI_LUA_LIB" ;;
    esac
    set -x
    genheader "$LUA" "$obj/session_lua.h"
    for san in "" "-asan"; do
        flags="-O2 -g -Wall -Wextra"
        [ -n "$san" ] && flags="-O1 -g -Wall -fsanitize=address -fno-omit-frame-pointer"
        # shellcheck disable=SC2086
        $CC $flags $luainc -I"$obj" -DLEXIFTOOL_PORT_VERSION="\"$(portversion)\"" \
            -c "$CAPI/lexiftool.c" -o "$obj/lexiftool$san.o"
        ar rcs "$obj/liblexiftool$san.a" "$obj/lexiftool$san.o"
        for p in example test_capi test_threads test_sideeffects; do
            # shellcheck disable=SC2086
            $CC $flags $luainc -I"$CAPI" "$CAPI/$p.c" "$obj/liblexiftool$san.a" $lualib -lm -lpthread \
                -o "$obj/$p$san"
        done
    done
    set +x
    ls -l "$obj"/liblexiftool*.a
    ;;

sideeffects)
    T="$PROJECT/vendor/exiftool/t/images"
    tmp="$OUT/test-sideeffects"; rm -rf "$tmp"; mkdir -p "$tmp"
    cd "$PROJECT"
    [ -n "${LUA_PATH_5_5:-}" ] || rock_paths
    status=0
    # every build there is: rock (plain, ASan/LSan), embedded (static
    # archive, shared library)
    for b in "rock rock/test_sideeffects" "rock-asan rock/test_sideeffects-asan" \
             "embedded embedded/bin/test_sideeffects" "shared embedded/bin/test_sideeffects-so"; do
        set -- $b
        exe="$OUT/$2"
        [ -x "$exe" ] || { echo "$1: not built"; continue; }
        [ "$exe" -nt "$CAPI/lexiftool.c" ] || { echo "$1: older than capi/lexiftool.c, skipped"; continue; }
        mkdir -p "$tmp/$1"
        if ASAN_OPTIONS=detect_leaks=1 "$exe" "$T" "$tmp/$1" > "$tmp/$1.txt" 2>&1; then
            echo "$1: test_sideeffects $(grep -c '^ok' "$tmp/$1.txt") ok"
        else
            grep -E '^not ok|^#' "$tmp/$1.txt" | sed "s/^/$1: /"
            echo "$1: test_sideeffects FAILED, see $tmp/$1.txt"; status=1
        fi
    done
    # valgrind over test_capi (memcheck: errors and leaks), rock build and
    # shared library
    if valgrind -q --error-exitcode=1 /bin/true > /dev/null 2>&1; then
        for b in "rock rock/test_capi" "shared embedded/bin/test_capi-so"; do
            set -- $b
            [ -x "$OUT/$2" ] || continue
            mkdir -p "$tmp/valgrind-$1"
            if valgrind -q --error-exitcode=99 --leak-check=full \
                    --errors-for-leak-kinds=definite,indirect --log-file="$tmp/valgrind-$1.txt" \
                    "$OUT/$2" "$T" "$tmp/valgrind-$1" 3 > "$tmp/valgrind-$1-test.txt" 2>&1; then
                echo "valgrind: $1 test_capi $(grep -c '^ok' "$tmp/valgrind-$1-test.txt") ok, no errors or leaks"
            else
                echo "valgrind: $1 test_capi FAILED, see $tmp/valgrind-$1.txt and $tmp/valgrind-$1-test.txt"
                status=1
            fi
        done
    else
        echo "valgrind: cannot start here (needs the C library's symbols); ASan/LSan only"
    fi
    exit $status
    ;;

tsan)
    T="$PROJECT/vendor/exiftool/t/images"
    obj="$OUT/tsan"
    src="$obj/src"
    tree="$obj/rocks"
    mkdir -p "$src" "$obj/cpath/lexiftool"
    TSAN="-O1 -g -fsanitize=thread -fno-omit-frame-pointer"
    CC=${CC:-gcc}
    # Lua, as standalone/fetch.sh pins it (the first URL that answers)
    lua_sha=$(awk '/^fetch lua.tar.gz/ { getline; print $1; exit }' "$PROJECT/standalone/fetch.sh")
    lua_urls=$(awk '/^fetch lua.tar.gz/ { while (getline > 0) { u = $1; sub(/\\$/, "", u);
                   if (u ~ /^https:/) print u; if ($0 !~ /\\$/) break } exit }' "$PROJECT/standalone/fetch.sh")
    if [ ! -f "$src/lua/src/liblua.a" ]; then
        rm -rf "$src/lua" "$src/lua.tar.gz"
        for u in $lua_urls; do curl -fsSL --retry 3 -o "$src/lua.tar.gz" "$u" && break; done
        echo "$lua_sha  $src/lua.tar.gz" | sha256sum -c -
        mkdir -p "$src/lua"
        tar xzf "$src/lua.tar.gz" -C "$src/lua" --strip-components=1
        make -C "$src/lua/src" linux ALL=a CC="$CC" MYCFLAGS="$TSAN -fPIC" > "$src/lua-build.log" 2>&1 ||
            { cat "$src/lua-build.log"; exit 1; }
    fi
    LUAINC="$src/lua/src"
    # the Lua C modules lexiftool requires, built by luarocks with TSan
    for r in luafilesystem lpcre carray digest compress.zlib compress.brotli \
             compress.lzma compress.bzip2 cipher.aes cipher.rc4; do
        [ -d "$tree/lib/luarocks/rocks-5.5/$r" ] && continue
        luarocks --lua-version 5.5 --tree "$tree" install --deps-mode none "$r" \
            LUA_INCDIR="$LUAINC" CFLAGS="$TSAN -fPIC" LIBFLAG="-shared -fsanitize=thread" \
            > "$obj/rock-$r.log" 2>&1 || { cat "$obj/rock-$r.log"; exit 1; }
    done
    set -x
    $CC $TSAN -Wall -fPIC -shared -DLEXIFTOOL_LUA_VERSION_NUM=505 -I"$LUAINC" \
        -o "$obj/cpath/lexiftool/sys.so" "$PROJECT/src/lexiftool/sys.c"
    genheader "${CAPI_LUA:-lua5.5}" "$obj/session_lua.h"
    $CC $TSAN -Wall -I"$LUAINC" -I"$obj" -DLEXIFTOOL_PORT_VERSION="\"$(portversion)\"" \
        -c "$CAPI/lexiftool.c" -o "$obj/lexiftool.o"
    for p in test_threads test_capi; do
        # (-Wl,-E: the Lua API for the modules loaded with dlopen)
        $CC $TSAN -Wall -I"$LUAINC" -I"$CAPI" "$CAPI/$p.c" "$obj/lexiftool.o" "$LUAINC/liblua.a" \
            -Wl,-E -ldl -lm -lpthread -o "$obj/$p"
    done
    set +x
    cd "$PROJECT"
    export LUA_PATH_5_5="$PROJECT/src/?.lua;$PROJECT/src/?/init.lua;$tree/share/lua/5.5/?.lua;$tree/share/lua/5.5/?/init.lua"
    export LUA_CPATH_5_5="$obj/cpath/?.so;$tree/lib/lua/5.5/?.so"
    tsan_run tsan "$obj" "$OUT/test-tsan"
    ;;

tsan-embedded)
    obj="$OUT/tsan-embedded"
    if [ ! -d /opt/lx ]; then
        # in a container of the builder image (its gcc and libtsan), with
        # the host's time zone data (the image has none)
        mkdir -p "$obj"
        exec podman run --rm -e LEXIFTOOL_PORT_VERSION="$(portversion)" \
            -e TSAN_THREADS="${TSAN_THREADS:-}" -e TSAN_SHARE="${TSAN_SHARE:-}" \
            -e TSAN_OPTIONS="${TSAN_OPTIONS:-}" \
            -v /usr/share/zoneinfo:/usr/share/zoneinfo:ro -v "$PROJECT:/project" \
            lexiftool-builder-linux sh /project/capi/build-linux.sh tsan-embedded
    fi
    LX=/opt/lx
    SA="$PROJECT/standalone"
    T="$PROJECT/vendor/exiftool/t/images"
    lib="$obj/lib"
    # the dependencies, instrumented: standalone/deps.sh linux-tsan over
    # the sources of standalone/fetch.sh (downloaded and built once; again
    # when either script changes)
    key=$(cat "$SA/fetch.sh" "$SA/deps.sh" | sha256sum | cut -c1-16)
    if [ "$(cat "$lib/key" 2>/dev/null)" != "$key" ]; then
        rm -rf "$lib" "$obj/src"; mkdir -p "$lib" "$obj/src"
        (cd "$obj/src" && sh "$SA/fetch.sh") > "$obj/fetch.log" 2>&1 || { cat "$obj/fetch.log"; exit 1; }
        cp "$obj/src"/*.tar.* /usr/src/
        sh "$SA/deps.sh" linux-tsan > "$obj/deps.log" 2>&1 || { tail -40 "$obj/deps.log"; exit 1; }
        cp "$LX/lib/x86_64-tsan"/*.a "$lib/"
        rm -rf "$obj/src"
        echo "$key" > "$lib/key"
    fi
    o="$obj/obj"
    rm -rf "$o"; mkdir -p "$o"
    CC=gcc
    TSAN="-O1 -g -fsanitize=thread -fno-omit-frame-pointer -Wall"
    : "${LEXIFTOOL_PORT_VERSION:?LEXIFTOOL_PORT_VERSION must be set (passed in by the host part above)}"
    set -x
    "$LX/bin/lua55" "$SA/genembed.lua" "$o" "$PROJECT" 0 zstd "$LX/bin/zstd" "$LEXIFTOOL_PORT_VERSION"
    genheader "$LX/bin/lua55" "$o/session_lua.h"
    # the own objects as for "embedded", with ThreadSanitizer
    $CC $TSAN -I"$LX/include" -I"$o" -I"$CAPI" -DLEXIFTOOL_CAPI_EMBEDDED \
        -DLEXIFTOOL_PORT_VERSION="\"$LEXIFTOOL_PORT_VERSION\"" \
        -c "$CAPI/lexiftool.c" -o "$o/lexiftool.o"
    $CC $TSAN -I"$LX/include" -I"$SA" -I"$o" -DLX_NO_MAIN -c "$SA/main.c" -o "$o/setup.o"
    $CC $TSAN -I"$SA" -c "$o/embedded_index.c" -o "$o/embedded_index.o"
    (cd "$o" && $CC $TSAN -I"$SA" -c "$SA/blob.c" -o "$o/blob.o")
    $CC $TSAN -I"$LX/include" -DLEXIFTOOL_LUA_VERSION_NUM=505 \
        -c "$PROJECT/src/lexiftool/sys.c" -o "$o/sys.o"
    for p in test_threads test_capi; do
        $CC $TSAN -DLEXIFTOOL_TEST_EMBEDDED -I"$CAPI" "$CAPI/$p.c" "$o/lexiftool.o" "$o/setup.o" \
            "$o/embedded_index.o" "$o/blob.o" "$o/sys.o" -L"$lib" -Wl,--start-group \
            -lluamods -lbrotli -lzstd -lpcre2-8 -lz -llzma -lbz2 -llua55 -Wl,--end-group \
            -lm -lpthread -o "$o/$p"
    done
    set +x
    cd "$PROJECT"
    tsan_run tsan-embedded "$o" "$OUT/test-tsan-embedded"
    ;;

test)
    T="$PROJECT/vendor/exiftool/t/images"
    tmp="$OUT/test"; rm -rf "$tmp"; mkdir -p "$tmp"
    cd "$PROJECT"
    [ -n "${LUA_PATH_5_5:-}" ] || rock_paths
    status=0
    # 1. the API tests, every build there is: "BUILD DIR SUFFIX" (rock,
    #    rock with ASan/LSan, embedded static archive, embedded shared
    #    library); test_capi and test_threads (CAPI_THREADS threads,
    #    default 8, file share 2) in each, test_hostlibs in the embedded
    #    ones (ThreadSanitizer: "tsan", "tsan-embedded")
    builds=""
    for b in "rock rock" "rock-asan rock -asan" "embedded embedded/bin" "shared embedded/bin -so"; do
        set -- $b
        exe="$OUT/$2/test_capi${3:-}"
        [ -x "$exe" ] || { echo "$1: not built"; continue; }
        [ "$exe" -nt "$CAPI/lexiftool.c" ] || { echo "$1: older than capi/lexiftool.c, skipped"; continue; }
        builds="$builds $1:$2:${3:-}"
        tests="test_capi test_threads"
        case $1 in embedded|shared) tests="test_capi test_threads test_hostlibs" ;; esac
        for p in $tests; do
            args=""; [ $p = test_threads ] && args="${CAPI_THREADS:-8} 2"
            rm -rf "$tmp/$1-$p"; mkdir -p "$tmp/$1-$p"
            # shellcheck disable=SC2086
            if ASAN_OPTIONS=detect_leaks=1 "$OUT/$2/$p${3:-}" "$T" "$tmp/$1-$p" $args \
                    > "$tmp/$1-$p.txt" 2>&1; then
                echo "$1: $p $(grep -c '^ok' "$tmp/$1-$p.txt") ok"
            else
                grep -E '^not ok' "$tmp/$1-$p.txt" | sed "s/^/$1: /"
                echo "$1: $p FAILED, see $tmp/$1-$p.txt"; status=1
            fi
        done
    done
    # 2. lexiftool_image_info against Perl's Image::ExifTool, capi/example
    #    of every build but ASan (capi/compare-perl.sh)
    examples=""
    for b in $builds; do
        name=${b%%:*} rest=${b#*:}
        [ "$name" = rock-asan ] && continue
        examples="$examples $name=$OUT/${rest%%:*}/example${rest#*:}"
    done
    if [ -n "$examples" ]; then
        # shellcheck disable=SC2086
        sh "$CAPI/compare-perl.sh" "$tmp" $examples || status=1
    fi
    exit $status
    ;;

install)
    # the embedded libraries (built by "embedded") into DESTDIR/PREFIX:
    # include/lexiftool.h, lib/liblexiftool.a, lib/liblexiftool.so.API with
    # the link liblexiftool.so, lib/pkgconfig/lexiftool.pc (prefix=PREFIX)
    src="$OUT/embedded"
    API=$(apiversion)
    for f in include/lexiftool.h lib/liblexiftool.a "lib/liblexiftool.so.$API" lib/pkgconfig/lexiftool.pc; do
        [ -f "$src/$f" ] || { echo "install: $src/$f missing (build-linux.sh embedded)" >&2; exit 1; }
    done
    PREFIX="${PREFIX:-/usr/local}"
    case "$PREFIX" in /*) ;; *) echo "install: PREFIX must be absolute" >&2; exit 1 ;; esac
    dest="${DESTDIR:-}$PREFIX"
    set -x
    mkdir -p "$dest/include" "$dest/lib/pkgconfig"
    cp "$src/include/lexiftool.h" "$dest/include/lexiftool.h"
    cp "$src/lib/liblexiftool.a" "$dest/lib/liblexiftool.a"
    cp "$src/lib/liblexiftool.so.$API" "$dest/lib/liblexiftool.so.$API"
    chmod 644 "$dest/include/lexiftool.h" "$dest/lib/liblexiftool.a"
    chmod 755 "$dest/lib/liblexiftool.so.$API"
    ln -sf "liblexiftool.so.$API" "$dest/lib/liblexiftool.so"
    sed "s|^prefix=.*|prefix=$PREFIX|" "$src/lib/pkgconfig/lexiftool.pc" > "$dest/lib/pkgconfig/lexiftool.pc"
    chmod 644 "$dest/lib/pkgconfig/lexiftool.pc"
    ;;

*)
    echo "build-linux.sh: unknown variant '$VARIANT'" >&2; exit 1 ;;
esac
