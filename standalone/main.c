/*------------------------------------------------------------------------------
 * File:         standalone/main.c
 *
 * Description:  Host program of the standalone lexiftool executable: a Lua
 *               5.5 interpreter with everything lexiftool needs linked or
 *               embedded, so that nothing is loaded from the file system.
 *
 *               - C modules, linked statically, registered in
 *                 package.preload: lexiftool.sys (src/lexiftool/sys.c), lpcre,
 *                 carray, lbrotli, lfs, digest, zlib (lua-zlib).
 *               - Lua modules, embedded as bytecode (standalone/genembed.lua,
 *                 blob.c): found by a searcher inserted right after the
 *                 preload searcher, so they win over any file on
 *                 package.path; the loader gets the module name and the
 *                 virtual path "<embedded>/lexiftool/X.lua", as Lua's file
 *                 searcher passes the file name.
 *               - Data files (Geolocation.dat, ...): handed to the launcher
 *                 chunk as getFile(rel), which serves them through io.open
 *                 (standalone/launcher.lua).
 *               - Every embedded entry is compressed on its own (zstd,
 *                 genembed.lua; its embedded_codec.h says whether, so the
 *                 build must have the generated directory on the include
 *                 path) and decoded only when it is used: on the
 *                 module's require, on the data file's io.open. A run pays
 *                 for the modules it loads, not for all of them.
 *
 *               The global `arg` is set up as the standalone interpreter
 *               does for a script: arg[0] is the program, arg[1..n] the
 *               command-line arguments; arg[-1], the interpreter, is the
 *               program too (main.lua's -xpath reads it as Perl's $^X).
 *               Errors are reported with a traceback, like lua.c does.
 *
 *               The setup of a Lua state (C modules, searcher, launcher
 *               chunk) is lx_setup(), which the C API (capi/lexiftool.c)
 *               uses as well; compiled with -DLX_NO_MAIN this file provides
 *               only that, for the library.
 *------------------------------------------------------------------------------
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "embedded.h"
#include "embedded_codec.h"     /* LX_CODEC, written by genembed.lua */

#if LX_CODEC == LX_CODEC_ZSTD
#  include <zstd.h>
#endif

#define LX_VROOT "<embedded>"

/* Statically linked Lua C modules */
int luaopen_lexiftool_sys(lua_State* L);
int luaopen_lpcre(lua_State* L);
int luaopen_carray(lua_State* L);
int luaopen_lbrotli(lua_State* L);
int luaopen_lfs(lua_State* L);
int luaopen_digest(lua_State* L);
int luaopen_zlib(lua_State* L);

static const luaL_Reg lx_cmodules[] = {
    { "lexiftool.sys", luaopen_lexiftool_sys },
    { "lpcre",         luaopen_lpcre },
    { "carray",        luaopen_carray },
    { "lbrotli",       luaopen_lbrotli },
    { "lfs",           luaopen_lfs },
    { "digest",        luaopen_digest },
    { "zlib",          luaopen_zlib },
    { NULL, NULL }
};

static const struct lx_entry* lx_find(int kind, const char* name)
{
    const struct lx_entry* e;
    for (e = lx_entries; e->name != NULL; e++) {
        if (e->kind == kind && strcmp(e->name, name) == 0) return e;
    }
    return NULL;
}

/* The bytes of entry e: a pointer into lx_blob for an entry stored as is
 * (*owned = NULL), else a malloc'd buffer with the decoded bytes, which
 * the caller frees (*owned = the buffer). NULL if decoding fails. */
static const char* lx_data(const struct lx_entry* e, size_t* len, char** owned)
{
    char* buf;
    size_t n = e->ulen;

    *owned = NULL;
    if (e->ulen == 0) {
        *len = e->len;
        return (const char*)lx_blob + e->offset;
    }
    buf = malloc(n);
    if (buf == NULL) return NULL;
#if LX_CODEC == LX_CODEC_ZSTD
    /* one frame of known size into a buffer of exactly that size */
    n = ZSTD_decompress(buf, e->ulen, lx_blob + e->offset, e->len);
    if (ZSTD_isError(n) || n != e->ulen) {
        free(buf);
        return NULL;
    }
#else
    free(buf);      /* uncompressed build: no entry has ulen > 0 */
    return NULL;
#endif
    *owned = buf;
    *len = n;
    return buf;
}

/* load entry e as a chunk (bytecode only) */
static int lx_load(lua_State* L, const struct lx_entry* e, const char* chunkname)
{
    size_t len;
    char* owned;
    const char* data = lx_data(e, &len, &owned);
    int status;

    if (data == NULL) {
        lua_pushfstring(L, "cannot decode embedded entry '%s'", e->name);
        return LUA_ERRMEM;
    }
    /* mode "b", not "B": the chunk copies what it needs, so the decoded
       buffer can go right away */
    status = luaL_loadbufferx(L, data, len, chunkname, "b");
    free(owned);
    return status;
}

