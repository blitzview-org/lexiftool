# activate.sh - module paths for running lexiftool from this checkout.
#
# Source it into the running shell from the repository root:
#
#     make sys            # build/<ver>/lexiftool/{sys,util}.so
#     . ./activate.sh
#     bin/lexiftool -ver -v
#
# The launcher `bin/lexiftool` sets no module paths itself (README.md
# "Starting lexiftool"). For every Lua lexiftool runs on (5.4, 5.5) that is
# installed as lua5.x, lua-5.x, lua5x or lua, this sets the versioned
# LUA_PATH_5_x/LUA_CPATH_5_x, which that Lua takes in preference to an
# unversioned LUA_PATH/LUA_CPATH (e.g. one `luarocks path` set up for 5.1):
#
#     LUA_PATH_5_x   <repo>/src/?.lua;<repo>/src/?/init.lua;
#                    $LUA_ROCKS/share/lua/5.x/?.lua;$LUA_ROCKS/share/lua/5.x/?/init.lua;
#                    <the interpreter's default package.path>
#     LUA_CPATH_5_x  <repo>/build/5.x/?.so;$LUA_ROCKS/lib/lua/5.x/?.so;
#                    <the interpreter's default package.cpath>
#
# LUA_ROCKS is the rock tree the Makefile uses (default $HOME/.luarocks,
# where `luarocks --local install` puts the rocks). The defaults are taken
# from `lua5.x -E`, so whatever LUA_PATH* is set already does not end up in
# them, and sourcing this twice gives the same paths. The unversioned
# LUA_PATH/LUA_CPATH are left alone (lexiftool needs Lua 5.4 or newer).
# Not needed for an installed lexiftool (make install, LuaRocks).

lx_repo=$(pwd)

if [ ! -f "$lx_repo/activate.sh" ] || [ ! -f "$lx_repo/src/lexiftool/main.lua" ]; then

    echo '**** ERROR: ". ./activate.sh" must be invoked from the lexiftool repository root ****' >&2

else

    echo "Setting lua paths for: $lx_repo"
    lx_rocks=${LUA_ROCKS:-$HOME/.luarocks}

    for lx_ver in 5.5 5.4; do
        lx_nodot=$(echo "$lx_ver" | tr -d .)
        lx_cmd=""
        for lx_try in "lua$lx_ver" "lua-$lx_ver" "lua$lx_nodot" lua; do
            if command -v "$lx_try" > /dev/null 2>&1 &&
               [ "$("$lx_try" -E -e 'io.write((_VERSION:gsub("^Lua ", "")))' 2>/dev/null)" = "$lx_ver" ]; then
                lx_cmd=$lx_try
                break
            fi
        done
        if [ -n "$lx_cmd" ]; then
            echo "Setting path for $lx_cmd (version=$lx_ver)"
            lx_var=$(echo "$lx_ver" | tr . _)
            lx_path="$lx_repo/src/?.lua;$lx_repo/src/?/init.lua;$lx_rocks/share/lua/$lx_ver/?.lua;$lx_rocks/share/lua/$lx_ver/?/init.lua;$("$lx_cmd" -E -e 'io.write(package.path)')"
            lx_cpath="$lx_repo/build/$lx_ver/?.so;$lx_rocks/lib/lua/$lx_ver/?.so;$("$lx_cmd" -E -e 'io.write(package.cpath)')"
            eval "export LUA_PATH_$lx_var=\"\$lx_path\" LUA_CPATH_$lx_var=\"\$lx_cpath\""
            [ -f "$lx_repo/build/$lx_ver/lexiftool/sys.so" ] ||
                echo "  (build/$lx_ver/lexiftool/sys.so is missing: make sys$lx_ver)"
        fi
    done

fi

unset lx_repo lx_rocks lx_ver lx_nodot lx_cmd lx_try lx_var lx_path lx_cpath
