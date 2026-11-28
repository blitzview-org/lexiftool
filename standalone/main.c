/*------------------------------------------------------------------------------
 * File:         standalone/main.c
 *
 * Description:  Host program of the standalone lexiftool executable: a Lua
 *               5.5 interpreter with everything lexiftool needs linked or
 *               embedded, so that nothing is loaded from the file system.
 *
 *               - C modules, linked statically, registered in
 *                 package.preload: lexiftool.sys and lexiftool.util
 *                 (src/lexiftool/sys.c, util.c), lpcre, carray, lfs,
 *                 digest, compress.brotli, compress.zlib,
 *                 compress.lzma, compress.bzip2, cipher.aes, cipher.rc4.
 *               - Lua modules, embedded as bytecode (standalone/genembed.lua,
 *                 blob.c): found by a searcher inserted right after the
 *                 preload searcher, so they win over any file on
 *                 package.path; the loader gets the module name and the
 *                 virtual path "<embedded>/lexiftool/X.lua", as Lua's file
 *                 searcher passes the file name.
 *               - An embedded entry is stored as is (the default: a module
 *                 is loaded straight from the mapped executable) or, with
 *                 SA_COMPRESS=zstd, compressed on its own (genembed.lua; its
 *                 embedded_codec.h says which, so the build must have the
 *                 generated directory on the include path) and decoded
 *                 only when it is used, on the module's require. A run
 *                 pays for the modules it loads, not for all of them.
 *
 *               The global `arg` is set up as the standalone interpreter
 *               does for a script: arg[0] is the program, arg[1..n] the
 *               command-line arguments; arg[-1], the interpreter, is the
 *               program too (main.lua's -xpath reads it as Perl's $^X).
 *               Errors are reported with a traceback, like lua.c does.
 *
 *               - Sealed against the environment: LUA_NOENV is set in the
 *                 registry before the standard libraries are opened (as
 *                 `lua -E` does; LUA_PATH, LUA_CPATH and their _5_5 forms
 *                 are not read, and LUA_INIT is never run), and lx_setup()
 *                 empties package.path and package.cpath: a module that is
 *                 neither linked nor embedded fails to load, with Lua's
 *                 "module not found" message, instead of being taken from
 *                 the file system.
 *
 *               The setup of a Lua state (C modules, searcher, empty
 *               paths, launcher chunk) is lx_setup(), which the C API
 *               (capi/lexiftool.c) uses as well; compiled with -DLX_NO_MAIN
 *               this file provides only that, for the library.
 *------------------------------------------------------------------------------
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "embedded.h"
#include "embedded_codec.h"     /* LX_CODEC, written by genembed.lua */

#if LX_CODEC == LX_CODEC_ZSTD
#  include <zstd.h>
#endif

#if defined(__linux__) || defined(__APPLE__)
#  include <sys/mman.h>
#  include <unistd.h>
#  define LX_HAVE_MADVISE 1
#endif

#define LX_VROOT "<embedded>"

/* An entry loaded straight from the blob (uncompressed build) has been
 * read once and is not needed again, but its pages -- part of the
 * executable's read-only data -- stay resident afterwards: with all
 * modules loaded, as a run over many file types does, some 15 MB of
 * bytecode would count towards the process's memory for the rest of
 * its life. So the whole pages inside the entry are given back after
 * loading. They are clean and file-backed; should anything touch them
 * again (a second require after package.loaded was cleared), the kernel
 * reads them from the executable once more. Pages shared with a
 * neighbouring entry at either end are left alone. */
static void lx_release(const char* data, size_t len)
{
#ifdef LX_HAVE_MADVISE
    long page = sysconf(_SC_PAGESIZE);
    uintptr_t start, end;
    if (page <= 0) return;
    start = ((uintptr_t)data + (uintptr_t)page - 1) & ~((uintptr_t)page - 1);
    end = ((uintptr_t)data + len) & ~((uintptr_t)page - 1);
    if (end > start) madvise((void*)start, end - start, MADV_DONTNEED);
#else
    (void)data; (void)len;
#endif
}

