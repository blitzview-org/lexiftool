/*
 * ctime_fake.c -- LD_PRELOAD shim for the CLI comparison harness.
 *
 * exiftool reports "File Inode Change Date/Time" from the kernel's stat(2)
 * st_ctime, which is stamped to the wall clock at copy/touch time and cannot
 * be faked by libfaketime (that only intercepts libc time functions, not the
 * kernel stat path). This shim overrides the stat family so that every
 * caller sees a fixed ctime (2099-01-01 00:00:00 local), making the value
 * reproducible across reference-build and test runs without stripping dates
 * from the output.
 *
 * st_ctime and (for statx) stx_btime are rewritten; mtime/atime stay under
 * the harness' set_times() control. The shim is inherited by every child (perl exiftool, lua), so a
 * single LD_PRELOAD on the harness covers both sides of the comparison.
 *
 * Build: gcc -shared -fPIC -o ctime_fake.so ctime_fake.c -ldl
 */

#define _GNU_SOURCE
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/sysmacros.h>
#include <time.h>
#include <dlfcn.h>
#include <string.h>

static time_t g_fixed_ctime = 0;

__attribute__((constructor))
static void ctime_fake_init(void) {
    struct tm t;
    memset(&t, 0, sizeof(t));
    t.tm_year = 2099 - 1900;
    t.tm_mon = 0;
    t.tm_mday = 1;
    t.tm_hour = 0;
    t.tm_min = 0;
    t.tm_sec = 0;
    t.tm_isdst = -1;
    g_fixed_ctime = mktime(&t);
}

/* glibc x86_64 uses a single 64-bit struct stat for stat and stat64; the
 * layouts are identical, so a void* helper covers both. */
static void fix_stat(void *vb) {
    struct stat *s = (struct stat *) vb;
    if (!s) return;
    s->st_ctime = g_fixed_ctime;
    s->st_ctim.tv_nsec = 0;
}

static void fix_statx(void *vb) {
    struct statx *x = (struct statx *) vb;
    if (!x) return;
    x->stx_ctime.tv_sec = (typeof(x->stx_ctime.tv_sec)) g_fixed_ctime;
    x->stx_ctime.tv_nsec = 0;
    /* File::StatX may expose the birth time as FileCreateDate (ExifTool.pm
     * only does so when the module is installed), so pin that as well. */
    x->stx_btime.tv_sec = (typeof(x->stx_btime.tv_sec)) g_fixed_ctime;
    x->stx_btime.tv_nsec = 0;
}

#define FWD(name, ret, params, call, fix)                                   \
    static ret (*real_##name) params;                                       \
    ret name params {                                                       \
        if (!real_##name) real_##name = (ret (*) params) dlsym(RTLD_NEXT, #name); \
        ret r = real_##name call;                                           \
        if (r == 0) fix;                                                    \
        return r;                                                           \
    }

FWD(stat, int, (const char *p, struct stat *b), (p, b), fix_stat(b))
FWD(lstat, int, (const char *p, struct stat *b), (p, b), fix_stat(b))
FWD(fstat, int, (int fd, struct stat *b), (fd, b), fix_stat(b))
FWD(fstatat, int, (int dfd, const char *p, struct stat *b, int f), (dfd, p, b, f), fix_stat(b))
FWD(__xstat, int, (int v, const char *p, struct stat *b), (v, p, b), fix_stat(b))
FWD(__lxstat, int, (int v, const char *p, struct stat *b), (v, p, b), fix_stat(b))
FWD(__fxstat, int, (int v, int fd, struct stat *b), (v, fd, b), fix_stat(b))
FWD(statx, int, (int dfd, const char *p, int flags, unsigned int mask, struct statx *b), (dfd, p, flags, mask, b), fix_statx(b))

FWD(stat64, int, (const char *p, struct stat64 *b), (p, b), fix_stat(b))
FWD(lstat64, int, (const char *p, struct stat64 *b), (p, b), fix_stat(b))
FWD(fstat64, int, (int fd, struct stat64 *b), (fd, b), fix_stat(b))
FWD(fstatat64, int, (int dfd, const char *p, struct stat64 *b, int f), (dfd, p, b, f), fix_stat(b))
FWD(__xstat64, int, (int v, const char *p, struct stat64 *b), (v, p, b), fix_stat(b))
FWD(__lxstat64, int, (int v, const char *p, struct stat64 *b), (v, p, b), fix_stat(b))
FWD(__fxstat64, int, (int v, int fd, struct stat64 *b), (v, fd, b), fix_stat(b))
FWD(__fxstatat, int, (int v, int dfd, const char *p, struct stat *b, int f), (v, dfd, p, b, f), fix_stat(b))
FWD(__fxstatat64, int, (int v, int dfd, const char *p, struct stat64 *b, int f), (v, dfd, p, b, f), fix_stat(b))
