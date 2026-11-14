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
#   liblzma        licenses/xz.txt             COPYING (XZ Utils tarball:
#                                              liblzma is 0BSD)
#                  licenses/xz-0bsd.txt        COPYING.0BSD
#   libbz2         licenses/bzip2.txt          LICENSE (bzip2 tarball)
#   luafilesystem  licenses/luafilesystem.txt  LICENSE
#   carray         licenses/carray.txt         LICENSE
#   lpcre          licenses/lpcre.txt          LICENSE
#   compress       licenses/compress.txt       LICENSE (lua-compress:
#                                              compress.brotli, compress.zlib,
#                                              compress.lzma, compress.bzip2)
#   digest         licenses/digest.txt         LICENSE (the Lua binding)
#                  licenses/digest-third-party.txt
#                                              LICENSE-THIRD-PARTY (its MD5
#                                              core, PUC-Rio; its SHA-2 core
#                                              by Aaron D. Gifford;
#                                              carray_capi.h)
#   cipher         licenses/cipher.txt         LICENSE (lua-cipher:
#                                              cipher.aes, cipher.rc4; with
#                                              the notices of BearSSL's AES
#                                              and GHASH and lua-compat-5.3)

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
need licenses/xz.txt            liblzma         'liblzma is under the BSD Zero Clause License'
need licenses/xz-0bsd.txt       liblzma         'Permission to use, copy, modify, and/or distribute'
need licenses/bzip2.txt         libbz2          'Julian R Seward'
need licenses/luafilesystem.txt luafilesystem   'Permission is hereby granted'
need licenses/carray.txt        carray          'Permission is hereby granted'
need licenses/lpcre.txt         lpcre           'Permission is hereby granted'
need licenses/compress.txt      compress        'Permission is hereby granted'
need licenses/digest.txt        digest          'Permission is hereby granted'
need licenses/digest-third-party.txt digest     'PUC-Rio'
need licenses/digest-third-party.txt digest     'Aaron D. Gifford'
need licenses/digest-third-party.txt digest     'lua-carray-capi'
need licenses/cipher.txt        cipher          'Permission is hereby granted'
need licenses/cipher.txt        cipher          'Thomas Pornin'

# nothing in licenses/ that the list above does not account for
for f in "$DIR"/licenses/*; do
    case "$(basename "$f")" in
        lua.txt|pcre2.txt|zlib.txt|brotli.txt|zstd.txt|xz.txt|xz-0bsd.txt|\
        bzip2.txt|luafilesystem.txt|\
        carray.txt|lpcre.txt|compress.txt|digest.txt|\
        digest-third-party.txt|cipher.txt) ;;
        *) echo "check-licenses: unlisted file licenses/$(basename "$f")" >&2; fail=1 ;;
    esac
done

[ "$fail" = 0 ] || { echo "check-licenses: FAILED" >&2; exit 1; }
echo "check-licenses: all license texts present"
