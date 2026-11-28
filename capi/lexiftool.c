/*------------------------------------------------------------------------------
 * File:         capi/lexiftool.c
 *
 * Description:  C API of lexiftool (capi/lexiftool.h).
 *
 *               A session is a Lua 5.5 state running capi/session.lua
 *               (embedded here as a string, see build-linux.sh), which
 *               opens the session of lexiftool.main -- the command-line
 *               script itself, waiting in its own -stay_open loop for the
 *               next command -- and one ExifTool object, and offers the
 *               calls on both (execute, executeText, setOption, imageInfo,
 *               setNewValue, writeInfo). This file only marshals between C
 *               and those calls: arguments are pushed as Lua strings (with
 *               their lengths), results are copied out of the Lua values
 *               into memory owned by the caller. The Lua state's standard
 *               streams are not touched; the file has no static or global
 *               state of its own.
 *
 *               Build variants:
 *                 LEXIFTOOL_CAPI_EMBEDDED  modules linked/embedded as in
 *                                          the standalone executable: the
 *                                          setup is standalone/main.c's
 *                                          lx_setup() (compiled with
 *                                          -DLX_NO_MAIN)
 *                 (not defined)            "rock": Lua modules and C
 *                                          modules from package.path and
 *                                          package.cpath
 *               LEXIFTOOL_PREFIX, LEXIFTOOL_LIBDIR (and optionally
 *               LEXIFTOOL_ROCKS_TREE): a "rock" build for a system-wide
 *               installation (the Makefile's capi-shared): those module
 *               directories go in front of Lua's default paths
 *               LEXIFTOOL_PORT_VERSION: the version string (build script)
 *
 *               Environment (doc/capi.md "Module paths"): the embedded
 *               build and the installed one set LUA_NOENV in the registry
 *               before the standard libraries are opened, as `lua -E` does,
 *               so LUA_PATH, LUA_CPATH and their _5_5 forms are not read;
 *               the embedded one then clears package.path and package.cpath
 *               (lx_setup), nothing is loaded from the file system. The
 *               development "rock" build (capi/build-*.sh rock) takes them
 *               from the environment, as Lua does by default.
 *------------------------------------------------------------------------------
 */

#include <stdlib.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/* (Windows: the library's own definitions are never dllimport; the DLL's
 * exports come from its .def file, see build-windows.sh) */
#if defined(_WIN32) && !defined(LEXIFTOOL_BUILD_DLL) && !defined(LEXIFTOOL_STATIC)
#  define LEXIFTOOL_STATIC
#endif
#include "lexiftool.h"
#include "session_lua.h"    /* generated: lx_session_lua[], lx_session_lua_len */

#ifndef LEXIFTOOL_PORT_VERSION
#  define LEXIFTOOL_PORT_VERSION "Unknown"
#endif

#ifdef LEXIFTOOL_CAPI_EMBEDDED
/* standalone/main.c: registers the linked C modules and the searcher of
 * the embedded Lua modules, pushes the launcher chunk; 0 on failure
 * with a message pushed */
int lx_setup(lua_State* L);
#endif

struct lexiftool_session {
    lua_State*  L;
    lexiftool_options options;  /* the caller's, during lexiftool_open only */
    int         api;        /* registry ref of session.lua's table */
    int         dead;       /* LEXIFTOOL_E_FAILED / LEXIFTOOL_E_ENDED, or 0 */
    char*       error;      /* last error message */
};

/* ---------------------------------------------------------------------------
 * Helpers
 */

static void lx_set_error_len(lexiftool_session* s, const char* msg, size_t n)
{
    free(s->error);
    s->error = NULL;
    if (msg != NULL && (s->error = malloc(n + 1)) != NULL) {
        memcpy(s->error, msg, n);
        s->error[n] = '\0';
    }
}

static void lx_set_error(lexiftool_session* s, const char* msg)
{
    lx_set_error_len(s, msg, msg != NULL ? strlen(msg) : 0);
}

