#!/bin/sh
# deps.sh PLATFORM - runs during the builder image build (after fetch.sh);
# compiles every third-party dependency of the standalone executable as a
# static library for PLATFORM (windows | linux | macos) and collects the
# license texts from the very same source tarballs.
#
# Result in /opt/lx:
#   bin/              lua55 (NATIVE host interpreter: the embed generator
#                     must dump Lua 5.5.1 bytecode, see genembed.lua)
#                     zstd (NATIVE zstd 1.5.7 command-line tool: the embed
#                     generator compresses every entry with it,
#                     SA_COMPRESS=zstd)
#   include/          lua.h, lauxlib.h, lualib.h, luaconf.h,
#                     brotli/*.h, zstd.h + zstd_errors.h (main.c decodes
#                     the entries)
#   lib/<arch>/       liblua55.a      Lua 5.5 core + standard libraries
#                     libpcre2-8.a    PCRE2 (8-bit, Unicode, no JIT)
#                     libz.a          zlib
#                     libbrotli.a     brotli common + decoder + encoder
#                     libzstd.a       zstd decoder only (no compression,
#                                     no legacy formats, no dictBuilder)
#                     liblzma.a       liblzma (XZ Utils), without threads
#                     libbz2.a        libbz2 (bzip2)
#                     libluamods.a    lfs, carray, lpcre, digest,
#                                     compress.brotli, compress.zlib,
#                                     compress.lzma, compress.bzip2,
#                                     cipher.aes, cipher.rc4
#                     (<arch> = x86_64, plus aarch64 for macos)
#   lib/x86_64-gnu-pic/   linux only: the same archives once more, built
#                     with -fPIC against glibc 2.17, for the shared C API
#                     library (capi/build-linux.sh; a library loaded into
#                     an ordinary glibc process must not carry musl)
#   licenses/         one license text per component (see check-licenses.sh)
#   versions.txt      component versions, for the build log
#
# The lexiftool-specific parts (lexiftool.sys from src/lexiftool/sys.c,
# the Lua modules, including the bundled Geolocation database) are NOT in
# the image: build.sh takes them from the mounted project on every build.

set -eux

PLATFORM="${1:?usage: deps.sh windows|linux|macos}"
PREFIX=/opt/lx

# Module version strings, as LuaRocks would pass them (-D<NAME>_VERSION).
CARRAY_VERSION=0.0.4
LPCRE_VERSION=0.0.1
COMPRESS_VERSION=0.0.1
LUA_DIGEST_VERSION=0.0.1
CIPHER_VERSION=0.0.1

cd /usr/src

# Unpack every tarball into a directory of fixed name (no version in it)
for t in lua pcre2 zlib brotli zstd xz bzip2 luafilesystem carray lpcre compress digest cipher; do
    mkdir "$t"
    tar xf "$t".tar.* -C "$t" --strip-components=1
done

mkdir -p "$PREFIX/include" "$PREFIX/bin" "$PREFIX/licenses"

# ---- Native Lua 5.5 interpreter for the embed generator ---------------------
# MUST run before the cross passes below: all of them drop their *.o into
# lua's src/ directory.
cd /usr/src/lua/src
make -j"$(nproc)" posix >/dev/null
cp lua "$PREFIX/bin/lua55"
make clean
cp lua.h lauxlib.h lualib.h luaconf.h "$PREFIX/include/"

# ---- brotli headers (for the compress.brotli module build below; the library
# itself still uses brotli for JXL/WOFF2, only the blob codec dropped it) --
mkdir -p "$PREFIX/include/brotli"
cp /usr/src/brotli/c/include/brotli/*.h "$PREFIX/include/brotli/"

# ---- Native zstd tool for the embed generator -------------------------------
# The same for SA_COMPRESS=zstd. Without zlib/lzma/lz4 support (not needed,
# and not auto-detected from whatever the image happens to carry); the
# objects are removed again before the cross passes.
cd /usr/src/zstd
make -j"$(nproc)" -C programs zstd HAVE_ZLIB=0 HAVE_LZMA=0 HAVE_LZ4=0 >/dev/null
cp programs/zstd "$PREFIX/bin/zstd"
make clean >/dev/null
cp lib/zstd.h lib/zstd_errors.h "$PREFIX/include/"

# ---- License texts, verbatim from the source tarballs -----------------------
# Lua ships its license only as the notice at the end of lua.h (and in
# doc/readme.html): cut that comment block out unchanged, minus the
# comment frame.
L="$PREFIX/licenses"
sed -n '/^\* Copyright (C) 1994-/,/^\*\*\*\*/p' /usr/src/lua/src/lua.h \
    | sed -e '$d' -e 's/^\* \{0,1\}//' > "$L/lua.txt"
