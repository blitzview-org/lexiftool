# System-wide installation

`make install` installs lexiftool from the sources the way a distribution
package lays it out: the command-line tool, the Lua modules,
`lexiftool.sys` and the C API as a shared library, for one Lua version.

```sh
make install PREFIX=/usr LUA_VERSION=5.5          # DESTDIR=... for a staged install
```

Settings: `PREFIX` (default `/usr/local`), `LIBDIR` (default
`PREFIX/lib`), `LUA_VERSION` (default 5.5), `LUA_BIN` (the interpreter the
launcher's shebang names), `DESTDIR` (a staging root, as packaging tools
use it), `INSTALL_BYTECODE` (default 1, see below).

| What                                  | Where                                   |
|---------------------------------------|-----------------------------------------|
| `lexiftool` (launcher)                | `PREFIX/bin/`                           |
| Lua modules (bytecode), Geolocation database | `PREFIX/share/lua/<ver>/lexiftool/` |
| `lexiftool.sys`                       | `LIBDIR/lua/<ver>/lexiftool/sys.so`     |
| `liblexiftool.so.<API>`, `.so` link   | `LIBDIR`                                |
| `lexiftool.h`, `lexiftool.pc`         | `PREFIX/include/`, `LIBDIR/pkgconfig/`  |

The modules are installed as bytecode of that Lua version, under their
module names: Lua loads a binary chunk whatever the file is called, and a
start then parses no sources (several hundred KB even for `-ver`, with tag
tables of several MB behind it), so the installed tool starts as fast as
the standalone executable. The chunk names are the installed paths and the
debug information is kept, so tracebacks name file and line as with the
sources. `INSTALL_BYTECODE=0` installs the sources
instead. Bytecode is bound to the Lua version: `tools/compile_tree.lua`
runs under `LUA_BIN`, the Lua the modules are installed for.

Nothing is embedded: the rocks listed in the [README](../README.md#installation)
must be installed for that Lua, system-wide (`luarocks install` without
`--local`, or the distribution's packages). The launcher and the library
find them and the lexiftool modules through Lua's default
`package.path`/`package.cpath`.

The shared library is the `rock` variant of the C API
([capi.md](capi.md), "Build variants"), linked against the system's
`liblua` of `LUA_VERSION`; `make capi-shared` builds it alone. The build's
identity (`git describe`) is set in the installed launcher and library, so
`lexiftool -ver -v` and `lexiftool_version()` report it.

On Arch Linux the whole chain is in the AUR: `lexiftool-git` together with
`lua-lpcre`, `lua-carray`, `lua-digest`, `lua-compress` and `lua-cipher`.
