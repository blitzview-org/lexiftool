/*------------------------------------------------------------------------------
 * File:         capi/test_capi.c
 *
 * Description:  Tests of the lexiftool C API prototype (run by
 *               build-linux.sh): many commands in one session, two sessions
 *               used alternately from one thread, -common_args, binary
 *               stdout (-b), status codes, lexiftool_image_info against -j
 *               tag for tag, lexiftool_set_tags, the end of a session by
 *               "-stay_open False", repeated open/close. Prints "ok"/"not
 *               ok" lines and the resident set size (Linux /proc) for a
 *               coarse leak check; run it under ASan or valgrind for the
 *               exact one.
 *               Usage: test_capi T_IMAGES_DIR [ITERATIONS [THUMB_OUT
 *                                [INFO_THUMB_OUT [SCRATCH_DIR]]]]
 *------------------------------------------------------------------------------
 */

#define _POSIX_C_SOURCE 200809L    /* sigaction */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lexiftool.h"

static int failed = 0, total = 0;

static void ok(int cond, const char* name)
{
    total++;
    if (!cond) failed++;
    printf("%s %d - %s\n", cond ? "ok" : "not ok", total, name);
}

static long rss_kb(void)
{
    long pages = 0, rss = 0;
    FILE* f = fopen("/proc/self/statm", "r");
    if (f == NULL) return -1;
    if (fscanf(f, "%ld %ld", &pages, &rss) != 2) rss = -1;
    fclose(f);
    return rss < 0 ? -1 : rss * 4;
}

/* run argv, return rc; result in *r (caller frees) */
static int exec2(lexiftool_session* s, lexiftool_result* r, const char* a, const char* b)
{
    const char* argv[2] = { a, b };
    return lexiftool_execute(s, b ? 2 : 1, argv, r);
}

static void write_file(const char* path, const char* data, size_t len)
{
    FILE* f = fopen(path, "wb");
    if (f) { fwrite(data, 1, len, f); fclose(f); }
}

/* ---------------------------------------------------------------------------
 * A minimal reader for the -j output of one file: [{ "KEY": VALUE, ... }]
 * with VALUE a string, a number or an array of those (joined with ", " as
 * lexiftool_image_info joins lists). Keys "GROUP:NAME" with -G.
 */
typedef struct { char* key; char* val; } kv;

static const char* jp;      /* parse position */

static void skipws(void) { while (*jp == ' ' || *jp == '\n' || *jp == '\r' || *jp == '\t') jp++; }

static void put_utf8(char** o, unsigned c)
{
    char* p = *o;
    if (c < 0x80) *p++ = (char)c;
    else if (c < 0x800) { *p++ = (char)(0xC0 | (c >> 6)); *p++ = (char)(0x80 | (c & 0x3F)); }
    else { *p++ = (char)(0xE0 | (c >> 12)); *p++ = (char)(0x80 | ((c >> 6) & 0x3F));
           *p++ = (char)(0x80 | (c & 0x3F)); }
    *o = p;
}

/* a JSON scalar (string or number) as a malloc'd string */
static char* jscalar(void)
{
    char* buf, *o;
    skipws();
    if (*jp == '"') {
        buf = o = malloc(strlen(jp) + 1);
        jp++;
        while (*jp && *jp != '"') {
            if (*jp == '\\') {
                jp++;
                switch (*jp) {
                case 'n': *o++ = '\n'; break;
                case 'r': *o++ = '\r'; break;
                case 't': *o++ = '\t'; break;
                case 'b': *o++ = '\b'; break;
                case 'f': *o++ = '\f'; break;
                case 'u': { unsigned c = 0; sscanf(jp + 1, "%4x", &c); jp += 4; put_utf8(&o, c); break; }
                default:  *o++ = *jp; break;
                }
                jp++;
            } else {
                *o++ = *jp++;
            }
        }
        *o = '\0';
        if (*jp == '"') jp++;
        return buf;
    }
    {   /* number (or true/false/null): the token as it is */
        const char* start = jp;
        while (*jp && *jp != ',' && *jp != '}' && *jp != ']' && *jp != '\n') jp++;
        buf = malloc((size_t)(jp - start) + 1);
        memcpy(buf, start, (size_t)(jp - start));
        buf[jp - start] = '\0';
        return buf;
    }
}

