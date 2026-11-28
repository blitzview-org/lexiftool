/*------------------------------------------------------------------------------
 * File:         capi/test_threads.c
 *
 * Description:  Thread test of the lexiftool C API (Linux, macOS, Windows;
 *               on Linux also under ThreadSanitizer): NTHREADS threads, each with a
 *               session of its own, run a mixed sequence -- image_info and
 *               commands over a share of t/images with a time zone of their
 *               own (the object's TimeZone option, -api TimeZone in the
 *               common arguments or in each command, or none), -d with %Z,
 *               -lang de, the Geolocation feature, set_new_value/write_info
 *               and a writing command on copies of their own, and repeated
 *               open/close. Every thread's output is first produced by the
 *               same sequence run alone, one thread after the other; the
 *               parallel run must give the same bytes.
 *               Usage: test_threads T_IMAGES_DIR SCRATCH_DIR [NTHREADS [SHARE]]
 *                 SHARE: thread k takes the files whose index i in the
 *                 sorted directory listing has i % SHARE == k % SHARE
 *                 (default 2: every file is read by NTHREADS/2 threads)
 *               Writes each thread's output to SCRATCH_DIR/threadK.alone,
 *               and, where it differs, the parallel one to .parallel.
 *------------------------------------------------------------------------------
 */

#include "test_platform.h"
#include "lexiftool.h"

enum { MAXTHREADS = 32 };

/* a growing byte buffer (the whole output of one thread) */
typedef struct { char* p; size_t n, cap; int oom; } buf;

static void put(buf* b, const char* data, size_t len)
{
    if (b->oom) return;
    if (b->n + len + 1 > b->cap) {
        size_t cap = b->cap ? b->cap : 65536;
        char* p;
        while (cap < b->n + len + 1) cap *= 2;
        if ((p = realloc(b->p, cap)) == NULL) { b->oom = 1; return; }
        b->p = p;
        b->cap = cap;
    }
    if (len) memcpy(b->p + b->n, data, len);
    b->n += len;
    b->p[b->n] = '\0';
}

static void puts_(buf* b, const char* s) { put(b, s, strlen(s)); }

static void putf(buf* b, const char* fmt, int a, const char* s)
{
    char tmp[2200];
    snprintf(tmp, sizeof(tmp), fmt, a, s);
    puts_(b, tmp);
}

/* ---------------------------------------------------------------------------
 * One thread's sequence
 */

typedef struct {
    int          k;          /* thread number */
    const char*  images;     /* t/images */
    const char*  scratch;    /* the thread's own directory */
    char**       files;      /* t/images listing */
    int          nfiles, share;
    buf          out;        /* everything the sequence produced */
} job;

/* the time zones of the threads: NULL is the process's own zone */
static const char* const zones[] = {
    "UTC", "America/New_York", "Asia/Tokyo", "Europe/Berlin",
    "EST5EDT", "<+0530>-5:30", "Australia/Lord_Howe", NULL,
};
enum { NZONES = sizeof(zones) / sizeof(zones[0]) };

static const char* const DATEFMT = "%Y-%m-%d %H:%M:%S %Z %z";

/* appends a command's result (stdout, stderr, status) */
static void put_result(buf* b, int rc, const lexiftool_result* r)
{
    putf(b, "== rc %d %s\n", rc, "");
    put(b, r->stdout_data, r->stdout_len);
    puts_(b, "-- stderr\n");
    put(b, r->stderr_data, r->stderr_len);
    putf(b, "-- status %d%s\n", r->status, "");
}

/* runs argv (plus the zone arguments, per command for odd threads) */
static void run(job* j, lexiftool_session* s, int argc, const char** argv)
{
    const char* zone = zones[j->k % NZONES];
    const char* v[32];
    char tzarg[128];
    lexiftool_result r;
    int n = 0, i, rc;
    if (zone != NULL && j->k % 2 == 1) {
        snprintf(tzarg, sizeof(tzarg), "TimeZone=%s", zone);
        v[n++] = "-api";
        v[n++] = tzarg;
    }
    for (i = 0; i < argc && n < 32; i++) v[n++] = argv[i];
    rc = lexiftool_execute(s, n, v, &r);
    put_result(&j->out, rc, &r);
    lexiftool_result_free(&r);
}

/* appends every entry of an image_info except FileAccessDate (which
 * reading changes) */