/* malloc'd, NUL-terminated copy of n bytes (NULL when out of memory) */
static char* lx_dup(const char* data, size_t n)
{
    char* p = malloc(n + 1);
    if (p == NULL) return NULL;
    if (n > 0) memcpy(p, data, n);
    p[n] = '\0';
    return p;
}

/* traceback handler for the calls into session.lua */
static int lx_msghandler(lua_State* L)
{
    const char* msg = lua_tostring(L, 1);
    if (msg == NULL) msg = lua_pushfstring(L, "(error object is a %s value)",
                                           luaL_typename(L, 1));
    luaL_traceback(L, L, msg, 1);
    return 1;
}

/* pushes the message handler and session.lua's function `name`; returns
 * the stack index of the handler */
static int lx_push_call(lexiftool_session* s, const char* name)
{
    lua_State* L = s->L;
    int base = lua_gettop(L) + 1;
    lua_pushcfunction(L, lx_msghandler);
    lua_rawgeti(L, LUA_REGISTRYINDEX, s->api);
    lua_getfield(L, -1, name);
    lua_remove(L, -2);
    return base;
}

/* pushes a list of n strings (NULL entries as "") */
static void lx_push_list(lua_State* L, int n, const char* const v[])
{
    int i;
    lua_createtable(L, n, 0);
    for (i = 0; i < n; i++) {
        if (v[i] != NULL) lua_pushstring(L, v[i]);
        else lua_pushliteral(L, "");
        lua_rawseti(L, -2, i + 1);
    }
}

/* common checks of a call; 0 = go on, else the return code */
static int lx_check(lexiftool_session* s)
{
    if (s == NULL) return LEXIFTOOL_E_ARG;
    lx_set_error(s, NULL);
    if (s->dead) {
        lx_set_error(s, s->dead == LEXIFTOOL_E_ENDED ? "the session has ended"
                                                     : "the session has failed");
        return s->dead;
    }
    return 0;
}

/* a call into session.lua with nargs arguments pushed after lx_push_call;
 * a Lua error makes the session unusable. Returns 0 or LEXIFTOOL_E_FAILED */
static int lx_pcall(lexiftool_session* s, int base, int nargs, int nres)
{
    if (lua_pcall(s->L, nargs, nres, base) != LUA_OK) {
        lx_set_error(s, lua_tostring(s->L, -1));
        s->dead = LEXIFTOOL_E_FAILED;
        return LEXIFTOOL_E_FAILED;
    }
    return 0;
}

/* ---------------------------------------------------------------------------
 * Session
 */

const char* lexiftool_version(void)
{
    return LEXIFTOOL_PORT_VERSION;
}

int lexiftool_api_version(void)
{
    return LEXIFTOOL_API_VERSION;
}

const char* lexiftool_last_error(const lexiftool_session* s)
{
    return s != NULL ? s->error : NULL;
}

int lexiftool_state(const lexiftool_session* s)
{
    if (s == NULL) return LEXIFTOOL_E_ARG;
    return s->dead ? s->dead : LEXIFTOOL_OK;
}

#ifdef LEXIFTOOL_PREFIX
#  ifndef LEXIFTOOL_LIBDIR
#    define LEXIFTOOL_LIBDIR LEXIFTOOL_PREFIX "/lib"
#  endif
#  ifdef LEXIFTOOL_ROCKS_TREE
#    define LX_ROCKS_PATH  LEXIFTOOL_ROCKS_TREE "/share/lua/" LUA_VDIR "/?.lua;" \
                           LEXIFTOOL_ROCKS_TREE "/share/lua/" LUA_VDIR "/?/init.lua;"
#    define LX_ROCKS_CPATH LEXIFTOOL_ROCKS_TREE "/lib/lua/" LUA_VDIR "/?.so;"
#  else
#    define LX_ROCKS_PATH  ""
#    define LX_ROCKS_CPATH ""
#  endif
/* package[field] = prefix .. package[field] */
static void lx_prepend_path(lua_State* L, const char* field, const char* prefix)
{
    lua_getglobal(L, "package");
    lua_pushstring(L, prefix);
    lua_getfield(L, -2, field);
    lua_concat(L, 2);
    lua_setfield(L, -2, field);
    lua_pop(L, 1);
}
#endif

