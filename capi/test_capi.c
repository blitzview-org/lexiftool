/*------------------------------------------------------------------------------
 * File:         capi/test_capi.c
 *
 * Description:  Tests of the lexiftool C API (run by build-linux.sh, build-macos.sh
 *               and build-windows.sh test):
 *               every function, with its edge cases -- sessions (open,
 *               failed start, struct_size, state, close), commands
 *               (execute, execute_text with the argfile rules, binary
 *               stdout, status, -stay_open False), the session's ExifTool
 *               object (set_option, image_info with tag lists, duplicates,
 *               binary values with and without request, NUL bytes,
 *               set_new_value/write_info with read back, a UTF-8 file name
 *               with CharsetFileName), two sessions used
 *               alternately, several threads with a session each, repeated
 *               open/close, no process-wide signal handler. Prints "ok"/
 *               "not ok" lines; run it under ASan/LeakSanitizer or
 *               valgrind for the memory checks.
 *               Usage: test_capi T_IMAGES_DIR SCRATCH_DIR [ITERATIONS]
 *               Compiled with -DLEXIFTOOL_TEST_EMBEDDED for the embedded
 *               libraries, whose modules do not come from lua_path/
 *               lua_cpath: there a start with such paths succeeds.
 *------------------------------------------------------------------------------
 */

#include "test_platform.h"
#include <stddef.h>
#include "lexiftool.h"

static int failed = 0, total = 0;

static void ok(int cond, const char* name)
{
    total++;
    if (!cond) failed++;
    printf("%s %d - %s\n", cond ? "ok" : "not ok", total, name);
    fflush(stdout);
}

static int exec1(lexiftool_session* s, lexiftool_result* r, const char* a,
                 const char* b, const char* c)
{
    const char* argv[3] = { a, b, c };
    return lexiftool_execute(s, c ? 3 : b ? 2 : 1, argv, r);
}

static const lexiftool_tag* find_tag(const lexiftool_info* info, const char* name, int copy)
{
    size_t i;
    for (i = 0; i < info->count; i++)
        if (strcmp(info->tags[i].name, name) == 0 && info->tags[i].copy_num == copy)
            return &info->tags[i];
    return NULL;
}

/* one value read back with image_info (NULL if not there; malloc'd) */
static char* read_value(lexiftool_session* s, const char* file, const char* tag, size_t* len)
{
    lexiftool_info info;
    const char* name = strchr(tag, ':') ? strchr(tag, ':') + 1 : tag;
    const lexiftool_tag* t;
    char* v = NULL;
    if (lexiftool_image_info(s, file, &tag, 1, 0, &info) == LEXIFTOOL_OK &&
        (t = find_tag(&info, name, 0)) != NULL && (v = malloc(t->value_len + 1)) != NULL) {
        memcpy(v, t->value, t->value_len + 1);
        if (len) *len = t->value_len;
    }
    lexiftool_info_free(&info);
    return v;
}

/* a text dump of all fields of an info (for comparisons between runs),
 * except FileAccessDate: reading the file may change it (on a fresh copy
 * with relatime the first read does), as in test_threads.c */
static char* dump_info(const lexiftool_info* info)
{
    size_t size = 64, i, n = 0;
    char* p;
    for (i = 0; i < info->count; i++) {
        const lexiftool_tag* t = &info->tags[i];
        size += strlen(t->name) + strlen(t->group[0]) + strlen(t->group[1]) +
                strlen(t->group[2]) + strlen(t->desc) + strlen(t->id) +
                t->value_len + t->num_len + 64;
    }
    if ((p = malloc(size)) == NULL) return NULL;
    for (i = 0; i < info->count; i++) {
        const lexiftool_tag* t = &info->tags[i];
        if (strcmp(t->name, "FileAccessDate") == 0) continue;
        n += (size_t)sprintf(p + n, "%s|%s|%s|%s|%s|%s|%d|%d|%zu|", t->name, t->group[0],
                             t->group[1], t->group[2], t->desc, t->id, t->copy_num,
                             t->binary, t->binary_len);
        memcpy(p + n, t->value, t->value_len); n += t->value_len;
        p[n++] = '|';
        memcpy(p + n, t->num, t->num_len); n += t->num_len;
        p[n++] = '\n';
    }
    p[n] = '\0';
    return p;
}

/* ---------------------------------------------------------------------------
 * Threads: each runs the same sequence in a session of its own; the
 * result is compared with the same sequence run alone before.
 * Google.jpg: its HDR+ maker note runs the C module lexiftool.util
 * (base64decode, pbRecord/pbIsProtobuf, hdrpDecrypt) in parallel sessions.
 */
enum { NTHREADS = 4, NFILES = 5 };
static const char* const thread_files[NFILES] = { "Canon.jpg", "Nikon.jpg", "ExifTool.jpg", "XMP.jpg",
                                                  "Google.jpg" };

typedef struct {
    const char* dir;
    const char* zone;   /* TimeZone option of the session */
    char*       out;    /* the dumps of all files plus a command's stdout */
    int         rc;
} job;

