/*------------------------------------------------------------------------------
 * File:         capi/lexiftool.c
 *
 * Description:  C API of lexiftool (capi/lexiftool.h), prototype.
 *
 *               A session is a Lua 5.5 state running capi/session.lua
 *               (embedded here as a string, see build-linux.sh), which
 *               opens the session of lexiftool.main -- the command-line
 *               script itself, waiting in its own -stay_open loop for the
 *               next command -- and offers three calls: execute (one
 *               command: its stdout and stderr come back as Lua strings,
 *               collected in Lua tables by the perl facade, never written
 *               to the process's streams), imageInfo and setTags (tags as
 *               a Lua list). This file only marshals between C and those
 *               calls; the Lua state's standard streams are not touched.
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
 *               LEXIFTOOL_PORT_VERSION: the version string (build script)
 *------------------------------------------------------------------------------
 */

#include <stdlib.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "lexiftool.h"
#include "session_lua.h"    /* generated: lx_session_lua[], lx_session_lua_len */

#ifndef LEXIFTOOL_PORT_VERSION
#  define LEXIFTOOL_PORT_VERSION "Unknown"
#endif

#ifdef LEXIFTOOL_CAPI_EMBEDDED
/* standalone/main.c: registers the linked C modules and the searcher of
 * the embedded Lua modules, pushes launcher, VROOT, getFile; 0 on failure
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

static void lx_set_error(lexiftool_session* s, const char* msg)
{
    free(s->error);
    s->error = NULL;
    if (msg != NULL) {
        size_t n = strlen(msg) + 1;
        if ((s->error = malloc(n)) != NULL) memcpy(s->error, msg, n);
    }
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

/* pushes a list of n strings (NULL entries as nil when nils, else "") */
static void lx_push_list(lua_State* L, int n, const char* const v[], int nils)
{
    int i;
    lua_createtable(L, n, 0);
    for (i = 0; i < n; i++) {
        if (v[i] != NULL) lua_pushstring(L, v[i]);
        else if (nils) continue;
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

/* ---------------------------------------------------------------------------
 * Tags: the Lua lists of imageInfo/setTags as one block of memory
 *   tags      at index t (0 = none): list of { name, group|nil, value, binary }
 *   messages  at index m: list of { level, text }
 */

/* bytes of field i of entry (a table at the top of the stack) */
static const char* lx_field(lua_State* L, int i, size_t* len)
{
    const char* p;
    lua_rawgeti(L, -1, i);
    p = lua_tolstring(L, -1, len);
    lua_pop(L, 1);      /* (the string stays alive in the entry table) */
    return p;
}

static int lx_fill_tags(lua_State* L, int t, int m, lexiftool_tags* out)
{
    size_t nt = t ? lua_rawlen(L, t) : 0, nm = lua_rawlen(L, m);
    size_t size, len, i;
    int k;
    char* mem, *p;
    const char* str;

    /* 1. size: the two arrays, then all strings with their NULs */
    size = nt * sizeof(lexiftool_tag) + nm * sizeof(lexiftool_message);
    for (i = 1; i <= nt; i++) {
        lua_rawgeti(L, t, (lua_Integer)i);
        for (k = 1; k <= 3; k++)
            if (lx_field(L, k, &len) != NULL) size += len + 1;
        lua_pop(L, 1);
    }
    for (i = 1; i <= nm; i++) {
        lua_rawgeti(L, m, (lua_Integer)i);
        for (k = 1; k <= 2; k++)
            if (lx_field(L, k, &len) != NULL) size += len + 1;
        lua_pop(L, 1);
    }
    if ((mem = malloc(size > 0 ? size : 1)) == NULL) return 0;

    /* 2. copy */
    out->mem = mem;
    out->tags = nt ? (lexiftool_tag*)mem : NULL;
    out->messages = nm ? (lexiftool_message*)(mem + nt * sizeof(lexiftool_tag)) : NULL;
    out->count = nt;
    out->message_count = nm;
    p = mem + nt * sizeof(lexiftool_tag) + nm * sizeof(lexiftool_message);
#define LX_COPY(dst, k) \
    do { \
        str = lx_field(L, k, &len); \
        if (str != NULL) { memcpy(p, str, len); p[len] = '\0'; (dst) = p; p += len + 1; } \
        else (dst) = NULL; \
    } while (0)
    for (i = 0; i < nt; i++) {
        lexiftool_tag* tag = &out->tags[i];
        lua_rawgeti(L, t, (lua_Integer)i + 1);
        LX_COPY(tag->name, 1);
        LX_COPY(tag->group, 2);
        LX_COPY(tag->value, 3);
        tag->value_len = str != NULL ? len : 0;
        if (tag->name == NULL) tag->name = "";
        if (tag->value == NULL) tag->value = "";
        lua_rawgeti(L, -1, 4);
        tag->binary = lua_toboolean(L, -1);
        lua_pop(L, 2);
    }
    for (i = 0; i < nm; i++) {
        lexiftool_message* msg = &out->messages[i];
        lua_rawgeti(L, m, (lua_Integer)i + 1);
        LX_COPY(msg->level, 1);
        LX_COPY(msg->text, 2);
        if (msg->level == NULL) msg->level = "";
        if (msg->text == NULL) msg->text = "";
        lua_pop(L, 1);
    }
#undef LX_COPY
    return 1;
}

/* ---------------------------------------------------------------------------
 * API
 */

const char* lexiftool_version(void)
{
    return LEXIFTOOL_PORT_VERSION;
}

const char* lexiftool_last_error(const lexiftool_session* s)
{
    return s != NULL ? s->error : NULL;
}

void lexiftool_result_free(lexiftool_result* r)
{
    if (r == NULL) return;
    free(r->stdout_data);
    free(r->stderr_data);
    memset(r, 0, sizeof(*r));
}

void lexiftool_tags_free(lexiftool_tags* t)
{
    if (t == NULL) return;
    free(t->mem);
    memset(t, 0, sizeof(*t));
}

/* the protected part of lexiftool_open (argument: the session): opens the
 * libraries, runs session.lua; leaves session.lua's table on the stack */
static int lx_start(lua_State* L)
{
    lexiftool_session* s = (lexiftool_session*)lua_touserdata(L, 1);
    const lexiftool_options* o = &s->options;
    int nargs;

    luaL_openlibs(L);
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
    if (!lx_setup(L)) return lua_error(L);    /* +3: launcher, VROOT, getFile */
#else
    lua_pushnil(L);
    lua_pushnil(L);
    lua_pushnil(L);
#endif
    if (o->config_file != NULL) lua_pushstring(L, o->config_file);
    else lua_pushnil(L);
    nargs = o->common_argc > 0 && o->common_argv != NULL ? o->common_argc : 0;
    lx_push_list(L, nargs, o->common_argv, 0);
    lua_call(L, 5, 1);
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
        size_t n = options->struct_size > 0 ? (size_t)options->struct_size
                                             : sizeof(*options);
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

int lexiftool_execute(lexiftool_session* s, int argc, const char* const argv[],
                      lexiftool_result* out)
{
    lua_State* L;
    const char* data, *state;
    size_t len;
    int rc, base;

    if (out == NULL) return LEXIFTOOL_E_ARG;
    memset(out, 0, sizeof(*out));
    rc = (argc < 0 || (argc > 0 && argv == NULL)) ? LEXIFTOOL_E_ARG : lx_check(s);
    if (rc != 0) {
        out->stdout_data = lx_dup("", 0);
        out->stderr_data = lx_dup("", 0);
        return rc;
    }
    L = s->L;
    base = lx_push_call(s, "execute");
    lx_push_list(L, argc, argv, 0);
    /* -> stdout, stderr, status, state, message */
    if (lua_pcall(L, 1, 5, base) != LUA_OK) {
        lx_set_error(s, lua_tostring(L, -1));
        s->dead = rc = LEXIFTOOL_E_FAILED;
    } else {
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
        if (rc == LEXIFTOOL_OK) rc = LEXIFTOOL_E_NOMEM;
        lx_set_error(s, "out of memory");
    }
    lua_settop(L, 0);
    return rc;
}

int lexiftool_image_info(lexiftool_session* s, const char* path, int argc,
                         const char* const argv[], lexiftool_tags* out)
{
    lua_State* L;
    int rc, base;

    if (out == NULL) return LEXIFTOOL_E_ARG;
    memset(out, 0, sizeof(*out));
    if (path == NULL || argc < 0 || (argc > 0 && argv == NULL)) return LEXIFTOOL_E_ARG;
    if ((rc = lx_check(s)) != 0) return rc;
    L = s->L;
    base = lx_push_call(s, "imageInfo");
    lua_pushstring(L, path);
    lx_push_list(L, argc, argv, 0);
    /* -> tags, messages, status  |  nil, message */
    if (lua_pcall(L, 2, 3, base) != LUA_OK) {
        lx_set_error(s, lua_tostring(L, -1));
        rc = LEXIFTOOL_E_ERROR;
    } else if (!lua_istable(L, base + 1)) {
        lx_set_error(s, lua_tostring(L, base + 2));
        rc = LEXIFTOOL_E_ARG;
    } else if (!lx_fill_tags(L, base + 1, base + 2, out)) {
        lx_set_error(s, "out of memory");
        rc = LEXIFTOOL_E_NOMEM;
    } else {
        out->status = (int)lua_tointeger(L, base + 3);
    }
    lua_settop(L, 0);
    return rc;
}

int lexiftool_set_tags(lexiftool_session* s, const char* path, int n,
                       const char* const names[], const char* const values[],
                       lexiftool_tags* out)
{
    lua_State* L;
    int rc, base, i;

    if (out == NULL) return LEXIFTOOL_E_ARG;
    memset(out, 0, sizeof(*out));
    if (path == NULL || n < 0 || (n > 0 && (names == NULL || values == NULL)))
        return LEXIFTOOL_E_ARG;
    for (i = 0; i < n; i++)
        if (names[i] == NULL) return LEXIFTOOL_E_ARG;
    if ((rc = lx_check(s)) != 0) return rc;
    L = s->L;
    base = lx_push_call(s, "setTags");
    lua_pushstring(L, path);
    lx_push_list(L, n, names, 0);
    lx_push_list(L, n, values, 1);      /* NULL value: delete the tag */
    lua_pushinteger(L, n);
    /* -> messages, status */
    if (lua_pcall(L, 4, 2, base) != LUA_OK) {
        lx_set_error(s, lua_tostring(L, -1));
        rc = LEXIFTOOL_E_ERROR;
    } else if (!lx_fill_tags(L, 0, base + 1, out)) {
        lx_set_error(s, "out of memory");
        rc = LEXIFTOOL_E_NOMEM;
    } else {
        out->status = (int)lua_tointeger(L, base + 2);
    }
    lua_settop(L, 0);
    return rc;
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