/* the protected part of lexiftool_open (argument: the session): opens the
 * libraries, runs session.lua; leaves session.lua's table on the stack */
static int lx_start(lua_State* L)
{
    lexiftool_session* s = (lexiftool_session*)lua_touserdata(L, 1);
    const lexiftool_options* o = &s->options;
    int nargs;

#if defined(LEXIFTOOL_CAPI_EMBEDDED) || defined(LEXIFTOOL_PREFIX)
    /* as `lua -E`: package.path/cpath start from Lua's defaults, not from
     * LUA_PATH/LUA_CPATH (loadlib.c reads this registry field) */
    lua_pushboolean(L, 1);
    lua_setfield(L, LUA_REGISTRYINDEX, "LUA_NOENV");
#endif
    luaL_openlibs(L);
#ifdef LEXIFTOOL_PREFIX
    /* the installation's own modules first, as in the installed launcher */
    lx_prepend_path(L, "path", LEXIFTOOL_PREFIX "/share/lua/" LUA_VDIR "/?.lua;"
                               LEXIFTOOL_PREFIX "/share/lua/" LUA_VDIR "/?/init.lua;" LX_ROCKS_PATH);
    lx_prepend_path(L, "cpath", LEXIFTOOL_LIBDIR "/lua/" LUA_VDIR "/?.so;" LX_ROCKS_CPATH);
#endif
    if (o->lua_path != NULL) {
        lua_getglobal(L, "package");
        lua_pushstring(L, o->lua_path);
        lua_setfield(L, -2, "path");
        lua_pop(L, 1);
    }
    if (o->lua_cpath != NULL) {
        lua_getglobal(L, "package");
        lua_pushstring(L, o->lua_cpath);
        lua_setfield(L, -2, "cpath");
        lua_pop(L, 1);
    }

    if (luaL_loadbufferx(L, (const char*)lx_session_lua, lx_session_lua_len,
                         "=capi/session.lua", "t") != LUA_OK)
        return lua_error(L);
#ifdef LEXIFTOOL_CAPI_EMBEDDED
    if (!lx_setup(L)) return lua_error(L);    /* +1: the launcher chunk */
#else
    lua_pushnil(L);
#endif
    if (o->config_file != NULL) lua_pushstring(L, o->config_file);
    else lua_pushnil(L);
    nargs = o->common_argc > 0 && o->common_argv != NULL ? o->common_argc : 0;
    lx_push_list(L, nargs, o->common_argv);
    lua_call(L, 3, 1);
    return 1;
}

lexiftool_session* lexiftool_open(const lexiftool_options* options)
{
    lexiftool_session* s = calloc(1, sizeof(*s));
    lua_State* L;

    if (s == NULL) return NULL;
    s->api = LUA_NOREF;
    s->L = L = luaL_newstate();
    if (L == NULL) {
        free(s);
        return NULL;
    }
    /* the caller's options, as far as its struct_size covers them */
    if (options != NULL) {
        size_t n = options->struct_size > 0 ? options->struct_size : sizeof(*options);
        memcpy(&s->options, options, n < sizeof(*options) ? n : sizeof(*options));
    }
    lua_pushcfunction(L, lx_msghandler);
    lua_pushcfunction(L, lx_start);
    lua_pushlightuserdata(L, s);
    if (lua_pcall(L, 1, 1, -3) != LUA_OK) {
        lx_set_error(s, lua_tostring(L, -1));
        s->dead = LEXIFTOOL_E_FAILED;
    } else {
        s->api = luaL_ref(L, LUA_REGISTRYINDEX);
    }
    lua_settop(L, 0);
    memset(&s->options, 0, sizeof(s->options));
    return s;
}

