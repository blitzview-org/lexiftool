/*------------------------------------------------------------------------------
 * File:         capi/test_hostlibs.c
 *
 * Description:  The embedded lexiftool library inside a host program that
 *               links a Lua of another version and the system's zlib
 *               itself (build-linux.sh embedded links it against
 *               liblexiftool.a and liblexiftool.so, test runs it). Both
 *               libraries carry their own Lua 5.5 and zlib with every
 *               symbol but lexiftool_* hidden, so neither the static link
 *               nor the dynamic loader may mix them up (Linux, macOS,
 *               Windows: there the DLL, or the program that links the
 *               static library, exports none of them): the host's Lua
 *               reports its own version and keeps working while sessions
 *               run, the host's zlib is the system's, lexiftool reports
 *               its own Lua and zlib and writes and reads a compressed PNG
 *               text chunk, and none of the libraries' internal symbols
 *               (Lua, PCRE2) can be found in the process.
 *               Prints "ok"/"not ok" lines.
 *               Usage: test_hostlibs T_IMAGES_DIR SCRATCH_DIR
 *------------------------------------------------------------------------------
 */

#include "test_platform.h"
#if !defined(_WIN32)
#  include <dlfcn.h>
#endif
#include <zlib.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "lexiftool.h"

static int failed = 0, total = 0;

static void ok(int cond, const char* name)
{
    total++;
    if (!cond) failed++;
    printf("%s %d - %s\n", cond ? "ok" : "not ok", total, name);
    fflush(stdout);
}

/* runs CODE in the host's Lua state; its string result or NULL */
static const char* host_lua(lua_State* L, const char* code)
{
    lua_settop(L, 0);
    if (luaL_dostring(L, code) != LUA_OK) {
        printf("# host Lua: %s\n", lua_tostring(L, -1));
        return NULL;
    }
    return lua_tostring(L, -1);
}

/* the host's zlib: a round trip through compress/uncompress */
static int host_zlib(void)
{
    const char text[] = "the host's own zlib, the host's own zlib, the host's own zlib";
    unsigned char packed[256], back[256];
    uLongf plen = sizeof(packed), blen = sizeof(back);
    return compress(packed, &plen, (const unsigned char*)text, sizeof(text)) == Z_OK &&
           uncompress(back, &blen, packed, plen) == Z_OK &&
           blen == sizeof(text) && memcmp(back, text, blen) == 0;
}

/* the value of "Name (version)" in -ver -v output: the text after
 * PREFIX up to the end of the line, copied into BUF */
static const char* line_after(const char* out, const char* prefix, char* buf, size_t size)
{
    const char* p = strstr(out, prefix);
    size_t n;
    if (p == NULL) return NULL;
    p += strlen(prefix);
    n = strcspn(p, "\n");
    if (n >= size) n = size - 1;
    memcpy(buf, p, n);
    buf[n] = '\0';
    return buf;
}

