#!/bin/sh
# fetch.sh - runs during every builder image build (Dockerfile.*):
# downloads the third-party sources into the current directory and
# verifies each one against its pinned SHA256. This file is the ONLY
# place where versions are pinned; all three images use it, so the
# Windows, macOS and Linux executables are built from identical sources.
#
# The tarball names written here are what deps.sh unpacks.

set -eu

fetch() {   # fetch <local name> <sha256> <url>
    curl -fsSL --retry 3 -o "$1" "$3"
    echo "$2  $1" | sha256sum -c -
}

# ---- C libraries ------------------------------------------------------------
fetch lua.tar.gz \
    1c4b4068d67061f2a2231ad2b5422e77acea1487ea9890f6320af614f4373dce \
    https://www.lua.org/ftp/lua-5.5.1.tar.gz
fetch pcre2.tar.bz2 \
    47fe8c99461250d42f89e6e8fdaeba9da057855d06eb7fc08d9ca03fd08d7bc7 \
    https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.47/pcre2-10.47.tar.bz2
fetch zlib.tar.gz \
    bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16 \
    https://github.com/madler/zlib/releases/download/v1.3.2/zlib-1.3.2.tar.gz
fetch brotli.tar.gz \
    816c96e8e8f193b40151dad7e8ff37b1221d019dbcb9c35cd3fadbfe6477dfec \
    https://github.com/google/brotli/archive/refs/tags/v1.2.0.tar.gz
fetch zstd.tar.gz \
    eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3 \
    https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz

# ---- Lua C modules (the same versions the LuaRocks install uses) -------------
fetch luafilesystem.tar.gz \
    1142c1876e999b3e28d1c236bf21ffd9b023018e336ac25120fb5373aade1450 \
    https://github.com/keplerproject/luafilesystem/archive/refs/tags/v1_9_0.tar.gz
fetch lua-zlib.tar.gz \
    c2a59e96d2df6e192cf0bf6f19b312977ce24020c4072426c0cf8b6594767308 \
    https://github.com/brimworks/lua-zlib/archive/refs/tags/v1.4.tar.gz
fetch carray.tar.gz \
    9e9259c1bf70879b2aa07651d2516f14035f0e13bd9b50d4cdef4bca8507da4c \
    https://github.com/osch/lua-carray/archive/refs/tags/v0.0.4.tar.gz

# lpcre/lbrotli/digest: release tag v0.0.1, same tag the published LuaRocks
# rockspecs pin (their source.url is the GitHub .zip of this tag; fetch.sh
# uses the .tar.gz of the same tag instead, since deps.sh unpacks
# everything with "tar xf").
LPCRE_URL=https://github.com/osch/lua-lpcre/archive/v0.0.1.tar.gz
LPCRE_SHA256=42d3708e1eb71a09f8f59932b81c9a3754d22550f1f39758f73d749a84600514
LBROTLI_URL=https://github.com/osch/lua-lbrotli/archive/v0.0.1.tar.gz
LBROTLI_SHA256=6acf1999cdaf8193e72e9b77f3374af6e1832ad9fe4b8446933d085cfacdf384
DIGEST_URL=https://github.com/osch/lua-digest/archive/v0.0.1.tar.gz
DIGEST_SHA256=7342bf56e77691ce35995c23dc5d7ee632ae44a5de42e6620dd7b3d7ccd4981b
fetch lpcre.tar.gz "$LPCRE_SHA256" "$LPCRE_URL"
fetch lbrotli.tar.gz "$LBROTLI_SHA256" "$LBROTLI_URL"
fetch digest.tar.gz "$DIGEST_SHA256" "$DIGEST_URL"

echo "fetch: all sources verified"