void lexiftool_close(lexiftool_session* s)
{
    if (s == NULL) return;
    if (s->L != NULL) {
        if (!s->dead && s->api != LUA_NOREF) {
            /* "-stay_open False": the loop runs Exit() (cleanup) and ends */
            int base = lx_push_call(s, "execute");
            lua_pushnil(s->L);
            lua_pcall(s->L, 1, 0, base);
        }
        lua_close(s->L);
    }
    free(s->error);
    free(s);
}

/* ---------------------------------------------------------------------------
 * Commands
 */

void lexiftool_result_free(lexiftool_result* r)
{
    if (r == NULL) return;
    free(r->stdout_data);
    free(r->stderr_data);
    memset(r, 0, sizeof(*r));
}

/* the part of execute/execute_text after the argument was pushed: runs
 * session.lua's call (-> stdout, stderr, status, state, message) and fills
 * *out */
static int lx_run(lexiftool_session* s, int base, lexiftool_result* out)
{
    lua_State* L = s->L;
    const char* data, *state;
    size_t len;
    int rc = lx_pcall(s, base, 1, 5);

    if (rc == 0) {
        data = lua_tolstring(L, base + 1, &len);
        out->stdout_data = lx_dup(data ? data : "", data ? len : 0);
        out->stdout_len = data ? len : 0;
        data = lua_tolstring(L, base + 2, &len);
        out->stderr_data = lx_dup(data ? data : "", data ? len : 0);
        out->stderr_len = data ? len : 0;
        out->status = (int)lua_tointeger(L, base + 3);
        state = lua_tostring(L, base + 4);
        if (state == NULL || strcmp(state, "failed") == 0) {
            lx_set_error(s, lua_tostring(L, base + 5));
            s->dead = rc = LEXIFTOOL_E_FAILED;
        } else if (strcmp(state, "ended") == 0) {
            lx_set_error(s, "the command ended the session (-stay_open False)");
            s->dead = rc = LEXIFTOOL_E_ENDED;
        }
    }
    if (out->stdout_data == NULL || out->stderr_data == NULL) {
        lexiftool_result_free(out);
        out->stdout_data = lx_dup("", 0);
        out->stderr_data = lx_dup("", 0);
        if (rc == LEXIFTOOL_OK) {
            rc = LEXIFTOOL_E_NOMEM;
            lx_set_error(s, "out of memory");
        }
    }
    lua_settop(L, 0);
    return rc;
}

/* start of execute/execute_text: out zeroed and given empty strings on an
 * early return; 0 = go on, else the return code */
static int lx_begin_result(lexiftool_session* s, int bad, lexiftool_result* out)
{
    int rc;
    memset(out, 0, sizeof(*out));
    rc = bad ? LEXIFTOOL_E_ARG : lx_check(s);
    if (rc != 0) {
        out->stdout_data = lx_dup("", 0);
        out->stderr_data = lx_dup("", 0);
    }
    return rc;
}

int lexiftool_execute(lexiftool_session* s, int argc, const char* const argv[],
                      lexiftool_result* out)
{
    int rc, base;

    if (out == NULL) return LEXIFTOOL_E_ARG;
    rc = lx_begin_result(s, argc < 0 || (argc > 0 && argv == NULL), out);
    if (rc != 0) return rc;
    base = lx_push_call(s, "execute");
    lx_push_list(s->L, argc, argv);
    return lx_run(s, base, out);
}

int lexiftool_execute_text(lexiftool_session* s, const char* text, size_t len,
                           lexiftool_result* out)
{
    int rc, base;

    if (out == NULL) return LEXIFTOOL_E_ARG;
    rc = lx_begin_result(s, text == NULL, out);
    if (rc != 0) return rc;
    if (len == LEXIFTOOL_NUL_TERMINATED) len = strlen(text);
    base = lx_push_call(s, "executeText");
    lua_pushlstring(s->L, text, len);
    return lx_run(s, base, out);
}