static void* run_job(void* arg)
{
    job* j = arg;
    lexiftool_session* s = lexiftool_open(NULL);
    size_t len = 0;
    int i;
    j->out = calloc(1, 1);
    j->rc = s == NULL ? LEXIFTOOL_E_NOMEM : lexiftool_state(s);
    if (j->rc == LEXIFTOOL_OK) j->rc = lexiftool_set_option(s, "TimeZone", j->zone);
    for (i = 0; i < NFILES && j->rc == LEXIFTOOL_OK; i++) {
        char path[1100];
        lexiftool_info info;
        lexiftool_result r;
        char* d;
        const char* v[] = { "-j", "-G1", "--FileAccessDate", path };
        snprintf(path, sizeof(path), "%s/%s", j->dir, thread_files[i]);
        if ((j->rc = lexiftool_image_info(s, path, NULL, 0, 0, &info)) != LEXIFTOOL_OK) break;
        d = dump_info(&info);
        lexiftool_info_free(&info);
        if ((j->rc = lexiftool_execute(s, 4, v, &r)) == LEXIFTOOL_OK && d != NULL) {
            size_t dl = strlen(d);
            char* o = realloc(j->out, len + dl + r.stdout_len + 1);
            if (o != NULL) {
                memcpy(o + len, d, dl);
                memcpy(o + len + dl, r.stdout_data, r.stdout_len);
                len += dl + r.stdout_len;
                o[len] = '\0';
                j->out = o;
            }
        }
        free(d);
        lexiftool_result_free(&r);
    }
    lexiftool_close(s);
    return NULL;
}