static void put_info(buf* b, int rc, const lexiftool_info* info)
{
    size_t i;
    putf(b, "== info rc %d %s\n", rc, "");
    for (i = 0; i < info->count; i++) {
        const lexiftool_tag* t = &info->tags[i];
        char head[1024];
        if (strcmp(t->name, "FileAccessDate") == 0) continue;
        snprintf(head, sizeof(head), "%s|%s|%s|%s|%s|%s|%d|%d|%zu|", t->name,
                 t->group[0], t->group[1], t->group[2], t->desc, t->id,
                 t->copy_num, t->binary, t->binary_len);
        puts_(b, head);
        put(b, t->value, t->value_len);
        puts_(b, "|");
        put(b, t->num, t->num_len);
        puts_(b, "\n");
    }
}

static void* run_job(void* arg)
{
    job* j = arg;
    const char* zone = zones[j->k % NZONES];
    char tzarg[128], path[2048], copy[2048], copy2[2048], title[64];
    const char* common[2];
    lexiftool_options opt = { .struct_size = sizeof(opt) };
    lexiftool_session* s;
    lexiftool_info info;
    int i, rc;

    /* even threads: -api TimeZone in the common arguments */
    if (zone != NULL && j->k % 2 == 0) {
        snprintf(tzarg, sizeof(tzarg), "TimeZone=%s", zone);
        common[0] = "-api";
        common[1] = tzarg;
        opt.common_argc = 2;
        opt.common_argv = common;
    }
    s = lexiftool_open(&opt);
    if (s == NULL || lexiftool_state(s) != LEXIFTOOL_OK) {
        putf(&j->out, "open failed %d %s\n", 0, s ? lexiftool_last_error(s) : "");
        lexiftool_close(s);
        return NULL;
    }
    /* the session's object: its time zone, a date format with %Z, and the
     * language for half of the threads */
    if (zone != NULL) putf(&j->out, "TimeZone %d%s\n", lexiftool_set_option(s, "TimeZone", zone), "");
    putf(&j->out, "DateFormat %d%s\n", lexiftool_set_option(s, "DateFormat", DATEFMT), "");
    if (j->k % 4 < 2) putf(&j->out, "Lang %d%s\n", lexiftool_set_option(s, "Lang", "de"), "");

    /* 1. the thread's share of t/images: image_info and a command */
    for (i = 0; i < j->nfiles; i++) {
        if (i % j->share != j->k % j->share) continue;
        snprintf(path, sizeof(path), "%s/%s", j->images, j->files[i]);
        putf(&j->out, "### %d %s\n", i, j->files[i]);
        rc = lexiftool_image_info(s, path, NULL, 0, 0, &info);
        put_info(&j->out, rc, &info);
        lexiftool_info_free(&info);
        {
            const char* v[] = { "-G1", "-s", "-d", DATEFMT, "-lang", (j->k % 4 < 2) ? "de" : "en",
                                "--FileAccessDate", path };
            run(j, s, 8, v);
        }
    }

    /* 2. Geolocation (reverse geocoding of GPS.jpg, and a city by name) */
    snprintf(path, sizeof(path), "%s/GPS.jpg", j->images);
    {
        const char* v[] = { "-api", "Geolocation", "-G", "-s", "-Geolocation*", path };
        run(j, s, 6, v);
    }
    {
        const char* v[] = { "-api", "Geolocation=Paris,FR", "-G", "-s", "-Geolocation*", path };
        run(j, s, 6, v);
    }

    /* 3. writing, on copies of the thread's own */
    snprintf(path, sizeof(path), "%s/Writer.jpg", j->images);
    snprintf(copy, sizeof(copy), "%s/w.jpg", j->scratch);
    snprintf(copy2, sizeof(copy2), "%s/w2.jpg", j->scratch);
    remove(copy2);
    if (!tp_copy_file(path, copy)) puts_(&j->out, "copy failed\n");
    snprintf(title, sizeof(title), "thread %d", j->k);
    putf(&j->out, "snv %d%s\n", lexiftool_set_new_value(s, "Artist", title, LEXIFTOOL_NUL_TERMINATED), "");
    putf(&j->out, "snv %d%s\n", lexiftool_set_new_value(s, "XMP:Title", title, LEXIFTOOL_NUL_TERMINATED), "");
    putf(&j->out, "snv %d%s\n", lexiftool_set_new_value(s, "DateTimeOriginal", "2021:03:28 02:30:00",
                                                       LEXIFTOOL_NUL_TERMINATED), "");
    putf(&j->out, "write %d%s\n", lexiftool_write_info(s, copy, NULL), "");
    putf(&j->out, "write %d%s\n", lexiftool_write_info(s, copy, copy2), "");
    lexiftool_set_new_value(s, NULL, NULL, 0);
    {
        const char* v[] = { "-overwrite_original", "-Comment=written by a command",
                            "-geolocate=Berlin,DE", copy };
        run(j, s, 4, v);
    }
    {
        const char* tags[] = { "Artist", "Title", "DateTimeOriginal", "Comment", "GPSLatitude",
                               "GPSLongitude", "XMP:City" };
        rc = lexiftool_image_info(s, copy, tags, 7, 0, &info);
        put_info(&j->out, rc, &info);
        lexiftool_info_free(&info);
        rc = lexiftool_image_info(s, copy2, tags, 7, 0, &info);
        put_info(&j->out, rc, &info);
        lexiftool_info_free(&info);
    }
    {
        const char* v[] = { "-G", "-s", "-d", DATEFMT, "-lang", "de", "-Artist", "-Title",
                            "-DateTimeOriginal", "-Comment", "-GPS*", copy };
        run(j, s, 12, v);
    }
    /* 4. error cases: a missing file, a bad option value */
    {
        const char* v[] = { "-s", "/nonexistent/file.jpg" };
        run(j, s, 2, v);
    }
    {
        const char* v[] = { "-api", "TimeZone=Not/AZone", "-d", DATEFMT, "-s", "-DateTimeOriginal", copy };
        run(j, s, 7, v);
    }
    lexiftool_close(s);

    /* 5. open/close in a row */
    for (i = 0; i < 3; i++) {
        lexiftool_result r;
        const char* v[] = { "-ver" };
        s = lexiftool_open(NULL);
        rc = lexiftool_execute(s, 1, v, &r);
        put_result(&j->out, rc, &r);
        lexiftool_result_free(&r);
        lexiftool_close(s);
    }
    return NULL;
}