int main(int argc, char** argv)
{
    lua_State* L;
    lexiftool_session* s;
    lexiftool_result r;
    lexiftool_info info;
    char png[4096], out[4096], buf[256], zver[64], comment[1024] = "", assign[1100];
    const char* v;
    int i, found;

    if (argc < 3) {
        fprintf(stderr, "usage: test_hostlibs T_IMAGES_DIR SCRATCH_DIR\n");
        return 2;
    }
    snprintf(png, sizeof(png), "%s/PNG.png", argv[1]);
    snprintf(out, sizeof(out), "%s/hostlibs.png", argv[2]);
    remove(out);

    /* the host's own libraries, before any session */
    L = luaL_newstate();
    luaL_openlibs(L);
    v = host_lua(L, "return _VERSION");
    printf("# host: %s (header %s), zlib %s (header %s)\n", v ? v : "?", LUA_VERSION,
           zlibVersion(), ZLIB_VERSION);
    ok(v != NULL && strcmp(v, LUA_VERSION) == 0 && lua_version(L) == LUA_VERSION_NUM,
       "host Lua: its own version");
    ok(strcmp(zlibVersion(), ZLIB_VERSION) == 0 && host_zlib(), "host zlib: the system's, working");

    /* a session in between */
    s = lexiftool_open(NULL);
    ok(s != NULL && lexiftool_state(s) == LEXIFTOOL_OK, "lexiftool session opened");
    {
        const char* a[] = { "-ver", "-v" };
        memset(&r, 0, sizeof(r));
        ok(lexiftool_execute(s, 2, a, &r) == LEXIFTOOL_OK && r.status == 0 && r.stdout_data != NULL,
           "lexiftool -ver -v");
        printf("# lexiftool: %s\n", line_after(r.stdout_data ? r.stdout_data : "", "lexiftool port ", buf, sizeof(buf))
                                     ? buf : "?");
        ok(r.stdout_data != NULL && strstr(r.stdout_data, ", Lua 5.5.") != NULL, "lexiftool runs its own Lua 5.5");
        if (line_after(r.stdout_data ? r.stdout_data : "", "Compress::Zlib", buf, sizeof(buf)) != NULL) {
            const char* z = strstr(buf, "(zlib ");
            snprintf(zver, sizeof(zver), "%s", z ? z + 6 : "?");
            zver[strcspn(zver, ")")] = '\0';
        } else {
            strcpy(zver, "?");
        }
        printf("# lexiftool's zlib %s, the host's %s\n", zver, zlibVersion());
        ok(strcmp(zver, "?") != 0, "lexiftool reports its zlib");
        if (strcmp(zver, zlibVersion()) == 0)
            printf("# (same zlib version on both sides: the versions cannot tell them apart)\n");
        lexiftool_result_free(&r);
    }
    /* the host's Lua between two lexiftool calls */
    v = host_lua(L, "local t = {} for i = 1, 1000 do t[i] = i * 2 end "
                    "return ('%d %s'):format(#t, math.type(1 // 1))");
    ok(v != NULL && strcmp(v, "1000 integer") == 0, "host Lua works while a session is open");
    for (i = 0; i < 20; i++) strcat(comment, "[compressed by lexiftool's own zlib]");
    snprintf(assign, sizeof(assign), "-PNG:Comment=%s", comment);
    {   /* compressed text through lexiftool's zlib, written and read back
         * (long and repetitive: exiftool keeps text that would not get
         * smaller as tEXt) */
        const char* a[] = { "-zip", assign, "-o", out, png };
        const char* tags[] = { "PNG:Comment" };
        memset(&r, 0, sizeof(r));
        ok(lexiftool_execute(s, 5, a, &r) == LEXIFTOOL_OK && r.status == 0,
           "lexiftool writes a compressed text chunk (-zip)");
        lexiftool_result_free(&r);
        memset(&info, 0, sizeof(info));
        found = 0;
        if (lexiftool_image_info(s, out, tags, 1, 0, &info) == LEXIFTOOL_OK) {
            for (i = 0; i < (int)info.count; i++)
                if (strcmp(info.tags[i].name, "Comment") == 0 &&
                    strcmp(info.tags[i].value, comment) == 0)
                    found = 1;
        }
        ok(found, "... and reads it back");
        lexiftool_info_free(&info);
    }
    {   /* the zTXt chunk really is compressed: inflate it with the host's zlib */
        FILE* f = fopen(out, "rb");
        unsigned char data[65536], text[1024];
        size_t n = f ? fread(data, 1, sizeof(data), f) : 0, k;
        uLongf tlen = sizeof(text);
        int inflated = 0;
        if (f) fclose(f);
        for (k = 8; k + 12 <= n; ) {
            size_t len = ((size_t)data[k] << 24) | (data[k + 1] << 16) | (data[k + 2] << 8) | data[k + 3];
            if (k + 12 + len > n) break;
            if (memcmp(data + k + 4, "zTXt", 4) == 0) {
                const unsigned char* c = data + k + 8;
                size_t kw = strnlen((const char*)c, len);
                /* keyword, NUL, method 0, zlib stream */
                if (kw + 2 < len && uncompress(text, &tlen, c + kw + 2, len - kw - 2) == Z_OK &&
                    tlen == strlen(comment) && memcmp(text, comment, tlen) == 0)
                    inflated = 1;
            }
            k += 12 + len;
        }
        ok(inflated, "the host's zlib inflates lexiftool's zTXt chunk");
    }
    lexiftool_close(s);

#if defined(_WIN32)
    {   /* the module that holds lexiftool (the DLL, or the program itself)
         * exports neither Lua's nor PCRE2's, libbz2's, liblzma's or the
         * setup's symbols */
        static const char* const names[] = { "lua_newstate", "luaL_newstate", "pcre2_compile_8",
                                             "BZ2_bzlibVersion", "lzma_version_string", "lx_setup",
                                             "luaopen_carray", "inflate" };
        HMODULE m = NULL;
        int none = GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                                      GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                                      (LPCSTR)(void*)lexiftool_open, &m) != 0;
        size_t k;
        for (k = 0; none && k < sizeof(names) / sizeof(names[0]); k++)
            if (GetProcAddress(m, names[k]) != NULL) {
                printf("# %s exported\n", names[k]);
                none = 0;
            }
        ok(none, "lexiftool's module exports no Lua, PCRE2, zlib, libbz2, liblzma or setup symbols");
        ok(GetProcAddress(m, "lexiftool_open") != NULL || m == GetModuleHandleA(NULL),
           "... but lexiftool_open (DLL)");
    }
#else
    /* the libraries' own symbols cannot be found in the process: Lua's
     * (the host's Lua defines them itself, so the lookup must give the
     * host's) and PCRE2's (the host has none) */
    ok(dlsym(RTLD_DEFAULT, "lua_newstate") == (void*)lua_newstate,
       "lua_newstate in the process is the host's");
    ok(dlsym(RTLD_DEFAULT, "pcre2_compile_8") == NULL && dlsym(RTLD_DEFAULT, "BZ2_bzlibVersion") == NULL &&
       dlsym(RTLD_DEFAULT, "lzma_version_string") == NULL && dlsym(RTLD_DEFAULT, "lx_setup") == NULL,
       "no PCRE2, libbz2, liblzma or setup symbols visible");

#endif
    /* and the host's Lua after the session */
    v = host_lua(L, "return _VERSION");
    ok(v != NULL && lua_version(L) == LUA_VERSION_NUM && host_zlib(), "host Lua and zlib after the session");
    lua_close(L);

    printf("%s: %d of %d ok\n", failed ? "FAILED" : "PASSED", total - failed, total);
    return failed ? 1 : 0;
}