cp /usr/src/pcre2/LICENCE.md          "$L/pcre2.txt"
cp /usr/src/zlib/LICENSE              "$L/zlib.txt"
cp /usr/src/brotli/LICENSE            "$L/brotli.txt"
cp /usr/src/zstd/LICENSE              "$L/zstd.txt"
# xz: COPYING says which license covers which part (liblzma: 0BSD),
# COPYING.0BSD is that license's text
cp /usr/src/xz/COPYING                "$L/xz.txt"
cp /usr/src/xz/COPYING.0BSD           "$L/xz-0bsd.txt"
cp /usr/src/bzip2/LICENSE             "$L/bzip2.txt"
cp /usr/src/luafilesystem/LICENSE     "$L/luafilesystem.txt"
cp /usr/src/carray/LICENSE            "$L/carray.txt"
cp /usr/src/lpcre/LICENSE             "$L/lpcre.txt"
cp /usr/src/compress/LICENSE          "$L/compress.txt"
# digest: LICENSE covers the binding (MIT), LICENSE-THIRD-PARTY its MD5 core
# (PUC-Rio, MIT), its SHA-2 core (Aaron D. Gifford, BSD-3-Clause, whose
# clause 2 asks for the notice in binary distributions) and carray_capi.h
cp /usr/src/digest/LICENSE            "$L/digest.txt"
cp /usr/src/digest/LICENSE-THIRD-PARTY "$L/digest-third-party.txt"
# cipher: LICENSE holds the binding's MIT license and, below it, the notices
# of the code it adapts (BearSSL's AES and GHASH, lua-compat-5.3)
cp /usr/src/cipher/LICENSE            "$L/cipher.txt"

cat > "$PREFIX/versions.txt" <<VERSIONS
Lua           5.5.1
PCRE2         10.47 (8-bit, Unicode, no JIT)
zlib          1.3.2
brotli        1.2.0
zstd          1.5.7 (decoder only)
liblzma       5.8.4 (XZ Utils, without threads)
libbz2        1.0.8
luafilesystem 1.9.0
carray        $CARRAY_VERSION
lpcre         $LPCRE_VERSION
compress      $COMPRESS_VERSION (compress.brotli, compress.zlib, compress.lzma,
              compress.bzip2)
digest        $LUA_DIGEST_VERSION
cipher        $CIPHER_VERSION (cipher.aes, cipher.rc4)
VERSIONS