static char* jvalue(void)
{
    skipws();
    if (*jp == '[') {
        size_t len = 0;
        char* acc = calloc(1, 1);
        jp++;
        skipws();
        while (*jp && *jp != ']') {
            char* item = jscalar();
            acc = realloc(acc, len + strlen(item) + 3);
            if (len > 0) { memcpy(acc + len, ", ", 2); len += 2; }
            memcpy(acc + len, item, strlen(item) + 1);
            len += strlen(item);
            free(item);
            skipws();
            if (*jp == ',') jp++;
            skipws();
        }
        if (*jp == ']') jp++;
        return acc;
    }
    return jscalar();
}

/* parses the object of the first file; returns the number of entries */
static size_t jparse(const char* json, kv* out, size_t max)
{
    size_t n = 0;
    jp = json;
    skipws();
    if (*jp == '[') jp++;
    skipws();
    if (*jp != '{') return 0;
    jp++;
    for (;;) {
        skipws();
        if (*jp != '"') break;
        if (n == max) return n;
        out[n].key = jscalar();
        skipws();
        if (*jp == ':') jp++;
        out[n].val = jvalue();
        n++;
        skipws();
        if (*jp == ',') jp++;
    }
    return n;
}

/* image_info(file, opts) == -j opts file, entry for entry (SourceFile
 * aside); returns 1 if equal, prints the first difference */
static int same_as_json(lexiftool_session* s, const char* file, int nopt, const char* opt[])
{
    enum { MAX = 2000 };
    static kv j[MAX];
    const char* argv[4];
    lexiftool_result r;
    lexiftool_tags t;
    size_t n, i;
    int k, rc, same = 1;

    for (k = 0; k < nopt; k++) argv[k] = opt[k];
    argv[nopt] = "-j";
    argv[nopt + 1] = file;
    rc = lexiftool_execute(s, nopt + 2, argv, &r);
    if (rc != LEXIFTOOL_OK) return 0;
    n = jparse(r.stdout_data, j, MAX);
    rc = lexiftool_image_info(s, file, nopt, opt, &t);
    if (rc != LEXIFTOOL_OK || n < 2 || strcmp(j[0].key, "SourceFile") != 0 || t.count != n - 1) {
        printf("# %s: rc %d, %zu JSON entries, %zu tags\n", file, rc, n, t.count);
        same = 0;
    }
    for (i = 1; same && i < n; i++) {
        const lexiftool_tag* tag = &t.tags[i - 1];
        char key[512];
        if (tag->group) snprintf(key, sizeof(key), "%s:%s", tag->group, tag->name);
        else snprintf(key, sizeof(key), "%s", tag->name);
        /* -j writes the values True/False as JSON booleans and drops NUL
         * bytes (EscapeJSON); the value itself keeps them */
        char* v = malloc(tag->value_len + 1), *q = v;
        size_t m;
        int boolean;
        for (m = 0; m < tag->value_len; m++)
            if (tag->value[m] != '\0') *q++ = tag->value[m];
        *q = '\0';
        boolean = (strcmp(j[i].val, "true") == 0 && strcmp(v, "True") == 0) ||
                  (strcmp(j[i].val, "false") == 0 && strcmp(v, "False") == 0);
        if (strcmp(key, j[i].key) != 0 || (strcmp(v, j[i].val) != 0 && !boolean)) {
            printf("# entry %zu: -j \"%s\" = \"%s\", image_info \"%s\" = \"%s\"\n",
                   i, j[i].key, j[i].val, key, v);
            same = 0;
        }
        free(v);
    }
    for (i = 0; i < n; i++) { free(j[i].key); free(j[i].val); }
    lexiftool_tags_free(&t);
    lexiftool_result_free(&r);
    return same;
}

