#!/bin/sh
# smoke.sh CMD... - smoke test of a built standalone executable, run from
# the repository root (needs the vendor/exiftool submodule for its test
# images). CMD is the executable, or a runner plus the executable:
#
#   sh standalone/smoke.sh dist-linux/lexiftool
#   sh standalone/smoke.sh wine dist-windows/lexiftool.exe
#
# With SMOKE_REF set to a second command (e.g. SMOKE_REF=./lexiftool, the
# launcher), the -j output must equal that command's, apart from the file
# system tags that depend on the platform (dates' time zone notation,
# permissions).

set -eu

IMG=vendor/exiftool/t/images
[ -f "$IMG/Canon.jpg" ] || { echo "smoke: $IMG missing (git submodule update --init)" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

run() { "$@" | tr -d '\r'; }    # (wine: CRLF from the console)
check() {   # check <file> <fixed string>
    grep -qF -- "$2" "$1" || { echo "smoke: '$2' not found in output:" >&2; cat "$1" >&2; exit 1; }
}

echo "== -ver -v"
run "$@" -ver -v > "$tmp/ver"
cat "$tmp/ver"
check "$tmp/ver" "Lua 5.5.1, bytecode yes"
check "$tmp/ver" "lbrotli (libbrotli"
check "$tmp/ver" "lua-zlib (zlib"
check "$tmp/ver" "Digest::MD5                  digest "
check "$tmp/ver" "Digest::SHA                  digest "

echo "== -j $IMG/Canon.jpg"
run "$@" -j "$IMG/Canon.jpg" > "$tmp/canon.json"
check "$tmp/canon.json" '"Model": "Canon EOS DIGITAL REBEL"'
echo "ok ($(wc -l < "$tmp/canon.json") lines)"
if [ -n "${SMOKE_REF:-}" ]; then
    $SMOKE_REF -j "$IMG/Canon.jpg" | tr -d '\r' > "$tmp/ref.json"
    filter() { grep -vE '"File(ModifyDate|AccessDate|InodeChangeDate|CreateDate|Permissions)"' "$1"; }
    filter "$tmp/canon.json" > "$tmp/a"
    filter "$tmp/ref.json" > "$tmp/b"
    diff "$tmp/b" "$tmp/a"
    echo "ok (identical to $SMOKE_REF)"
fi

echo "== -listgeo (embedded Geolocation.dat)"
run "$@" -listgeo > "$tmp/geo"
head -3 "$tmp/geo"
check "$tmp/geo" "Geolocation database:"
n=$(wc -l < "$tmp/geo")
[ "$n" -gt 100000 ] || { echo "smoke: only $n lines from -listgeo" >&2; exit 1; }
echo "ok ($n lines)"
run "$@" -api geolocation=1 -GeolocationCity -s "$IMG/GPS.jpg" > "$tmp/city"
cat "$tmp/city"
check "$tmp/city" "Prudhoe"

echo "== -stay_open"
printf -- '-ver\n-execute\n-s\n-Model\n%s\n-execute\n-stay_open\nFalse\n' "$IMG/Canon.jpg" \
    | run "$@" -stay_open True -@ - > "$tmp/stay"
cat "$tmp/stay"
check "$tmp/stay" "{ready}"
check "$tmp/stay" "Canon EOS DIGITAL REBEL"

echo "smoke: all passed"