int main(int argc, char** argv)
{
    int nthreads = argc > 3 ? atoi(argv[3]) : 8;
    int share = argc > 4 ? atoi(argv[4]) : 2;
    job alone[MAXTHREADS], par[MAXTHREADS];
    tp_thread th[MAXTHREADS];
    char** files;
    char dir[1100];
    int nfiles = 0, k, failed = 0;

    if (argc < 3 || nthreads < 1 || nthreads > MAXTHREADS || share < 1) {
        fprintf(stderr, "usage: test_threads T_IMAGES_DIR SCRATCH_DIR [NTHREADS [SHARE]]\n");
        return 2;
    }
    if ((files = tp_list_files(argv[1], &nfiles)) == NULL || nfiles == 0) {
        fprintf(stderr, "test_threads: no files in %s\n", argv[1]);
        return 2;
    }
    for (k = 0; k < nthreads; k++) {
        snprintf(dir, sizeof(dir), "%s/thread%d", argv[2], k);
        tp_mkdir(dir);
        alone[k] = (job){ k, argv[1], NULL, files, nfiles, share, { 0 } };
        alone[k].scratch = strdup(dir);
        par[k] = alone[k];
    }
    /* the reference: one thread after the other */
    for (k = 0; k < nthreads; k++) run_job(&alone[k]);
    /* the same, all threads at once */
    for (k = 0; k < nthreads; k++)
        if (tp_thread_start(&th[k], run_job, &par[k]) != 0) {
            fprintf(stderr, "test_threads: cannot start a thread\n");
            return 2;
        }
    for (k = 0; k < nthreads; k++) tp_thread_join(th[k]);

    for (k = 0; k < nthreads; k++) {
        const buf* a = &alone[k].out, *p = &par[k].out;
        int same = !a->oom && !p->oom && a->n == p->n && memcmp(a->p, p->p, a->n) == 0;
        char name[1200];
        FILE* f;
        snprintf(name, sizeof(name), "%s/thread%d.alone", argv[2], k);
        if ((f = fopen(name, "wb")) != NULL) { fwrite(a->p, 1, a->n, f); fclose(f); }
        if (!same) {
            size_t i = 0;
            while (i < a->n && i < p->n && a->p[i] == p->p[i]) i++;
            snprintf(name, sizeof(name), "%s/thread%d.parallel", argv[2], k);
            if ((f = fopen(name, "wb")) != NULL) { fwrite(p->p, 1, p->n, f); fclose(f); }
            printf("not ok %d - thread %d (zone %s): differs from the run alone at byte %zu"
                   " (thread%d.alone/.parallel)\n", k + 1, k,
                   zones[k % NZONES] ? zones[k % NZONES] : "(process)", i, k);
            failed++;
        } else {
            printf("ok %d - thread %d (zone %s): %zu bytes, as when run alone\n", k + 1, k,
                   zones[k % NZONES] ? zones[k % NZONES] : "(process)", a->n);
        }
        free(alone[k].out.p);
        free(par[k].out.p);
        free((char*)alone[k].scratch);
    }
    for (k = 0; k < nfiles; k++) free(files[k]);
    free(files);
    printf("# %d threads, %d failed\n", nthreads, failed);
    return failed ? 1 : 0;
}
