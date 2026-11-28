#!/bin/sh
# capi/test-package.sh ZIP|FOLDER - links test_capi and example against
# a release zip of capi/package.sh (unpacked into capi/build/test-package/
# first, or an unpacked folder) as a user would, with the platform's own
# compiler, and runs test_capi over vendor/exiftool/t/images and example
# over one image: the proof that the published files work. Any failure
# fails.
#
#   Linux    cc (CC, default cc): against lib/liblexiftool.a (static) and
#            through the symbolic link lib/liblexiftool.so (-llexiftool,
#            rpath into the folder); ldd must name the folder's library
#   macOS    cc -arch x86_64 -arch arm64, against the archive and the
#            dylib (rpath into the folder); run natively and, where Rosetta
#            runs, as x86_64 (arch -x86_64)
#   Windows  Git Bash with MSVC in the environment (cl): against
#            lib/lexiftool.lib, bin/lexiftool.dll copied next to the
#            programs (the MinGW libraries: build-windows.sh embedded links
#            its test programs against the very same files, `make
#            capi-test-wine`)
#
# Run from anywhere; paths are taken from the script's location.

set -eu

ARG="${1:?usage: test-package.sh ZIP|FOLDER}"
CAPI="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$CAPI/.." && pwd)"
work="$CAPI/build/test-package"
rm -rf "$work"; mkdir -p "$work/out"

case "$ARG" in
*.zip)
    if command -v unzip > /dev/null 2>&1; then
        unzip -q "$ARG" -d "$work"
    else
        # (Git Bash has no unzip; PowerShell's Expand-Archive does it)
        powershell -NoProfile -Command \
            "Expand-Archive -Path '$(cygpath -w "$ARG")' -DestinationPath '$(cygpath -w "$work")'"
    fi
    pkg=$(ls -d "$work"/lexiftool-capi-*/) ;;
*)  pkg=$ARG ;;
esac
pkg=$(cd "$pkg" && pwd)
echo "package: $pkg"
# the sources: test_capi.c with its test_platform.h and example.c, in a
# directory of their own, so that "lexiftool.h" is the package's
src="$work/src"
mkdir -p "$src"
cp "$CAPI/test_capi.c" "$CAPI/test_platform.h" "$pkg/example.c" "$src/"
cmp "$CAPI/lexiftool.h" "$pkg/include/lexiftool.h"
T="$PROJECT/vendor/exiftool/t/images"
IMG="$T/Canon.jpg"
status=0

# a path as the programs take it: Windows programs from Git Bash a
# mixed one (D:/a/...), elsewhere the path itself
nat() {
    if command -v cygpath > /dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi
}

# run NAME [PREFIX...]: test_capi (bin/NAME-test_capi) and example
# (bin/NAME-example) of one build, PREFIX before them (arch -x86_64)
run() {
    name=$1; shift
    mkdir -p "$work/out/$name"
    if "$@" "$work/bin/$name-test_capi$EXE" "$(nat "$T")" "$(nat "$work/out/$name")" \
            > "$work/out/$name.txt" 2>&1; then
        echo "$name: test_capi $(grep -c '^ok' "$work/out/$name.txt") ok"
    else
        grep -E '^not ok|^#' "$work/out/$name.txt" | sed "s/^/$name: /"
        echo "$name: test_capi FAILED, see $work/out/$name.txt"; status=1
    fi
    if "$@" "$work/bin/$name-example$EXE" "$(nat "$IMG")" > "$work/out/$name-example.txt" 2>&1 &&
            grep -q '^Make	' "$work/out/$name-example.txt"; then
        echo "$name: example $(grep -c '	' "$work/out/$name-example.txt") tags"
    else
        echo "$name: example FAILED, see $work/out/$name-example.txt"; status=1
    fi
}

