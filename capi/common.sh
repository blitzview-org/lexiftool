# capi/common.sh - shell functions shared by build-linux.sh, build-macos.sh,
# build-windows.sh and package.sh (sourced; CAPI and PROJECT set by the caller).

# the build's own version/identity (CONTRIBUTING.md "Configuration",
# _G.LEXIFTOOL_PORT_VERSION; same scheme as Makefile.standalone's
# SA_IDENTITY). Run on the host: the builder containers have no git, so it
# is computed before a container is started and passed in via
# LEXIFTOOL_PORT_VERSION instead of calling this again.
portversion() {
    git -C "$PROJECT" describe --tags --always --long --dirty --match 'v*' 2>/dev/null || echo Unknown
}

# the time of the last commit (Makefile.standalone's SA_SOURCE_DATE_EPOCH):
# SOURCE_DATE_EPOCH of the embedded builds (PE time stamp, Mach-O object
# times) and of the release zips (capi/package.sh); host side, like
# portversion
sourcedate() {
    git -C "$PROJECT" log -1 --pretty=%ct 2>/dev/null || echo 0
}

# the version in a release zip's name, from an identity (as
# standalone/build.sh): the bare tag on an exact, clean release (git
# describe --long appends "-0-g<hash>" even then), the identity otherwise,
# "-dirty" included; a slash of the tag becomes "-"
zipversion() {
    v=$1
    case "$v" in
        *-0-g*-dirty) ;;
        *-0-g*)       v=${v%-0-g*} ;;
    esac
    printf '%s' "$v" | tr '/' '-'
}

# LEXIFTOOL_API_VERSION of the header
apiversion() {
    sed -n 's/^#define LEXIFTOOL_API_VERSION \([0-9][0-9]*\).*/\1/p' "$CAPI/lexiftool.h"
}

# the exported functions (lexiftool_*), one per line
exports() {
    sed -n 's/^LEXIFTOOL_API .*[ *]\(lexiftool_[a-z_]*\)(.*/\1/p' "$CAPI/lexiftool.h"
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

# lexiftool.pc of an embedded build, relocatable (${pcfiledir}):
# pkgconfig FILE LIBS_PRIVATE CFLAGS_PRIVATE (LEXIFTOOL_PORT_VERSION set)
pkgconfig() {
    pcversion=$(echo "$LEXIFTOOL_PORT_VERSION" | sed -n 's/^v\([0-9][0-9.]*[0-9]\).*/\1/p')
    {
        echo 'prefix=${pcfiledir}/../..'
        echo 'libdir=${prefix}/lib'
        echo 'includedir=${prefix}/include'
        echo
        echo 'Name: lexiftool'
        echo 'Description: Image metadata (a Lua port of ExifTool) through a C API, Lua and libraries embedded'
        echo "Version: ${pcversion:-0}"
        echo 'Cflags: -I${includedir}'
        [ -z "$3" ] || echo "Cflags.private: $3"
        echo 'Libs: -L${libdir} -llexiftool'
        [ -z "$2" ] || echo "Libs.private: $2"
    } > "$1"
}

# the rock variant finds the modules as with the repo's activate.sh (src/,
# build/5.5/, LUA_ROCKS), then the system trees
rock_paths() {
    ROCKS="${LUA_ROCKS:-$HOME/.luarocks}"
    LP="$PROJECT/src/?.lua;$PROJECT/src/?/init.lua;$ROCKS/share/lua/5.5/?.lua;$ROCKS/share/lua/5.5/?/init.lua;/usr/share/lua/5.5/?.lua;/usr/local/share/lua/5.5/?.lua"
    LCP="$PROJECT/build/5.5/?.so;$ROCKS/lib/lua/5.5/?.so;/usr/lib/lua/5.5/?.so;/usr/local/lib/lua/5.5/?.so"
    export LUA_PATH_5_5="$LP" LUA_CPATH_5_5="$LCP"
}