# ---- Cross pass: everything as static archives for one target ---------------
# cc_each CFLAGS... -- FILES: zig cc cannot compile several sources in one
# -c invocation (it silently produces only the first object), so every
# file is compiled on its own; objects are named after their directory to
# keep the few duplicate base names apart.
build_target() {    # build_target <arch> <lib dir>
    ARCH="$1"
    LIB="$2"
    mkdir -p "$LIB"
    OBJ=/usr/src/obj-$ARCH
    rm -rf "$OBJ"
    mkdir -p "$OBJ/lua" "$OBJ/pcre2" "$OBJ/zlib" "$OBJ/brotli" "$OBJ/lzma" \
        "$OBJ/bz2" "$OBJ/mods"

    # Lua 5.5 core library (no lua.c/luac.c). Unix: LUA_USE_POSIX for
    # io.popen (perl.lua's backticks/system), mkstemp and 64-bit fseeko,
    # but NOT LUA_USE_DLOPEN: a static executable loads no shared modules.
    # Windows: luaconf.h selects LUA_USE_WINDOWS by itself.
    cd /usr/src/lua/src
    for f in lapi lauxlib lbaselib lcode lcorolib lctype ldblib ldebug ldo \
             ldump lfunc lgc linit liolib llex lmathlib lmem loadlib lobject \
             lopcodes loslib lparser lstate lstring lstrlib ltable ltablib \
             ltm lundump lutf8lib lvm lzio; do
        $CC $CFLAGS $LUA_CFLAGS -c "$f.c" -o "$OBJ/lua/$f.o"
    done
    $AR rcs "$LIB/liblua55.a" "$OBJ"/lua/*.o

    # PCRE2, 8-bit, minimal build without its build system (generic
    # headers). Deliberately WITHOUT SUPPORT_JIT: smaller binary and no
    # executable memory at runtime (AV heuristics); lpcre falls back to
    # the interpreter by itself (re:jit() reports false).
    cd /usr/src/pcre2/src
    cp pcre2.h.generic pcre2.h
    cp config.h.generic config.h
    cp pcre2_chartables.c.dist pcre2_chartables.c
    for f in pcre2_auto_possess pcre2_chartables pcre2_chkdint pcre2_compile \
             pcre2_compile_cgroup pcre2_compile_class pcre2_config \
             pcre2_context pcre2_convert pcre2_dfa_match pcre2_error \
             pcre2_extuni pcre2_find_bracket pcre2_jit_compile \
             pcre2_maketables pcre2_match pcre2_match_data pcre2_match_next \
             pcre2_newline pcre2_ord2utf pcre2_pattern_info pcre2_script_run \
             pcre2_serialize pcre2_string_utils pcre2_study pcre2_substitute \
             pcre2_substring pcre2_tables pcre2_ucd pcre2_valid_utf \
             pcre2_xclass; do
        $CC $CFLAGS -DHAVE_CONFIG_H -DPCRE2_CODE_UNIT_WIDTH=8 -DPCRE2_STATIC \
            -DSUPPORT_UNICODE -c "$f.c" -o "$OBJ/pcre2/$f.o"
    done
    $AR rcs "$LIB/libpcre2-8.a" "$OBJ"/pcre2/*.o

    # zlib
    cd /usr/src/zlib
    for f in adler32 compress crc32 deflate gzclose gzlib gzread gzwrite \
             infback inffast inflate inftrees trees uncompr zutil; do
        $CC $CFLAGS $ZLIB_CFLAGS -c "$f.c" -o "$OBJ/zlib/$f.o"
    done
    $AR rcs "$LIB/libz.a" "$OBJ"/zlib/*.o

    # brotli: common + dec + enc in one archive
    cd /usr/src/brotli/c
    for d in common dec enc; do
        for f in "$d"/*.c; do
            b=$(basename "$f" .c)
            $CC $CFLAGS -Iinclude -c "$f" -o "$OBJ/brotli/$d-$b.o"
        done
    done
    $AR rcs "$LIB/libbrotli.a" "$OBJ"/brotli/*.o

    # zstd: the decoder only, through zstd's own lib/Makefile (it compiles
    # one file per call, so zig cc is fine; it adds the XXH_NAMESPACE and
    # the x86-64 Huffman assembly, which is empty on the other targets)
    # (removed by hand, not by "make clean": zig cc leaves a file "-.o"
    # from the Makefile's compiler probes, which trips clean's rm)
    cd /usr/src/zstd/lib
    rm -rf obj libzstd.a ./-.o
    make -j"$(nproc)" libzstd.a CC="$CC" AR="$AR" CFLAGS="$CFLAGS" \
        ZSTD_LIB_COMPRESSION=0 ZSTD_LIB_DEPRECATED=0 ZSTD_LEGACY_SUPPORT=0 \
        ZSTD_LIB_DICTBUILDER=0 >/dev/null
    cp libzstd.a "$LIB/libzstd.a"
    rm -rf obj libzstd.a ./-.o

    # liblzma (XZ Utils), without its build system: the defines its
    # CMakeLists.txt passes for the default feature set (every check,
    # encoder, decoder and match finder, the lzip decoder), but without
    # threads (no MYTHREAD_*: the *_mt coders, outqueue and cputhreads stay
    # out; compress.lzma uses none of them), without the CLMUL/ARM64 CRC
    # code (generic tables) and static (LZMA_API_STATIC: no dllimport on
    # Windows; the module below is compiled with it as well)
    cd /usr/src/xz/src
    LZMA_DEFS="-DHAVE_STDBOOL_H -DHAVE__BOOL -DHAVE_STDINT_H -DHAVE_INTTYPES_H \
        -DHAVE_CHECK_CRC32 -DHAVE_CHECK_CRC64 -DHAVE_CHECK_SHA256 \
        -DHAVE_MF_HC3 -DHAVE_MF_HC4 -DHAVE_MF_BT2 -DHAVE_MF_BT3 -DHAVE_MF_BT4 \
        -DHAVE_ENCODERS -DHAVE_DECODERS -DHAVE_LZIP_DECODER \
        -DTUKLIB_SYMBOL_PREFIX=lzma_ -DTUKLIB_FAST_UNALIGNED_ACCESS \
        -DHAVE_VISIBILITY=0 -DLZMA_API_STATIC"
    for c in LZMA1 LZMA2 X86 POWERPC IA64 ARM ARMTHUMB ARM64 SPARC RISCV DELTA; do
        LZMA_DEFS="$LZMA_DEFS -DHAVE_ENCODER_$c -DHAVE_DECODER_$c"
    done
    LZMA_INC="-Iliblzma/api -Iliblzma/common -Iliblzma/check -Iliblzma/lz \
        -Iliblzma/rangecoder -Iliblzma/lzma -Iliblzma/delta -Iliblzma/simple \
        -Icommon"
    for f in common/tuklib_physmem.c liblzma/*/*.c; do
        case "$f" in
            *_small.c|*_tablegen.c|*/crc_clmul_consts_gen.c|*_mt.c|\
            */outqueue.c|*/hardware_cputhreads.c) continue ;;
        esac
        b=$(echo "$f" | sed -e 's,^liblzma/,,' -e 's,/,-,g' -e 's,\.c$,,')
        $CC $CFLAGS $LZMA_DEFS $LZMA_CFLAGS $LZMA_INC -c "$f" -o "$OBJ/lzma/$b.o"
    done
    $AR rcs "$LIB/liblzma.a" "$OBJ"/lzma/*.o

    # libbz2 (bzip2): the library part of its Makefile's OBJS (bzlib.h
    # defines BZ_EXPORT by itself unless BZ_IMPORT is set, so on Windows
    # it declares functions, not DLL function pointers)
    cd /usr/src/bzip2
    for f in blocksort huffman crctable randtable compress decompress bzlib; do
        $CC $CFLAGS -D_FILE_OFFSET_BITS=64 -c "$f.c" -o "$OBJ/bz2/$f.o"
    done
    $AR rcs "$LIB/libbz2.a" "$OBJ"/bz2/*.o

    # Lua C modules
    INC="-I$PREFIX/include"
    cd /usr/src
    $CC $CFLAGS $INC -c luafilesystem/src/lfs.c -o "$OBJ/mods/lfs.o"
    for f in main carray carray_capi_impl carray_compat; do
        $CC $CFLAGS $INC -DCARRAY_VERSION=$CARRAY_VERSION \
            -c "carray/src/$f.c" -o "$OBJ/mods/carray-$f.o"
    done
    for f in main lpcre lpcre_compat; do
        $CC $CFLAGS $INC -I/usr/src/pcre2/src -DPCRE2_CODE_UNIT_WIDTH=8 \
            -DPCRE2_STATIC -DLPCRE_VERSION=$LPCRE_VERSION \
            -c "lpcre/src/$f.c" -o "$OBJ/mods/lpcre-$f.o"
    done
    # compress.brotli and compress.zlib (lua-compress): both modules'
    # *_compat.c compile the same common/compat-5.3.c with the same symbol
    # prefix, so it goes into the archive once (as brotli_compat.c)
    for f in main brotli brotli_compat; do
        $CC $CFLAGS $INC -I/usr/src/brotli/c/include \
            -DCOMPRESS_BROTLI_VERSION=$COMPRESS_VERSION \
            -c "compress/src/brotli/$f.c" -o "$OBJ/mods/compress-brotli-$f.o"
    done
    for f in main zlibmod; do
        $CC $CFLAGS $INC -I/usr/src/zlib \
            -DCOMPRESS_ZLIB_VERSION=$COMPRESS_VERSION \
            -c "compress/src/zlib/$f.c" -o "$OBJ/mods/compress-zlib-$f.o"
    done
    # compress.lzma and compress.bzip2: the same, without their *_compat.c
    for f in main lzmamod; do
        $CC $CFLAGS $INC -I/usr/src/xz/src/liblzma/api -DLZMA_API_STATIC \
            -DCOMPRESS_LZMA_VERSION=$COMPRESS_VERSION \
            -c "compress/src/lzma/$f.c" -o "$OBJ/mods/compress-lzma-$f.o"
    done
    for f in main bzip2mod; do
        $CC $CFLAGS $INC -I/usr/src/bzip2 \
            -DCOMPRESS_BZIP2_VERSION=$COMPRESS_VERSION \
            -c "compress/src/bzip2/$f.c" -o "$OBJ/mods/compress-bzip2-$f.o"
    done
    # digest: one translation unit (digestlib.c includes md5.c and sha2.c);
    # carray_capi.h is in the source directory
    $CC $CFLAGS $INC -I/usr/src/digest -DLUA_DIGEST_VERSION=$LUA_DIGEST_VERSION \
        -c digest/digestlib.c -o "$OBJ/mods/digest.o"
    # cipher.aes and cipher.rc4 (lua-cipher): both modules' *_compat.c
    # compile the same common/compat-5.3.c with the same symbol prefix, so
    # it goes into the archive once (as aes_compat.c); carray_capi.h is in
    # common/
    for f in main aesmod aes_ct64 ghash aes_compat; do
        $CC $CFLAGS $INC -DCIPHER_AES_VERSION=$CIPHER_VERSION \
            -c "cipher/src/aes/$f.c" -o "$OBJ/mods/cipher-aes-$f.o"
    done
    for f in main rc4mod; do
        $CC $CFLAGS $INC -DCIPHER_RC4_VERSION=$CIPHER_VERSION \
            -c "cipher/src/rc4/$f.c" -o "$OBJ/mods/cipher-rc4-$f.o"
    done
    $AR rcs "$LIB/libluamods.a" "$OBJ"/mods/*.o

    rm -rf "$OBJ"
    echo "deps: done with $PLATFORM/$ARCH"
}

# Full -O2 everywhere (no -Os: performance first). The section flags only
# enable dead-code elimination at link time (-Wl,--gc-sections on Linux,
# -dead_strip semantics on macOS).
case "$PLATFORM" in
    windows)
        CC=x86_64-w64-mingw32-gcc
        AR=x86_64-w64-mingw32-ar
        CFLAGS="-O2 -Wall"
        LUA_CFLAGS=""
        ZLIB_CFLAGS=""
        LZMA_CFLAGS=""
        build_target x86_64 "$PREFIX/lib/x86_64"
        ;;
    linux)
        CC="zig cc -target x86_64-linux-musl"
        AR=ar
        CFLAGS="-O2 -Wall -ffunction-sections -fdata-sections"
        LUA_CFLAGS="-DLUA_USE_POSIX"
        ZLIB_CFLAGS="-DHAVE_UNISTD_H"
        LZMA_CFLAGS="-DTUKLIB_PHYSMEM_SYSCONF"
        build_target x86_64 "$PREFIX/lib/x86_64"
        # position-independent, glibc: for liblexiftool.so (capi/)
        CC="zig cc -target x86_64-linux-gnu.2.17"
        CFLAGS="-O2 -Wall -fPIC -ffunction-sections -fdata-sections"
        build_target x86_64 "$PREFIX/lib/x86_64-gnu-pic"
        ;;
    macos)
        AR=llvm-ar-14
        CFLAGS="-O2 -Wall -ffunction-sections -fdata-sections"
        LUA_CFLAGS="-DLUA_USE_POSIX"
        ZLIB_CFLAGS="-DHAVE_UNISTD_H"
        LZMA_CFLAGS="-DTUKLIB_PHYSMEM_SYSCTL"
        CC="zig cc -target x86_64-macos-none -mmacosx-version-min=11.0"
        build_target x86_64 "$PREFIX/lib/x86_64"
        CC="zig cc -target aarch64-macos-none -mmacosx-version-min=11.0"
        build_target aarch64 "$PREFIX/lib/aarch64"
        ;;
    *)
        echo "deps: unknown platform '$PLATFORM'" >&2
        exit 1
        ;;
esac

echo "deps: done"
ls -l "$PREFIX"/lib/* "$PREFIX/licenses"