/* Statically linked Lua C modules */
int luaopen_lexiftool_sys(lua_State* L);
int luaopen_lexiftool_util(lua_State* L);
int luaopen_lpcre(lua_State* L);
int luaopen_carray(lua_State* L);
int luaopen_lfs(lua_State* L);
int luaopen_digest(lua_State* L);
int luaopen_compress_brotli(lua_State* L);
int luaopen_compress_zlib(lua_State* L);
int luaopen_compress_lzma(lua_State* L);
int luaopen_compress_bzip2(lua_State* L);
int luaopen_cipher_aes(lua_State* L);
int luaopen_cipher_rc4(lua_State* L);

static const luaL_Reg lx_cmodules[] = {
    { "lexiftool.sys",   luaopen_lexiftool_sys   },
    { "lexiftool.util",  luaopen_lexiftool_util  },
    { "lpcre",           luaopen_lpcre           },
    { "carray",          luaopen_carray          },
    { "lfs",             luaopen_lfs             },
    { "digest",          luaopen_digest          },
    { "compress.brotli", luaopen_compress_brotli },
    { "compress.zlib",   luaopen_compress_zlib   },
    { "compress.lzma",   luaopen_compress_lzma   },
    { "compress.bzip2",  luaopen_compress_bzip2  },
    { "cipher.aes",      luaopen_cipher_aes      },
    { "cipher.rc4",      luaopen_cipher_rc4      },
    { NULL,              NULL                    }
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
    *owned = NULL;
    if (e->ulen == 0) {             /* stored as is */
        *len = e->len;
        return (const char*)lx_blob + e->offset;
    }
#if LX_CODEC == LX_CODEC_ZSTD
    {
        /* one frame of known size into a buffer of exactly that size */
        char* buf = malloc(e->ulen);
        size_t n;
        if (buf == NULL) return NULL;
        n = ZSTD_decompress(buf, e->ulen, lx_blob + e->offset, e->len);
        if (ZSTD_isError(n) || n != e->ulen) {
            free(buf);
            return NULL;
        }
        *owned = buf;
        *len = n;
        return buf;
    }
#else
    /* unreachable with a consistent build: without a codec genembed.lua
       writes ulen = 0 for every entry (index and codec header come from
       the same run); a mismatch reads as "cannot decode" instead of
       crashing */
    return NULL;
#endif
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
       buffer can go right away -- and the blob's pages as well */
    status = luaL_loadbufferx(L, data, len, chunkname, "b");
    if (owned != NULL) free(owned); else lx_release(data, len);
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

/* Sets up the Lua state L (its standard libraries already open, with
 * LUA_NOENV set) for the embedded lexiftool: registers the linked C modules
 * (package.preload) and the searcher of the embedded Lua modules
 * (package.searchers[2]), empties package.path and package.cpath, then
 * pushes the launcher chunk. Returns 1, or 0 with an error message pushed
 * instead. */
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

    /* nothing from the file system: the file searchers find nothing */
    lua_getglobal(L, "package");
    lua_pushliteral(L, "");
    lua_setfield(L, -2, "path");
    lua_pushliteral(L, "");
    lua_setfield(L, -2, "cpath");
    lua_pop(L, 1);

    /* the launcher chunk */
    m = lx_find(LX_MAIN, "launcher");
    if (m == NULL) {
        lua_pushliteral(L, "missing");
        return 0;
    }
    if (lx_load(L, m, "=launcher") != LUA_OK)     /* (decodes it if compressed) */
        return 0;
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
    /* as `lua -E`: LUA_PATH/LUA_CPATH are not read (loadlib.c) */
    lua_pushboolean(L, 1);
    lua_setfield(L, LUA_REGISTRYINDEX, "LUA_NOENV");
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

    /* run the launcher chunk */
    lua_pushcfunction(L, lx_msghandler);
    if (!lx_setup(L)) {
        fprintf(stderr, "lexiftool: cannot load the embedded launcher: %s\n",
                lua_tostring(L, -1));
        lua_close(L);
        return EXIT_FAILURE;
    }
    status = lua_pcall(L, 0, 0, 1);
    if (status != LUA_OK) {
        const char* msg = lua_tostring(L, -1);
        fprintf(stderr, "lexiftool: %s\n", msg ? msg : "(error object is not a string)");
    }
    lua_close(L);
    return status == LUA_OK ? EXIT_SUCCESS : EXIT_FAILURE;
}
#endif
