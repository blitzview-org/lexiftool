#!/bin/sh
# check-licenses.sh DIR - fails unless the release folder DIR carries the
# license text of every component linked or embedded into the standalone
# executable. Run by build.sh on the staged zip contents.
#
#   component      file in DIR                 source of the text
#   lexiftool      LICENSE                     this repository
#   Image::ExifTool, GeoNames (Geolocation.dat), all components
#                  LICENSE-THIRD-PARTY         this repository
#   Lua            licenses/lua.txt            notice in lua.h (Lua tarball)
#   PCRE2          licenses/pcre2.txt          LICENCE.md (PCRE2 tarball)
#   zlib           licenses/zlib.txt           LICENSE (zlib tarball)
#   brotli         licenses/brotli.txt         LICENSE (brotli tarball)
#   zstd           licenses/zstd.txt           LICENSE (zstd tarball; BSD,
#                                              of its BSD/GPLv2 dual license)
#   luafilesystem  licenses/luafilesystem.txt  LICENSE
#   lua-zlib       licenses/lua-zlib.txt       LICENCE
#   carray         licenses/carray.txt         LICENSE
#   lpcre          licenses/lpcre.txt          LICENSE
#   lbrotli        licenses/lbrotli.txt        LICENSE
#   digest         licenses/digest.txt         LICENSE (the Lua binding)
#                  licenses/digest-third-party.txt
#                                              LICENSE-THIRD-PARTY (its MD5
#                                              core, PUC-Rio; its SHA-2 core
#                                              by Aaron D. Gifford;
#                                              carray_capi.h)

set -eu

DIR="${1:?usage: check-licenses.sh DIR}"
fail=0

need() {    # need <file> <component> <text that must occur in it>
    if [ ! -s "$DIR/$1" ]; then
        echo "check-licenses: MISSING $1 ($2)" >&2; fail=1
    elif ! grep -qi -- "$3" "$DIR/$1"; then
        echo "check-licenses: $1 ($2) does not mention '$3'" >&2; fail=1
    else
        printf '  %-28s %s\n' "$1" "$2"
    fi
}

need LICENSE                    lexiftool       'Artistic License'
need LICENSE-THIRD-PARTY        Image::ExifTool 'Image::ExifTool'
need LICENSE-THIRD-PARTY        GeoNames        'geonames.org'
need licenses/lua.txt           Lua             'Lua.org, PUC-Rio'
need licenses/pcre2.txt         PCRE2           'PCRE2'
need licenses/zlib.txt          zlib            'Jean-loup Gailly'
need licenses/brotli.txt        brotli          'Permission is hereby granted'
need licenses/zstd.txt          zstd            'Redistribution and use in source and binary forms'
need licenses/luafilesystem.txt luafilesystem   'Permission is hereby granted'
need licenses/lua-zlib.txt      lua-zlib        'Permission is hereby granted'
need licenses/carray.txt        carray          'Permission is hereby granted'
need licenses/lpcre.txt         lpcre           'Permission is hereby granted'
need licenses/lbrotli.txt       lbrotli         'Permission is hereby granted'
need licenses/digest.txt        digest          'Permission is hereby granted'
need licenses/digest-third-party.txt digest     'PUC-Rio'
need licenses/digest-third-party.txt digest     'Aaron D. Gifford'
need licenses/digest-third-party.txt digest     'lua-carray-capi'

# nothing in licenses/ that the list above does not account for
for f in "$DIR"/licenses/*; do
    case "$(basename "$f")" in
        lua.txt|pcre2.txt|zlib.txt|brotli.txt|zstd.txt|luafilesystem.txt|\
        lua-zlib.txt|carray.txt|lpcre.txt|lbrotli.txt|digest.txt|\
        digest-third-party.txt) ;;
        *) echo "check-licenses: unlisted file licenses/$(basename "$f")" >&2; fail=1 ;;
    esac
done

[ "$fail" = 0 ] || { echo "check-licenses: FAILED" >&2; exit 1; }
echo "check-licenses: all license texts present"
