#!/bin/sh
# build.sh PLATFORM - runs INSIDE the builder container (make windows |
# macos | linux); builds the standalone executable and its release zip.
#
# The image provides /opt/lx (deps.sh): static libraries, Lua, brotli and
# zstd headers, the native lua55 and zstd and the license texts. The
# project is mounted at /project; from it come the Lua modules (including
# the bundled Geolocation database) and src/lexiftool/sys.c.
#
# Output:
#   dist-<platform>/lexiftool[.exe]               the executable
#   dist-<platform>/lexiftool-<platform>-<version>.zip
#       release archive: the executable, LICENSE, LICENSE-THIRD-PARTY and
#       licenses/ in a folder named like the zip without the .zip
#       extension; <version> is the bare tag on an exact, clean release,
#       the full identity otherwise (see below)
#   dist-<platform>/identity.txt                  LEXIFTOOL_IDENTITY, verbatim
#       (written for callers that need the identity without recomputing
#       git describe themselves)
#   build/standalone/<platform>/                  intermediate files
#
# Reproducible: same sources + same image -> byte-identical executable and
# zip. SOURCE_DATE_EPOCH (the Makefile passes the last commit time) goes
# into the PE timestamp and the zip entry times; ELF and Mach-O carry no
# wall-clock time.

set -eu

PLATFORM="${1:?usage: build.sh windows|linux|macos}"
PROJECT="${PROJECT:-/project}"
STRIP_BYTECODE="${STRIP_BYTECODE:-0}"
# codec of the embedded entries: zstd | 0 (none); the default is the
# Makefile's SA_COMPRESS
COMPRESS="${COMPRESS:?COMPRESS must be set (the Makefile does)}"
: "${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH must be set (the Makefile does)}"
export SOURCE_DATE_EPOCH
# the build's git-describe identity (the Makefile computes it on the host;
# the container has no git), embedded as _G.LEXIFTOOL_PORT_VERSION
: "${LEXIFTOOL_IDENTITY:?LEXIFTOOL_IDENTITY must be set (the Makefile does)}"
LX=/opt/lx
SA="$PROJECT/standalone"
obj="$PROJECT/build/standalone/$PLATFORM"
out="$PROJECT/dist-$PLATFORM"

rm -rf "$obj" "$out"
mkdir -p "$obj" "$out"
# keep the output directory out of git status without touching .gitignore
echo '*' > "$out/.gitignore"

set -x

# 1. Embed the Lua modules (bytecode) and the data files, each entry
#    zstd-compressed unless COMPRESS=0
case "$COMPRESS" in
    zstd)   CODEC=zstd; TOOL="$LX/bin/zstd" ;;
    0|none) CODEC=none;   TOOL="" ;;
    *) echo "build: COMPRESS must be zstd or 0 (got '$COMPRESS')" >&2; exit 1 ;;
esac
"$LX/bin/lua55" "$SA/genembed.lua" "$obj" "$PROJECT" "$STRIP_BYTECODE" "$CODEC" "$TOOL" "$LEXIFTOOL_IDENTITY"
echo "$LEXIFTOOL_IDENTITY" > "$out/identity.txt"

# 2. Compile and link
#    compile <cc...> -- per target: main.c, embedded_index.c, blob.c (from
#    the blob's directory, for .incbin) and the port's own sys.c
compile() {     # compile <suffix> <cc + flags...>
    sfx="$1"; shift
    "$@" -I"$LX/include" -I"$SA" -I"$obj" -c "$SA/main.c" -o "$obj/main$sfx.o"
    "$@" -I"$SA" -c "$obj/embedded_index.c" -o "$obj/embedded_index$sfx.o"
    (cd "$obj" && "$@" -I"$SA" -c "$SA/blob.c" -o "$obj/blob$sfx.o")
    "$@" -I"$LX/include" -DLEXIFTOOL_LUA_VERSION_NUM=505 \
        -c "$PROJECT/src/lexiftool/sys.c" -o "$obj/sys$sfx.o"
}
OBJS() { echo "$obj/main$1.o $obj/embedded_index$1.o $obj/blob$1.o $obj/sys$1.o"; }
# libzstd is only pulled in by a zstd build (main.c references it then)
LIBS="-lluamods -lbrotli -lzstd -lpcre2-8 -lz -llua55"

case "$PLATFORM" in
windows)
    EXE=lexiftool.exe
    CC=x86_64-w64-mingw32-gcc
    compile "" $CC -O2 -Wall
    $CC -static -s $(OBJS "") -L"$LX/lib/x86_64" \
        -Wl,--start-group $LIBS -Wl,--end-group -o "$out/$EXE"
    # only the system DLLs every Windows has
    x86_64-w64-mingw32-objdump -p "$out/$EXE" | grep 'DLL Name' | tee "$obj/dlls.txt"
    if grep -viE 'DLL Name: (KERNEL32|msvcrt)\.dll' "$obj/dlls.txt"; then
        echo "build: unexpected DLL import" >&2; exit 1
    fi
    ;;