/* package.searchers entry: embedded Lua modules */
static int lx_searcher(lua_State* L)
{
    const char* name = luaL_checkstring(L, 1);
    const struct lx_entry* e = lx_find(LX_MODULE, name);
    if (e == NULL) {
        lua_pushfstring(L, "no embedded module '%s'", name);
        return 1;
    }
    if (lx_load(L, e, name) != LUA_OK) {
        return luaL_error(L, "error loading embedded module '%s':\n\t%s",
                          name, lua_tostring(L, -1));
    }
    /* second value: the "file name", as the file searchers pass it */
    luaL_gsub(L, name, ".", "/");
    lua_pushfstring(L, LX_VROOT "/%s.lua", lua_tostring(L, -1));
    lua_remove(L, -2);
    return 2;
}

/* getFile(rel) -> contents of the embedded data file, or nil */
static int lx_getfile(lua_State* L)
{
    const struct lx_entry* e = lx_find(LX_FILE, luaL_checkstring(L, 1));
    size_t len;
    char* owned;
    const char* data;
    if (e == NULL) return 0;
    data = lx_data(e, &len, &owned);
    if (data == NULL) return luaL_error(L, "cannot decode embedded file '%s'", e->name);
    lua_pushlstring(L, data, len);
    free(owned);
    return 1;
}

#ifndef LX_NO_MAIN
/* message handler: error message plus traceback (as lua.c) */
static int lx_msghandler(lua_State* L)
{
    const char* msg = lua_tostring(L, 1);
    if (msg == NULL) {
        if (luaL_callmeta(L, 1, "__tostring") && lua_type(L, -1) == LUA_TSTRING)
            return 1;
        msg = lua_pushfstring(L, "(error object is a %s value)", luaL_typename(L, 1));
    }
    luaL_traceback(L, L, msg, 1);
    return 1;
}
#endif

/* Sets up the Lua state L (its standard libraries already open) for the
 * embedded lexiftool: registers the linked C modules (package.preload) and
 * the searcher of the embedded Lua modules (package.searchers[2]), then
 * pushes the launcher chunk and its two arguments, VROOT and getFile.
 * Returns 1, or 0 with an error message pushed instead. */
int lx_setup(lua_State* L);
int lx_setup(lua_State* L)
{
    const struct lx_entry* m;
    int i;

    /* C modules -> package.preload */
    luaL_getsubtable(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
    for (i = 0; lx_cmodules[i].name != NULL; i++) {
        lua_pushcfunction(L, lx_cmodules[i].func);
        lua_setfield(L, -2, lx_cmodules[i].name);
    }
    lua_pop(L, 1);

    /* embedded Lua modules: searcher at position 2, after preload */
    lua_getglobal(L, "table");
    lua_getfield(L, -1, "insert");
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "searchers");
    lua_remove(L, -2);
    lua_pushinteger(L, 2);
    lua_pushcfunction(L, lx_searcher);
    lua_call(L, 3, 0);
    lua_pop(L, 1);  /* table */

    /* the launcher chunk and its arguments */
    m = lx_find(LX_MAIN, "launcher");
    if (m == NULL) {
        lua_pushliteral(L, "missing");
        return 0;
    }
    if (lx_load(L, m, "=launcher") != LUA_OK)     /* (decodes it if compressed) */
        return 0;
    lua_pushliteral(L, LX_VROOT);
    lua_pushcfunction(L, lx_getfile);
    return 1;
}

#ifndef LX_NO_MAIN
int main(int argc, char** argv)
{
    lua_State* L = luaL_newstate();
    const char* progname = (argc > 0 && argv[0] != NULL) ? argv[0] : "lexiftool";
    int i, status;

    if (L == NULL) {
        fprintf(stderr, "lexiftool: cannot create Lua state: not enough memory\n");
        return EXIT_FAILURE;
    }
    luaL_openlibs(L);

    /* arg table */
    lua_createtable(L, argc, 2);
    lua_pushstring(L, progname);
    lua_rawseti(L, -2, -1);
    lua_pushstring(L, progname);
    lua_rawseti(L, -2, 0);
    for (i = 1; i < argc; i++) {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i);
    }
    lua_setglobal(L, "arg");

    /* run the launcher chunk: launcher(VROOT, getFile) */
    lua_pushcfunction(L, lx_msghandler);
    if (!lx_setup(L)) {
        fprintf(stderr, "lexiftool: cannot load the embedded launcher: %s\n",
                lua_tostring(L, -1));
        lua_close(L);
        return EXIT_FAILURE;
    }
    status = lua_pcall(L, 2, 0, 1);
    if (status != LUA_OK) {
        const char* msg = lua_tostring(L, -1);
        fprintf(stderr, "lexiftool: %s\n", msg ? msg : "(error object is not a string)");
    }
    lua_close(L);
    return status == LUA_OK ? EXIT_SUCCESS : EXIT_FAILURE;
}
#endif