/* ---------------------------------------------------------------------------
 * The session's ExifTool object
 */

int lexiftool_set_option(lexiftool_session* s, const char* name, const char* value)
{
    int rc, base;

    if (name == NULL) return LEXIFTOOL_E_ARG;
    if ((rc = lx_check(s)) != 0) return rc;
    base = lx_push_call(s, "setOption");
    lua_pushstring(s->L, name);
    if (value != NULL) lua_pushstring(s->L, value);
    else lua_pushnil(s->L);
    rc = lx_pcall(s, base, 2, 0);
    lua_settop(s->L, 0);
    return rc;
}

void lexiftool_info_free(lexiftool_info* info)
{
    if (info == NULL) return;
    free(info->mem);
    memset(info, 0, sizeof(*info));
}

/* the string fields of an imageInfo entry, by their index in the entry */
enum { LX_F_NAME = 1, LX_F_G0, LX_F_G1, LX_F_G2, LX_F_DESC, LX_F_ID,
       LX_F_VALUE, LX_F_NUM, LX_F_COPY, LX_F_KIND, LX_F_BINLEN };

/* bytes of field i of the entry at the top of the stack (the string stays
 * alive in the entry table); "" for a missing one */
static const char* lx_field(lua_State* L, int i, size_t* len)
{
    const char* p;
    lua_rawgeti(L, -1, i);
    p = lua_tolstring(L, -1, len);
    lua_pop(L, 1);
    if (p == NULL) { p = ""; *len = 0; }
    return p;
}

static lua_Integer lx_ifield(lua_State* L, int i)
{
    lua_Integer v;
    lua_rawgeti(L, -1, i);
    v = lua_tointeger(L, -1);
    lua_pop(L, 1);
    return v;
}

/* num is stored apart from value unless it holds the same bytes */
static int lx_num_shared(lua_State* L)
{
    size_t vl, nl;
    const char* v = lx_field(L, LX_F_VALUE, &vl);
    const char* n = lx_field(L, LX_F_NUM, &nl);
    return vl == nl && (v == n || memcmp(v, n, vl) == 0);
}

/* the list at stack index t as one block in *out; 0 when out of memory */
static int lx_fill_info(lua_State* L, int t, lexiftool_info* out)
{
    size_t nt = lua_rawlen(L, t);
    size_t size, len, i;
    int k;
    char* mem, *p;
    const char* str;

    /* 1. size: the array, then all strings with their NULs */
    size = nt * sizeof(lexiftool_tag);
    for (i = 1; i <= nt; i++) {
        lua_rawgeti(L, t, (lua_Integer)i);
        for (k = LX_F_NAME; k <= LX_F_NUM; k++) {
            if (k == LX_F_NUM && lx_num_shared(L)) continue;
            lx_field(L, k, &len);
            size += len + 1;
        }
        lua_pop(L, 1);
    }
    if ((mem = malloc(size > 0 ? size : 1)) == NULL) return 0;

    /* 2. copy */
    out->mem = mem;
    out->tags = nt ? (lexiftool_tag*)mem : NULL;
    out->count = nt;
    p = mem + nt * sizeof(lexiftool_tag);
#define LX_COPY(dst, k, dstlen) \
    do { \
        str = lx_field(L, k, &len); \
        memcpy(p, str, len); p[len] = '\0'; (dst) = p; p += len + 1; \
        dstlen = len; \
    } while (0)
    for (i = 0; i < nt; i++) {
        lexiftool_tag* tag = &out->tags[i];
        size_t ignored;
        lua_rawgeti(L, t, (lua_Integer)i + 1);
        LX_COPY(tag->name, LX_F_NAME, ignored);
        LX_COPY(tag->group[0], LX_F_G0, ignored);
        LX_COPY(tag->group[1], LX_F_G1, ignored);
        LX_COPY(tag->group[2], LX_F_G2, ignored);
        LX_COPY(tag->desc, LX_F_DESC, ignored);
        LX_COPY(tag->id, LX_F_ID, ignored);
        LX_COPY(tag->value, LX_F_VALUE, tag->value_len);
        if (lx_num_shared(L)) {
            tag->num = tag->value;
            tag->num_len = tag->value_len;
        } else {
            LX_COPY(tag->num, LX_F_NUM, tag->num_len);
        }
        (void)ignored;
        tag->copy_num = (int)lx_ifield(L, LX_F_COPY);
        tag->binary = (int)lx_ifield(L, LX_F_KIND);
        tag->binary_len = (size_t)lx_ifield(L, LX_F_BINLEN);
        lua_pop(L, 1);
        if (strcmp(tag->group[0], "ExifTool") == 0) {
            if (out->error == NULL && strcmp(tag->name, "Error") == 0)
                out->error = tag->value;
            else if (out->warning == NULL && strcmp(tag->name, "Warning") == 0)
                out->warning = tag->value;
        }
    }
#undef LX_COPY
    return 1;
}