linux)
    EXE=lexiftool
    # dynamic against glibc 2.17 (libc, libm, libpthread), the rest static from the
    # PIC archives: at run time the system's glibc reads the system's
    # locale data (strftime names with -d), which a static musl cannot
    CC="zig cc -target x86_64-linux-gnu.2.17"
    compile "" $CC -O2 -Wall -fPIC -ffunction-sections -fdata-sections
    $CC -s -Wl,--gc-sections $(OBJS "") -L"$LX/lib/x86_64-gnu-pic" \
        -Wl,--start-group $LIBS -Wl,--end-group -lm -o "$out/$EXE"
    # only libc, libm and libpthread from the system. libpthread comes in
    # because glibc 2.17 exports its cancellation points (read, write,
    # waitpid, ...) from libpthread as well and the linker binds some of
    # them there; every glibc ships libpthread.so.0 (since 2.34 as an
    # empty compatibility library whose symbols live in libc), so it adds
    # no requirement beyond glibc itself
    readelf -d "$out/$EXE" | grep NEEDED | tee "$obj/needed.txt"
    if grep -vE 'Shared library: \[(libc\.so\.6|libm\.so\.6|libpthread\.so\.0)\]' "$obj/needed.txt"; then
        echo "build: unexpected shared library" >&2; exit 1
    fi
    # no symbol version newer than the GLIBC_2.17 baseline
    if objdump -T "$out/$EXE" | grep -E 'GLIBC_2\.(1[89]|[2-9][0-9])'; then
        echo "build: symbol newer than GLIBC_2.17" >&2; exit 1
    fi
    file "$out/$EXE" | tee /dev/stderr | grep -q 'dynamically linked'
    "$out/$EXE" -ver
    ;;
macos)
    EXE=lexiftool
    for ARCH in x86_64 aarch64; do
        CC="zig cc -target $ARCH-macos-none -mmacosx-version-min=11.0"
        compile "-$ARCH" $CC -O2 -Wall -ffunction-sections -fdata-sections
        # dynamic against libSystem only (always present), the rest static
        $CC -s -Wl,--gc-sections $(OBJS "-$ARCH") -L"$LX/lib/$ARCH" \
            $LIBS -o "$obj/$EXE-$ARCH"
    done
    # Apple Silicon kills unsigned arm64 binaries; lld signs ad hoc
    llvm-objdump-14 --macho --private-headers "$obj/$EXE-aarch64" | grep -q LC_CODE_SIGNATURE
    llvm-lipo-14 -create "$obj/$EXE-x86_64" "$obj/$EXE-aarch64" -o "$out/$EXE"
    llvm-lipo-14 -info "$out/$EXE"
    file "$out/$EXE"
    ;;
*)
    echo "build: unknown platform '$PLATFORM'" >&2; exit 1 ;;
esac

# 3. Release zip: <zip name without .zip>/{executable, LICENSE,
#    LICENSE-THIRD-PARTY, licenses/} -- the folder is named like the zip file, so unzipping
#    always yields one self-describing directory.
#    <version> in the zip name: the bare tag on an exact, clean release
#    (git describe --long always appends "-0-g<hash>" even then), the full
#    identity otherwise -- including a "-dirty" suffix.
version=$LEXIFTOOL_IDENTITY
case "$version" in
    *-0-g*-dirty) ;;
    *-0-g*)       version=${version%-0-g*} ;;
esac
# a tag may contain a slash (v1.2/foo); keep it out of file names
version=$(printf '%s' "$version" | tr '/' '-')
zipname="lexiftool-$PLATFORM-$version.zip"
folder=${zipname%.zip}
stage="$obj/stage"
mkdir -p "$stage/$folder/licenses"
cp "$out/$EXE" "$stage/$folder/"
cp "$PROJECT/LICENSE" "$PROJECT/LICENSE-THIRD-PARTY" "$stage/$folder/"
cp "$LX"/licenses/* "$stage/$folder/licenses/"
sh "$SA/check-licenses.sh" "$stage/$folder"
# deterministic: fixed modes and times, sorted entries, no extra fields
find "$stage" -type d -exec chmod 755 {} +
find "$stage" -type f -exec chmod 644 {} +
[ "$PLATFORM" = windows ] || chmod 755 "$stage/$folder/$EXE"
find "$stage" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
(cd "$stage" && find "$folder" -type f | LC_ALL=C sort | TZ=UTC zip -X -D -9 -q "$out/$zipname" -@)

set +x
ls -l "$out"
sha256sum "$out/$EXE" "$out/$zipname"
echo "==> $out/$EXE"
echo "==> $out/$zipname"