mkdir -p "$work/bin"
EXE=""
case "$(uname -s)" in
Linux)
    CC=${CC:-cc}
    set -x
    $CC -O2 -Wall -I"$pkg/include" -DLEXIFTOOL_TEST_EMBEDDED "$src/test_capi.c" \
        "$pkg/lib/liblexiftool.a" -lm -lpthread -o "$work/bin/static-test_capi"
    $CC -O2 -Wall -I"$pkg/include" "$src/example.c" \
        "$pkg/lib/liblexiftool.a" -lm -lpthread -o "$work/bin/static-example"
    $CC -O2 -Wall -I"$pkg/include" -DLEXIFTOOL_TEST_EMBEDDED "$src/test_capi.c" \
        -L"$pkg/lib" -llexiftool -Wl,-rpath,"$pkg/lib" -o "$work/bin/shared-test_capi"
    $CC -O2 -Wall -I"$pkg/include" "$src/example.c" \
        -L"$pkg/lib" -llexiftool -Wl,-rpath,"$pkg/lib" -o "$work/bin/shared-example"
    set +x
    if ldd "$work/bin/static-test_capi" | grep liblexiftool; then
        echo "static-test_capi needs a liblexiftool.so" >&2; status=1
    fi
    so=$(ldd "$work/bin/shared-test_capi" | awk '/liblexiftool/ { print $3 }')
    echo "shared-test_capi: liblexiftool from $so"
    [ "$so" = "$pkg/lib/liblexiftool.so.$(sed -n 's/^#define LEXIFTOOL_API_VERSION \([0-9]*\).*/\1/p' "$pkg/include/lexiftool.h")" ] ||
        { echo "shared-test_capi does not use the package's library" >&2; status=1; }
    run static
    run shared
    ;;
Darwin)
    CC=${CC:-cc}
    API=$(sed -n 's/^#define LEXIFTOOL_API_VERSION \([0-9]*\).*/\1/p' "$pkg/include/lexiftool.h")
    set -x
    for p in test_capi example; do
        def=""; [ $p = test_capi ] && def=-DLEXIFTOOL_TEST_EMBEDDED
        $CC -arch x86_64 -arch arm64 -O2 -Wall -I"$pkg/include" $def "$src/$p.c" \
            "$pkg/lib/liblexiftool.a" -o "$work/bin/static-$p"
        $CC -arch x86_64 -arch arm64 -O2 -Wall -I"$pkg/include" $def "$src/$p.c" \
            -L"$pkg/lib" -llexiftool -Wl,-rpath,"$pkg/lib" -o "$work/bin/shared-$p"
    done
    set +x
    if otool -L "$work/bin/static-test_capi" | grep liblexiftool; then
        echo "static-test_capi needs a liblexiftool dylib" >&2; status=1
    fi
    otool -L "$work/bin/shared-test_capi" | grep -q "@rpath/liblexiftool.$API.dylib" ||
        { echo "shared-test_capi does not use liblexiftool.$API.dylib" >&2; status=1; }
    lipo -info "$pkg/lib/liblexiftool.a" "$pkg/lib/liblexiftool.$API.dylib"
    otool -L "$pkg/lib/liblexiftool.$API.dylib"
    run static
    run shared
    if arch -x86_64 /usr/bin/true 2> /dev/null; then
        for b in static shared; do
            for p in test_capi example; do cp "$work/bin/$b-$p" "$work/bin/$b-x86_64-$p"; done
            run "$b-x86_64" arch -x86_64
        done
    else
        echo "x86_64: no Rosetta here, not run"
    fi
    ;;
MINGW*|MSYS*|CYGWIN*)
    # cl's options with "-", paths as cl takes them (build-windows.sh)
    w() { cygpath -w "$1"; }
    EXE=.exe
    cp "$pkg/bin/lexiftool.dll" "$work/bin/"
    set -x
    for p in test_capi example; do
        def=""; [ $p = test_capi ] && def=-DLEXIFTOOL_TEST_EMBEDDED
        cl -nologo -O2 -W3 -I"$(w "$pkg/include")" $def "$(w "$src/$p.c")" \
            "$(w "$pkg/lib/lexiftool.lib")" -Fo"$(w "$work/bin/$p.obj")" -Fe"$(w "$work/bin/msvc-$p.exe")"
    done
    set +x
    run msvc
    ;;
*)
    echo "test-package.sh: unknown system $(uname -s)" >&2; exit 1 ;;
esac
exit $status