int lexiftool_image_info(lexiftool_session* s, const char* file,
                         const char* const tags[], int ntags,
                         unsigned flags, lexiftool_info* out)
{
    int rc, base;

    if (out == NULL) return LEXIFTOOL_E_ARG;
    memset(out, 0, sizeof(*out));
    if (file == NULL || ntags < 0) return LEXIFTOOL_E_ARG;
    if ((rc = lx_check(s)) != 0) return rc;
    if (tags == NULL) ntags = 0;
    base = lx_push_call(s, "imageInfo");
    lua_pushstring(s->L, file);
    lx_push_list(s->L, ntags, tags);
    lua_pushboolean(s->L, (flags & LEXIFTOOL_INFO_BINARY) != 0);
    if ((rc = lx_pcall(s, base, 3, 1)) == 0 && !lx_fill_info(s->L, base + 1, out)) {
        lx_set_error(s, "out of memory");
        rc = LEXIFTOOL_E_NOMEM;
    }
    lua_settop(s->L, 0);
    return rc;
}

int lexiftool_set_new_value(lexiftool_session* s, const char* tag,
                            const char* value, size_t len)
{
    int rc, base;
    size_t n;
    const char* msg;

    if ((rc = lx_check(s)) != 0) return rc;
    base = lx_push_call(s, "setNewValue");
    if (tag != NULL) {
        lua_pushstring(s->L, tag);
        if (value == NULL) lua_pushnil(s->L);
        else lua_pushlstring(s->L, value, len == LEXIFTOOL_NUL_TERMINATED ? strlen(value) : len);
    } else {
        lua_pushnil(s->L);
        lua_pushnil(s->L);
    }
    /* -> number of tags set, message or nil */
    if ((rc = lx_pcall(s, base, 2, 2)) == 0) {
        rc = (int)lua_tointeger(s->L, base + 1);
        if ((msg = lua_tolstring(s->L, base + 2, &n)) != NULL) lx_set_error_len(s, msg, n);
    }
    lua_settop(s->L, 0);
    return rc;
}

int lexiftool_write_info(lexiftool_session* s, const char* file, const char* outfile)
{
    int rc, base;
    size_t n;
    const char* msg;

    if (file == NULL) return LEXIFTOOL_E_ARG;
    if ((rc = lx_check(s)) != 0) return rc;
    base = lx_push_call(s, "writeInfo");
    lua_pushstring(s->L, file);
    if (outfile != NULL) lua_pushstring(s->L, outfile);
    else lua_pushnil(s->L);
    /* -> result, error, warning */
    if ((rc = lx_pcall(s, base, 2, 3)) == 0) {
        rc = (int)lua_tointeger(s->L, base + 1);
        msg = lua_tolstring(s->L, rc == 0 ? base + 2 : base + 3, &n);
        if (msg != NULL) lx_set_error_len(s, msg, n);
        else if (rc == 0) lx_set_error(s, "WriteInfo failed");
    }
    lua_settop(s->L, 0);
    return rc;
}