int main(int argc, char** argv)
{
    char canon[1024], nikon[1024], exiftooljpg[1024], copy[1100];
    int iterations = argc > 2 ? atoi(argv[2]) : 100;
    lexiftool_options opt = { .struct_size = sizeof(opt) };
    const char* common[] = { "-G" };
    lexiftool_options optG = { .struct_size = sizeof(optG),
                               .common_argc = 1, .common_argv = common };
    lexiftool_session* s, *a, *b;
    lexiftool_result r, ref;
    lexiftool_tags t;
    int i, same, rc;
    long rss0, rss1;

    if (argc < 2) {
        fprintf(stderr, "usage: test_capi T_IMAGES_DIR [ITERATIONS [THUMB_OUT [INFO_THUMB_OUT [SCRATCH_DIR]]]]\n");
        return 2;
    }
    snprintf(canon, sizeof(canon), "%s/Canon.jpg", argv[1]);
    snprintf(nikon, sizeof(nikon), "%s/Nikon.jpg", argv[1]);
    snprintf(exiftooljpg, sizeof(exiftooljpg), "%s/ExifTool.jpg", argv[1]);

    /* 1. many commands in one session ---------------------------------- */
    s = lexiftool_open(&opt);
    ok(s != NULL && lexiftool_last_error(s) == NULL, "open");
    {   /* main.lua sets $SIG{INT}: must not reach the process */
        struct sigaction sa;
        sigaction(SIGINT, NULL, &sa);
        ok(sa.sa_handler == SIG_DFL, "no process-wide SIGINT handler installed");
    }
    rc = exec2(s, &ref, "-j", canon);
    ok(rc == LEXIFTOOL_OK && ref.status == 0 && ref.stdout_len > 1000, "-j Canon.jpg");
    ok(strstr(ref.stdout_data, "{ready") == NULL, "no {ready} in stdout");
    rss0 = rss_kb();
    same = 1;
    for (i = 0; i < iterations; i++) {
        rc = exec2(s, &r, "-j", canon);
        if (rc != LEXIFTOOL_OK || r.status != 0 || r.stdout_len != ref.stdout_len ||
            memcmp(r.stdout_data, ref.stdout_data, r.stdout_len) != 0 || r.stderr_len != 0)
            same = 0;
        lexiftool_result_free(&r);
    }
    rss1 = rss_kb();
    ok(same, "same -j output on every iteration");
    printf("# %d commands: RSS %ld kB -> %ld kB\n", iterations, rss0, rss1);

    rc = exec2(s, &r, "-ver", NULL);
    ok(rc == LEXIFTOOL_OK && r.status == 0 && strncmp(r.stdout_data, "13.", 3) == 0, "-ver");
    lexiftool_result_free(&r);

    rc = exec2(s, &r, "-j", "/nonexistent/file.jpg");
    ok(rc == LEXIFTOOL_OK && r.status == 1 && strstr(r.stderr_data, "File not found") != NULL,
       "missing file: status 1 and message on stderr");
    lexiftool_result_free(&r);

    {   /* -echo4 with ${status}: the status of the previous command */
        const char* e[] = { "-echo4", "status=${status}", "-ver" };
        rc = lexiftool_execute(s, 3, e, &r);
        ok(rc == LEXIFTOOL_OK && strcmp(r.stderr_data, "status=0\n") == 0, "-echo4 ${status}");
        lexiftool_result_free(&r);
    }
    {   /* arguments are passed verbatim: newline and blanks kept */
        const char* e[] = { "-echo", " two\nlines " };
        rc = lexiftool_execute(s, 2, e, &r);
        ok(rc == LEXIFTOOL_OK && strcmp(r.stdout_data, " two\nlines \n") == 0,
           "arguments verbatim");
        lexiftool_result_free(&r);
    }

    /* 2. binary stdout --------------------------------------------------- */
    {
        const char* e[] = { "-b", "-ThumbnailImage", exiftooljpg };
        rc = lexiftool_execute(s, 3, e, &r);
        ok(rc == LEXIFTOOL_OK && r.stdout_len > 1000 &&
           (unsigned char)r.stdout_data[0] == 0xFF && (unsigned char)r.stdout_data[1] == 0xD8,
           "-b -ThumbnailImage ExifTool.jpg: JPEG bytes");
        if (argc > 3) write_file(argv[3], r.stdout_data, r.stdout_len);
        lexiftool_result_free(&r);
    }

    /* 3. structured: lexiftool_image_info ------------------------------- */
    {
        const char* g1[] = { "-G1" };
        const char* g01[] = { "-G0:1", "-n" };
        ok(same_as_json(s, canon, 0, NULL), "image_info Canon.jpg == -j, tag for tag");
        ok(same_as_json(s, canon, 1, g1), "image_info -G1 Canon.jpg == -j -G1");
        ok(same_as_json(s, exiftooljpg, 2, g01), "image_info -G0:1 -n ExifTool.jpg == -j -G0:1 -n (lists)");
    }
    {
        const char* o[] = { "-b", "-ThumbnailImage" };
        rc = lexiftool_image_info(s, exiftooljpg, 2, o, &t);
        ok(rc == LEXIFTOOL_OK && t.count == 1 && t.tags[0].binary &&
           strcmp(t.tags[0].name, "ThumbnailImage") == 0 && t.tags[0].value_len > 1000,
           "image_info -b -ThumbnailImage: raw bytes");
        if (rc == LEXIFTOOL_OK && t.count == 1 && argc > 4)
            write_file(argv[4], t.tags[0].value, t.tags[0].value_len);
        ok(rc == LEXIFTOOL_OK && t.message_count >= 1 &&
           strcmp(t.messages[0].level, "Warning") == 0 &&
           strstr(t.messages[0].text, "IPTCDigest") != NULL && t.status == 0,
           "image_info: warnings as messages, status 0");
        lexiftool_tags_free(&t);
    }
    {
        const char* o[] = { "-ThumbnailImage" };
        rc = lexiftool_image_info(s, exiftooljpg, 1, o, &t);
        ok(rc == LEXIFTOOL_OK && t.count == 1 && !t.tags[0].binary &&
           strncmp(t.tags[0].value, "(Binary data ", 13) == 0, "image_info: binary placeholder without -b");
        lexiftool_tags_free(&t);
    }
    rc = lexiftool_image_info(s, "/nonexistent/file.jpg", 0, NULL, &t);
    ok(rc == LEXIFTOOL_OK && t.count == 0 && t.status == 1 && t.message_count == 1 &&
       strcmp(t.messages[0].level, "Error") == 0 &&
       strcmp(t.messages[0].text, "File not found") == 0, "image_info: missing file");
    lexiftool_tags_free(&t);
    {
        const char* o[] = { "-Make", "other.jpg" };
        rc = lexiftool_image_info(s, canon, 2, o, &t);
        ok(rc == LEXIFTOOL_E_ARG && lexiftool_last_error(s) != NULL && t.count == 0,
           "image_info: a file name among the options is LEXIFTOOL_E_ARG");
        lexiftool_tags_free(&t);
    }

    /* 4. lexiftool_set_tags ----------------------------------------------- */
    if (argc > 5) {
        const char* names[] = { "Artist", "Copyright", "Bogus" };
        const char* values[] = { "Test Artist", "(c) test", "x" };
        const char* o[] = { "-Artist", "-Copyright" };
        lexiftool_result c;
        snprintf(copy, sizeof(copy), "%s/settags.jpg", argv[5]);
        {   /* copy Canon.jpg */
            FILE* in = fopen(canon, "rb"), *out = fopen(copy, "wb");
            char buf[65536];
            size_t n;
            while (in && out && (n = fread(buf, 1, sizeof(buf), in)) > 0) fwrite(buf, 1, n, out);
            if (in) fclose(in);
            if (out) fclose(out);
        }
        rc = lexiftool_set_tags(s, copy, 3, names, values, &t);
        ok(rc == LEXIFTOOL_OK && t.status == 0 && t.message_count == 1 &&
           strstr(t.messages[0].text, "Bogus") != NULL, "set_tags: written, unknown tag as warning");
        lexiftool_tags_free(&t);
        rc = lexiftool_image_info(s, copy, 2, o, &t);
        ok(rc == LEXIFTOOL_OK && t.count == 2 && strcmp(t.tags[0].value, "Test Artist") == 0 &&
           strcmp(t.tags[1].value, "(c) test") == 0, "set_tags: values read back");
        lexiftool_tags_free(&t);
        rc = exec2(s, &c, "-Artist", copy);
        ok(rc == LEXIFTOOL_OK && strstr(c.stdout_data, "Test Artist") != NULL, "set_tags: seen by the CLI path");
        lexiftool_result_free(&c);
        {
            const char* del[] = { "Artist" };
            const char* nul[] = { NULL };
            rc = lexiftool_set_tags(s, copy, 1, del, nul, &t);
            lexiftool_tags_free(&t);
            rc = lexiftool_image_info(s, copy, 2, o, &t);
            ok(rc == LEXIFTOOL_OK && t.count == 1 && strcmp(t.tags[0].name, "Copyright") == 0,
               "set_tags: NULL value deletes");
            lexiftool_tags_free(&t);
        }
    }

    /* 5. two sessions, used alternately -------------------------------------
     * Each session runs ROUNDS x (-j Canon.jpg, -s Nikon.jpg); b with the
     * common argument -G. Reference: the same sequence, each in a session
     * of its own, run one after the other. (The -j output is not the same
     * in every round: like exiftool's, the Composite tag order depends on
     * the files processed before in the same process.) */
    {
        enum { ROUNDS = 10 };
        static lexiftool_result want[2][ROUNDS];
        const lexiftool_options* o[2] = { &opt, &optG };
        lexiftool_session* x[2];
        int k, j;

        same = 1;
        for (j = 0; j < 2; j++) {
            lexiftool_session* t2 = lexiftool_open(o[j]);
            for (k = 0; k < ROUNDS; k++) {
                if (exec2(t2, &want[j][k], "-j", canon) != LEXIFTOOL_OK) same = 0;
                if (exec2(t2, &r, "-s", nikon) != LEXIFTOOL_OK) same = 0;
                lexiftool_result_free(&r);
            }
            lexiftool_close(t2);
        }
        ok(same && strstr(want[1][0].stdout_data, "\"EXIF:Make\"") != NULL &&
           strstr(want[0][0].stdout_data, "\"EXIF:Make\"") == NULL,
           "reference sequences (common_args -G in the second)");
        ok(same && strstr(want[1][ROUNDS - 1].stdout_data, "\"EXIF:Make\"") != NULL,
           "-common_args still applied in the last command");
        a = lexiftool_open(&opt);
        b = lexiftool_open(&optG);
        ok(a && b && !lexiftool_last_error(a) && !lexiftool_last_error(b), "open two sessions");
        x[0] = a;
        x[1] = b;
        for (k = 0; k < ROUNDS; k++) {
            for (j = 0; j < 2; j++) {
                rc = exec2(x[j], &r, "-j", canon);
                if (rc != LEXIFTOOL_OK || r.stdout_len != want[j][k].stdout_len ||
                    memcmp(r.stdout_data, want[j][k].stdout_data, r.stdout_len) != 0) {
                    if (same) printf("# session %c, round %d differs\n", "ab"[j], k);
                    same = 0;
                }
                lexiftool_result_free(&r);
            }
            for (j = 0; j < 2; j++) {
                rc = exec2(x[j], &r, "-s", nikon);
                if (rc != LEXIFTOOL_OK || r.status != 0) same = 0;
                lexiftool_result_free(&r);
            }
        }
        ok(same, "alternating sessions: same output as each one alone");
        lexiftool_close(a);
        lexiftool_close(b);
        for (j = 0; j < 2; j++)
            for (k = 0; k < ROUNDS; k++) lexiftool_result_free(&want[j][k]);
    }

    /* 6. the end of a session ------------------------------------------- */
    rc = exec2(s, &r, "-stay_open", "False");
    ok(rc == LEXIFTOOL_E_ENDED, "-stay_open False ends the session");
    lexiftool_result_free(&r);
    rc = exec2(s, &r, "-ver", NULL);
    ok(rc == LEXIFTOOL_E_ENDED && r.stdout_data && r.stdout_len == 0, "no command after the end");
    lexiftool_result_free(&r);
    lexiftool_close(s);
    lexiftool_result_free(&ref);

    /* 7. repeated open/close --------------------------------------------- */
    rss0 = rss_kb();
    same = 1;
    for (i = 0; i < 10; i++) {
        s = lexiftool_open(&opt);
        rc = exec2(s, &r, "-ver", NULL);
        if (rc != LEXIFTOOL_OK) same = 0;
        lexiftool_result_free(&r);
        lexiftool_close(s);
    }
    rss1 = rss_kb();
    ok(same, "10x open/-ver/close");
    printf("# 10 sessions: RSS %ld kB -> %ld kB\n", rss0, rss1);

    printf("# %d tests, %d failed\n", total, failed);
    return failed ? 1 : 0;
}