int main(int argc, char** argv)
{
    char canon[1024], nikon[1024], exiftooljpg[1024], casio[1024], copy[1100], copy2[1100];
    int iterations = argc > 3 ? atoi(argv[3]) : 20;
    lexiftool_options opt = { .struct_size = sizeof(opt) };
    const char* common[] = { "-G" };
    lexiftool_options optG = { .struct_size = sizeof(optG),
                               .common_argc = 1, .common_argv = common };
    lexiftool_session* s, *a, *b;
    lexiftool_result r, ref;
    lexiftool_info info, info2;
    int i, same, rc;
    char* v;
    size_t len;

    if (argc < 3) {
        fprintf(stderr, "usage: test_capi T_IMAGES_DIR SCRATCH_DIR [ITERATIONS]\n");
        return 2;
    }
    snprintf(canon, sizeof(canon), "%s/Canon.jpg", argv[1]);
    snprintf(nikon, sizeof(nikon), "%s/Nikon.jpg", argv[1]);
    snprintf(exiftooljpg, sizeof(exiftooljpg), "%s/ExifTool.jpg", argv[1]);
    snprintf(casio, sizeof(casio), "%s/Casio2.jpg", argv[1]);

    /* 0. without a session ------------------------------------------------ */
    ok(lexiftool_api_version() == LEXIFTOOL_API_VERSION, "api_version == LEXIFTOOL_API_VERSION");
    ok(lexiftool_version() != NULL && lexiftool_version()[0] != '\0', "version");
    ok(lexiftool_state(NULL) == LEXIFTOOL_E_ARG && lexiftool_last_error(NULL) == NULL, "NULL session: state, last_error");
    ok(exec1(NULL, &r, "-ver", NULL, NULL) == LEXIFTOOL_E_ARG && r.stdout_data && r.stdout_len == 0,
       "NULL session: execute, empty result");
    lexiftool_result_free(&r);
    ok(lexiftool_image_info(NULL, canon, NULL, 0, 0, &info) == LEXIFTOOL_E_ARG && info.count == 0,
       "NULL session: image_info");
    ok(lexiftool_set_option(NULL, "Sort", "File") == LEXIFTOOL_E_ARG &&
       lexiftool_set_new_value(NULL, "Artist", "x", LEXIFTOOL_NUL_TERMINATED) == LEXIFTOOL_E_ARG &&
       lexiftool_write_info(NULL, canon, NULL) == LEXIFTOOL_E_ARG, "NULL session: set_option, set_new_value, write_info");
    lexiftool_close(NULL);
    memset(&r, 0, sizeof(r)); lexiftool_result_free(&r);
    memset(&info, 0, sizeof(info)); lexiftool_info_free(&info);
    lexiftool_result_free(NULL); lexiftool_info_free(NULL);
    ok(1, "close/free of NULL and zeroed structs");
#ifdef LEXIFTOOL_TEST_EMBEDDED
    {   /* embedded build: the modules come from the library, not from the
         * paths (there is no way to make the start fail) */
        lexiftool_options bad = { .struct_size = sizeof(bad),
                                  .lua_path = "/nonexistent/?.lua", .lua_cpath = "/nonexistent/?.so" };
        lexiftool_session* f = lexiftool_open(&bad);
        ok(f != NULL && lexiftool_state(f) == LEXIFTOOL_OK && exec1(f, &r, "-ver", NULL, NULL) == LEXIFTOOL_OK &&
           r.status == 0, "embedded: the modules do not depend on lua_path/lua_cpath");
        lexiftool_result_free(&r);
        lexiftool_close(f);
    }
#else
    {   /* a failed start: no modules on the paths */
        lexiftool_options bad = { .struct_size = sizeof(bad),
                                  .lua_path = "/nonexistent/?.lua", .lua_cpath = "/nonexistent/?.so" };
        lexiftool_session* f = lexiftool_open(&bad);
        ok(f != NULL && lexiftool_state(f) == LEXIFTOOL_E_FAILED && lexiftool_last_error(f) != NULL &&
           strstr(lexiftool_last_error(f), "lexiftool") != NULL, "failed start: E_FAILED, message");
        ok(exec1(f, &r, "-ver", NULL, NULL) == LEXIFTOOL_E_FAILED &&
           lexiftool_image_info(f, canon, NULL, 0, 0, &info) == LEXIFTOOL_E_FAILED,
           "failed session: calls return E_FAILED");
        lexiftool_result_free(&r);
        lexiftool_close(f);
    }
#endif
    {   /* struct_size covers only the first fields: the rest counts as 0 */
        lexiftool_options part;
        memset(&part, 0xff, sizeof(part));      /* (garbage beyond struct_size) */
        part.struct_size = offsetof(lexiftool_options, common_argc);
        part.config_file = "";
        s = lexiftool_open(&part);
        ok(s != NULL && lexiftool_state(s) == LEXIFTOOL_OK, "struct_size: fields beyond it ignored");
        lexiftool_close(s);
    }

    /* 1. commands ----------------------------------------------------------- */
    s = lexiftool_open(&opt);
    ok(s != NULL && lexiftool_state(s) == LEXIFTOOL_OK && lexiftool_last_error(s) == NULL, "open");
    {   /* main.lua sets $SIG{INT}: must not reach the process */
        ok(tp_sigint_default(), "no process-wide SIGINT handler installed");
    }
    /* (--FileAccessDate: the first read may change it, see dump_info) */
    rc = exec1(s, &ref, "-j", "--FileAccessDate", canon);
    ok(rc == LEXIFTOOL_OK && ref.status == 0 && ref.stdout_len > 1000 &&
       strstr(ref.stdout_data, "{ready") == NULL, "execute -j Canon.jpg (no {ready})");
    same = 1;
    for (i = 0; i < iterations; i++) {
        rc = exec1(s, &r, "-j", "--FileAccessDate", canon);
        if (rc != LEXIFTOOL_OK || r.status != 0 || r.stdout_len != ref.stdout_len ||
            memcmp(r.stdout_data, ref.stdout_data, r.stdout_len) != 0 || r.stderr_len != 0)
            same = 0;
        lexiftool_result_free(&r);
    }
    ok(same, "same -j output on every iteration");
    rc = exec1(s, &r, "-ver", NULL, NULL);
    ok(rc == LEXIFTOOL_OK && r.status == 0 && strncmp(r.stdout_data, "13.", 3) == 0, "-ver");
    lexiftool_result_free(&r);
    rc = exec1(s, &r, "-j", "/nonexistent/file.jpg", NULL);
    ok(rc == LEXIFTOOL_OK && r.status == 1 && strstr(r.stderr_data, "File not found") != NULL,
       "missing file: status 1 and message on stderr");
    lexiftool_result_free(&r);
    rc = exec1(s, &r, "-echo4", "status=${status}", "-ver");
    ok(rc == LEXIFTOOL_OK && strcmp(r.stderr_data, "status=0\n") == 0, "-echo4 ${status} (of this command)");
    lexiftool_result_free(&r);
    rc = exec1(s, &r, "-echo", " two\nlines ", NULL);
    ok(rc == LEXIFTOOL_OK && strcmp(r.stdout_data, " two\nlines \n") == 0, "execute: arguments verbatim");
    lexiftool_result_free(&r);
    rc = lexiftool_execute(s, 0, NULL, &r);
    ok(rc == LEXIFTOOL_OK, "execute: empty argument list");
    lexiftool_result_free(&r);
    rc = lexiftool_execute(s, -1, NULL, &r);
    lexiftool_result_free(&r);
    ok(rc == LEXIFTOOL_E_ARG && lexiftool_execute(s, 1, NULL, &r) == LEXIFTOOL_E_ARG &&
       lexiftool_execute(s, 1, (const char* const[]){ "-ver" }, NULL) == LEXIFTOOL_E_ARG,
       "execute: bad arguments are E_ARG");
    lexiftool_result_free(&r);
    rc = exec1(s, &r, "-b", "-ThumbnailImage", exiftooljpg);
    ok(rc == LEXIFTOOL_OK && r.stdout_len > 1000 && memchr(r.stdout_data, 0, r.stdout_len) != NULL &&
       (unsigned char)r.stdout_data[0] == 0xFF && (unsigned char)r.stdout_data[1] == 0xD8,
       "execute -b -ThumbnailImage: JPEG bytes with NULs");

    /* 2. execute_text ------------------------------------------------------ */
    {
        lexiftool_result t;
        const char* text =
            "# a comment line\n"
            "   -echo\n"
            "  leading blanks removed\n"
            "\n"
            "#[CSTR]-echo\n"
            "#[CSTR]tab\\there, \\\"quoted\\\"\n"
            "-echo\n"
            "#[CSTR]two\\nlines\n"
            "-execute\n"
            "-echo4\n"
            "status=${status}\n"
            "-ver\n";
        const char* want = "leading blanks removed\ntab\there, \"quoted\"\ntwo\nlines\n13.";
        rc = lexiftool_execute_text(s, text, LEXIFTOOL_NUL_TERMINATED, &t);
        ok(rc == LEXIFTOOL_OK && t.status == 0 && strncmp(t.stdout_data, want, strlen(want)) == 0 &&
           strcmp(t.stderr_data, "status=0\n") == 0,
           "execute_text: comments, blanks, #[CSTR], two commands");
        lexiftool_result_free(&t);
        rc = lexiftool_execute_text(s, "-echo\nlast line without newline", LEXIFTOOL_NUL_TERMINATED, &t);
        ok(rc == LEXIFTOOL_OK && strcmp(t.stdout_data, "last line without newline\n") == 0,
           "execute_text: last line without newline");
        lexiftool_result_free(&t);
        rc = lexiftool_execute_text(s, "-ver\n-execute\n", LEXIFTOOL_NUL_TERMINATED, &t);
        ok(rc == LEXIFTOOL_OK && strncmp(t.stdout_data, "13.", 3) == 0 && strchr(t.stdout_data, '\n') ==
           t.stdout_data + t.stdout_len - 1, "execute_text: a final -execute ends the command");
        lexiftool_result_free(&t);
        rc = lexiftool_execute_text(s, "-ver\n-echo\nnot this", 5, &t);
        ok(rc == LEXIFTOOL_OK && strncmp(t.stdout_data, "13.", 3) == 0 && strstr(t.stdout_data, "not") == NULL,
           "execute_text: explicit length");
        lexiftool_result_free(&t);
        {
            char text2[1200];
            snprintf(text2, sizeof(text2), "-b\n-ThumbnailImage\n%s\n", exiftooljpg);
            rc = lexiftool_execute_text(s, text2, LEXIFTOOL_NUL_TERMINATED, &t);
            ok(rc == LEXIFTOOL_OK && t.stdout_len == r.stdout_len &&
               memcmp(t.stdout_data, r.stdout_data, r.stdout_len) == 0, "execute_text -b: same bytes as execute");
            lexiftool_result_free(&t);
        }
        ok(lexiftool_execute_text(s, NULL, 0, &t) == LEXIFTOOL_E_ARG && t.stdout_data != NULL,
           "execute_text: NULL text is E_ARG");
        lexiftool_result_free(&t);
    }

    /* 3. image_info -------------------------------------------------------- */
    rc = lexiftool_image_info(s, canon, NULL, 0, 0, &info);
    ok(rc == LEXIFTOOL_OK && info.count > 100 && strcmp(info.tags[0].name, "ExifToolVersion") == 0 &&
       info.error == NULL && info.warning == NULL, "image_info Canon.jpg: all tags, file order");
    {
        const lexiftool_tag* make = find_tag(&info, "Make", 0);
        const lexiftool_tag* fsize = find_tag(&info, "FileSize", 0);
        size_t k;
        int fields = 1;
        for (k = 0; k < info.count; k++) {
            const lexiftool_tag* t = &info.tags[k];
            if (!t->name || !t->group[0] || !t->group[1] || !t->group[2] || !t->desc || !t->id ||
                !t->value || !t->num || t->value[t->value_len] != '\0' || t->num[t->num_len] != '\0')
                fields = 0;
        }
        ok(fields, "image_info: no NULL field, values NUL-terminated");
        ok(make && strcmp(make->group[0], "EXIF") == 0 && strcmp(make->group[1], "IFD0") == 0 &&
           strcmp(make->group[2], "Camera") == 0 && strcmp(make->desc, "Make") == 0 &&
           strcmp(make->id, "271") == 0 && strcmp(make->value, "Canon") == 0 && make->copy_num == 0 &&
           make->binary == LEXIFTOOL_BINARY_NONE, "image_info: Make with groups, desc, id, value");
        ok(fsize && strcmp(fsize->value, "2.7 kB") == 0 && strcmp(fsize->num, "2697") == 0 &&
           fsize->num != fsize->value, "image_info: PrintConv value and ValueConv num");
        ok(find_tag(&info, "ExposureCompensation", 1) != NULL, "image_info: duplicate with copy_num 1");
    }
    {   /* the same with an empty tag list */
        const char* none[1] = { NULL };
        rc = lexiftool_image_info(s, canon, none, 0, 0, &info2);
        ok(rc == LEXIFTOOL_OK && info2.count == info.count, "image_info: empty tag list = all tags");
        lexiftool_info_free(&info2);
    }
    lexiftool_info_free(&info);
    {   /* requested tags: their order, duplicates, a group, ValueConv "#" */
        const char* tags[] = { "Model", "Make", "ExposureCompensation", "EXIF:Model", "FileSize#", "NoSuchTag" };
        rc = lexiftool_image_info(s, canon, tags, 6, 0, &info);
        ok(rc == LEXIFTOOL_OK && info.count >= 5 && strcmp(info.tags[0].name, "Model") == 0 &&
           strcmp(info.tags[1].name, "Make") == 0 && strcmp(info.tags[2].name, "ExposureCompensation") == 0 &&
           find_tag(&info, "ExposureCompensation", 1) != NULL && find_tag(&info, "NoSuchTag", 0) == NULL,
           "image_info with tags: requested order, duplicates, missing tag left out");
        {
            const lexiftool_tag* fs = find_tag(&info, "FileSize", 0);
            ok(fs && strcmp(fs->value, "2697") == 0, "image_info: TAG# gives the ValueConv value");
        }
        lexiftool_info_free(&info);
    }
    rc = lexiftool_image_info(s, "/nonexistent/file.jpg", NULL, 0, 0, &info);
    ok(rc == LEXIFTOOL_OK && info.error != NULL && strcmp(info.error, "Error opening file") == 0 &&
       find_tag(&info, "Error", 0) != NULL, "image_info: missing file gives the Error tag (as ImageInfo)");
    lexiftool_info_free(&info);
    ok(lexiftool_image_info(s, NULL, NULL, 0, 0, &info) == LEXIFTOOL_E_ARG &&
       lexiftool_image_info(s, canon, NULL, -1, 0, &info) == LEXIFTOOL_E_ARG &&
       lexiftool_image_info(s, canon, NULL, 0, 0, NULL) == LEXIFTOOL_E_ARG, "image_info: bad arguments are E_ARG");
    {   /* binary values: placeholder, by name, by flag */
        const char* thumb[] = { "ThumbnailImage" };
        const lexiftool_tag* t;
        rc = lexiftool_image_info(s, exiftooljpg, NULL, 0, 0, &info);
        t = find_tag(&info, "ThumbnailImage", 0);
        ok(rc == LEXIFTOOL_OK && t && t->binary == LEXIFTOOL_BINARY_HIDDEN && t->binary_len == r.stdout_len &&
           strcmp(t->value, "(Binary data 0 bytes, use -b option to extract)") != 0 &&
           strncmp(t->value, "(Binary data ", 13) == 0 && strstr(t->value, ", use -b option to extract)"),
           "image_info: binary value as placeholder with its length");
        ok(info.warning != NULL && strstr(info.warning, "IPTCDigest") != NULL, "image_info: warning");
        t = find_tag(&info, "JUMDLabel", 0);
        ok(t && t->value_len == 4 && memcmp(t->value, "cai\0", 4) == 0, "image_info: NUL byte inside a value");
        lexiftool_info_free(&info);
        rc = lexiftool_image_info(s, exiftooljpg, thumb, 1, 0, &info);
        ok(rc == LEXIFTOOL_OK && info.count == 1 && info.tags[0].binary == LEXIFTOOL_BINARY_DATA &&
           info.tags[0].value_len == r.stdout_len && info.tags[0].binary_len == r.stdout_len &&
           memcmp(info.tags[0].value, r.stdout_data, r.stdout_len) == 0 && info.tags[0].num == info.tags[0].value,
           "image_info: requested binary tag delivered (bytes as -b, num shared)");
        lexiftool_info_free(&info);
        rc = lexiftool_image_info(s, exiftooljpg, NULL, 0, LEXIFTOOL_INFO_BINARY, &info);
        t = find_tag(&info, "ThumbnailImage", 0);
        ok(rc == LEXIFTOOL_OK && t && t->binary == LEXIFTOOL_BINARY_DATA && t->value_len == r.stdout_len &&
           memcmp(t->value, r.stdout_data, r.stdout_len) == 0, "image_info: LEXIFTOOL_INFO_BINARY delivers all");
        lexiftool_info_free(&info);
    }
    rc = lexiftool_image_info(s, casio, (const char* const[]){ "FirmwareDate" }, 1, 0, &info);
    ok(rc == LEXIFTOOL_OK && info.count == 1 && info.tags[0].num_len == 18 &&
       memcmp(info.tags[0].num, "0302\0\0" "2809\0\0" "45\0\0\0\0", 18) == 0 && info.tags[0].num != info.tags[0].value,
       "image_info: NUL bytes in the ValueConv value");
    lexiftool_info_free(&info);

    lexiftool_result_free(&r);     /* (the thumbnail of section 1) */

    /* 4. set_option -------------------------------------------------------- */
    {
        const char* tags[] = { "FileSize" };
        ok(lexiftool_set_option(s, "PrintConv", "0") == LEXIFTOOL_OK, "set_option PrintConv 0");
        rc = lexiftool_image_info(s, canon, tags, 1, 0, &info);
        ok(rc == LEXIFTOOL_OK && info.count == 1 && strcmp(info.tags[0].value, "2697") == 0,
           "set_option PrintConv 0: value is ValueConv");
        lexiftool_info_free(&info);
        lexiftool_set_option(s, "PrintConv", "1");
        ok(lexiftool_set_option(s, "Duplicates", "0") == LEXIFTOOL_OK &&
           lexiftool_image_info(s, canon, NULL, 0, 0, &info) == LEXIFTOOL_OK &&
           find_tag(&info, "ExposureCompensation", 1) == NULL, "set_option Duplicates 0: no copies");
        lexiftool_info_free(&info);
        lexiftool_set_option(s, "Duplicates", "1");
        ok(lexiftool_set_option(s, "Sort", "Group0:1:2:4") == LEXIFTOOL_OK &&
           lexiftool_image_info(s, canon, NULL, 0, 0, &info) == LEXIFTOOL_OK && info.count > 2 &&
           strcmp(info.tags[4].name, "FilePermissions") == 0, "set_option Sort Group0:1:2:4: -php order");
        lexiftool_info_free(&info);
        ok(lexiftool_set_option(s, "Sort", NULL) == LEXIFTOOL_OK &&
           lexiftool_image_info(s, canon, NULL, 0, 0, &info) == LEXIFTOOL_OK &&
           strcmp(info.tags[4].name, "FilePermissions") != 0, "set_option NULL: back to file order");
        lexiftool_info_free(&info);
        ok(lexiftool_set_option(s, NULL, "1") == LEXIFTOOL_E_ARG, "set_option: NULL name is E_ARG");
        rc = exec1(s, &r, "-FileSize", canon, NULL);
        ok(rc == LEXIFTOOL_OK && strstr(r.stdout_data, "2.7 kB") != NULL, "options do not reach execute");
        lexiftool_result_free(&r);
    }

    /* 5. set_new_value / write_info ---------------------------------------- */
    snprintf(copy, sizeof(copy), "%s/write.jpg", argv[2]);
    snprintf(copy2, sizeof(copy2), "%s/write-out.jpg", argv[2]);
    remove(copy2);
    ok(tp_copy_file(canon, copy), "copy Canon.jpg");
    ok(lexiftool_set_new_value(s, "Artist", "Test Artist", LEXIFTOOL_NUL_TERMINATED) > 0 &&
       lexiftool_set_new_value(s, "XMP:Title", "x\ny", LEXIFTOOL_NUL_TERMINATED) > 0, "set_new_value: two tags");
    rc = lexiftool_set_new_value(s, "Bogus", "x", LEXIFTOOL_NUL_TERMINATED);
    ok(rc == 0 && lexiftool_last_error(s) != NULL && strstr(lexiftool_last_error(s), "Bogus") != NULL,
       "set_new_value: unknown tag is 0 with a message");
    ok(lexiftool_set_new_value(s, "Comment", "a\0b", 3) > 0, "set_new_value: value with a NUL byte");
    rc = lexiftool_write_info(s, copy, NULL);
    ok(rc == 1, "write_info in place: 1");
    v = read_value(s, copy, "Artist", NULL);
    ok(v && strcmp(v, "Test Artist") == 0, "write_info: Artist read back");
    free(v);
    v = read_value(s, copy, "XMP:Title", NULL);
    ok(v && strcmp(v, "x\ny") == 0, "write_info: newline in a value read back");
    free(v);
    v = read_value(s, copy, "Comment", &len);
    ok(v && len == 3 && memcmp(v, "a\0b", 3) == 0, "write_info: NUL byte in a value read back");
    free(v);
    rc = exec1(s, &r, "-s3", "-Artist", copy);
    ok(rc == LEXIFTOOL_OK && strcmp(r.stdout_data, "Test Artist\n") == 0, "write_info: seen by execute");
    lexiftool_result_free(&r);
    rc = lexiftool_write_info(s, copy, copy2);
    ok(rc == 1, "write_info to outfile: 1 (new values kept for a second write)");
    v = read_value(s, copy2, "Artist", NULL);
    ok(v && strcmp(v, "Test Artist") == 0, "write_info to outfile: read back");
    free(v);
    rc = lexiftool_write_info(s, copy, copy2);
    ok(rc == 0 && lexiftool_last_error(s) && strstr(lexiftool_last_error(s), "exists"),
       "write_info: existing outfile is 0 with the Error");
    ok(lexiftool_set_new_value(s, NULL, NULL, 0) >= 0, "set_new_value NULL: clears all");
    ok(lexiftool_set_new_value(s, "Artist", NULL, 0) > 0, "set_new_value: NULL value deletes");
    rc = lexiftool_write_info(s, copy, NULL);
    v = read_value(s, copy, "Artist", NULL);
    ok(rc == 1 && v == NULL, "write_info: tag deleted");
    free(v);
    v = read_value(s, copy, "XMP:Title", NULL);
    ok(v && strcmp(v, "x\ny") == 0, "write_info: the cleared values were not written again");
    free(v);
    {   /* a binary value, through set_new_value, from image_info */
        const char* thumb[] = { "ThumbnailImage" };
        lexiftool_set_new_value(s, NULL, NULL, 0);
        rc = lexiftool_image_info(s, exiftooljpg, thumb, 1, 0, &info);
        ok(rc == LEXIFTOOL_OK && info.count == 1 &&
           lexiftool_set_new_value(s, "ThumbnailImage", info.tags[0].value, info.tags[0].value_len) > 0 &&
           lexiftool_write_info(s, copy, NULL) == 1, "set_new_value: binary value written");
        rc = lexiftool_image_info(s, copy, thumb, 1, 0, &info2);
        ok(rc == LEXIFTOOL_OK && info2.count == 1 && info2.tags[0].value_len == info.tags[0].value_len &&
           memcmp(info2.tags[0].value, info.tags[0].value, info.tags[0].value_len) == 0,
           "set_new_value: binary value read back byte for byte");
        lexiftool_info_free(&info);
        lexiftool_info_free(&info2);
        lexiftool_set_new_value(s, NULL, NULL, 0);
    }
    rc = lexiftool_write_info(s, "/nonexistent/file.jpg", NULL);
    ok(rc == 2, "write_info without new values: 2 (as WriteInfo, even for a missing file)");
    lexiftool_set_new_value(s, "Artist", "x", LEXIFTOOL_NUL_TERMINATED);
    rc = lexiftool_write_info(s, "/nonexistent/file.jpg", NULL);
    ok(rc == 0 && lexiftool_last_error(s) != NULL && strcmp(lexiftool_last_error(s), "Error opening file") == 0,
       "write_info: missing file is 0 with the Error");
    lexiftool_set_new_value(s, NULL, NULL, 0);
    ok(lexiftool_write_info(s, NULL, NULL) == LEXIFTOOL_E_ARG, "write_info: NULL file is E_ARG");

    /* 5b. a file name outside ASCII ----------------------------------------
     * Names are bytes, as for exiftool: with CharsetFileName UTF8 (the
     * option of the object, -charset filename=utf8 for a command) a UTF-8
     * name works everywhere -- on Windows through the wide file API. */
    {
        const char* uname = "Gr\xc3\xbc\xc3\x9f""e \xe2\x82\xac.jpg";     /* "Grüße €.jpg" */
        char upath[1200], want[64];
        const char* fname[] = { "FileName" };
        FILE* f;
        snprintf(upath, sizeof(upath), "%s/%s", argv[2], uname);
        if ((f = tp_fopen_utf8(upath, "wb")) != NULL) {     /* a copy of Canon.jpg */
            FILE* in = fopen(canon, "rb");
            char tmp[8192];
            size_t n;
            while (in && (n = fread(tmp, 1, sizeof(tmp), in)) > 0) fwrite(tmp, 1, n, f);
            if (in) fclose(in);
            fclose(f);
        }
        ok(f != NULL, "UTF-8 file name: file created");
        ok(lexiftool_set_option(s, "CharsetFileName", "UTF8") == LEXIFTOOL_OK &&
           lexiftool_image_info(s, upath, fname, 1, 0, &info) == LEXIFTOOL_OK && info.error == NULL &&
           info.count == 1 && strcmp(info.tags[0].value, uname) == 0,
           "UTF-8 file name: image_info with CharsetFileName UTF8");
        lexiftool_info_free(&info);
        ok(lexiftool_set_new_value(s, "Artist", "unicode", LEXIFTOOL_NUL_TERMINATED) > 0 &&
           lexiftool_write_info(s, upath, NULL) == 1, "UTF-8 file name: write_info");
        lexiftool_set_new_value(s, NULL, NULL, 0);
        v = read_value(s, upath, "Artist", NULL);
        ok(v && strcmp(v, "unicode") == 0, "UTF-8 file name: written value read back");
        free(v);
        lexiftool_set_option(s, "CharsetFileName", NULL);
        {
            const char* a[] = { "-charset", "filename=utf8", "-s3", "-FileName", "-Artist", upath };
            snprintf(want, sizeof(want), "%s\nunicode\n", uname);
            rc = lexiftool_execute(s, 6, a, &r);
            ok(rc == LEXIFTOOL_OK && r.status == 0 && strcmp(r.stdout_data, want) == 0 && r.stderr_len == 0,
               "UTF-8 file name: a command with -charset filename=utf8");
            lexiftool_result_free(&r);
        }
    }

    /* 6. two sessions, used alternately -------------------------------------
     * Each session runs ROUNDS x (-j Canon.jpg, -s Nikon.jpg); b with the
     * common argument -G. Reference: the same sequence, each in a session
     * of its own, run one after the other. (The -j output is not the same
     * in every round: like exiftool's, the Composite tag order depends on
     * the files processed before in the same process.) */
    {
        enum { ROUNDS = 5 };
        lexiftool_result want[2][ROUNDS];
        const lexiftool_options* o[2] = { &opt, &optG };
        lexiftool_session* x[2];
        int k, j;

        memset(want, 0, sizeof(want));
        same = 1;
        for (j = 0; j < 2; j++) {
            lexiftool_session* t2 = lexiftool_open(o[j]);
            for (k = 0; k < ROUNDS; k++) {
                if (exec1(t2, &want[j][k], "-j", canon, NULL) != LEXIFTOOL_OK) same = 0;
                if (exec1(t2, &r, "-s", nikon, NULL) != LEXIFTOOL_OK) same = 0;
                lexiftool_result_free(&r);
            }
            lexiftool_close(t2);
        }
        ok(same && strstr(want[1][0].stdout_data, "\"EXIF:Make\"") != NULL &&
           strstr(want[0][0].stdout_data, "\"EXIF:Make\"") == NULL &&
           strstr(want[1][ROUNDS - 1].stdout_data, "\"EXIF:Make\"") != NULL,
           "common_args applied to every command");
        a = lexiftool_open(&opt);
        b = lexiftool_open(&optG);
        x[0] = a;
        x[1] = b;
        for (k = 0; k < ROUNDS; k++) {
            for (j = 0; j < 2; j++) {
                rc = exec1(x[j], &r, "-j", canon, NULL);
                if (rc != LEXIFTOOL_OK || r.stdout_len != want[j][k].stdout_len ||
                    memcmp(r.stdout_data, want[j][k].stdout_data, r.stdout_len) != 0) same = 0;
                lexiftool_result_free(&r);
            }
            for (j = 0; j < 2; j++) {
                rc = exec1(x[j], &r, "-s", nikon, NULL);
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

    /* 7. threads, a session each ------------------------------------------- */
    {
#if defined(_WIN32)
        /* (the C runtime's TZ syntax: it knows no zone names) */
        static const char* const zones[NTHREADS] = { "UTC0", "EST5EDT", "JST-9", "CET-1CEST" };
#else
        static const char* const zones[NTHREADS] = { "UTC", "America/New_York", "Asia/Tokyo", "Europe/Berlin" };
#endif
        job alone[NTHREADS], par[NTHREADS];
        tp_thread th[NTHREADS];
        int k;
        same = 1;
        for (k = 0; k < NTHREADS; k++) {
            alone[k] = (job){ argv[1], zones[k], NULL, 0 };
            par[k] = alone[k];
            run_job(&alone[k]);
            if (alone[k].rc != LEXIFTOOL_OK || strlen(alone[k].out) < 1000) same = 0;
        }
        ok(same && strcmp(alone[0].out, alone[1].out) != 0, "threads: reference runs (zones differ)");
        for (k = 0; k < NTHREADS; k++)
            if (tp_thread_start(&th[k], run_job, &par[k]) != 0) same = 0;
        for (k = 0; k < NTHREADS; k++) tp_thread_join(th[k]);
        for (k = 0; k < NTHREADS; k++) {
            if (par[k].rc != LEXIFTOOL_OK || strcmp(par[k].out, alone[k].out) != 0) same = 0;
            free(par[k].out);
            free(alone[k].out);
        }
        ok(same, "threads: each session's results as when run alone");
    }

    /* 8. the end of a session ----------------------------------------------- */
    rc = exec1(s, &r, "-stay_open", "False", NULL);
    ok(rc == LEXIFTOOL_E_ENDED && lexiftool_state(s) == LEXIFTOOL_E_ENDED, "-stay_open False ends the session");
    lexiftool_result_free(&r);
    rc = exec1(s, &r, "-ver", NULL, NULL);
    ok(rc == LEXIFTOOL_E_ENDED && r.stdout_data && r.stdout_len == 0 &&
       lexiftool_image_info(s, canon, NULL, 0, 0, &info) == LEXIFTOOL_E_ENDED &&
       lexiftool_write_info(s, copy, NULL) == LEXIFTOOL_E_ENDED, "no call after the end");
    lexiftool_result_free(&r);
    lexiftool_close(s);
    lexiftool_result_free(&ref);

    /* 9. repeated open/close ----------------------------------------------- */
    same = 1;
    for (i = 0; i < 5; i++) {
        s = lexiftool_open(&opt);
        rc = exec1(s, &r, "-ver", NULL, NULL);
        if (rc != LEXIFTOOL_OK) same = 0;
        lexiftool_result_free(&r);
        if (lexiftool_image_info(s, canon, NULL, 0, 0, &info) != LEXIFTOOL_OK) same = 0;
        lexiftool_info_free(&info);
        lexiftool_close(s);
    }
    ok(same, "5x open/execute/image_info/close");

    printf("# %d tests, %d failed\n", total, failed);
    return failed ? 1 : 0;
}
